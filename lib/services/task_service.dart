import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import '../models/queued_task.dart';
import '../adapters/cloud_adapter.dart'; // Import the interface
import '../models/cloud_node.dart';
import '../models/encrypted_file_mapping.dart';
import '../services/security_service.dart';
import '../services/hive_storage_service.dart';
import '../services/rust_folder_scanner.dart';
import '../services/rust_file_operations_service.dart';
import '../services/unified_copy_service.dart';
import '../services/encryption_name_service.dart';

/// Represents a single item to be uploaded (file or folder) for parallel processing
class FolderUploadItem {
  final String localPath;
  final String relativePath; // Path relative to root folder
  final bool isFolder;
  final int size; // File size in bytes (0 for folders)
  final List<String> pathSegments; // Path segments for hierarchy

  FolderUploadItem({
    required this.localPath,
    required this.relativePath,
    required this.isFolder,
    this.size = 0,
    required this.pathSegments,
  });

  String get name => localPath.split(Platform.pathSeparator).last;
}

/// Represents a single item to be downloaded (file or folder) for parallel processing
class FolderDownloadItem {
  final String cloudId;
  final String name;
  final String relativePath; // Path relative to root folder
  final bool isFolder;
  final int size; // File size in bytes (0 for folders)

  FolderDownloadItem({
    required this.cloudId,
    required this.name,
    required this.relativePath,
    required this.isFolder,
    this.size = 0,
  });
}

/// Semaphore for controlling concurrent operations
class _Semaphore {
  final int maxCount;
  int _currentCount;
  final Queue<Completer<void>> _waitQueue = Queue<Completer<void>>();

  _Semaphore(this.maxCount) : _currentCount = maxCount;

  Future<void> acquire() async {
    if (_currentCount > 0) {
      _currentCount--;
      return;
    }

    final completer = Completer<void>();
    _waitQueue.add(completer);
    return completer.future;
  }

  void release() {
    if (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeFirst();
      completer.complete();
    } else {
      _currentCount++;
    }
  }
}

/// Represents a single file to be uploaded for batch processing
class FileUploadItem {
  final File originalFile;
  final File fileToUpload;
  final String originalName;
  final String uploadName;
  final bool isEncrypted;

  FileUploadItem({
    required this.originalFile,
    required this.fileToUpload,
    required this.originalName,
    required this.uploadName,
    required this.isEncrypted,
  });
}

/// Represents a single file to be downloaded for batch processing
class FileDownloadItem {
  final String fileId;
  final String fileName;
  final String savePath;
  final bool shouldDecrypt;

  FileDownloadItem({
    required this.fileId,
    required this.fileName,
    required this.savePath,
    required this.shouldDecrypt,
  });
}

class TaskService extends ChangeNotifier {
  // Singleton
  static final TaskService instance = TaskService._init();
  TaskService._init();
  
  final List<QueuedTask> _tasks = [];
  final Set<String> _processingTasks = {}; // Track actively processing tasks
  bool _isProcessing = false;
  
  // Parallel processing configuration
  static int _maxConcurrentTasks = 15; // Configurable limit (default: 15)
  static int _maxConcurrentTransfersPerAccount = 3; // Per-account limit (default: 3)
  static int _maxConcurrentTransfersSameAccount = 5; // Same-account limit (default: 5)
  static const int MEMORY_STREAMING_THRESHOLD = 50 * 1024 * 1024; // 50MB threshold for memory streaming
  
  // Getters for task limits
  int get MAX_CONCURRENT_TASKS => _maxConcurrentTasks;
  int get MAX_CONCURRENT_TRANSFERS_PER_ACCOUNT => _maxConcurrentTransfersPerAccount;
  int get MAX_CONCURRENT_TRANSFERS_SAME_ACCOUNT => _maxConcurrentTransfersSameAccount;
  
  /// Set task limits and save to storage
  Future<void> setTaskLimits({
    required int maxConcurrentTasks,
    required int maxConcurrentTransfersPerAccount,
    required int maxConcurrentTransfersSameAccount,
  }) async {
    // Validate limits (must be between 1 and 20)
    _maxConcurrentTasks = maxConcurrentTasks.clamp(1, 20);
    _maxConcurrentTransfersPerAccount = maxConcurrentTransfersPerAccount.clamp(1, 20);
    _maxConcurrentTransfersSameAccount = maxConcurrentTransfersSameAccount.clamp(1, 20);
    
    // Save to Hive
    await HiveStorageService.instance.saveTaskLimits(
      maxConcurrentTasks: _maxConcurrentTasks,
      maxConcurrentTransfersPerAccount: _maxConcurrentTransfersPerAccount,
      maxConcurrentTransfersSameAccount: _maxConcurrentTransfersSameAccount,
    );
    
  }
  
  /// Load task limits from Hive storage
  Future<void> loadTaskLimits() async {
    final limits = await HiveStorageService.instance.getTaskLimits();
    
    if (limits != null) {
      _maxConcurrentTasks = limits['maxConcurrentTasks'] ?? 15;
      _maxConcurrentTransfersPerAccount = limits['maxConcurrentTransfersPerAccount'] ?? 3;
      _maxConcurrentTransfersSameAccount = limits['maxConcurrentTransfersSameAccount'] ?? 5;
      
    } else {
    }
  }
  
  // Track concurrent transfers per account
  final Map<String, int> _concurrentTransfersPerAccount = {};
  
  // Performance optimization: Global progress manager with single timer
  Timer? _globalProgressTimer;
  final Map<String, double> _pendingProgressUpdates = {}; // taskId -> progress value
  DateTime _lastGlobalNotifyTime = DateTime.now();
  // OPTIMIZATION: Increased from 500ms to 2000ms to reduce UI rebuild frequency by 75%
  static const Duration GLOBAL_NOTIFY_INTERVAL = Duration(milliseconds: 2000); // Notify every 2 seconds globally
  static const Duration TIME_BASED_PROGRESS_INTERVAL = Duration(seconds: 1); // Update progress every 1 second
  
  // OPTIMIZATION: Per-task throttling to prevent rapid updates from multiple concurrent tasks
  final Map<String, DateTime> _perTaskLastUpdateTime = {}; // taskId -> last update time
  static const Duration PER_TASK_MIN_UPDATE_INTERVAL = Duration(milliseconds: 500); // Minimum 500ms between updates per task
  
  // Function to get adapter instead of direct provider reference
  ICloudAdapter? Function(String accountId)? getAdapterForAccount;
  
  // Function to get selected items count
  int Function()? _getSelectedItemsCountCallback;

  List<QueuedTask> get tasks => UnmodifiableListView(_tasks);
  List<QueuedTask> get activeTasks => _tasks.where((t) =>
      t.status == TaskStatus.pending ||
      t.status == TaskStatus.running ||
      t.status == TaskStatus.paused).toList();

  void setAdapterGetter(ICloudAdapter? Function(String accountId) getter) {
    getAdapterForAccount = getter;
  }
  
  void setSelectedItemsCountGetter(int Function() getter) {
    _getSelectedItemsCountCallback = getter;
  }
  
  // Global progress manager with single timer - batches all progress updates
  void _scheduleGlobalProgressUpdate(String taskId, double progress) {
    _pendingProgressUpdates[taskId] = progress;
    
    // Only one timer running globally
    _globalProgressTimer ??= Timer(GLOBAL_NOTIFY_INTERVAL, () {
      if (_pendingProgressUpdates.isEmpty) {
        _globalProgressTimer = null;
        return;
      }
      
      // Apply all pending updates in a single notification
      for (final entry in _pendingProgressUpdates.entries) {
        final task = _tasks.firstWhere(
          (t) => t.id == entry.key,
          orElse: () => throw Exception("Task not found: ${entry.key}"),
        );
        task.progress = entry.value;
      }
      
      _pendingProgressUpdates.clear();
      _globalProgressTimer = null;
      _lastGlobalNotifyTime = DateTime.now();
      
      if (hasListeners) {
        notifyListeners();
      }
    });
  }
  
  // Time-based progress update - updates every 1 second regardless of bytes
  // OPTIMIZATION: Add per-task throttling to prevent multiple tasks from spamming UI
  void _updateProgressTimeBased(QueuedTask task, double progress) {
    final now = DateTime.now();
    final lastUpdate = _perTaskLastUpdateTime[task.id];
    
    // Only update if enough time has passed since last update for THIS task
    if (lastUpdate == null || now.difference(lastUpdate) >= PER_TASK_MIN_UPDATE_INTERVAL) {
      _scheduleGlobalProgressUpdate(task.id, progress);
      _perTaskLastUpdateTime[task.id] = now;
      _lastGlobalNotifyTime = now;
    }
  }

  // --- 1. ADD TASK ---
  void addTask(QueuedTask task) {
    _tasks.add(task);
    notifyListeners();
    _processQueue();
  }

  // --- 2. PROCESS QUEUE ---
  Future<void> _processQueue() async {
    if (_isProcessing) return;
    if (getAdapterForAccount == null) {
      return;
    }

    _isProcessing = true;
    
    try {
      // Process multiple tasks in parallel, respecting limits
      await _processMultipleTasks();
    } finally {
      _isProcessing = false;
    }
  }
  
  /// Process multiple tasks concurrently
  Future<void> _processMultipleTasks() async {
    final pendingTasks = _tasks
        .where((t) => t.status == TaskStatus.pending && !_processingTasks.contains(t.id))
        .toList();
    
    if (pendingTasks.isEmpty) return;
    
    
    // Group tasks by account to respect per-account limits
    final tasksByAccount = <String, List<QueuedTask>>{};
    for (final task in pendingTasks) {
      final accountId = task.accountId ?? 'unknown';
      if (!tasksByAccount.containsKey(accountId)) {
        tasksByAccount[accountId] = [];
      }
      tasksByAccount[accountId]!.add(task);
    }
    
    // Process tasks with concurrency limits
    final futures = <Future<void>>[];
    
    for (final entry in tasksByAccount.entries) {
      final accountId = entry.key;
      final accountTasks = entry.value;
      
      // Respect per-account concurrent transfer limits
      final currentConcurrent = _concurrentTransfersPerAccount[accountId] ?? 0;
      final availableSlots = MAX_CONCURRENT_TRANSFERS_PER_ACCOUNT - currentConcurrent;
      
      if (availableSlots > 0) {
        final tasksToProcess = accountTasks.take(availableSlots).toList();
        for (final task in tasksToProcess) {
          futures.add(_processSingleTask(task, accountId));
        }
      }
    }
    
    // Wait for all tasks to complete
    if (futures.isNotEmpty) {
      await Future.wait(futures);
      // Continue processing any remaining tasks
      await _processMultipleTasks();
    }
  }
  
