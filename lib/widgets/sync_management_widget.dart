import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import '../services/task_service.dart';
import '../providers/file_system_provider.dart';
import '../themes/ubuntu_theme.dart' as theme;
import '../models/cloud_node.dart';
import '../models/cloud_account.dart';
import '../models/queued_task.dart';
import '../services/hive_storage_service.dart';
import '../services/folder_upload_service.dart';
import '../services/rust_file_operations_service.dart';

/// Represents a local file or folder item for sync operations
class LocalItem {
  final String path;
  final String relativePath;
  final bool isFolder;
  final int size;
    
  LocalItem({
    required this.path,
    required this.relativePath,
    required this.isFolder,
    this.size = 0,
  });
    
  String get name => path.split(Platform.pathSeparator).last;
}

/// Cloud item info for sync comparison
class CloudItemInfo {
  final String id;
  final String name;
  final bool isFolder;
  final int size;
  final String parentId;
   
  CloudItemInfo({
    required this.id,
    required this.name,
    required this.isFolder,
    required this.size,
    required this.parentId,
  });
}

/// Sync configuration model
class SyncConfig {
  final String id;
  final String name;
  final String localPath;
  final String cloudAccountId;
  final String cloudAccountEmail;
  final String cloudAccountProvider;
  final String cloudFolderId;
  final String cloudFolderPath;
  final DateTime createdAt;
    
  SyncConfig({
    required this.id,
    required this.name,
    required this.localPath,
    required this.cloudAccountId,
    required this.cloudAccountEmail,
    required this.cloudAccountProvider,
    required this.cloudFolderId,
    required this.cloudFolderPath,
    required this.createdAt,
  });
    
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'localPath': localPath,
      'cloudAccountId': cloudAccountId,
      'cloudAccountEmail': cloudAccountEmail,
      'cloudAccountProvider': cloudAccountProvider,
      'cloudFolderId': cloudFolderId,
      'cloudFolderPath': cloudFolderPath,
      'createdAt': createdAt.toIso8601String(),
    };
  }
    
  static SyncConfig fromMap(Map<String, dynamic> map) {
    return SyncConfig(
      id: map['id'] ?? '',
      name: map['name'] ?? 'Unnamed',
      localPath: map['localPath'] ?? '',
      cloudAccountId: map['cloudAccountId'] ?? '',
      cloudAccountEmail: map['cloudAccountEmail'] ?? '',
      cloudAccountProvider: map['cloudAccountProvider'] ?? '',
      cloudFolderId: map['cloudFolderId'] ?? 'root',
      cloudFolderPath: map['cloudFolderPath'] ?? '',
      createdAt: map['createdAt'] != null
          ? DateTime.parse(map['createdAt'])
          : DateTime.now(),
    );
  }
    
  String get cloudDisplayPath => '$cloudAccountEmail ($cloudAccountProvider)$cloudFolderPath';
}

/// Result of cloud folder selection
class CloudFolderSelection {
  final String accountId;
  final String accountEmail;
  final String accountProvider;
  final String folderId;
  final String folderPath;
   
  CloudFolderSelection({
    required this.accountId,
    required this.accountEmail,
    required this.accountProvider,
    required this.folderId,
    required this.folderPath,
  });
   
  String get displayPath => '$accountEmail ($accountProvider)$folderPath';
}

class SyncManagementWidget extends StatefulWidget {
  const SyncManagementWidget({Key? key}) : super(key: key);

  @override
  State<SyncManagementWidget> createState() => _SyncManagementWidgetState();
}

class _SyncManagementWidgetState extends State<SyncManagementWidget> {
  final TextEditingController _configNameController = TextEditingController();
  final TextEditingController _localPathController = TextEditingController();
  final TextEditingController _cloudPathController = TextEditingController();
   
  String? _localPath;
  CloudFolderSelection? _cloudFolderSelection;
  bool _isSyncing = false;
  int _filesScanned = 0;
  int _filesProcessed = 0;
  int _filesFailed = 0;
  final List<String> _scanErrors = [];
  final List<SyncConfig> _savedConfigs = [];
  SyncConfig? _selectedConfig;
   
  @override
  void initState() {
    super.initState();
    _loadSavedConfigs();
  }
   
  @override
  void dispose() {
    _configNameController.dispose();
    _localPathController.dispose();
    _cloudPathController.dispose();
    super.dispose();
  }
   
  Future<void> _loadSavedConfigs() async {
    try {
      final configMaps = await HiveStorageService.instance.getSyncConfigs();
      final configs = configMaps.map((e) => SyncConfig.fromMap(e)).toList();
      setState(() {
        _savedConfigs.clear();
        _savedConfigs.addAll(configs);
      });
    } catch (e) {
    }
  }
   
