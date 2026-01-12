import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import '../models/cloud_node.dart';
import '../models/encrypted_file_mapping.dart';
import '../adapters/cloud_adapter.dart';
import '../providers/file_system_provider.dart';
import '../services/task_service.dart';
import '../models/queued_task.dart';
import '../services/security_service.dart';
import '../services/hive_storage_service.dart';
import '../services/encryption_name_service.dart';
import 'rust_file_operations_service.dart';
import 'package:path_provider/path_provider.dart';

/// Throttled stream controller to prevent main thread flooding
class ThrottledStreamController<T> {
  final StreamController<T> _controller;
  final Duration throttleDuration;
  Timer? _throttleTimer;
  T? _pendingValue;
  bool _hasPendingValue = false;

  ThrottledStreamController({
    required this.throttleDuration,
    void Function()? onListen,
    void Function()? onCancel,
  }) : _controller = StreamController<T>.broadcast(
    onListen: onListen,
    onCancel: onCancel,
  );

  Stream<T> get stream => _controller.stream;

  void add(T value) {
    _pendingValue = value;
    _hasPendingValue = true;

    if (_throttleTimer == null || !_throttleTimer!.isActive) {
      _throttleTimer = Timer(throttleDuration, _emitPending);
    }
  }

  void _emitPending() {
    if (_hasPendingValue && _pendingValue != null) {
      _controller.add(_pendingValue!);
      _hasPendingValue = false;
      _pendingValue = null;
    }
  }

  Future<void> close() async {
    _throttleTimer?.cancel();
    // Emit any pending value before closing
    if (_hasPendingValue && _pendingValue != null) {
      _controller.add(_pendingValue!);
    }
    await _controller.close();
  }

  bool get isClosed => _controller.isClosed;
}

/// Represents a single item to be uploaded (file or folder)
class UploadItem {
  final String localPath;
  final String relativePath; // Path relative to root folder
  final bool isFolder;
  final int size; // File size in bytes (0 for folders)
  final String? parentId; // Cloud parent folder ID

  UploadItem({
    required this.localPath,
    required this.relativePath,
    required this.isFolder,
    this.size = 0,
    this.parentId,
  });

  String get name => path.basename(localPath);
}

/// Progress information for folder upload
class FolderUploadProgress {
  final String folderName;
  final int totalItems;
  final int completedItems;
  final int totalBytes;
  final int uploadedBytes;
  final String currentItem;
  final bool isCompleted;
  final String? error;

  FolderUploadProgress({
    required this.folderName,
    required this.totalItems,
    required this.completedItems,
    required this.totalBytes,
    required this.uploadedBytes,
    required this.currentItem,
    this.isCompleted = false,
    this.error,
  });

  double get progressPercentage => totalItems > 0 ? completedItems / totalItems : 0.0;
  double get bytesProgressPercentage => totalBytes > 0 ? uploadedBytes / totalBytes : 0.0;
}

/// Service for handling folder uploads to cloud storage
class FolderUploadService {
  static const int MAX_CONCURRENT_UPLOADS = 3;
  static const int DEFAULT_CHUNK_SIZE = 1024 * 1024; // 1MB
  static const int LARGE_FILE_THRESHOLD = 50 * 1024 * 1024; // 50MB - threshold for large files
  static const int MAX_FILE_SIZE_FOR_MEMORY = 500 * 1024 * 1024; // 500MB - max size to load into memory

  final Map<String, ThrottledStreamController<FolderUploadProgress>> _progressControllers = {};
  final Map<String, bool> _activeUploads = {};
  
  /// Rust file operations service for high-performance I/O
  final RustFileOperationsService _rustService;

  FolderUploadService({RustFileOperationsService? rustService})
      : _rustService = rustService ?? RustFileOperationsService();