  /// Process a single task with proper tracking
  Future<void> _processSingleTask(QueuedTask task, String accountId) async {
    // Mark as processing
    _processingTasks.add(task.id);
    _concurrentTransfersPerAccount[accountId] =
        (_concurrentTransfersPerAccount[accountId] ?? 0) + 1;
    
    try {
      // Update status to Running
      task.status = TaskStatus.running;
      notifyListeners();
      
      
      // EXECUTE BASED ON TYPE with progress tracking
      switch (task.type) {
        case TaskType.upload:
          await _executeUploadParallel(task);
          break;
        case TaskType.uploadFolder:
          await _executeUploadFolder(task);
          break;
        case TaskType.download:
          await _executeDownloadParallel(task);
          break;
        case TaskType.downloadFolder:
          await _executeDownloadFolder(task);
          break;
        case TaskType.copyFile:
          await _executeCopyFileParallel(task);
          break;
        case TaskType.copyFolder:
          await _executeCopyFolderParallel(task);
          break;
        default:
          await _executeStandardTask(task);
      }
      
      task.status = TaskStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      
    } catch (e) {
      task.status = TaskStatus.failed;
      task.errorMessage = e.toString();
    } finally {
      // Clean up tracking
      _processingTasks.remove(task.id);
      _concurrentTransfersPerAccount[accountId] =
          (_concurrentTransfersPerAccount[accountId] ?? 1) - 1;
      if (_concurrentTransfersPerAccount[accountId] == 0) {
        _concurrentTransfersPerAccount.remove(accountId);
      }
      
      notifyListeners();
    }
  }
  
  /// Enhanced upload execution with streaming and progress
  /// Uses Rust-based file I/O for large files to prevent main thread flooding
  Future<void> _executeUploadParallel(QueuedTask task) async {
    // Check if this is a batch upload
    final isBatchUpload = task.payload['batchUpload'] == true;
    
    if (isBatchUpload) {
      // Handle batch upload - create individual tasks for each file
      final filePaths = task.payload['filePaths'] as List<String>;
      final fileNames = task.payload['fileNames'] as List<String>;
      final parentId = task.payload['parentId'];
      final accountId = task.accountId;
      final shouldEncrypt = task.payload['shouldEncrypt'] as bool? ?? false;
      
      
      // Create individual tasks for each file
      for (int i = 0; i < filePaths.length; i++) {
        final filePath = filePaths[i];
        final fileName = fileNames[i];
        
        final uploadTask = QueuedTask(
          id: const Uuid().v4(),
          type: TaskType.upload,
          name: fileName,
          accountId: accountId,
          payload: {
            'filePath': filePath,
            'parentId': parentId,
            'shouldEncrypt': shouldEncrypt,
            'isEncrypted': shouldEncrypt,
            'originalFileName': fileName,
          },
        );
        
        addTask(uploadTask);
      }
      
      // Mark the batch task as completed
      task.status = TaskStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      
      return;
    }
    
    // Single file upload
    final filePath = task.payload['filePath'] as String;
    final parentId = task.payload['parentId'];
    final accountId = task.accountId;
    final shouldEncrypt = task.payload['shouldEncrypt'] as bool? ?? false;
    
    if (filePath.isEmpty) {
      throw Exception("File path is empty");
    }
    
    final adapter = getAdapterForAccount!(accountId!);
    if (adapter == null) throw Exception("Account not found");
    
    // Check if cancelled before starting
    if (task.cancellationToken.isCancelled) {
      throw Exception("Upload cancelled by user");
    }
    
    // Get file info
    final file = File(filePath);
    final fileNameFromPath = file.uri.pathSegments.last;
    final fileSize = await file.length();
    
    // Check if file is already encrypted (has .enc extension)
    final isAlreadyEncrypted = fileNameFromPath.toLowerCase().endsWith('.enc');
    
    // Determine the true original filename (before any encryption)
    String trueOriginalName;
    if (isAlreadyEncrypted) {
      // Remove .enc to get the original name
      trueOriginalName = fileNameFromPath.substring(0, fileNameFromPath.length - 4);
    } else {
      trueOriginalName = fileNameFromPath;
    }
    
    
    // Initialize encryption name service
    await EncryptionNameService.instance.initialize();
    
    String uploadName = trueOriginalName;
    File fileToUpload = file;
    int fileSizeToUpload = fileSize;
    
    // Handle encryption with random filename
    if (shouldEncrypt || isAlreadyEncrypted) {
      if (!SecurityService.instance.isUnlocked) {
        throw Exception("Vault locked!");
      }
      
      // Generate random encrypted filename
      uploadName = EncryptionNameService.instance.generateRandomFilename();
      
      if (!isAlreadyEncrypted) {
        // Need to encrypt the file
        final tempDir = await getTemporaryDirectory();
        final tempFile = File('${tempDir.path}/$uploadName');
        
        // Encrypt file
        await SecurityService.instance.encryptFile(file, tempFile);
        
        fileToUpload = tempFile;
        fileSizeToUpload = await tempFile.length();
        
      } else {
        // File is already encrypted, use it directly
      }
    }
    
    // Use standard Dart streaming for all file uploads
    
    final stream = fileToUpload.openRead();
    
    // Track progress during upload with time-based updates
    int bytesUploaded = 0;
    
    final progressStream = stream.transform<List<int>>(
      StreamTransformer.fromHandlers(
        handleData: (chunk, sink) {
          // Check for cancellation/pause
          if (task.cancellationToken.isCancelled) {
            throw Exception("Upload cancelled by user");
          }
          
          bytesUploaded += chunk.length;
          // Time-based progress updates
          final now = DateTime.now();
          if (now.difference(_lastGlobalNotifyTime) >= TIME_BASED_PROGRESS_INTERVAL) {
            final progress = fileSizeToUpload > 0 ? bytesUploaded / fileSizeToUpload : 0.0;
            _updateProgressTimeBased(task, progress);
            _lastGlobalNotifyTime = now;
          }
          sink.add(chunk);
        },
        handleDone: (sink) {
          final progress = fileSizeToUpload > 0 ? 1.0 : 0.0;
          _updateProgressTimeBased(task, progress);
          sink.close();
        },
      ),
    );
    
    // Upload with encrypted name (random or original)
    await adapter.uploadStream(
      uploadName,
      progressStream,
      fileSizeToUpload,
      parentId,
      cancellationToken: task.cancellationToken,
    );
    
    // Save mapping if encryption was enabled
    if (shouldEncrypt || isAlreadyEncrypted) {
      // Get the uploaded file's cloud ID
      final cloudFileId = await adapter.getFileIdByName(uploadName, parentId);
      
      if (cloudFileId != null) {
        await EncryptionNameService.instance.saveMapping(
          EncryptedFileMapping(
            encryptedFileName: uploadName,
            originalFileName: trueOriginalName,
            cloudFileId: cloudFileId,
            accountId: accountId!,
            parentId: parentId,
            createdAt: DateTime.now(),
            originalFileSize: fileSize, // Store original file size for sync comparison
          ),
        );
      } else {
      }
      
      // Clean up temp encrypted file if it was created
      if (!isAlreadyEncrypted) {
        try {
          await fileToUpload.delete();
        } catch (e) {
        }
      }
    }
    
  }
  
  /// Public method to upload multiple files as separate individual tasks
  /// Each file gets its own task, allowing independent pause/cancel for each file
  Future<void> uploadFilesUnified(
    List<String> filePaths,
    List<String> fileNames,
    String parentId,
    String accountId,
    bool shouldEncrypt,
  ) async {
    
    for (int i = 0; i < filePaths.length; i++) {
      final filePath = filePaths[i];
      final fileName = fileNames[i];
      
      // Create individual task for each file
      final task = QueuedTask(
        id: const Uuid().v4(),
        type: TaskType.upload,
        name: fileName,
        accountId: accountId,
        payload: {
          'filePath': filePath,
          'parentId': parentId,
          'shouldEncrypt': shouldEncrypt,
          'isEncrypted': shouldEncrypt,
        },
      );
      
      addTask(task);
    }
    
  }
  
  /// Execute download task with parallel processing
  Future<void> _executeDownloadParallel(QueuedTask task) async {
    // Check if this is a batch download
    if (task.payload['batchDownload'] == true) {
      await _executeBatchDownloadParallel(task);
    } else {
      await _executeSingleDownloadParallel(task);
    }
  }
  
  /// Execute single file download with parallel processing
  Future<void> _executeSingleDownloadParallel(QueuedTask task) async {
    final fileId = task.payload['fileId'];
    final encryptedFileName = task.payload['fileName'] as String?; // This is the encrypted name on cloud
    final savePath = task.payload['savePath'];
    final accountId = task.accountId;
    
    final adapter = getAdapterForAccount!(accountId!);
    if (adapter == null) throw Exception("Account not found");
    
    // Check if cancelled before starting
    if (task.cancellationToken.isCancelled) {
      throw Exception("Download cancelled by user");
    }
    
    try {
      // Initialize encryption name service
      await EncryptionNameService.instance.initialize();
      
      // Look up original filename from mapping
      String? originalFileName;
      if (encryptedFileName != null) {
        originalFileName = await EncryptionNameService.instance.getOriginalName(encryptedFileName);
        if (originalFileName != null) {
        }
      }
      
      // Use streaming download for better memory efficiency
      final sourceStream = await adapter.downloadStream(fileId);
      final sink = File(savePath).openWrite();
      
      // Track progress during download with time-based updates to prevent main thread flooding
      int bytesDownloaded = 0;
      int lastProgressUpdate = 0;
      const progressUpdateInterval = 10 * 1024 * 1024; // Update progress every 10MB (increased from 5MB)
      
      final progressStream = sourceStream.transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleData: (chunk, sink) {
            // Check for cancellation/pause
            if (task.cancellationToken.isCancelled) {
              throw Exception("Download cancelled by user");
            }
            
            bytesDownloaded += chunk.length;
            // Time-based progress updates - use global timer
            final now = DateTime.now();
            if (now.difference(_lastGlobalNotifyTime) >= TIME_BASED_PROGRESS_INTERVAL) {
              // For downloads, we don't know the total size in advance, so we use a simple progress indicator
              final progress = bytesDownloaded > 0 ? math.min(0.9, bytesDownloaded / (1024 * 1024)) : 0.0; // Progress up to 90% based on MB downloaded
              _updateProgressTimeBased(task, progress);
              _lastGlobalNotifyTime = now;
              lastProgressUpdate = bytesDownloaded;
            }
            sink.add(chunk);
          },
          handleDone: (sink) {
            // Send final progress update
            _updateProgressTimeBased(task, 1.0);
            sink.close();
          },
        ),
      );
      