  Future<void> _saveConfig() async {
    if (_configNameController.text.isEmpty) {
      _showError('Please enter a configuration name');
      return;
    }
     
    if (_localPath == null || _cloudFolderSelection == null) {
      _showError('Please select both local directory and cloud destination');
      return;
    }
     
    final config = SyncConfig(
      id: const Uuid().v4(),
      name: _configNameController.text,
      localPath: _localPath!,
      cloudAccountId: _cloudFolderSelection!.accountId,
      cloudAccountEmail: _cloudFolderSelection!.accountEmail,
      cloudAccountProvider: _cloudFolderSelection!.accountProvider,
      cloudFolderId: _cloudFolderSelection!.folderId,
      cloudFolderPath: _cloudFolderSelection!.folderPath,
      createdAt: DateTime.now(),
    );
     
    try {
      await HiveStorageService.instance.saveSyncConfig(config.toMap());
       
      setState(() {
        _savedConfigs.add(config);
        _selectedConfig = config;
      });
       
      _showMessage('Configuration saved successfully', theme.UbuntuColors.orange);
    } catch (e) {
      _showError('Failed to save configuration: $e');
    }
  }
   
  Future<void> _deleteConfig(SyncConfig config) async {
    try {
      await HiveStorageService.instance.deleteSyncConfig(config.id);
       
      setState(() {
        _savedConfigs.remove(config);
        if (_selectedConfig?.id == config.id) {
          _selectedConfig = null;
        }
      });
       
      _showMessage('Configuration deleted', theme.UbuntuColors.orange);
    } catch (e) {
      _showError('Failed to delete configuration: $e');
    }
  }
   
  void _selectConfig(SyncConfig config) {
    setState(() {
      _selectedConfig = config;
      _configNameController.text = config.name;
      _localPath = config.localPath;
      _localPathController.text = config.localPath;
      _cloudFolderSelection = CloudFolderSelection(
        accountId: config.cloudAccountId,
        accountEmail: config.cloudAccountEmail,
        accountProvider: config.cloudAccountProvider,
        folderId: config.cloudFolderId,
        folderPath: config.cloudFolderPath,
      );
      _cloudPathController.text = config.cloudDisplayPath;
    });
  }
   
  Future<void> _startSyncToSource() async {
    final config = _selectedConfig;
    if (config == null) {
      _showError('Please select or create a configuration first');
      return;
    }
     
    final fs = context.read<FileSystemProvider>();
    final account = await fs.getAvailableAccounts().then(
      (accounts) => accounts.firstWhere(
        (acc) => acc.id == config.cloudAccountId,
        orElse: () => throw Exception('Account not found'),
      ),
    );
     
    setState(() {
      _isSyncing = true;
      _filesScanned = 0;
      _filesProcessed = 0;
      _filesFailed = 0;
      _scanErrors.clear();
    });
     
    // Step 1: Scan local directory using Rust scanner
    final localItems = await _scanLocalDirectoryRust(config.localPath);
    setState(() {
      _filesScanned = localItems.length;
    });
     
    if (localItems.isEmpty) {
      _showMessage('No files found in the local directory', theme.UbuntuColors.orange);
      _resetSyncState();
      return;
    }
     
    // Step 2: Scan cloud directory
    final adapter = fs.getAdapterForAccount(account.id);
    if (adapter == null) {
      _showError('Could not access cloud adapter');
      _resetSyncState();
      return;
    }
     
    final cloudItems = await _getAllCloudItemsWithSizes(adapter, config.cloudFolderId);
     
    // Step 3: Compare and sync - upload missing items and replace different-sized files
    await _syncLocalToCloud(fs, account, config, localItems, cloudItems);
     
    final message = _filesFailed > 0
        ? 'Sync completed with $_filesProcessed succeeded, $_filesFailed failed'
        : 'Sync completed successfully: $_filesProcessed items synced to cloud';
     
    _showMessage(message, theme.UbuntuColors.orange);
    _resetSyncState();
  }
   
  Future<void> _startSyncToDestination() async {
    final config = _selectedConfig;
    if (config == null) {
      _showError('Please select or create a configuration first');
      return;
    }
     
    final fs = context.read<FileSystemProvider>();
    final account = await fs.getAvailableAccounts().then(
      (accounts) => accounts.firstWhere(
        (acc) => acc.id == config.cloudAccountId,
        orElse: () => throw Exception('Account not found'),
      ),
    );
     
    setState(() {
      _isSyncing = true;
      _filesScanned = 0;
      _filesProcessed = 0;
      _filesFailed = 0;
      _scanErrors.clear();
    });
     
    // Step 1: Scan cloud directory
    final adapter = fs.getAdapterForAccount(account.id);
    if (adapter == null) {
      _showError('Could not access cloud adapter');
      _resetSyncState();
      return;
    }
     
    final cloudItems = await _getAllCloudItemsWithSizes(adapter, config.cloudFolderId);
    setState(() {
      _filesScanned = cloudItems.length;
    });
     
    if (cloudItems.isEmpty) {
      _showMessage('No files found in the cloud directory', theme.UbuntuColors.orange);
      _resetSyncState();
      return;
    }
     
    // Step 2: Scan local directory using Rust scanner
    final localItems = await _scanLocalDirectoryRust(config.localPath);
     
    // Step 3: Compare and sync - download missing items and replace different-sized files
    await _syncCloudToLocal(fs, account, config, localItems, cloudItems);
     
    final message = _filesFailed > 0
        ? 'Sync completed with $_filesProcessed succeeded, $_filesFailed failed'
        : 'Sync completed successfully: $_filesProcessed items synced from cloud';
     
    _showMessage(message, theme.UbuntuColors.orange);
    _resetSyncState();
  }
   