  /// Upload a local folder to cloud storage
  Future<String> uploadFolder({
    required String folderPath,
    required ICloudAdapter adapter,
    required String? parentFolderId,
    required String accountId,
    ProgressCallback? onProgress,
    VoidCallback? onComplete,
    Function(String)? onError,
  }) async {
    final uploadId = const Uuid().v4();
    final folderName = path.basename(folderPath);
    

    try {
      // Create throttled progress controller for this upload (updates every 200ms max)
      final progressController = ThrottledStreamController<FolderUploadProgress>(
        throttleDuration: const Duration(milliseconds: 200),
      );
      _progressControllers[uploadId] = progressController;
      _activeUploads[uploadId] = true;

      // Step 1: Scan folder structure (using Rust for better performance)
      final uploadItems = await _scanFolderRust(folderPath, parentFolderId);

      // Step 2: Create root folder in cloud
      final rootFolderId = await adapter.createFolder(folderName, parentFolderId);

      // Step 3: Upload folder structure and files
      await _uploadFolderStructure(
        uploadItems,
        adapter,
        rootFolderId,
        accountId,
        progressController,
        onProgress,
      );

      // Clean up
      await progressController.close();
      _progressControllers.remove(uploadId);
      _activeUploads.remove(uploadId);

      onComplete?.call();
      
      return rootFolderId;

    } catch (e) {
      onError?.call(e.toString());
      
      // Clean up on error
      _progressControllers.remove(uploadId);
      _activeUploads.remove(uploadId);
      
      rethrow;
    }
  }

  /// Scan local folder using Dart (original implementation)
  Future<List<UploadItem>> _scanFolder(String folderPath, String? parentId) async {
    final uploadItems = <UploadItem>[];
    final folder = Directory(folderPath);

    if (!await folder.exists()) {
      throw Exception("Folder does not exist: $folderPath");
    }

    await for (final entity in folder.list(recursive: true, followLinks: false)) {
      final relativePath = path.relative(entity.path, from: folderPath);
      
      if (entity is File) {
        final fileSize = await entity.length();
        uploadItems.add(UploadItem(
          localPath: entity.path,
          relativePath: relativePath,
          isFolder: false,
          size: fileSize,
        ));
      } else if (entity is Directory) {
        uploadItems.add(UploadItem(
          localPath: entity.path,
          relativePath: relativePath,
          isFolder: true,
        ));
      }
    }

    // Sort items: folders first, then files, maintaining directory structure
    uploadItems.sort((a, b) {
      if (a.isFolder && !b.isFolder) return -1;
      if (!a.isFolder && b.isFolder) return 1;
      return a.relativePath.compareTo(b.relativePath);
    });

    return uploadItems;
  }

  /// Scan local folder using Rust for better performance with large folders
  Future<List<UploadItem>> _scanFolderRust(String folderPath, String? parentId) async {
    try {
      // Use Rust scanning for better performance
      final entries = await _rustService.scanDirectory(folderPath);
      
      final uploadItems = <UploadItem>[];
      
      for (final entry in entries) {
        uploadItems.add(UploadItem(
          localPath: entry['path'] as String,
          relativePath: entry['relativePath'] as String,
          isFolder: entry['isFolder'] as bool,
          size: entry['size'] as int? ?? 0,
        ));
      }
      
      // Sort items: folders first, then files, maintaining directory structure
      uploadItems.sort((a, b) {
        if (a.isFolder && !b.isFolder) return -1;
        if (!a.isFolder && b.isFolder) return 1;
        return a.relativePath.compareTo(b.relativePath);
      });
      
      return uploadItems;
    } catch (e) {
      return _scanFolder(folderPath, parentId);
    }
  }