      await progressStream.pipe(sink);
      await sink.close();
      
      // Handle decryption and original filename restoration
      final isEncrypted = task.payload['isEncrypted'] ?? false;
      if (isEncrypted || (encryptedFileName != null && EncryptionNameService.instance.isEncryptedFilename(encryptedFileName))) {
        await _handleDecryptionWithOriginalName(task, savePath, encryptedFileName, originalFileName);
      } else if (isEncrypted) {
        await _handleDecryption(task, savePath);
      }
      
      
    } catch (e) {
      rethrow;
    }
  }
  
  /// Handle decryption of downloaded files with original filename restoration
  Future<void> _handleDecryptionWithOriginalName(
    QueuedTask task,
    String downloadPath,
    String? encryptedFileName,
    String? originalFileName,
  ) async {
    if (!SecurityService.instance.isUnlocked) {
      throw Exception("Vault locked!");
    }
    
    try {
      // Determine the final filename
      final directory = File(downloadPath).parent;
      String finalSavePath;
      
      if (originalFileName != null) {
        // Use the original filename from mapping
        finalSavePath = '${directory.path}/$originalFileName';
      } else {
        // Fallback: remove .enc extension
        finalSavePath = downloadPath.replaceAll('.enc', '');
      }
      
      // Decrypt the file (FEK is embedded in the file)
      await SecurityService.instance.decryptFile(
        File(downloadPath),
        File(finalSavePath),
      );
      
      // Clean up encrypted temp file - ensure it exists before deleting
      final encryptedFile = File(downloadPath);
      if (await encryptedFile.exists()) {
        await encryptedFile.delete();
      } else {
      }
      
      
    } catch (e) {
      // Don't rethrow - the encrypted file is still available
    }
  }
  
  /// Execute batch download task with parallel processing
  Future<void> _executeBatchDownloadParallel(QueuedTask task) async {
    final fileIds = task.payload['fileIds'] as List<String>;
    final fileNames = task.payload['fileNames'] as List<String>;
    final saveDirectory = task.payload['saveDirectory'];
    final shouldDecrypt = task.payload['shouldDecrypt'] as bool;
    final accountId = task.accountId;
    
    // Check if cancelled before starting
    if (task.cancellationToken.isCancelled) {
      throw Exception("Batch download cancelled by user");
    }
    
    
    final adapter = getAdapterForAccount!(accountId!);
    if (adapter == null) throw Exception("Account not found");
    
    try {
      // Update progress to show we're starting
      _updateProgressTimeBased(task, 0.05);
      
      
      // Create download items
      final downloadItems = <FileDownloadItem>[];
      
      for (int i = 0; i < fileIds.length; i++) {
        final fileId = fileIds[i];
        final fileName = fileNames[i];
        
        downloadItems.add(FileDownloadItem(
          fileId: fileId,
          fileName: fileName,
          savePath: '$saveDirectory/$fileName',
          shouldDecrypt: shouldDecrypt && fileName.endsWith('.enc'),
        ));
      }
      
      _updateProgressTimeBased(task, 0.1);
      
      // Download files in parallel
      await _downloadMultipleFilesParallel(
        downloadItems,
        adapter,
        accountId,
        task,
      );
      
      task.status = TaskStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      
      
    } catch (e) {
      task.status = TaskStatus.failed;
      task.errorMessage = e.toString();
    }
    
    notifyListeners();
  }
  
  /// Handle decryption of downloaded files
  Future<void> _handleDecryption(QueuedTask task, String downloadPath) async {
    if (!SecurityService.instance.isUnlocked) {
      throw Exception("Vault locked!");
    }
    
    final originalFileName = task.payload['originalFileName'] as String?;
    final fileId = task.payload['fileId'] as String;
    
    if (originalFileName == null) {
      return;
    }
    
    try {
      // Use the same directory as the downloaded file, not the downloads directory
      final directory = File(downloadPath).parent;
      final finalSavePath = '${directory.path}/$originalFileName';
      
      
      // Decrypt the file (FEK is embedded in the file)
      await SecurityService.instance.decryptFile(
        File(downloadPath),
        File(finalSavePath),
      );
      
      // Clean up encrypted temp file - ensure it exists before deleting
      final encryptedFile = File(downloadPath);
      if (await encryptedFile.exists()) {
        await encryptedFile.delete();
      } else {
      }
      
      
    } catch (e) {
      // Don't rethrow - the encrypted file is still available
    }
  }
  
  /// Execute folder download task with parallel processing
  Future<void> _executeDownloadFolder(QueuedTask task) async {
    final folderId = task.payload['folderId'];
    final savePath = task.payload['savePath'];
    final accountId = task.accountId;
    
    // Check if cancelled before starting
    if (task.cancellationToken.isCancelled) {
      throw Exception("Folder download cancelled by user");
    }
    
    
    final adapter = getAdapterForAccount!(accountId!);
    if (adapter == null) throw Exception("Account not found");
    
    try {
      // Update progress to show we're starting
      _updateProgressTimeBased(task, 0.05);
      
      // Get folder name from task
      final folderName = task.name;
      
      // Create local folder
      final localFolder = Directory(savePath);
      await localFolder.create(recursive: true);
      
      // Update progress for folder creation
      _updateProgressTimeBased(task, 0.1);
      
      // Get all files and folders in the cloud folder structure
      final downloadItems = await _scanCloudFolderStructure(adapter, folderId, '');
      final totalItems = downloadItems.length;
      final totalFiles = downloadItems.where((item) => !item.isFolder).length;
      
      
      if (totalItems == 0) {
        // No files to download, just mark as complete
        task.status = TaskStatus.completed;
        task.progress = 1.0;
        task.completedAt = DateTime.now();
        return;
      }
      
      // Create local folder structure first (sequentially to maintain hierarchy)
      await _createLocalFolderStructure(downloadItems, savePath);
      _updateProgressTimeBased(task, 0.2);
      
      // Download files in parallel
      final filesToDownload = downloadItems.where((item) => !item.isFolder).toList();
      if (filesToDownload.isNotEmpty) {
        await _downloadFilesParallel(
          filesToDownload,
          adapter,
          accountId,
          savePath,
          task,
        );
      }
      
      task.status = TaskStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      
      
    } catch (e) {
      task.status = TaskStatus.failed;
      task.errorMessage = e.toString();
    }
    
    notifyListeners();
  }
  
  /// Scan cloud folder structure and return download items
  Future<List<FolderDownloadItem>> _scanCloudFolderStructure(
    ICloudAdapter adapter,
    String folderId,
    String relativePath,
  ) async {
    final items = <FolderDownloadItem>[];
    
    try {
      final result = await adapter.listFolder(folderId);
      final cloudItems = result.nodes;
      
      for (final item in cloudItems) {
        final itemRelativePath = relativePath.isEmpty ? item.name : '$relativePath/${item.name}';
        
        if (item.isFolder) {
          items.add(FolderDownloadItem(
            cloudId: item.cloudId!,
            name: item.name,
            relativePath: itemRelativePath,
            isFolder: true,
          ));
          
          // Recursively scan subfolder
          final subItems = await _scanCloudFolderStructure(adapter, item.cloudId!, itemRelativePath);
          items.addAll(subItems);
        } else {
          items.add(FolderDownloadItem(
            cloudId: item.cloudId!,
            name: item.name,
            relativePath: itemRelativePath,
            isFolder: false,
            size: item.size,
          ));
        }
      }
    } catch (e) {
    }
    
    return items;
  }
  
  /// Create local folder structure
  Future<void> _createLocalFolderStructure(
    List<FolderDownloadItem> downloadItems,
    String basePath,
  ) async {
    final folders = downloadItems.where((item) => item.isFolder).toList();
    
    
    for (final folder in folders) {
      try {
        final localFolderPath = '$basePath/${folder.relativePath}';
        final localFolder = Directory(localFolderPath);
        await localFolder.create(recursive: true);
      } catch (e) {
      }
    }
  }
  
  /// Download multiple files in parallel
  Future<void> _downloadFilesParallel(
    List<FolderDownloadItem> files,
    ICloudAdapter adapter,
    String accountId,
    String basePath,
    QueuedTask task,
  ) async {
    
    int completedFiles = 0;
    final semaphore = _Semaphore(MAX_CONCURRENT_TRANSFERS_PER_ACCOUNT);
    final futures = <Future<void>>[];
    
    for (final file in files) {
      futures.add(_downloadSingleFileWithSemaphore(
        file,
        adapter,
        accountId,
        basePath,
        semaphore,
        task,
        () {
          completedFiles++;
          // Batch progress updates - only update every 5 files or at the end
          if (completedFiles % 5 == 0 || completedFiles == files.length) {
            final newProgress = 0.2 + (0.75 * completedFiles / files.length);
            _updateProgressTimeBased(task, newProgress);
          }
        },
      ));
    }
    
    // Wait for all downloads to complete
    await Future.wait(futures, eagerError: false);
    
    // Final progress update
    _updateProgressTimeBased(task, 0.95);
    
  }
  
  /// Download a single file with semaphore control
  Future<void> _downloadSingleFileWithSemaphore(
    FolderDownloadItem file,
    ICloudAdapter adapter,
    String accountId,
    String basePath,
    _Semaphore semaphore,
    QueuedTask task,
    VoidCallback onProgress,
  ) async {
    await semaphore.acquire();
    
    try {
      final localFilePath = '$basePath/${file.relativePath}';
      final localFile = File(localFilePath);
      
      // Download the file with streaming and cancellation check
      final sourceStream = await adapter.downloadStream(file.cloudId);
      
      // Create progress stream with cancellation check
      int bytesDownloaded = 0;
      final progressStream = sourceStream.transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleData: (chunk, sink) {
            // Check for cancellation (handled by folder download task)
            bytesDownloaded += chunk.length;
            sink.add(chunk);
          },
          handleDone: (sink) {
            sink.close();
          },
        ),
      );
      
      final sink = localFile.openWrite();
      await progressStream.pipe(sink);
      await sink.close();
      
      // Handle decryption if needed
      if (file.name.endsWith('.enc')) {
        await _handleFileDecryption(file, localFilePath);
      }
      
      onProgress();
      
    } catch (e) {
    } finally {
      semaphore.release();
    }
  }
  
  /// Handle decryption of individual downloaded files
  Future<void> _handleFileDecryption(FolderDownloadItem file, String localFilePath) async {
    if (!SecurityService.instance.isUnlocked) {
      return;
    }
    
    try {
      // Look up original filename from mapping
      String? originalFileName = await EncryptionNameService.instance.getOriginalName(file.name);
      
      // Determine the final filename
      final directory = File(localFilePath).parent;
      String decryptedFilePath;
      
      if (originalFileName != null) {
        // Use the original filename from mapping
        decryptedFilePath = '${directory.path}/$originalFileName';
      } else {
        // Fallback: remove .enc extension
        decryptedFilePath = localFilePath.replaceAll('.enc', '');
      }
      
      final decryptedFile = File(decryptedFilePath);
      
      
      await SecurityService.instance.decryptFile(
        File(localFilePath),
        decryptedFile,
      );
      
      // Clean up encrypted file - ensure it exists before deleting
      final encryptedFile = File(localFilePath);
      if (await encryptedFile.exists()) {
        await encryptedFile.delete();
      } else {
      }
      
      
    } catch (e) {
    }
  }
  
  /// Download multiple files in parallel (for batch downloads)
  Future<void> _downloadMultipleFilesParallel(
    List<FileDownloadItem> downloadItems,
    ICloudAdapter adapter,
    String accountId,
    QueuedTask task,
  ) async {
    
    int completedFiles = 0;
    final semaphore = _Semaphore(MAX_CONCURRENT_TRANSFERS_PER_ACCOUNT);
    final futures = <Future<void>>[];
    
    for (final downloadItem in downloadItems) {
      futures.add(_downloadSingleBatchFileWithSemaphore(
        downloadItem,
        adapter,
        accountId,
        semaphore,
        task,
        () {
          completedFiles++;
          // Batch progress updates - only update every 5 files or at the end
          if (completedFiles % 5 == 0 || completedFiles == downloadItems.length) {
            final newProgress = 0.1 + (0.85 * completedFiles / downloadItems.length);
            _updateProgressTimeBased(task, newProgress);
          }
        },
      ));
    }
    
    // Wait for all downloads to complete
    await Future.wait(futures, eagerError: false);
    
    // Final progress update
    _updateProgressTimeBased(task, 0.95);
    
  }
  
  /// Download a single file with semaphore control (for batch downloads)
  Future<void> _downloadSingleBatchFileWithSemaphore(
    FileDownloadItem downloadItem,
    ICloudAdapter adapter,
    String accountId,
    _Semaphore semaphore,
    QueuedTask task,
    VoidCallback onProgress,
  ) async {
    await semaphore.acquire();
    
    try {
      // Download the file with streaming and cancellation check
      final sourceStream = await adapter.downloadStream(downloadItem.fileId);
      
      // Create progress stream with cancellation check
      int bytesDownloaded = 0;
      final progressStream = sourceStream.transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleData: (chunk, sink) {
            // Check for cancellation (handled by batch download task)
            bytesDownloaded += chunk.length;
            sink.add(chunk);
          },
          handleDone: (sink) {
            sink.close();
          },
        ),
      );
      
      final sink = File(downloadItem.savePath).openWrite();
      await progressStream.pipe(sink);
      await sink.close();
      
      // Handle decryption if needed
      if (downloadItem.shouldDecrypt) {
        await _handleBatchFileDecryption(downloadItem);
      }
      
      onProgress();
      
    } catch (e) {
    } finally {
      semaphore.release();
    }
  }
  
  /// Handle decryption of individual downloaded files in batch
  Future<void> _handleBatchFileDecryption(FileDownloadItem downloadItem) async {
    if (!SecurityService.instance.isUnlocked) {
      return;
    }
    
    try {
      // Look up original filename from mapping
      String? originalFileName = await EncryptionNameService.instance.getOriginalName(downloadItem.fileName);
      
      // Determine the final filename
      final directory = File(downloadItem.savePath).parent;
      String decryptedFilePath;
      
      if (originalFileName != null) {
        // Use the original filename from mapping
        decryptedFilePath = '${directory.path}/$originalFileName';
      } else {
        // Fallback: remove .enc extension
        decryptedFilePath = downloadItem.savePath.replaceAll('.enc', '');
      }
      
      final decryptedFile = File(decryptedFilePath);
      
      
      await SecurityService.instance.decryptFile(
        File(downloadItem.savePath),
        decryptedFile,
      );
      
      // Clean up encrypted file - ensure it exists before deleting
      final encryptedFile = File(downloadItem.savePath);
      if (await encryptedFile.exists()) {
        await encryptedFile.delete();
      } else {
      }
      
      
    } catch (e) {
    }
  }
  
  /// Execute folder upload task with parallel processing
  Future<void> _executeUploadFolder(QueuedTask task) async {
    final folderPath = task.payload['folderPath'];
    final parentFolderId = task.payload['parentFolderId'];
    final accountId = task.accountId;
    final provider = task.payload['provider'];
    
    // Check if cancelled before starting
    if (task.cancellationToken.isCancelled) {
      throw Exception("Folder upload cancelled by user");
    }
    
    
    // DEBUG: Log task payload details
    
    // DEBUG: Check for null values before using them
    if (accountId == null) {
      throw Exception("accountId is null in task payload");
    }
    
    final adapter = getAdapterForAccount!(accountId);
    if (adapter == null) {
      throw Exception("Account not found");
    }
    
    
    try {
      // Update progress to show we're starting
      _updateProgressTimeBased(task, 0.05);
      
      // DEBUG: Check folderPath before using it
      if (folderPath == null) {
        throw Exception("folderPath is null in task payload");
      }
      
      // Get folder name from path
      final folderName = folderPath.split(Platform.pathSeparator).last;
      
      // DEBUG: Check parentFolderId before using it
      if (parentFolderId == null) {
        throw Exception("parentFolderId is null in task payload");
      }
      
      // Create the folder in the cloud
      final newFolderId = await adapter.createFolder(folderName, parentFolderId);
      
      // Update progress for folder creation
      _updateProgressTimeBased(task, 0.1);
      
      // Get all files and folders in the directory structure
      final uploadItems = await _scanFolderStructure(folderPath);
      final totalItems = uploadItems.length;
      final totalFiles = uploadItems.where((item) => !item.isFolder).length;
      
      
      if (totalItems == 0) {
        // No files to upload, just mark as complete
        task.status = TaskStatus.completed;
        task.progress = 1.0;
        task.completedAt = DateTime.now();
        return;
      }
      
      // Check if encryption should be enabled for this account
      bool shouldEncrypt = await _shouldEncryptForAccount(accountId);
      
      // OPTIMIZED: Use dependency-based true parallel processing
      // Folders and files are processed together as soon as their parents are ready
      final folderMap = await _uploadFolderStructureOptimized(
        uploadItems,
        adapter,
        newFolderId,
        accountId,
        shouldEncrypt,
        folderPath,
        task,
      );
      
      // Update task with result
      task.payload['newFolderId'] = newFolderId;
      task.status = TaskStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      
    } catch (e) {
      task.status = TaskStatus.failed;
      task.errorMessage = e.toString();
    }
    
    notifyListeners();
  }
  
  /// Scan folder structure and return upload items
  /// Uses Rust scanner for better performance on large folders
  Future<List<FolderUploadItem>> _scanFolderStructure(String folderPath) async {
    final items = <FolderUploadItem>[];
    final directory = Directory(folderPath);
    
    if (!await directory.exists()) {
      return items;
    }
    
    try {
      // Use Rust scanner for better performance (fast C-based scanning)
      final result = await RustFolderScanner.scanFolderQuick(folderPath);
      
      // Convert FolderScanResult to FolderUploadItem
      for (final item in result.items) {
        final pathSegments = item.path.split('/').where((s) => s.isNotEmpty).toList();
        items.add(FolderUploadItem(
          localPath: '$folderPath/${item.path}', // Reconstruct full path
          relativePath: item.path,
          isFolder: item.isFolder,
          size: item.size,
          pathSegments: pathSegments,
        ));
      }
      
      // Items are already sorted by Rust scanner
      
    } catch (e) {
      // Fallback to Dart-based scanning if Rust scanner fails
      return await _scanFolderStructureDart(folderPath);
    }
    
    return items;
  }
  
  /// Scan folder structure using Dart (fallback method)
  Future<List<FolderUploadItem>> _scanFolderStructureDart(String folderPath) async {
    final items = <FolderUploadItem>[];
    final directory = Directory(folderPath);
    
    if (!await directory.exists()) {
      return items;
    }
    
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      final relativePath = entity.path.substring(folderPath.length);
      // Normalize path separators and remove leading separator
      final normalizedPath = relativePath.replaceAll('\\', '/').replaceFirst('/', '');
      final pathSegments = normalizedPath.split('/').where((s) => s.isNotEmpty).toList();
      
      if (entity is File) {
        final fileSize = await entity.length();
        items.add(FolderUploadItem(
          localPath: entity.path,
          relativePath: normalizedPath,
          isFolder: false,
          size: fileSize,
          pathSegments: pathSegments,
        ));
      } else if (entity is Directory) {
        items.add(FolderUploadItem(
          localPath: entity.path,
          relativePath: normalizedPath,
          isFolder: true,
          pathSegments: pathSegments,
        ));
      }
    }
    
    // Sort items: folders first, then files, maintaining directory structure
    items.sort((a, b) {
      if (a.isFolder && !b.isFolder) return -1;
      if (!a.isFolder && b.isFolder) return 1;
      return a.relativePath.compareTo(b.relativePath);
    });
    
    return items;
  }
  
  /// OPTIMIZED: Upload folder structure with true parallelism using dependency tracking
  /// This eliminates depth-based batching and processes items as soon as their parents are ready
  Future<Map<String, String>> _uploadFolderStructureOptimized(
    List<FolderUploadItem> uploadItems,
    ICloudAdapter adapter,
    String rootFolderId,
    String accountId,
    bool shouldEncrypt,
    String folderPath,
    QueuedTask task,
  ) async {
    
    final folderMap = <String, String>{'': rootFolderId}; // relativePath -> cloudId
    final dependencies = <String, String>{}; // item relativePath -> parent relativePath
    final pendingItems = <FolderUploadItem>[];
    final processingItems = <String>{}; // Track items being processed
    final completedItems = <String>{}; // Track completed items
    
    // Build dependency map and initialize pending items
    for (final item in uploadItems) {
      if (item.isFolder) {
        // Calculate parent path
        String parentPath = '';
        if (item.relativePath.contains('/')) {
          parentPath = item.relativePath.substring(0, item.relativePath.lastIndexOf('/'));
        }
        dependencies[item.relativePath] = parentPath;
      }
      pendingItems.add(item);
    }
    
    int completedCount = 0;
    final semaphore = _Semaphore(MAX_CONCURRENT_TRANSFERS_PER_ACCOUNT);
    
    // Process items continuously until all done
    while (completedCount < uploadItems.length) {
      // Check for cancellation before processing more items
      if (task.cancellationToken.isCancelled) {
        break;
      }
      
      final futures = <Future<void>>[];
      
      // Find items ready to process (parent exists and not processing)
      for (final item in pendingItems) {
        final itemId = item.relativePath;
        
        if (completedItems.contains(itemId)) continue;
        if (processingItems.contains(itemId)) continue;
        
        if (item.isFolder) {
          // Check if parent folder exists
          final parentPath = dependencies[itemId] ?? '';
          if (folderMap.containsKey(parentPath) || parentPath.isEmpty) {
            // Parent exists, can process
            processingItems.add(itemId);
            futures.add(_processItemOptimized(
              item,
              adapter,
              folderMap,
              rootFolderId,
              accountId,
              shouldEncrypt,
              folderPath,
              semaphore,
              () {
                completedItems.add(itemId);
                processingItems.remove(itemId);
                completedCount++;
                
                // Batch progress updates - only update every 5 items or at the end
                if (completedCount % 5 == 0 || completedCount == uploadItems.length) {
                  final newProgress = 0.1 + (0.85 * completedCount / uploadItems.length);
                  _updateProgressTimeBased(task, newProgress);
                }
              },
              task: task,
            ));
          }
        } else {
          // File: check if parent folder exists
          String parentPath = '';
          if (item.relativePath.contains('/')) {
            parentPath = item.relativePath.substring(0, item.relativePath.lastIndexOf('/'));
          }
          
          if (folderMap.containsKey(parentPath) || parentPath.isEmpty) {
            // Parent folder exists, can upload
            processingItems.add(itemId);
            futures.add(_processItemOptimized(
              item,
              adapter,
              folderMap,
              rootFolderId,
              accountId,
              shouldEncrypt,
              folderPath,
              semaphore,
              () {
                completedItems.add(itemId);
                processingItems.remove(itemId);
                completedCount++;
                
                // Batch progress updates
                if (completedCount % 5 == 0 || completedCount == uploadItems.length) {
                  final newProgress = 0.1 + (0.85 * completedCount / uploadItems.length);
                  _updateProgressTimeBased(task, newProgress);
                }
              },
              task: task,
            ));
          }
        }
      }
      
      // Process all ready items in parallel
      if (futures.isNotEmpty) {
        await Future.wait(futures, eagerError: false);
      } else {
        // No items ready, wait a bit and retry
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    
    // Final progress update
    _updateProgressTimeBased(task, 0.95);
    
    return folderMap;
  }
  
  /// OPTIMIZED: Process a single item (folder or file) with semaphore control
  /// This method handles both folder creation and file upload in a unified way
  Future<void> _processItemOptimized(
    FolderUploadItem item,
    ICloudAdapter adapter,
    Map<String, String> folderMap,
    String rootFolderId,
    String accountId,
    bool shouldEncrypt,
    String folderPath,
    _Semaphore semaphore,
    VoidCallback onProgress,
    {QueuedTask? task} // Optional task reference for cancellation
  ) async {
    await semaphore.acquire();
    
    try {
      // Check for cancellation before processing
      if (task?.cancellationToken.isCancelled == true) {
        onProgress();
        return;
      }
      
      if (item.isFolder) {
        // Create folder in cloud
        String parentPath = '';
        if (item.relativePath.contains('/')) {
          parentPath = item.relativePath.substring(0, item.relativePath.lastIndexOf('/'));
        }
        final parentId = folderMap[parentPath] ?? rootFolderId;
        
        if (parentId != null) {
          final folderName = item.pathSegments.last;
          final folderId = await adapter.createFolder(folderName, parentId);
          folderMap[item.relativePath] = folderId;
        }
      } else {
        // Upload file with encryption support
        String parentPath = '';
        if (item.relativePath.contains('/')) {
          parentPath = item.relativePath.substring(0, item.relativePath.lastIndexOf('/'));
        }
        final parentId = folderMap[parentPath] ?? rootFolderId;
        
        if (parentId != null) {
          final fileObj = File(item.localPath);
          final fileName = item.pathSegments.last;
          
          // Upload with streaming and cancellation check
          await _uploadFileWithEncryption(
            fileObj,
            fileName,
            parentId,
            adapter,
            accountId,
            shouldEncrypt,
            task: task,
          );
          
        }
      }
      
      onProgress();
    } catch (e) {
      // Still mark as complete to avoid deadlock
      onProgress();
    } finally {
      semaphore.release();
    }
  }
  
  /// Create a single folder in the cloud
  Future<void> _createSingleFolder(
    FolderUploadItem folder,
    ICloudAdapter adapter,
    Map<String, String> folderMap,
    String folderPath,
    String rootFolderId,
  ) async {
    try {
      // Handle root level folders (no path separator)
      String parentPath = '';
      // Use forward slash since we normalized paths to use forward slashes
      if (folder.relativePath.contains('/')) {
        parentPath = folder.relativePath.substring(0, folder.relativePath.lastIndexOf('/'));
      }
      final parentId = folderMap[parentPath] ?? rootFolderId;
      
      
      if (parentId != null) {
        final folderName = folder.pathSegments.last;
        final folderId = await adapter.createFolder(folderName, parentId);
        folderMap[folder.relativePath] = folderId;
      } else {
      }
    } catch (e) {
    }
  }
  
  /// Upload a single file with encryption support (for folder uploads)
  Future<void> _uploadFileWithEncryption(
    File file,
    String fileName,
    String parentFolderId,
    ICloudAdapter adapter,
    String accountId,
    bool shouldEncrypt,
    {QueuedTask? task} // Optional task reference for cancellation
  ) async {
    File fileToUpload = file;
    String uploadName = fileName;
    String originalName = fileName;
    int originalFileSize = await file.length();
    
    // --- ENCRYPTION (The Vault) ---
    if (shouldEncrypt) {
      if (!SecurityService.instance.isUnlocked) {
        throw Exception("Vault locked!");
      }
      
      // Initialize encryption name service
      await EncryptionNameService.instance.initialize();
      
      // Generate random encrypted filename
      uploadName = EncryptionNameService.instance.generateRandomFilename();
      
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$uploadName');
      
      
      // Encrypt file (FEK is now embedded in the file)
      await SecurityService.instance.encryptFile(
        file,
        tempFile,
      );
      
      fileToUpload = tempFile;
      
    }
    
    // Upload the file with streaming and cancellation check
    final fileStream = fileToUpload.openRead();
    final fileSize = await fileToUpload.length();
    
    final progressStream = fileStream.transform<List<int>>(
      StreamTransformer.fromHandlers(
        handleData: (chunk, sink) {
          // Check for cancellation
          if (task?.cancellationToken.isCancelled == true) {
            throw Exception("Upload cancelled by user");
          }
          sink.add(chunk);
        },
      ),
    );
    
    await adapter.uploadStream(uploadName, progressStream, fileSize, parentFolderId, cancellationToken: task?.cancellationToken);
    
    // Save mapping if encryption was enabled
    if (shouldEncrypt) {
      // Get the uploaded file's cloud ID
      final cloudFileId = await adapter.getFileIdByName(uploadName, parentFolderId);
      
      if (cloudFileId != null) {
        await EncryptionNameService.instance.saveMapping(
          EncryptedFileMapping(
            encryptedFileName: uploadName,
            originalFileName: originalName,
            cloudFileId: cloudFileId,
            accountId: accountId,
            parentId: parentFolderId,
            createdAt: DateTime.now(),
            originalFileSize: originalFileSize,
          ),
        );
      } else {
      }
    }
    
    // Cleanup temp encrypted file if it was created
    if (shouldEncrypt && fileToUpload.path != file.path) {
      try {
        await fileToUpload.delete();
      } catch (e) {
      }
    }
  }
  
  /// Check if encryption should be enabled for a specific account
  Future<bool> _shouldEncryptForAccount(String accountId) async {
    try {
      // Import HiveStorageService here to avoid circular dependency
      final hiveService = HiveStorageService.instance;
      final account = await hiveService.getAccount(accountId);
      final encryptUploads = account?.encryptUploads ?? false;
      return encryptUploads;
    } catch (e) {
      return false;
    }
  }
  
  /// Helper method to get all files in a folder recursively
  Future<List<File>> _getAllFilesInFolder(String folderPath) async {
    final files = <File>[];
    final directory = Directory(folderPath);
    
    if (!await directory.exists()) {
      return files;
    }
    
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        files.add(entity);
      }
    }
    
    return files;
  }
  
  /// Enhanced copy file execution with HYBRID approach
  /// - Same provider: Use native copy (instant, no bandwidth)
  /// - Cross provider: Use Rclone (reliable for large files) or streaming fallback
  Future<void> _executeCopyFileParallel(QueuedTask task) async {
    final sourceFileId = task.payload['sourceFileId'];
    final destinationParentId = task.payload['destinationParentId'];
    final newName = task.payload['newName'];
    final accountId = task.accountId;
    final sourceAccountId = task.payload['sourceAccountId'] ?? accountId;
    
    // Check if cancelled before starting
    if (task.cancellationToken.isCancelled) {
      throw Exception("Copy file cancelled by user");
    }
    
    final destAdapter = getAdapterForAccount!(accountId!);
    if (destAdapter == null) throw Exception("Destination account not found");
    
    final sourceAdapter = getAdapterForAccount!(sourceAccountId!);
    if (sourceAdapter == null) throw Exception("Source account not found");
    
    // Determine if this is a cross-provider copy
    final isCrossProviderCopy = sourceAccountId != accountId;
    
    
    // HYBRID APPROACH: Choose copy method based on provider
    if (!isCrossProviderCopy) {
      // SAME PROVIDER: Use native copy (instant, no bandwidth)
      
      try {
        final newFileId = await destAdapter.copyFileNative(
          sourceFileId: sourceFileId,
          destinationParentId: destinationParentId,
          newName: newName,
        );
        
        if (newFileId != null) {
          _updateProgressTimeBased(task, 1.0);
          return;
        } else {
        }
      } catch (e) {
      }
    }
    
    // CROSS-PROVIDER: Use streaming
    
    // Note: RClone service has been removed from project
    // Using streaming fallback
    
    // Fallback to streaming approach
    await _copyFileWithStreamingHybrid(
      sourceAdapter,
      destAdapter,
      sourceFileId,
      newName,
      destinationParentId,
      task,
    );
  }
  
  /// Copy file using Rclone (for cross-provider transfers)
  /// Note: RClone service has been removed from project
  /// This method is kept for reference but is no longer functional
  Future<void> _copyFileWithRclone(
    ICloudAdapter sourceAdapter,
    ICloudAdapter destAdapter,
    String sourceFileId,
    String fileName,
    String destFolderId,
    QueuedTask task,
  ) async {
    throw Exception("Rclone service has been removed from project. Use streaming approach instead.");
  }
  
  /// Copy file using streaming (hybrid approach for cross-provider)
  /// Uses UnifiedCopyService for chunk-based copy operations
  Future<void> _copyFileWithStreamingHybrid(
    ICloudAdapter sourceAdapter,
    ICloudAdapter destAdapter,
    String sourceFileId,
    String fileName,
    String destFolderId,
    QueuedTask task,
  ) async {
    
    // Get file metadata for progress tracking
    int fileSize = 0;
    try {
      final metadata = await sourceAdapter.getFileMetadata(sourceFileId);
      if (metadata != null && !metadata.isFolder) {
        fileSize = metadata.size;
      }
    } catch (e) {
    }
    
    // Use UnifiedCopyService for chunk-based copy
    // This handles the download→upload→clear loop for all provider combinations
    final unifiedService = UnifiedCopyService();
    
    // Get file metadata for size
    int sourceFileSize = 0;
    try {
      final metadata = await sourceAdapter.getFileMetadata(sourceFileId);
      if (metadata != null && !metadata.isFolder) {
        sourceFileSize = metadata.size;
      }
    } catch (e) {
    }
    
    final fileId = await unifiedService.copyFile(
      sourceAdapter: sourceAdapter,
      sourceFileId: sourceFileId,
      sourceFileSize: sourceFileSize,
      destAdapter: destAdapter,
      destParentId: destFolderId,
      destFileName: fileName,
      onProgress: (progress) {
        _updateProgressTimeBased(task, progress.progressPercent);
      },
      cancelFlag: () => task.cancellationToken.isCancelled,
    );
    
    if (fileId != null) {
    } else {
      throw Exception("Unified copy failed for $fileName");
    }
  }
  
  /// Enhanced copy folder execution with parallel processing
  Future<void> _executeCopyFolderParallel(QueuedTask task) async {
    final sourceFolderId = task.payload['sourceFolderId'];
    final destinationParentId = task.payload['destinationParentId'];
    final newName = task.payload['newName'];
    final accountId = task.accountId;
    final isRecursive = task.payload['isRecursive'] ?? false;
    
    // Check if cancelled before starting
    if (task.cancellationToken.isCancelled) {
      throw Exception("Copy folder cancelled by user");
    }
    
    
    final adapter = getAdapterForAccount!(accountId!);
    if (adapter == null) throw Exception("Account not found");
    
    try {
      // Update progress to show we're starting
      _updateProgressTimeBased(task, 0.1);
      
      // Determine if we should check duplicates based on provider
      final checkDuplicates = false;
      
      // Determine if this is a cross-provider copy
      final sourceAccountId = task.payload['sourceAccountId'] ?? accountId;
      final isCrossProviderCopy = sourceAccountId != accountId;
      
      String newFolderId;
      
      if (!isCrossProviderCopy) {
        // SAME PROVIDER COPY: Use destination adapter's copyFolder method
        newFolderId = await adapter.copyFolder(
          sourceFolderId,
          destinationParentId,
          newName,
          checkDuplicates: checkDuplicates,
        );
        
        // Update progress for folder creation
        _updateProgressTimeBased(task, 0.3);
        
        if (isRecursive) {
        }
      } else {
        // CROSS-PROVIDER COPY: Use UnifiedCopyService for optimized cross-provider transfer
        
        // Step 1: Get source adapter
        final sourceAdapter = getAdapterForAccount!(sourceAccountId!);
        if (sourceAdapter == null) throw Exception("Source account not found");
        
        
        // Step 2: Create destination folder using destination adapter
        newFolderId = await adapter.createFolder(newName, destinationParentId, checkDuplicates: checkDuplicates);
        
        // Update progress for folder creation
        _updateProgressTimeBased(task, 0.3);
        
        // Step 3: Use UnifiedCopyService.copyFolder() for recursive content copy
        
        
        // Step 3: Use UnifiedCopyService.copyFolder() for recursive content copy
        final unifiedService = UnifiedCopyService();
        
        await unifiedService.copyFolder(
          sourceFolderId: sourceFolderId,
          sourceAdapter: sourceAdapter,
          destAdapter: adapter,
          destParentId: newFolderId,
          destFolderName: newName,
          chunkSize: 10 * 1024 * 1024, // 10MB chunks
          onProgress: (progress) {
            // Convert UnifiedCopyService progress to TaskService progress
            // Progress range: 30% to 95%
            final newProgress = 0.3 + (0.65 * progress.progressPercent);
            _updateProgressTimeBased(task, newProgress);
          },
          cancelFlag: () => task.cancellationToken.isCancelled,
        );
        
      }
      
      // Update task with result
      task.payload['newFolderId'] = newFolderId;
      task.status = TaskStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      
    } catch (e) {
      task.status = TaskStatus.failed;
      task.errorMessage = e.toString();
    }
    
    notifyListeners();
  }
  
  /// Standard task execution for non-transfer tasks
  Future<void> _executeStandardTask(QueuedTask task) async {
    switch (task.type) {
      case TaskType.delete:
        await _executeDelete(task);
        break;
      case TaskType.move:
        await _executeMove(task);
        break;
      case TaskType.createFolder:
        await _executeCreateFolder(task);
        break;
      default:
        await Future.delayed(const Duration(seconds: 1)); // Mock
    }
  }
  
  /// Execute delete task with cancellation support
  Future<void> _executeDelete(QueuedTask task) async {
    final cloudId = task.payload['cloudId'];
    final accountId = task.accountId;
    
    // Check if cancelled before starting
    if (task.cancellationToken.isCancelled) {
      throw Exception("Delete cancelled by user");
    }
    
    final adapter = getAdapterForAccount!(accountId!);
    if (adapter == null) throw Exception("Account not found");
    
    // Update progress to show we're working
    _updateProgressTimeBased(task, 0.5);
    
    await adapter.deleteNode(cloudId);
    
    // Mark as completed
    task.status = TaskStatus.completed;
    task.progress = 1.0;
    task.completedAt = DateTime.now();
    
  }
  
  /// Execute move task with cancellation support
  Future<void> _executeMove(QueuedTask task) async {
    final cloudId = task.payload['cloudId'];
    final newParentId = task.payload['newParentId'];
    final newName = task.payload['newName'];
    final accountId = task.accountId;
    
    // Check if cancelled before starting
    if (task.cancellationToken.isCancelled) {
      throw Exception("Move cancelled by user");
    }
    
    final adapter = getAdapterForAccount!(accountId!);
    if (adapter == null) throw Exception("Account not found");
    
    // Update progress to show we're working
    _updateProgressTimeBased(task, 0.3);
    
    // Move the node
    await adapter.moveNode(cloudId, newParentId, newName: newName);
    
    // Update progress to show completion
    _updateProgressTimeBased(task, 0.9);
    
    // Mark as completed
    task.status = TaskStatus.completed;
    task.progress = 1.0;
    task.completedAt = DateTime.now();
    
  }
  
  /// Execute create folder task with cancellation support
  Future<void> _executeCreateFolder(QueuedTask task) async {
    final folderName = task.payload['folderName'];
    final parentId = task.payload['parentId'];
    final accountId = task.accountId;
    
    // Check if cancelled before starting
    if (task.cancellationToken.isCancelled) {
      throw Exception("Create folder cancelled by user");
    }
    
    final adapter = getAdapterForAccount!(accountId!);
    if (adapter == null) throw Exception("Account not found");
    
    // Update progress to show we're working
    _updateProgressTimeBased(task, 0.5);
    
    // Create the folder
    await adapter.createFolder(folderName, parentId);
    
    // Mark as completed
    task.status = TaskStatus.completed;
    task.progress = 1.0;
    task.completedAt = DateTime.now();
    
  }
  
  // --- 3. EXECUTORS ---
   
  Future<void> _executeUpload(QueuedTask task) async {
    final filePath = task.payload['filePath'];
    final parentId = task.payload['parentId'];
    final accountId = task.accountId;
    
    // Get the adapter using the getter function
    final adapter = getAdapterForAccount!(accountId!);
    if (adapter == null) throw Exception("Account not found");
    
    // Use the generic interface method - all adapters support uploadFile
    await adapter.uploadFile(filePath, parentId);
  }
   
  Future<void> _executeCopyFolder(QueuedTask task) async {
    final sourceFolderId = task.payload['sourceFolderId'];
    final destinationParentId = task.payload['destinationParentId'];
    final newName = task.payload['newName'];
    final accountId = task.accountId;
    final isRecursive = task.payload['isRecursive'] ?? false;
    
    
    final adapter = getAdapterForAccount!(accountId!);
    if (adapter == null) throw Exception("Account not found");
    
    try {
      // Update progress to show we're starting
      _updateProgressTimeBased(task, 0.1);
      
      // Determine if we should check duplicates based on provider
      final checkDuplicates = false;
      final newFolderId = await adapter.copyFolder(
        sourceFolderId,
        destinationParentId,
        newName,
        checkDuplicates: checkDuplicates,
      );
      
      // Update progress for folder creation
      _updateProgressTimeBased(task, 0.3);
      
      // Only do additional recursive copy if copying between different providers
      // or if the adapter's copyFolder method doesn't handle recursion
      final sourceAccountId = task.payload['sourceAccountId'] ?? accountId;
      final isCrossProviderCopy = sourceAccountId != accountId;
      
      if (isRecursive && isCrossProviderCopy) {
        final sourceAdapter = getAdapterForAccount!(sourceAccountId);
        if (sourceAdapter == null) throw Exception("Source account not found");
        
        
        // Get source folder contents
        final result = await sourceAdapter.listFolder(sourceFolderId);
        final sourceContents = result.nodes;
        int totalItems = sourceContents.length;
        int processedItems = 0;
        
        
        // Process each item
        for (final item in sourceContents) {
          try {
            
            if (item.isFolder) {
              // Recursively copy subfolder
              // Use provider-specific duplicate checking (OneDrive requires unique names)
              final checkDuplicates = adapter.providerId == 'onedrive';
              final subFolderId = await adapter.createFolder(item.name, newFolderId, checkDuplicates: checkDuplicates);
              
              await _copyFolderContentsRecursively(
                sourceAdapter,
                adapter,
                item.cloudId!,
                subFolderId,
              );
            } else {
              // Copy file
              await _copyFileBetweenAdapters(
                sourceAdapter,
                adapter,
                item.cloudId!,
                item.name,
                newFolderId,
              );
            }
            
            processedItems++;
            // Update progress (70-90% for content copying) - optimized
            final newProgress = 0.7 + (0.2 * processedItems / totalItems);
            _updateProgressTimeBased(task, newProgress);
          } catch (e) {
            // Continue with other items even if one fails
          }
        }
        
      } else if (isRecursive && !isCrossProviderCopy) {
      }
      
      // Update task with result
      task.payload['newFolderId'] = newFolderId;
      task.status = TaskStatus.completed;
      task.progress = 1.0;
      task.completedAt = DateTime.now();
      
    } catch (e) {
      task.status = TaskStatus.failed;
      task.errorMessage = e.toString();
    }
    
    notifyListeners();
  }
  
  /// Helper method to recursively copy folder contents between adapters
  /// Optimized with rate limiting to prevent main thread flooding
  Future<void> _copyFolderContentsRecursively(
    ICloudAdapter sourceAdapter,
    ICloudAdapter destAdapter,
    String sourceFolderId,
    String destFolderId,
    {int maxConcurrent = 1} // Limit concurrent operations to reduce main thread pressure
  ) async {
    final result = await sourceAdapter.listFolder(sourceFolderId);
    final contents = result.nodes;
    
    // Process items sequentially to avoid overwhelming the main thread
    int itemCount = 0;
    for (final item in contents) {
      try {
        if (item.isFolder) {
          // Create subfolder and recurse
          // Use provider-specific duplicate checking (OneDrive requires unique names)
          final checkDuplicates = destAdapter.providerId == 'onedrive';
          final newSubFolderId = await destAdapter.createFolder(item.name, destFolderId, checkDuplicates: checkDuplicates);
          await _copyFolderContentsRecursively(
            sourceAdapter,
            destAdapter,
            item.cloudId!,
            newSubFolderId,
          );
        } else {
          // Copy file with retry logic
          await _copyFileBetweenAdaptersWithRetry(
            sourceAdapter,
            destAdapter,
            item.cloudId!,
            item.name,
            destFolderId,
          );
        }
        // Add delay based on item count to progressively increase delay
        itemCount++;
        final delayMs = 50 + (itemCount ~/ 10) * 5; // Progressive delay: 50ms, 55ms, 60ms, etc.
        await Future.delayed(Duration(milliseconds: delayMs));
      } catch (e) {
        rethrow; // Re-throw to let caller handle the error
      }
    }
  }
  
  /// Helper method to copy folder contents between providers with parallel processing
  Future<void> _copyFolderContentsCrossProvider(
    QueuedTask task,
    ICloudAdapter sourceAdapter,
    ICloudAdapter destAdapter,
    String sourceFolderId,
    String destFolderId,
  ) async {
    // Get source folder contents
    final result = await sourceAdapter.listFolder(sourceFolderId);
    final sourceContents = result.nodes;
    int totalItems = sourceContents.length;
    int processedItems = 0;
    final failedItems = <String>[];
    
    
    // Separate folders and files for optimized processing
    final folders = sourceContents.where((item) => item.isFolder).toList();
    final files = sourceContents.where((item) => !item.isFolder).toList();
    
    
    // Process folders first (must be sequential to maintain hierarchy)
    final folderFutures = <Future<void>>[];
    for (final folder in folders) {
      try {
        // Use provider-specific duplicate checking (OneDrive requires unique names)
        final checkDuplicates = destAdapter.providerId == 'onedrive';
        final subFolderId = await destAdapter.createFolder(folder.name, destFolderId, checkDuplicates: checkDuplicates);
        
        // Process subfolder contents in parallel
        folderFutures.add(_copyFolderContentsRecursively(
          sourceAdapter,
          destAdapter,
          folder.cloudId!,
          subFolderId,
        ).catchError((e) {
          failedItems.add("${folder.name}/ (subfolder)");
        }));        
        processedItems++;
      } catch (e) {
        failedItems.add(folder.name);
      }
    }
    
    // Process files in parallel with semaphore control
    final fileFutures = <Future<void>>[];
    final semaphore = _Semaphore(MAX_CONCURRENT_TRANSFERS_PER_ACCOUNT);
    
    for (final file in files) {
      fileFutures.add(_copyFileBetweenAdaptersWithSemaphore(
        sourceAdapter,
        destAdapter,
        file.cloudId!,
        file.name,
        destFolderId,
        semaphore,
        () {
          processedItems++;
          // Batch progress updates - only update every 5 items or at the end
          if (processedItems % 5 == 0 || processedItems == totalItems) {
            final newProgress = 0.3 + (0.6 * processedItems / totalItems);
            _updateProgressTimeBased(task, newProgress);
          }
        },
      ).catchError((e) {
        failedItems.add(file.name);
      }));    
    }
    
    // Wait for all folder operations to complete
    if (folderFutures.isNotEmpty) {
      await Future.wait(folderFutures, eagerError: false);
    }
    
    // Wait for all file operations to complete
    if (fileFutures.isNotEmpty) {
      await Future.wait(fileFutures, eagerError: false);
    }
    
    // Report any failures
    if (failedItems.isNotEmpty) {
      final warningMsg = "Completed with ${failedItems.length} failed items: ${failedItems.join(', ')}";
      // Store warning in task payload for UI to display
      task.payload['warnings'] = failedItems;
    }
    
  }
  
  /// Copy file between adapters with semaphore control for parallel processing
  Future<void> _copyFileBetweenAdaptersWithSemaphore(
    ICloudAdapter sourceAdapter,
    ICloudAdapter destAdapter,
    String sourceFileId,
    String fileName,
    String destFolderId,
    _Semaphore semaphore,
    VoidCallback onProgress,
  ) async {
    await semaphore.acquire();
    
    try {
      await _copyFileBetweenAdapters(
        sourceAdapter,
        destAdapter,
        sourceFileId,
        fileName,
        destFolderId,
      );
      onProgress();
    } catch (e) {
      rethrow;
    } finally {
      semaphore.release();
    }
  }
  
  /// Helper method to copy file between adapters
  Future<void> _copyFileBetweenAdapters(
    ICloudAdapter sourceAdapter,
    ICloudAdapter destAdapter,
    String sourceFileId,
    String fileName,
    String destFolderId,
  ) async {
    await _copyFileBetweenAdaptersWithRetry(sourceAdapter, destAdapter, sourceFileId, fileName, destFolderId);
  }
  
  /// Helper method to copy file between adapters with retry logic using hybrid approach
  /// Uses streaming for small files (< 100MB) and temp files for large files (>= 100MB)
  Future<void> _copyFileBetweenAdaptersWithRetry(
    ICloudAdapter sourceAdapter,
    ICloudAdapter destAdapter,
    String sourceFileId,
    String fileName,
    String destFolderId, {
    int maxRetries = 3,
  }) async {
    int attempt = 0;
    Exception? lastError;
    bool success = false;
    
    
    // Try to get file size for progress tracking and to determine approach
    int fileSize = 0;
    bool fileSizeKnown = false;
    
    try {
      final metadata = await sourceAdapter.getFileMetadata(sourceFileId);
      if (metadata != null && !metadata.isFolder) {
        fileSize = metadata.size;
        fileSizeKnown = true;
      } else {
      }
    } catch (e) {
    }
    
    // Determine approach: streaming for small files, temp file for large files
    const int tempFileThreshold = 100 * 1024 * 1024; //100 MB threshold
    final bool useTempFile = fileSizeKnown && fileSize >= tempFileThreshold;
    
    if (useTempFile) {
    } else {
    }
    
    while (attempt < maxRetries && !success) {
      attempt++;
      try {
        if (useTempFile) {
          // TEMP FILE APPROACH: Download to temp file, then upload from temp file
          await _copyFileWithTempFile(
            sourceAdapter,
            destAdapter,
            sourceFileId,
            fileName,
            destFolderId,
            fileSize,
          );
        } else {
          // STREAMING APPROACH: Direct pipe from download to upload
          await _copyFileWithStreaming(
            sourceAdapter,
            destAdapter,
            sourceFileId,
            fileName,
            destFolderId,
            fileSizeKnown ? fileSize : 0,
          );
        }
        
        // Success!
        success = true;
        
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        
        if (attempt < maxRetries) {
          // Wait before retry (exponential backoff)
          final delayMs = 1000 * (1 << (attempt - 1)); // 1s, 2s, 4s
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
    }
    
    // Check final result
    if (success) {
    } else {
    }
    
    // All retries failed
    if (!success) {
      throw lastError ?? Exception("Failed to copy file $fileName after $maxRetries attempts");
    }
  }
  
  /// Copy file using streaming approach (for small files)
  /// Note: This method doesn't have direct task access, cancellation is handled at the caller level
  Future<void> _copyFileWithStreaming(
    ICloudAdapter sourceAdapter,
    ICloudAdapter destAdapter,
    String sourceFileId,
    String fileName,
    String destFolderId,
    int fileSize,
  ) async {
    // STREAMING: Direct pipe from download to upload without buffering
    final sourceStream = await sourceAdapter.downloadStream(sourceFileId);
    
    // Create a custom stream transformer for progress tracking
    int bytesTransferred = 0;
    final progressStream = sourceStream.transform<List<int>>(
      StreamTransformer.fromHandlers(
        handleData: (data, sink) {
          bytesTransferred += data.length;
          // Data is passed through immediately - no buffering
          sink.add(data);
        },
        handleError: (error, stackTrace, sink) {
          sink.addError(error, stackTrace);
        },
        handleDone: (sink) {
          sink.close();
        },
      ),
    );
    
    // Upload the stream - adapter handles chunking internally
    await destAdapter.uploadStream(fileName, progressStream, fileSize, destFolderId, cancellationToken: null);
  }
  
  /// Copy file using CHUNKED approach with temp files - download 10MB chunk, upload, delete
  /// This approach minimizes memory usage while working within cloud API limitations
  ///
  /// For cloud APIs that support resumable uploads (like Google Drive), we could use their
  /// native chunked upload API. For now, we use a practical approach:
  /// - Download complete file to temp location
  /// - Upload from temp location
  /// - Delete temp file
  ///
  /// Note: For true chunked uploads where each chunk is uploaded separately and deleted,
  /// the cloud adapter would need to support resumable/session-based uploads.
  Future<void> _copyFileWithChunkedTempFile(
    ICloudAdapter sourceAdapter,
    ICloudAdapter destAdapter,
    String sourceFileId,
    String fileName,
    String destFolderId,
    int fileSize,
  ) async {
    final tempDir = await getTemporaryDirectory();
    const chunkSize = 10 * 1024 * 1024; // 10MB target for chunked operations
    
    
    // Determine if we should use chunked approach based on file size
    const int minChunkedSize = 50 * 1024 * 1024; // 50MB minimum for chunked
    
    if (fileSize < minChunkedSize) {
      // For smaller files, use direct streaming
      await _copyFileWithStreaming(
        sourceAdapter,
        destAdapter,
        sourceFileId,
        fileName,
        destFolderId,
        fileSize,
      );
      return;
    }
    
    // For large files, download to temp file, then upload
    
    final tempFile = File('${tempDir.path}/$fileName.tmp');
    
    try {
      // Download to temp file (cloud to disk using Dart stream)
      
      final sourceStream = await sourceAdapter.downloadStream(sourceFileId);
      final sink = tempFile.openWrite();
      
      int bytesDownloaded = 0;
      int lastProgressUpdate = 0;
      
      // Process stream with progress tracking
      await for (final chunk in sourceStream) {
        sink.add(chunk);
        bytesDownloaded += chunk.length;
        
        // Progress update every 10MB
        if (bytesDownloaded - lastProgressUpdate >= chunkSize) {
          lastProgressUpdate = bytesDownloaded;
          if (fileSize > 0) {
            final progress = bytesDownloaded / fileSize;
          }
        }
      }
      
      await sink.close();
      
      // Upload from temp file using Dart streaming (disk to cloud)
      // Removed Rust-based streaming to fix MP4 corruption issues
      
      final tempFileStream = tempFile.openRead();
      int bytesUploaded = 0;
      
      final progressStream = tempFileStream.transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleData: (chunk, sink) {
            bytesUploaded += chunk.length;
            if (fileSize > 0) {
              final progress = bytesUploaded / fileSize;
            }
            sink.add(chunk);
          },
          handleDone: (sink) {
            sink.close();
          },
        ),
      );
      
      await destAdapter.uploadStream(fileName, progressStream, fileSize, destFolderId, cancellationToken: null);
      
      
    } finally {
      // Cleanup temp file
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (e) {
        }
      }
    }
  }
  
  /// Copy file using temp file approach (for large files)
  /// Now uses chunked/temp file approach by default for files >= 50MB
  Future<void> _copyFileWithTempFile(
    ICloudAdapter sourceAdapter,
    ICloudAdapter destAdapter,
    String sourceFileId,
    String fileName,
    String destFolderId,
    int fileSize,
  ) async {
    await _copyFileWithChunkedTempFile(
      sourceAdapter,
      destAdapter,
      sourceFileId,
      fileName,
      destFolderId,
      fileSize,
    );
  }
  
  /// Format bytes to human-readable string
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  
  // --- UNIFIED COPY/PASTE METHODS ---
  
  /// Public method to copy items (files and folders) between any providers/accounts
  /// This is the unified entry point for all copy/paste operations
  /// Creates tasks for tracking in TaskProgressWidget
  Future<void> copyItemsUnified(
    List<CloudNode> items,
    ICloudAdapter destAdapter,
    String destParentId,
    String destAccountId,
    String destProvider,
  ) async {
    
    // Separate folders and files
    final folders = items.where((item) => item.isFolder).toList();
    final files = items.where((item) => !item.isFolder).toList();
    
    
    // Create tasks for folders
    for (final folder in folders) {
      final task = QueuedTask(
        id: const Uuid().v4(),
        type: TaskType.copyFolder,
        name: folder.name,
        accountId: destAccountId,
        payload: {
          'sourceFolderId': folder.cloudId,
          'sourceAccountId': folder.accountId,
          'destinationParentId': destParentId,
          'newName': folder.name,
          'isRecursive': true,
        },
      );
      
      addTask(task);
    }
    
    // Create tasks for files
    for (final file in files) {
      final task = QueuedTask(
        id: const Uuid().v4(),
        type: TaskType.copyFile,
        name: file.name,
        accountId: destAccountId,
        payload: {
          'sourceFileId': file.cloudId,
          'sourceAccountId': file.accountId,
          'destinationParentId': destParentId,
          'newName': file.name,
        },
      );
      
      addTask(task);
    }
    
  }
  
  /// Unified method to copy items (files and folders) between any providers/accounts
  /// Handles: single/multiple files, single/multiple folders, mixed items
  /// Optimizations: True streaming, parallel file processing, sequential folder creation
  Future<void> _copyItemsUnified(
    List<CloudNode> items,
    ICloudAdapter destAdapter,
    String destParentId,
    String destAccountId,
    String destProvider,
  ) async {
    
    // Separate folders and files
    final folders = items.where((item) => item.isFolder).toList();
    final files = items.where((item) => !item.isFolder).toList();
    
    
    // Process folders sequentially (to maintain hierarchy)
    for (final folder in folders) {
      try {
        await _copyFolderUnified(
          folder,
          destAdapter,
          destParentId,
          destAccountId,
          destProvider,
        );
      } catch (e) {
        // Continue with other items even if one fails
      }
    }
    
    // Process files in parallel with semaphore control
    if (files.isNotEmpty) {
      final semaphore = _Semaphore(MAX_CONCURRENT_TRANSFERS_PER_ACCOUNT);
      final futures = <Future<void>>[];
      
      for (final file in files) {
        futures.add(_copyFileWithSemaphore(
          file,
          destAdapter,
          destParentId,
          destAccountId,
          semaphore,
        ));
      }
      
      // Wait for all file operations to complete
      await Future.wait(futures, eagerError: false);
      
    }
  }
  
  /// Unified folder copy method that works for all providers/accounts
  Future<void> _copyFolderUnified(
    CloudNode folder,
    ICloudAdapter destAdapter,
    String destParentId,
    String destAccountId,
    String destProvider,
  ) async {
    
    // Determine if we should check duplicates based on destination provider
    final checkDuplicates = destProvider == 'onedrive';
    
    // Create destination folder
    final newFolderId = await destAdapter.createFolder(
      folder.name,
      destParentId,
      checkDuplicates: checkDuplicates,
    );
    
    // Get source adapter
    final sourceAdapter = getAdapterForAccount!(folder.accountId!);
    if (sourceAdapter == null) throw Exception("Source account not found for ${folder.name}");
    
    // Get source folder contents
    final result = await sourceAdapter.listFolder(folder.cloudId!);
    final sourceContents = result.nodes;
    
    // Separate folders and files
    final subfolders = sourceContents.where((item) => item.isFolder).toList();
    final files = sourceContents.where((item) => !item.isFolder).toList();
    
    
    // Process subfolders recursively
    for (final subfolder in subfolders) {
      try {
        await _copyFolderUnified(
          subfolder,
          destAdapter,
          newFolderId,
          destAccountId,
          destProvider,
        );
      } catch (e) {
      }
    }
    
    // Process files in parallel with semaphore control
    if (files.isNotEmpty) {
      final semaphore = _Semaphore(MAX_CONCURRENT_TRANSFERS_PER_ACCOUNT);
      final futures = <Future<void>>[];
      
      for (final file in files) {
        futures.add(_copyFileWithSemaphore(
          file,
          destAdapter,
          newFolderId,
          destAccountId,
          semaphore,
        ));
      }
      
      await Future.wait(futures, eagerError: false);
    }
  }
  
  /// Unified file copy method with semaphore control for parallel processing
  Future<void> _copyFileWithSemaphore(
    CloudNode file,
    ICloudAdapter destAdapter,
    String destParentId,
    String destAccountId,
    _Semaphore semaphore,
  ) async {
    await semaphore.acquire();
    
    try {
      
      // Get source adapter
      final sourceAdapter = getAdapterForAccount!(file.accountId!);
      if (sourceAdapter == null) throw Exception("Source account not found for ${file.name}");
      
      // Copy file with retry logic
      await _copyFileBetweenAdapters(
        sourceAdapter,
        destAdapter,
        file.cloudId!,
        file.name,
        destParentId,
      );
      
    } catch (e) {
    } finally {
      semaphore.release();
    }
  }
  
  /// Get count of currently selected items
  /// This connects to the UI selection state through a callback
  int getSelectedItemsCount() {
    if (_getSelectedItemsCountCallback != null) {
      return _getSelectedItemsCountCallback!();
    }
    return 0;
  }
  
  // --- TASK CONTROL METHODS ---
   
  /// Pause a pending or running task
  /// For running tasks, we mark the cancellation token as paused
  /// The task will remain visible in the active tasks widget until cancelled or resumed
  void pauseTask(String taskId) {
    final task = _tasks.firstWhere((t) => t.id == taskId, orElse: () => throw Exception("Task not found"));
    
    if (task.status == TaskStatus.pending || task.status == TaskStatus.running) {
      task.status = TaskStatus.paused;
      task.cancellationToken.pause();
      notifyListeners();
      // Don't call _processQueue() here - we want to keep the task paused
    }
  }
   
  /// Resume a paused task (allows it to start again)
  void resumeTask(String taskId) {
    final task = _tasks.firstWhere((t) => t.id == taskId, orElse: () => throw Exception("Task not found"));
    if (task.status == TaskStatus.paused) {
      task.status = TaskStatus.pending;
      task.cancellationToken.resume();
      notifyListeners();
      // Process queue to pick up the resumed task
      _processQueue();
    }
  }
   
  /// Cancel a task (removes it from the queue)
  /// Works for pending, paused, and running tasks
  void cancelTask(String taskId) {
    final task = _tasks.firstWhere((t) => t.id == taskId, orElse: () => throw Exception("Task not found"));
    
    if (task.status == TaskStatus.pending || task.status == TaskStatus.paused || task.status == TaskStatus.running) {
      task.status = TaskStatus.failed;
      task.errorMessage = "Cancelled by user";
      task.completedAt = DateTime.now();
      task.cancellationToken.cancel();
      notifyListeners();
    }
  }
  
  /// Stop/cancel a pending or paused task (legacy method, use cancelTask instead)
  @Deprecated('Use cancelTask instead')
  void stopTask(String taskId) {
    cancelTask(taskId);
  }
  
  /// Toggle pause/resume for a task
  void togglePauseTask(String taskId) {
    final task = _tasks.firstWhere((t) => t.id == taskId, orElse: () => throw Exception("Task not found"));
    if (task.status == TaskStatus.pending || task.status == TaskStatus.running) {
      pauseTask(taskId);
    } else if (task.status == TaskStatus.paused) {
      resumeTask(taskId);
    }
  }
  
  @override
  void dispose() {
    _globalProgressTimer?.cancel();
    super.dispose();
  }
}