  /// Scan local directory using Rust scanner
  Future<List<LocalItem>> _scanLocalDirectoryRust(String folderPath) async {
    try {
      final rustService = RustFileOperationsService();
      final entries = await rustService.scanDirectory(folderPath);
       
      final items = <LocalItem>[];
      for (final entry in entries) {
        items.add(LocalItem(
          path: entry['path'] as String,
          relativePath: entry['relativePath'] as String,
          isFolder: entry['isFolder'] as bool,
          size: entry['size'] as int? ?? 0,
        ));
      }
       
      return items;
    } catch (e) {
      return _scanLocalDirectoryDart(folderPath);
    }
  }
   
  /// Fallback Dart scanner
  Future<List<LocalItem>> _scanLocalDirectoryDart(String folderPath) async {
    final items = <LocalItem>[];
    final directory = Directory(folderPath);
     
    if (!await directory.exists()) {
      throw Exception('Directory does not exist: $folderPath');
    }
     
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      final relativePath = path.relative(entity.path, from: folderPath);
       
      if (entity is File) {
        final fileSize = await entity.length();
        items.add(LocalItem(
          path: entity.path,
          relativePath: relativePath,
          isFolder: false,
          size: fileSize,
        ));
      } else if (entity is Directory) {
        items.add(LocalItem(
          path: entity.path,
          relativePath: relativePath,
          isFolder: true,
          size: 0,
        ));
      }
    }
     