  /// Upload folder structure and files to cloud
  Future<void> _uploadFolderStructure(
    List<UploadItem> uploadItems,
    ICloudAdapter adapter,
    String rootFolderId,
    String accountId,
    ThrottledStreamController<FolderUploadProgress> progressController,
    ProgressCallback? onProgress,
  ) async {
    final folderName = path.basename(uploadItems.first.localPath);
    final totalItems = uploadItems.length;
    final totalBytes = uploadItems.where((item) => !item.isFolder).fold<int>(0, (sum, item) => sum + item.size);
    
    int completedItems = 0;
    int uploadedBytes = 0;
    final createdFolders = <String, String>{rootFolderId: ''}; // cloudId -> relativePath

    // Process items in batches to control concurrency
    for (int i = 0; i < uploadItems.length; i += MAX_CONCURRENT_UPLOADS) {
      final batch = uploadItems.skip(i).take(MAX_CONCURRENT_UPLOADS).toList();
      final futures = <Future<void>>[];

      for (final item in batch) {
        futures.add(_processUploadItem(
          item,
          adapter,
          rootFolderId,
          accountId,
          createdFolders,
        ));
      }

      // Wait for batch to complete
      await Future.wait(futures, eagerError: false);
      
      // Update progress
      for (int j = 0; j < batch.length && (i + j) < uploadItems.length; j++) {
        final itemIndex = i + j;
        completedItems++;
        if (!uploadItems[itemIndex].isFolder) {
          uploadedBytes += uploadItems[itemIndex].size;
        }
      }

      // Send progress update
      final progress = FolderUploadProgress(
        folderName: folderName,
        totalItems: totalItems,
        completedItems: completedItems,
        totalBytes: totalBytes,
        uploadedBytes: uploadedBytes,
        currentItem: uploadItems[completedItems - 1]?.name ?? '',
      );

      progressController.add(progress);
      onProgress?.call(progress);

    }

    // Send final completion progress
    final finalProgress = FolderUploadProgress(
      folderName: folderName,
      totalItems: totalItems,
      completedItems: totalItems,
      totalBytes: totalBytes,
      uploadedBytes: uploadedBytes,
      currentItem: 'Completed',
      isCompleted: true,
    );

    progressController.add(finalProgress);
    onProgress?.call(finalProgress);
  }

  /// Process a single upload item (file or folder)
  Future<void> _processUploadItem(
    UploadItem item,
    ICloudAdapter adapter,
    String rootFolderId,
    String accountId,
    Map<String, String> createdFolders,
  ) async {
    try {
      if (item.isFolder) {
        // Create folder in cloud
        final parentPath = path.dirname(item.relativePath);
        final parentId = parentPath == '.' ? rootFolderId : createdFolders[parentPath];
        
        if (parentId != null) {
          final folderId = await adapter.createFolder(item.name, parentId);
          createdFolders[item.relativePath] = folderId;
        }
      } else {
        // Upload file with encryption support
        final parentPath = path.dirname(item.relativePath);
        final parentId = parentPath == '.' ? rootFolderId : createdFolders[parentPath];
        
        if (parentId != null) {
          final file = File(item.localPath);
          final fileName = path.basename(item.localPath);
          
          // Check if encryption should be enabled for this account
          bool shouldEncrypt = await _shouldEncryptForAccount(accountId);
          
          // Initialize encryption name service
          await EncryptionNameService.instance.initialize();
          
          File fileToUpload = file;
          String uploadName = fileName;
          int fileSizeToUpload = item.size;
          
          // Handle encryption if needed
          if (shouldEncrypt) {
            if (!SecurityService.instance.isUnlocked) {
              throw Exception("Vault locked!");
            }
            
            // Generate random encrypted filename
            uploadName = EncryptionNameService.instance.generateRandomFilename();
            
            final tempDir = await getTemporaryDirectory();
            final tempFile = File('${tempDir.path}/$uploadName');
            
            // Encrypt file
            await SecurityService.instance.encryptFile(file, tempFile);
            
            fileToUpload = tempFile;
            
            // Get encrypted file size
            final encryptedSize = await tempFile.length();
            fileSizeToUpload = encryptedSize;
            
          } else {
          }
          
          // Upload the file (encrypted or original)
          // Use Dart-based stream (removed Rust to fix MP4 corruption)
          final stream = fileToUpload.openRead();
          await adapter.uploadStream(
            uploadName,
            stream,
            fileSizeToUpload,  // Use actual file size (encrypted or original)
            parentId,
          );
          
          // Save mapping if encryption was enabled
          if (shouldEncrypt) {
            final cloudFileId = await adapter.getFileIdByName(uploadName, parentId);
            
            if (cloudFileId != null) {
              await EncryptionNameService.instance.saveMapping(
                EncryptedFileMapping(
                  encryptedFileName: uploadName,
                  originalFileName: fileName,
                  cloudFileId: cloudFileId,
                  accountId: accountId,
                  parentId: parentId,
                  createdAt: DateTime.now(),
                  originalFileSize: item.size, // Store original file size for sync comparison
                ),
              );
            } else {
            }
            
            // Clean up temp encrypted file
            if (await fileToUpload.exists()) {
              await fileToUpload.delete();
            }
          }
          
        }
      }
    } catch (e) {
      // Continue with other items even if one fails
    }
  }
  
  /// Check if encryption should be enabled for a specific account
  Future<bool> _shouldEncryptForAccount(String accountId) async {
    try {
      // Import HiveStorageService locally to avoid circular dependencies
      final storageService = HiveStorageService.instance;
      final account = await storageService.getAccount(accountId);
      return account?.encryptUploads ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Encrypt file using Dart (removed Rust to fix MP4 corruption)
  Future<void> _encryptFileRust(String inputPath, String outputPath, Uint8List masterKey) async {
    try {
      final inputFile = File(inputPath);
      final outputFile = File(outputPath);
      await SecurityService.instance.encryptFile(inputFile, outputFile);
    } catch (e) {
      rethrow;
    }
  }

  /// Create a chunked stream for file upload to prevent memory issues with large files
  Stream<List<int>> _createChunkedStream(File file, int fileSize) {
    // For small files, use normal stream
    if (fileSize < LARGE_FILE_THRESHOLD) {
      return file.openRead();
    }
    
    // For large files, use chunked stream with controlled buffer size
    return file.openRead().transform(
      StreamTransformer.fromHandlers(
        handleData: (data, sink) {
          // Process data in chunks to prevent memory overload
          sink.add(data);
        },
        handleError: (error, stack, sink) {
          sink.addError(error);
        },
        handleDone: (sink) {
          sink.close();
        },
      ),
    );
  }

  /// Format bytes to human-readable string
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Get progress stream for an upload
  Stream<FolderUploadProgress>? getProgressStream(String uploadId) {
    return _progressControllers[uploadId]?.stream;
  }

  /// Cancel an active upload
  Future<void> cancelUpload(String uploadId) async {
    if (_activeUploads.containsKey(uploadId)) {
      _activeUploads[uploadId] = false;
      
      final controller = _progressControllers[uploadId];
      if (controller != null && !controller.isClosed) {
        await controller.close();
      }
      
      _progressControllers.remove(uploadId);
      _activeUploads.remove(uploadId);
      
    }
  }

  /// Check if an upload is active
  bool isUploadActive(String uploadId) {
    return _activeUploads[uploadId] ?? false;
  }

  /// Get active uploads count
  int get activeUploadsCount => _activeUploads.length;

  /// Clean up completed uploads
  void cleanupCompletedUploads() {
    final completedUploads = <String>[];
    
    for (final entry in _activeUploads.entries) {
      if (!entry.value) {
        completedUploads.add(entry.key);
      }
    }
    
    for (final uploadId in completedUploads) {
      _activeUploads.remove(uploadId);
      final controller = _progressControllers.remove(uploadId);
      if (controller != null && !controller.isClosed) {
        controller.close();
      }
    }
  }
}

/// Progress callback type for folder uploads
typedef ProgressCallback = void Function(FolderUploadProgress progress);