    return items;
  }
   
  /// Get all cloud items with their sizes and relative paths
  Future<List<CloudItemInfo>> _getAllCloudItemsWithSizes(dynamic adapter, String rootFolderId) async {
    final items = <CloudItemInfo>[];
    final folderIdToPath = <String, String>{};
    final queue = <String>[];
     
    // Initialize root folder
    folderIdToPath[rootFolderId] = '';
    queue.add(rootFolderId);
     
    while (queue.isNotEmpty) {
      final currentId = queue.removeAt(0);
      final currentPath = folderIdToPath[currentId] ?? '';
      final result = await adapter.listFolder(currentId);
        
      for (final child in result.nodes) {
        // Build relative path for this item
        final relativePath = currentPath.isEmpty ? child.name : '$currentPath/${child.name}';
         
        // Get file size if it's a file
        int? fileSize;
        if (!child.isFolder) {
          try {
            final metadata = await adapter.getFileMetadata(child.cloudId ?? child.id);
            fileSize = metadata?.size;
          } catch (e) {
          }
        }
         
        items.add(CloudItemInfo(
          id: child.cloudId ?? child.id,
          name: relativePath, // Store full relative path
          isFolder: child.isFolder,
          size: fileSize ?? 0,
          parentId: currentId,
        ));
         
        if (child.isFolder) {
          final childId = child.cloudId ?? child.id;
          folderIdToPath[childId] = relativePath;
          queue.add(childId);
        }
      }
    }
     
    return items;
  }
   
  /// Sync local items to cloud
  Future<void> _syncLocalToCloud(
    FileSystemProvider fs,
    CloudAccount account,
    SyncConfig config,
    List<LocalItem> localItems,
    List<CloudItemInfo> cloudItems,
  ) async {
    try {
      final adapter = fs.getAdapterForAccount(account.id);
      if (adapter == null) {
        throw Exception('Could not access cloud adapter');
      }


      // Build cloud items map by relative path (normalized)
      final cloudItemsByPath = <String, CloudItemInfo>{};
      for (final item in cloudItems) {
        final normalizedPath = item.name.replaceAll('\\', '/');
        cloudItemsByPath[normalizedPath] = item;
      }

      // Group local items by depth
      final itemsByDepth = <int, List<LocalItem>>{};
      int maxDepth = 0;

      for (final item in localItems) {
        final normalizedPath = item.relativePath.replaceAll('\\', '/');
        final depth = normalizedPath.split('/').where((p) => p.isNotEmpty).length;
        itemsByDepth.putIfAbsent(depth, () => []).add(item);
        if (depth > maxDepth) maxDepth = depth;
      }

      // Track created cloud folders: relativePath -> cloudId
      final createdFolders = <String, String>{};
      createdFolders['.'] = config.cloudFolderId;

      // Process depth by depth - folders first, then files
      for (int depth = 0; depth <= maxDepth; depth++) {
        final itemsAtDepth = itemsByDepth[depth] ?? [];
        if (itemsAtDepth.isEmpty) continue;

        // Separate folders and files
        final folders = itemsAtDepth.where((item) => item.isFolder).toList();
        final files = itemsAtDepth.where((item) => !item.isFolder).toList();

        // Process all folders at this depth in parallel first
        if (folders.isNotEmpty) {
          await Future.wait(folders.map((item) => _processLocalFolder(
            item: item,
            adapter: adapter,
            config: config,
            createdFolders: createdFolders,
          )));
        }

        // Then process all files at this depth in parallel
        if (files.isNotEmpty) {
          await Future.wait(files.map((item) => _processLocalFile(
            item: item,
            adapter: adapter,
            config: config,
            accountId: account.id,
            cloudItemsByPath: cloudItemsByPath,
            createdFolders: createdFolders,
          )));
        }
      }


    } catch (e) {
      setState(() {
        _scanErrors.add('Sync step failed: $e');
      });
    }
  }

  /// Process a local file
  Future<void> _processLocalFile({
    required LocalItem item,
    required dynamic adapter,
    required SyncConfig config,
    required String accountId,
    required Map<String, CloudItemInfo> cloudItemsByPath,
    required Map<String, String> createdFolders,
  }) async {
    final normalizedPath = item.relativePath.replaceAll('\\', '/');
    final parentPath = path.dirname(normalizedPath);
    final parentId = createdFolders[parentPath] ?? config.cloudFolderId;


    // Simple path-based lookup
    final cloudItem = cloudItemsByPath[normalizedPath];

    if (cloudItem == null) {
      // File doesn't exist in cloud, upload it
      await _uploadFileToCloud(adapter, item, parentId, accountId);
      setState(() => _filesProcessed++);
    } else {
      // File exists in cloud, compare sizes

      if (cloudItem.size != item.size) {
        // Different size, delete and re-upload

        try {
          await adapter.deleteNode(cloudItem.id);
          await _uploadFileToCloud(adapter, item, parentId, accountId);
          setState(() => _filesProcessed++);
        } catch (e) {
          setState(() => _filesFailed++);
        }
      } else {
        // Same size, skip
        setState(() => _filesProcessed++);
      }
    }
  }

  /// Sync cloud items to local
  Future<void> _syncCloudToLocal(
    FileSystemProvider fs,
    CloudAccount account,
    SyncConfig config,
    List<LocalItem> localItems,
    List<CloudItemInfo> cloudItems,
  ) async {
    try {
      final adapter = fs.getAdapterForAccount(account.id);
      if (adapter == null) {
        throw Exception('Could not access cloud adapter');
      }


      // Build local items map by relative path (normalized)
      final localItemsByPath = <String, LocalItem>{};
      for (final item in localItems) {
        final normalizedPath = item.relativePath.replaceAll('\\', '/');
        localItemsByPath[normalizedPath] = item;
      }

      // Group cloud items by depth
      final itemsByDepth = <int, List<CloudItemInfo>>{};
      int maxDepth = 0;

      for (final item in cloudItems) {
        final normalizedPath = item.name.replaceAll('\\', '/');
        final depth = normalizedPath.split('/').where((p) => p.isNotEmpty).length - 1;
        itemsByDepth.putIfAbsent(depth, () => []).add(item);
        if (depth > maxDepth) maxDepth = depth;
      }

      // Track created local folders: relativePath -> localPath
      final createdFolders = <String, String>{};
      createdFolders['.'] = config.localPath;

      // Process depth by depth - folders first, then files
      for (int depth = 0; depth <= maxDepth; depth++) {
        final itemsAtDepth = itemsByDepth[depth] ?? [];
        if (itemsAtDepth.isEmpty) continue;

        // Separate folders and files
        final folders = itemsAtDepth.where((item) => item.isFolder).toList();
        final files = itemsAtDepth.where((item) => !item.isFolder).toList();

        // Process all folders at this depth in parallel first
        if (folders.isNotEmpty) {
          await Future.wait(folders.map((item) => _processCloudFolder(
            item: item,
            config: config,
            createdFolders: createdFolders,
          )));
        }

        // Then process all files at this depth in parallel
        if (files.isNotEmpty) {
          await Future.wait(files.map((item) => _processCloudFile(
            item: item,
            adapter: adapter,
            config: config,
            accountId: account.id,
            localItemsByPath: localItemsByPath,
            createdFolders: createdFolders,
          )));
        }
      }


    } catch (e) {
      setState(() {
        _scanErrors.add('Sync step failed: $e');
      });
    }
  }

  /// Process a cloud file
  Future<void> _processCloudFile({
    required CloudItemInfo item,
    required dynamic adapter,
    required SyncConfig config,
    required String accountId,
    required Map<String, LocalItem> localItemsByPath,
    required Map<String, String> createdFolders,
  }) async {
    final normalizedPath = item.name.replaceAll('\\', '/');
    final parentPath = path.dirname(normalizedPath);
    final parentDir = createdFolders[parentPath] ?? config.localPath;
    final fileName = path.basename(normalizedPath);
    final savePath = '$parentDir/$fileName';


    // Simple path-based lookup
    final localItem = localItemsByPath[normalizedPath];

    if (localItem == null) {
      // File doesn't exist locally, download it
      await _downloadFileToLocal(adapter, item, savePath, accountId);
      setState(() => _filesProcessed++);
    } else {
      // File exists locally, compare sizes

      if (item.size != localItem.size) {
        // Different size, delete and re-download

        try {
          await File(localItem.path).delete();
          await _downloadFileToLocal(adapter, item, savePath, accountId);
          setState(() => _filesProcessed++);
        } catch (e) {
          setState(() => _filesFailed++);
        }
      } else {
        // Same size, skip
        setState(() => _filesProcessed++);
      }
    }
  }

  /// Process a local folder - create it in cloud if needed
  Future<void> _processLocalFolder({
    required LocalItem item,
    required dynamic adapter,
    required SyncConfig config,
    required Map<String, String> createdFolders,
  }) async {
    final normalizedPath = item.relativePath.replaceAll('\\', '/');
    final parentPath = path.dirname(normalizedPath);
    final parentId = createdFolders[parentPath] ?? config.cloudFolderId;
     
    try {
      // Check if folder already exists in cloud by listing parent folder
      final result = await adapter.listFolder(parentId);
      final existingFolder = result.nodes.firstWhere(
        (child) => child.isFolder && child.name == item.name,
        orElse: () => CloudNode(
          id: '',
          name: '',
          isFolder: true,
          cloudId: '',
          provider: '',
          updatedAt: DateTime.now(),
        ),
      );
       
      if (existingFolder.id.isNotEmpty) {
        // Folder already exists, use its ID
        createdFolders[normalizedPath] = existingFolder.cloudId ?? existingFolder.id;
        setState(() => _filesProcessed++);
      } else {
        // Create new folder
        final folderId = await adapter.createFolder(item.name, parentId);
        createdFolders[normalizedPath] = folderId;
        setState(() => _filesProcessed++);
      }
    } catch (e) {
      setState(() => _filesFailed++);
    }
  }
   
  /// Process a cloud folder - create it locally if needed
  Future<void> _processCloudFolder({
    required CloudItemInfo item,
    required SyncConfig config,
    required Map<String, String> createdFolders,
  }) async {
    final normalizedPath = item.name.replaceAll('\\', '/');
    final itemName = path.basename(normalizedPath);
    final parentPath = path.dirname(normalizedPath);
    final parentDir = createdFolders[parentPath] ?? config.localPath;
    final folderPath = '$parentDir/$itemName';
     
    try {
      await Directory(folderPath).create(recursive: true);
      createdFolders[normalizedPath] = folderPath;
      setState(() => _filesProcessed++);
    } catch (e) {
      setState(() => _filesFailed++);
    }
  }
   
  Future<void> _uploadFileToCloud(
    dynamic adapter,
    LocalItem item,
    String parentId,
    String accountId,
  ) async {
    try {
      final file = File(item.path);
      final fileName = path.basename(item.path);
        
      // Create upload task
      final uploadTask = QueuedTask(
        id: const Uuid().v4(),
        type: TaskType.upload,
        name: fileName,
        accountId: accountId,
        status: TaskStatus.pending,
        progress: 0.0,
        payload: {
          'filePath': item.path,
          'parentId': parentId,
          'originalFileName': fileName,
          'shouldEncrypt': false,
        },
      );
        
      TaskService.instance.addTask(uploadTask);
        
    } catch (e) {
      setState(() => _filesFailed++);
    }
  }
   
  Future<void> _downloadFileToLocal(
    dynamic adapter,
    CloudItemInfo item,
    String savePath,
    String accountId,
  ) async {
    try {
      // Check if file is encrypted
      final isEncrypted = item.name.endsWith('.enc');
       
      // Determine original filename
      String originalFileName = item.name;
      if (isEncrypted) {
        originalFileName = item.name.replaceAll('.enc', '');
      }
       
      final downloadTask = QueuedTask(
        id: const Uuid().v4(),
        type: TaskType.download,
        name: item.name,
        accountId: accountId,
        status: TaskStatus.pending,
        progress: 0.0,
        payload: {
          'fileId': item.id,
          'savePath': savePath,
          'isEncrypted': isEncrypted,
          'originalFileName': originalFileName,
        },
      );
       
      TaskService.instance.addTask(downloadTask);
       
    } catch (e) {
      setState(() => _filesFailed++);
    }
  }
   
  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }
   
  void _showMessage(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }
   
  void _resetSyncState() {
    setState(() {
      _isSyncing = false;
      _filesScanned = 0;
      _filesProcessed = 0;
      _filesFailed = 0;
    });
  }
   
  Future<void> _selectLocalDirectory() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath();
      if (result != null) {
        setState(() {
          _localPath = result;
          _localPathController.text = result;
        });
      }
    } catch (e) {
      _showError('Failed to select directory: $e');
    }
  }
   
  Future<void> _selectCloudFolder() async {
    final fs = context.read<FileSystemProvider>();
    final accounts = await fs.getAvailableAccounts();
     
    if (accounts.isEmpty) {
      _showError('No cloud accounts connected. Please connect to Google Drive or OneDrive first.');
      return;
    }
     
    final selectedAccount = await showDialog<CloudAccount>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Cloud Account'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: accounts.length,
            itemBuilder: (context, index) {
              final account = accounts[index];
              return ListTile(
                leading: Icon(
                  account.provider == 'gdrive' ? Icons.add_to_drive : Icons.cloud,
                  color: account.provider == 'gdrive' ? Colors.green : Colors.blue,
                ),
                title: Text(account.name ?? 'Unknown'),
                subtitle: Text(account.email ?? 'No email'),
                onTap: () => Navigator.pop(context, account),
              );
            },
          ),
        ),
        actions: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
            ),
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                foregroundColor: theme.UbuntuColors.textGrey,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'Cancel',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
     
    if (selectedAccount == null) return;
     
    final folderSelection = await _showFolderPickerDialog(selectedAccount);
    if (folderSelection != null) {
      setState(() {
        _cloudFolderSelection = folderSelection;
        _cloudPathController.text = folderSelection.displayPath;
      });
    }
  }
   
  Future<CloudFolderSelection?> _showFolderPickerDialog(CloudAccount account) async {
    final fs = context.read<FileSystemProvider>();
    final adapter = fs.getAdapterForAccount(account.id);
     
    if (adapter == null) {
      _showError('Could not access cloud adapter for this account');
      return null;
    }
     
    List<CloudNode> currentFolders = [];
    String currentFolderId = 'root';
    String currentPath = '';
     
    try {
      currentFolders = (await adapter.listFolder('root')).nodes;
    } catch (e) {
      _showError('Failed to load folders: $e');
      return null;
    }
     
    return await showDialog<CloudFolderSelection>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Select Folder - ${account.name}'),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.UbuntuColors.lightGrey.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    currentPath.isEmpty ? 'Root' : currentPath,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: currentFolders.length,
                    itemBuilder: (context, index) {
                      final folder = currentFolders[index];
                      if (!folder.isFolder) return const SizedBox.shrink();
                       
                      return ListTile(
                        leading: const Icon(Icons.folder, color: theme.UbuntuColors.orange),
                        title: Text(folder.name),
                        onTap: () async {
                          final subFolders = (await adapter.listFolder(folder.cloudId ?? folder.id)).nodes;
                          setState(() {
                            currentFolders = subFolders;
                            currentFolderId = folder.cloudId ?? folder.id;
                            currentPath = currentPath.isEmpty 
                                ? '/${folder.name}'
                                : '$currentPath/${folder.name}';
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.UbuntuColors.orange,
                    theme.UbuntuColors.orange.withOpacity(0.85),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: theme.UbuntuColors.orange.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, CloudFolderSelection(
                  accountId: account.id,
                  accountEmail: account.email ?? '',
                  accountProvider: account.provider,
                  folderId: currentFolderId,
                  folderPath: currentPath,
                )),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  foregroundColor: Colors.white,
                  shadowColor: Colors.transparent,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: const Text(
                  'Select This Folder',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(
                  foregroundColor: theme.UbuntuColors.textGrey,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
   
  @override
  Widget build(BuildContext context) {
    return Consumer<FileSystemProvider>(
      builder: (context, fs, child) {
        return Scaffold(
          backgroundColor: theme.UbuntuColors.veryLightGrey,
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _showCreateConfigDialog(context),
            icon: const Icon(Icons.add_rounded),
            label: const Text('New Configuration'),
            backgroundColor: theme.UbuntuColors.orange,
            elevation: 4,
          ),
          body: _savedConfigs.isEmpty
              ? _buildEmptyState(context)
              : _buildConfigurationsList(context),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_sync_rounded,
            size: 80,
            color: theme.UbuntuColors.textGrey.withOpacity(0.3),
          ),
          const SizedBox(height: 24),
          Text(
            'No Sync Configurations',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: theme.UbuntuColors.darkGrey,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Create your first sync configuration to get started',
            style: TextStyle(
              fontSize: 14,
              color: theme.UbuntuColors.textGrey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigurationsList(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: _savedConfigs.length,
      itemBuilder: (context, index) {
        final config = _savedConfigs[index];
        return _buildConfigCard(context, config);
      },
    );
  }

  Widget _buildConfigCard(BuildContext context, SyncConfig config) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.UbuntuColors.lightGrey,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.UbuntuColors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.sync_rounded,
                        color: theme.UbuntuColors.orange,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            config.name,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Created ${_formatDate(config.createdAt)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.UbuntuColors.textGrey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildCompactSyncButton(
                          icon: Icons.cloud_upload_rounded,
                          tooltip: 'Sync to Source (Local → Cloud)',
                          gradient: LinearGradient(
                            colors: [
                              theme.UbuntuColors.orange,
                              theme.UbuntuColors.orange.withOpacity(0.85),
                            ],
                          ),
                          onPressed: () async {
                            _selectConfig(config);
                            await _startSyncToSource();
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildCompactSyncButton(
                          icon: Icons.cloud_download_rounded,
                          tooltip: 'Sync to Destination (Cloud → Local)',
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF2196F3),
                              Color(0xFF1976D2),
                            ],
                          ),
                          onPressed: () async {
                            _selectConfig(config);
                            await _startSyncToDestination();
                          },
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.edit_rounded, size: 20),
                          color: theme.UbuntuColors.textGrey,
                          onPressed: () => _showEditConfigDialog(context, config),
                          tooltip: 'Edit Configuration',
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, size: 20),
                          color: Colors.red,
                          onPressed: () => _deleteConfig(config),
                          tooltip: 'Delete Configuration',
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildInfoRow(
                  Icons.folder_rounded,
                  'Local',
                  config.localPath,
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  Icons.cloud_rounded,
                  'Cloud',
                  config.cloudDisplayPath,
                ),
              ],
            ),
          ),
          if (_isSyncing && _selectedConfig?.id == config.id) ...[
            const Divider(height: 1),
            _buildSyncProgressCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: theme.UbuntuColors.textGrey,
        ),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: theme.UbuntuColors.darkGrey,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: theme.UbuntuColors.textGrey,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildCompactSyncButton({
    required IconData icon,
    required String tooltip,
    required Gradient gradient,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: gradient.colors.first.withOpacity(0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Tooltip(
            message: tooltip,
            child: Icon(
              icon,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSyncProgressCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    theme.UbuntuColors.orange,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Syncing...',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            child: LinearProgressIndicator(
              value: _filesScanned > 0 ? (_filesProcessed / _filesScanned) : 0.0,
              backgroundColor: theme.UbuntuColors.lightGrey,
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.UbuntuColors.orange,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_filesScanned > 0)
            Text(
              '$_filesProcessed/$_filesScanned files processed • $_filesFailed failed',
              style: TextStyle(
                fontSize: 12,
                color: theme.UbuntuColors.textGrey,
              ),
            )
          else
            Text(
              'Scanning files...',
              style: TextStyle(
                fontSize: 12,
                color: theme.UbuntuColors.textGrey,
              ),
            ),
        ],
      ),
    );
  }

  void _showCreateConfigDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _CreateConfigDialog(
        onSave: (name, localPath, cloudFolder) async {
          _configNameController.text = name;
          _localPath = localPath;
          _localPathController.text = localPath;
          _cloudFolderSelection = cloudFolder;
          await _saveConfig();
        },
      ),
    );
  }

  void _showEditConfigDialog(BuildContext context, SyncConfig config) {
    _selectConfig(config);
    showDialog(
      context: context,
      builder: (context) => _CreateConfigDialog(
        initialConfig: config,
        onSave: (name, localPath, cloudFolder) async {
          await HiveStorageService.instance.deleteSyncConfig(config.id);
          _configNameController.text = name;
          _localPath = localPath;
          _localPathController.text = localPath;
          _cloudFolderSelection = cloudFolder;
          await _saveConfig();
        },
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);
    
    if (difference.inDays == 0) {
      return 'today';
    } else if (difference.inDays == 1) {
      return 'yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else if (difference.inDays < 30) {
      return '${(difference.inDays / 7).floor()} weeks ago';
    } else {
      return '${(difference.inDays / 30).floor()} months ago';
    }
  }
}

class _CreateConfigDialog extends StatefulWidget {
final SyncConfig? initialConfig;
final Function(String name, String localPath, CloudFolderSelection cloudFolder) onSave;
  
    const _CreateConfigDialog({
      Key? key,
      this.initialConfig,
      required this.onSave,
    }) : super(key: key);
  
    @override
    State<_CreateConfigDialog> createState() => _CreateConfigDialogState();
  }
  
  class _CreateConfigDialogState extends State<_CreateConfigDialog> {
    final TextEditingController _nameController = TextEditingController();
    final TextEditingController _localPathController = TextEditingController();
    final TextEditingController _cloudPathController = TextEditingController();
    
    String? _localPath;
    CloudFolderSelection? _cloudFolderSelection;
  
    @override
    void initState() {
      super.initState();
      if (widget.initialConfig != null) {
        _nameController.text = widget.initialConfig!.name;
        _localPath = widget.initialConfig!.localPath;
        _localPathController.text = widget.initialConfig!.localPath;
        _cloudFolderSelection = CloudFolderSelection(
          accountId: widget.initialConfig!.cloudAccountId,
          accountEmail: widget.initialConfig!.cloudAccountEmail,
          accountProvider: widget.initialConfig!.cloudAccountProvider,
          folderId: widget.initialConfig!.cloudFolderId,
          folderPath: widget.initialConfig!.cloudFolderPath,
        );
        _cloudPathController.text = widget.initialConfig!.cloudDisplayPath;
      }
    }
  
    @override
    void dispose() {
      _nameController.dispose();
      _localPathController.dispose();
      _cloudPathController.dispose();
      super.dispose();
    }
  
    Future<void> _selectLocalDirectory() async {
      try {
        final result = await FilePicker.platform.getDirectoryPath();
        if (result != null) {
          setState(() {
            _localPath = result;
            _localPathController.text = result;
          });
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to select directory: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  
    Future<void> _selectCloudFolder() async {
      final fs = context.read<FileSystemProvider>();
      final accounts = await fs.getAvailableAccounts();
      
      if (accounts.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No cloud accounts connected. Please connect to Google Drive or OneDrive first.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      final selectedAccount = await showDialog<CloudAccount>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select Cloud Account'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: accounts.length,
              itemBuilder: (context, index) {
                final account = accounts[index];
                return ListTile(
                  leading: Icon(
                    account.provider == 'gdrive' ? Icons.add_to_drive : Icons.cloud,
                    color: account.provider == 'gdrive' ? Colors.green : Colors.blue,
                  ),
                  title: Text(account.name ?? 'Unknown'),
                  subtitle: Text(account.email ?? 'No email'),
                  onTap: () => Navigator.pop(context, account),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      
      if (selectedAccount == null) return;
      
      final folderSelection = await _showFolderPickerDialog(selectedAccount);
      if (folderSelection != null) {
        setState(() {
          _cloudFolderSelection = folderSelection;
          _cloudPathController.text = folderSelection.displayPath;
        });
      }
    }
  
    Future<CloudFolderSelection?> _showFolderPickerDialog(CloudAccount account) async {
      final fs = context.read<FileSystemProvider>();
      final adapter = fs.getAdapterForAccount(account.id);
      
      if (adapter == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not access cloud adapter for this account'),
            backgroundColor: Colors.red,
          ),
        );
        return null;
      }
      
      List<CloudNode> currentFolders = [];
      String currentFolderId = 'root';
      String currentPath = '';
      
      try {
        currentFolders = (await adapter.listFolder('root')).nodes;
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load folders: $e'),
            backgroundColor: Colors.red,
          ),
        );
        return null;
      }
      
      return await showDialog<CloudFolderSelection>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text('Select Folder - ${account.name}'),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.UbuntuColors.lightGrey.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      currentPath.isEmpty ? 'Root' : currentPath,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: currentFolders.length,
                      itemBuilder: (context, index) {
                        final folder = currentFolders[index];
                        if (!folder.isFolder) return const SizedBox.shrink();
                        
                        return ListTile(
                          leading: const Icon(Icons.folder, color: theme.UbuntuColors.orange),
                          title: Text(folder.name),
                          onTap: () async {
                            final subFolders = (await adapter.listFolder(folder.cloudId ?? folder.id)).nodes;
                            setState(() {
                              currentFolders = subFolders;
                              currentFolderId = folder.cloudId ?? folder.id;
                              currentPath = currentPath.isEmpty
                                  ? '/${folder.name}'
                                  : '$currentPath/${folder.name}';
                            });
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.UbuntuColors.orange,
                      theme.UbuntuColors.orange.withOpacity(0.85),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: theme.UbuntuColors.orange.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, CloudFolderSelection(
                    accountId: account.id,
                    accountEmail: account.email ?? '',
                    accountProvider: account.provider,
                    folderId: currentFolderId,
                    folderPath: currentPath,
                  )),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                  child: const Text(
                    'Select This Folder',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.UbuntuColors.textGrey,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
  
    void _handleSave() {
      if (_nameController.text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a configuration name'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      if (_localPath == null || _cloudFolderSelection == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please select both local directory and cloud destination'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      widget.onSave(_nameController.text, _localPath!, _cloudFolderSelection!);
      Navigator.pop(context);
    }
  
    @override
    Widget build(BuildContext context) {
      return AlertDialog(
        title: Text(widget.initialConfig == null ? 'New Sync Configuration' : 'Edit Configuration'),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Configuration Name',
                  hintText: 'Enter a name for this sync config',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _localPathController,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: 'Local Directory',
                  hintText: 'Select local directory...',
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.folder_open),
                    color: theme.UbuntuColors.orange,
                    onPressed: _selectLocalDirectory,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _cloudPathController,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: 'Cloud Destination',
                  hintText: 'Select cloud folder...',
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.cloud),
                    color: theme.UbuntuColors.orange,
                    onPressed: _selectCloudFolder,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.UbuntuColors.orange,
                  theme.UbuntuColors.orange.withOpacity(0.85),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: theme.UbuntuColors.orange.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ElevatedButton(
              onPressed: _handleSave,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                foregroundColor: Colors.white,
                shadowColor: Colors.transparent,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: const Text(
                'Save',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      );
    }
  }