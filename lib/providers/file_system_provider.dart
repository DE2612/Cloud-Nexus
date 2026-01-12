// ignore_for_file: empty_catches

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cloud_nexus/models/encrypted_file_mapping.dart';
import 'package:cloud_nexus/models/queued_task.dart';
import 'package:cloud_nexus/services/encryption_name_service.dart';
import 'package:cloud_nexus/services/search_service.dart';
import 'package:cloud_nexus/services/security_service.dart';
import 'package:cloud_nexus/services/task_service.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http show get;
import 'package:uuid/uuid.dart';
import '../models/cloud_node.dart';
import '../models/cloud_account.dart';
import '../models/search_index.dart';
import 'package:hive/hive.dart';
import '../services/hive_storage_service.dart';
import '../adapters/google_drive_adapter.dart'; // Keep this
import '../adapters/cloud_adapter.dart'; // Import the Interface
import '../services/google_auth_manager.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import '../services/folder_upload_service.dart';
import '../utils/folder_picker.dart';
import '../widgets/folder_upload_progress_dialog.dart';
import '../widgets/storage_bar.dart';
import '../services/rust_folder_scanner.dart';
import '../services/rust_file_operations_service.dart';
import '../services/onedrive_auth_manager.dart';
import '../adapters/onedrive_adapter.dart';
import '../models/storage_quota.dart';
import '../models/virtual_raid_upload_strategy.dart';

/// Result of storage check before upload
class StorageCheckResult {
  final bool canUpload;
  final StorageCheckError error;
  final StorageQuota? quota;
  final int fileSizeBytes;
  final String? errorMessage;

  StorageCheckResult({
    required this.canUpload,
    required this.error,
    this.quota,
    required this.fileSizeBytes,
    this.errorMessage,
  });

  bool get hasError => error != StorageCheckError.none;
}

/// Error types for storage check
enum StorageCheckError {
  none,
  noAdapter,
  quotaFetchFailed,
  insufficientStorage,
}

/// Helper function to format bytes for display
String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  final digitGroups = (log(bytes) / log(1024)).floor();
  final size = bytes / pow(1024, digitGroups);
  return '${size.toStringAsFixed(size < 10 ? 1 : 0)} ${units[digitGroups]}';
}

/// Exception thrown when multiple files are selected to signal UI handling
class MultipleFilesSelectedException implements Exception {
  final List<String> filePaths;
  final List<String> fileNames;
  
  MultipleFilesSelectedException(this.filePaths, this.fileNames);
  
  @override
  String toString() => 'Multiple files selected: ${fileNames.join(', ')}';
}

/// Helper class to store Virtual Drive account information for selection dialog
class VirtualDriveAccountInfo {
  final String accountId;
  final CloudAccount account;
  final ICloudAdapter adapter;
  final bool isAvailable;

  VirtualDriveAccountInfo({
    required this.accountId,
    required this.account,
    required this.adapter,
    required this.isAvailable,
  });



  String get displayName => account.name ?? account.email ?? 'Unknown Account';
  String get providerDisplayName {
    switch (account.provider) {
      case 'gdrive':
        return 'Google Drive';
      case 'dropbox':
        return 'Dropbox';
      case 'onedrive':
        return 'OneDrive';
      default:
        return account.provider;
    }
  }

  IconData get providerIcon {
    switch (account.provider) {
      case 'gdrive':
        return Icons.cloud;
      case 'dropbox':
        return Icons.folder;
      case 'onedrive':
        return Icons.cloud_queue;
      default:
        return Icons.storage;
    }
  }

  Color get providerColor {
    switch (account.provider) {
      case 'gdrive':
        return Colors.green;
      case 'dropbox':
        return Colors.blue;
      case 'onedrive':
        return Colors.blue.shade800;
      default:
        return Colors.grey;
    }
  }
}

/// Sorting options for file list
enum SortOption {
  name,
  size,
  dateModified,
  type,
}

class FileSystemProvider with ChangeNotifier {
  List<CloudNode> _currentNodes = [];
  List<CloudNode> _breadcrumbs = [];
  
  // Sorting state
  SortOption _currentSortOption = SortOption.name;
  bool _sortAscending = true;
  
  SortOption get currentSortOption => _currentSortOption;
  bool get sortAscending => _sortAscending;
  
  // GENERIC MAP: Can now hold Google, Dropbox, or OneDrive adapters
  final Map<String, ICloudAdapter> _adapters = {};
  
  // Auth Managers - Use singleton instances
  final GoogleAuthManager _googleAuth = GoogleAuthManager.instance;
  // final DropboxAuthManager _dropboxAuth = DropboxAuthManager(); // Future

  List<CloudNode> get currentNodes => _currentNodes;
  List<CloudNode> get breadcrumbs => _breadcrumbs;
  
  String? get currentFolderId => _breadcrumbs.isEmpty ? null : _breadcrumbs.last.id;
  CloudNode? get currentFolderNode => _breadcrumbs.isEmpty ? null : _breadcrumbs.last;
  
  // Selected items count management
  int _selectedItemsCount = 0;
  int getSelectedItemsCount() => _selectedItemsCount;
  void setSelectedItemsCount(int count) {
    _selectedItemsCount = count;
    notifyListeners();
  }

  /// Clear selected items count when switching accounts or folders
  /// This ensures the count resets to 0 when navigating to a new location
  void clearSelectedItemsCount() {
    if (_selectedItemsCount > 0) {
      _selectedItemsCount = 0;
      notifyListeners();
    }
  }


  // Performance optimizations
  final Map<String, List<CloudNode>> _nodeCache = {};
  final Map<String, List<String>> _linkedAccountsCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  Timer? _debounceTimer;
  static const Duration _cacheExpiry = Duration(seconds: 60); // Increased to 60 seconds
  static const Duration _debounceDelay = Duration(milliseconds: 200);
  
  // Additional performance optimizations
  final Map<String, Future<List<CloudNode>>> _pendingRequests = {};
  static const Duration _requestTimeout = Duration(seconds: 15);
  static const int _maxConcurrentRequests = 3;
  
  // Loading state tracking
  bool _isLoading = false;
  bool get isLoading => _isLoading;
  
  // Track which folder is being loaded (for loading indicator)
  String? _loadingFolderId;
  String? get loadingFolderId => _loadingFolderId;
  
  // Pagination state
  String? _nextPageToken;
  String? get nextPageToken => _nextPageToken;
  bool _hasMore = false;
  bool get hasMore => _hasMore;
  bool _isLoadingMore = false;
  bool get isLoadingMore => _isLoadingMore;

  FileSystemProvider() {
    // Set up the adapter getter for TaskService to avoid circular dependencies
    TaskService.instance.setAdapterGetter(getAdapterForAccount);
    
    // Set up the selected items count getter
    TaskService.instance.setSelectedItemsCountGetter(getSelectedItemsCount);
    
    // Automatically restore saved accounts on startup
    _restoreSavedAccounts();
  }
  
  /// Restore saved accounts from Hive storage on app startup
  Future<void> _restoreSavedAccounts() async {
    
    try {
      // Check if Hive is initialized
      if (!HiveStorageService.instance.isInitialized) {
        await Future.delayed(Duration(seconds: 1));
        if (!HiveStorageService.instance.isInitialized) {
          return;
        }
      }
      
      // Get all saved accounts from Hive
      final savedAccounts = await HiveStorageService.instance.getAccounts();
      
      for (final account in savedAccounts) {
        
        if (account.credentials != null) {
        }
        
        // Create adapter based on provider
        ICloudAdapter? adapter;
        if (account.provider == 'gdrive') {
          // Restore Google Drive adapter from stored credentials
          try {
            final authClient = await GoogleAuthManager.instance.getAuthClient(account.id);
            if (authClient != null) {
              adapter = GoogleDriveAdapter(authClient, account.id);
              _adapters[account.id] = adapter;
            } else {
            }
          } catch (e) {
          }
        } else if (account.provider == 'onedrive') {
          // Restore OneDrive adapter from stored credentials
          try {
            final accessToken = await OneDriveAuthManager.instance.getAccessTokenForAccount(account.id);
            if (accessToken != null) {
              adapter = OneDriveAdapter(account.id);
              _adapters[account.id] = adapter;
            } else {
            }
          } catch (e) {
          }
        } else {
        }
      }
      

      // Note: RClone service has been removed from project
      // Initialize Search Service
      await SearchService.instance.initialize();
      
      // Load nodes to refresh the UI
      await loadNodes();
      
      // Refresh profile names for all accounts
      await refreshAccountProfileNames();
      
    } catch (e) {
    }
  }

  /// Build search index for all accounts in parallel
  Future<void> buildSearchIndexInParallel(List<CloudAccount> accounts) async {
    final stopwatch = Stopwatch()..start();
    
    try {
      final futures = accounts.map((account) {
        final adapter = _adapters[account.id];
        if (adapter == null) {
        }
        // Return a future that completes when this account's index is built
        return SearchService.instance.buildAccountIndex(account, adapter).then((_) {
        }).catchError((e) {
        });
      }).toList();

      await Future.wait(futures, eagerError: false);
      stopwatch.stop();
    } catch (e, stack) {
    }
  }

  // Optimized notification with debouncing
  void _debouncedNotify() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      if (hasListeners) {
        notifyListeners();
      }
    });
  }

  // Optimized cache management with size limits
  void _manageCacheSize() {
    if (_nodeCache.length > 50) { // Limit cache size
      final oldestKey = _cacheTimestamps.entries
          .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
          .key;
      _nodeCache.remove(oldestKey);
      _linkedAccountsCache.remove(oldestKey);
      _cacheTimestamps.remove(oldestKey);
    }
  }

  // Cancel pending requests for the same folder
  void _cancelPendingRequest(String cacheKey) {
    _pendingRequests.remove(cacheKey);
  }

  // Cache management
  bool _isCacheValid(String key) {
    final timestamp = _cacheTimestamps[key];
    return timestamp != null && DateTime.now().difference(timestamp) < _cacheExpiry;
  }

  void _invalidateCache() {
    _nodeCache.clear();
    _linkedAccountsCache.clear();
    _cacheTimestamps.clear();
    _pendingRequests.clear();
  }

  /// Invalidate cache for a specific folder only
  /// This preserves parent folder cache for instant back navigation
  void _invalidateCacheForFolder(String folderId) {
    _nodeCache.remove(folderId);
    _cacheTimestamps.remove(folderId);
    _cancelPendingRequest(folderId);
  }

  void _invalidateCacheForKey(String key) {
    _nodeCache.remove(key);
    _linkedAccountsCache.remove(key);
    _cacheTimestamps.remove(key);
    _cancelPendingRequest(key);
  }

  @override
  void dispose() {
    super.dispose();
  }

  // --- 1. GENERIC ADAPTER RETRIEVAL ---
  ICloudAdapter? _getAdapterForNode(CloudNode node) {
    // For virtual drive folders, use sourceAccountId if accountId is null
    final accountId = node.accountId ?? node.sourceAccountId;
    if (accountId == null) return null;
    return _adapters[accountId];
  }

  ICloudAdapter? getAdapterForAccount(String accountId) {
    return _adapters[accountId];
  }

  // --- 2. GOOGLE CONNECTION (Specific Logic) ---
  Future<void> connectGoogleDrive() async {
    // Sign in and get auth info (returns Map with email, name, credentials, authClient)
    final authInfo = await _googleAuth.signIn();
    if (authInfo == null) return;

    final email = authInfo['email'] as String;
    final name = authInfo['name'] as String;
    final credentials = authInfo['credentials'] as String;
    final authClient = authInfo['authClient'] as dynamic; // Use the original authenticated client


    // Create a new account ID
    final newAccountId = const Uuid().v4();
    
    // Create CloudAccount with credentials
    final newAccount = CloudAccount(
      id: newAccountId,
      provider: 'gdrive',
      name: name,
      email: email,
      credentials: credentials, // Store credentials in the account
    );
    
    // Save account to Hive
    await HiveStorageService.instance.createAccount(newAccount);
    
    // Verify the account was saved with credentials
    final savedAccount = await HiveStorageService.instance.getAccount(newAccountId);
    if (savedAccount?.credentials == null) {
    } else {
    }
    
    // Create and store the adapter using the original authClient from sign-in
    _adapters[newAccountId] = GoogleDriveAdapter(authClient, newAccountId);

    // Create Root Folder
    final mountPoint = CloudNode(
      id: const Uuid().v4(),
      name: "$email (Google Drive)",
      isFolder: true,
      provider: 'gdrive',
      accountId: newAccountId,
      updatedAt: DateTime.now(),
      cloudId: null, // Root - original behavior
    );
    
    await HiveStorageService.instance.createNode(mountPoint);
    await SearchService.instance.addEntry(mountPoint, newAccount);
    await loadNodes();
    
    
    // Note: RClone service has been removed from project
  }
  
  // --- 3. DROPBOX CONNECTION (Placeholder for next step) ---
  Future<void> connectDropbox() async {
    // We will implement this next. 
    // It will follow the same pattern: 
    // 1. Login 
    // 2. Call _registerAccount with a new DropboxAdapter
  }

  // --- 4. GENERIC ACCOUNT REGISTRATION ---
  Future<void> _registerAccount(
    String provider, 
    String name, 
    String email,
    ICloudAdapter Function(String id) adapterFactory
  ) async {
    final newAccountId = const Uuid().v4();
    
    // 1. Create DB Record
    final newAccount = CloudAccount(
      id: newAccountId, 
      provider: provider, 
      name: name, 
      email: email
    );
    await HiveStorageService.instance.createAccount(newAccount);

    // 2. Instantiate Specific Adapter & Store as Generic Interface
    _adapters[newAccountId] = adapterFactory(newAccountId);

    // 3. Create Root Folder
    final mountPoint = CloudNode(
      id: const Uuid().v4(),
      name: "$email ($provider)",
      isFolder: true,
      provider: provider,
      accountId: newAccountId,
      updatedAt: DateTime.now(),
      cloudId: null, // Root - original behavior
    );
    
    await HiveStorageService.instance.createNode(mountPoint);
    final account = await HiveStorageService.instance.getAccount(newAccountId);
    if (account != null) {
      await SearchService.instance.addEntry(mountPoint, account);
    }
    await loadNodes();
  }

  // --- 5. CORE LOGIC (Now completely generic) ---
  Future<void> loadNodes() async {
    final cacheKey = currentFolderId ?? 'root';
    
    // Check cache first - immediate return for cached data
    if (_isCacheValid(cacheKey) && _nodeCache.containsKey(cacheKey)) {
      _currentNodes = _nodeCache[cacheKey]!;
      _isLoading = false;
      _debouncedNotify();
      return;
    }

    // Check if there's already a pending request for this folder
    if (_pendingRequests.containsKey(cacheKey)) {
      try {
        _currentNodes = await _pendingRequests[cacheKey]!;
        _isLoading = false;
        _debouncedNotify();
        return;
      } catch (e) {
        // If pending request failed, remove it and continue
        _cancelPendingRequest(cacheKey);
      }
    }

    // Show loading state immediately for better UX
    _isLoading = true;
    _loadingFolderId = cacheKey;
    _currentNodes = [];
    _debouncedNotify();


    // Create the request future
    final requestFuture = _loadNodesInternal(cacheKey);
    _pendingRequests[cacheKey] = requestFuture;

    try {
      _currentNodes = await requestFuture;
      
      // Cache the results
      _nodeCache[cacheKey] = _currentNodes;
      _cacheTimestamps[cacheKey] = DateTime.now();
      
      // Manage cache size
      _manageCacheSize();
      
      
    } catch (e) {
      _currentNodes = [];
    } finally {
      // Remove from pending requests
      _cancelPendingRequest(cacheKey);
      _isLoading = false;
      _loadingFolderId = null;
    }
    
    _debouncedNotify();
  }

  // Internal method to handle the actual loading
  Future<List<CloudNode>> _loadNodesInternal(String cacheKey) async {
    // A. LOCAL - Fastest path
    if (currentFolderNode == null || currentFolderNode!.provider == 'local') {
      // Reset pagination for local folders (they don't need pagination)
      _nextPageToken = null;
      _hasMore = false;
      return await HiveStorageService.instance.getChildren(currentFolderId);
    }
    
    // B. VIRTUAL RAID - Optimized parallel loading
    else if (currentFolderNode!.provider == 'virtual') {
      // Reset pagination for virtual drives (they combine multiple sources)
      _nextPageToken = null;
      _hasMore = false;
      return await _loadVirtualRaidNodesOptimized(cacheKey);
    }

    // C. STANDARD CLOUD FOLDER - Optimized with timeout and pagination
    else {
      // Reset pagination for cloud folders
      _nextPageToken = null;
      _hasMore = false;
      return await _loadCloudNodesOptimized();
    }
  }

  // Optimized virtual RAID loading with parallel requests
  Future<List<CloudNode>> _loadVirtualRaidNodesOptimized(String cacheKey) async {
    List<CloudNode> mergedList = [];
    
    // Check if we're at the root of the virtual drive or inside a folder
    // We're at the root if the current folder is the virtual drive itself (no sourceAccountId)
    // We're inside a folder if the current folder has a sourceAccountId
    if (currentFolderNode!.sourceAccountId == null) {
      // We're at the root of the virtual drive - fetch from ALL linked accounts
      
      // 1. Get all accounts linked to this virtual drive (with caching)
      List<String> linkedAccountIds;
      if (_isCacheValid(cacheKey) && _linkedAccountsCache.containsKey(cacheKey)) {
        linkedAccountIds = _linkedAccountsCache[cacheKey]!;
      } else {
        linkedAccountIds = await HiveStorageService.instance.getLinkedAccounts(currentFolderNode!.id);
        _linkedAccountsCache[cacheKey] = linkedAccountIds;
        _cacheTimestamps[cacheKey] = DateTime.now();
      }
      
      // 2. Fetch from ALL linked accounts in parallel with timeout
      final futures = linkedAccountIds.map((accId) => _fetchAccountNodesWithTimeout(accId)).toList();
      final results = await Future.wait(futures, eagerError: false);
      
      // 3. Merge results
      for (final accountNodes in results) {
        if (accountNodes != null) {
          mergedList.addAll(accountNodes);
        }
      }
    } else {
      // We're inside a folder in the virtual drive - fetch only from the source account
      final sourceAccountId = currentFolderNode!.sourceAccountId!;
      final nodes = await _fetchAccountNodesWithTimeout(sourceAccountId);
      if (nodes != null) {
        mergedList.addAll(nodes);
      }
    }
    
    return mergedList;
  }

  // Fetch nodes from a single account with timeout and error handling
  Future<List<CloudNode>?> _fetchAccountNodesWithTimeout(String accId) async {
    
    // CRITICAL FIX: When inside a virtual drive folder, use sourceAccountId to get the adapter
    String actualAccountIdToUse = accId;
    if (currentFolderNode!.provider == 'virtual' && currentFolderNode!.sourceAccountId != null) {
      actualAccountIdToUse = currentFolderNode!.sourceAccountId!;
    }
    
    final adapter = _adapters[actualAccountIdToUse];
    if (adapter == null) {
      return null;
    }
    
    try {
      // Determine the folder ID to fetch from
      // If we're at the root of the virtual drive, fetch from 'root'
      // If we're inside a folder, fetch from the folder's cloudId
      String? folderIdToFetch;
      
      // Check if currentFolderNode is the virtual drive itself (root)
      if (currentFolderNode!.provider == 'virtual' && currentFolderNode!.parentId == null) {
        // We're at the root of the virtual drive, fetch from 'root' of each account
        folderIdToFetch = 'root';
      } else if (currentFolderNode!.provider == 'virtual') {
        // We're inside a folder in the virtual drive
        // Use the folder's cloudId to fetch its contents
        folderIdToFetch = currentFolderNode!.cloudId;
      } else {
        // Fallback to root
        folderIdToFetch = 'root';
      }
      
      // Add timeout to prevent hanging
      final result = await adapter.listFolder(folderIdToFetch).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException("Timeout fetching from account $accId", const Duration(seconds: 10));
        },
      );
       
      // Re-parent files to virtual folder and set source account
      return result.nodes.map((node) => CloudNode(
        id: node.id,
        parentId: currentFolderNode!.id, // Fake Parent
        cloudId: node.cloudId,
        accountId: currentFolderNode!.accountId, // Virtual drive's accountId
        sourceAccountId: node.accountId, // The actual account where file is stored
        name: node.name,
        isFolder: node.isFolder,
        provider: node.provider,
        updatedAt: node.updatedAt,
        size: node.size,
      )).toList();
      
    } catch (e) {
      return null;
    }
  }

  /// Update search index for a specific account
  Future<void> refreshSearchIndexForAccount(String accountId) async {
    final account = await HiveStorageService.instance.getAccount(accountId);
    final adapter = _adapters[accountId];
    if (account != null && adapter != null) {
      await SearchService.instance.buildAccountIndex(account, adapter);
    }
  }

  // Optimized cloud node loading with timeout and pagination
  Future<List<CloudNode>> _loadCloudNodesOptimized() async {
    final adapter = _getAdapterForNode(currentFolderNode!);
    if (adapter == null) {
      _nextPageToken = null;
      _hasMore = false;
      return [];
    }
    
    try {
      final result = await adapter.listFolder(
        currentFolderNode!.cloudId,
        pageToken: _nextPageToken,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw TimeoutException("Timeout fetching cloud folder", const Duration(seconds: 15));
        },
      );
      
      // Store pagination state
      _nextPageToken = result.nextPageToken;
      _hasMore = result.hasMore;
      
      return result.nodes;
    } catch (e) {
      _nextPageToken = null;
      _hasMore = false;
      return [];
    }
  }
  
  /// Load more items for the current folder (next page)
  Future<void> loadMoreNodes() async {
    if (_isLoadingMore || !_hasMore || _nextPageToken == null) {
      return;
    }
    
    _isLoadingMore = true;
    notifyListeners();
    
    try {
      final adapter = _getAdapterForNode(currentFolderNode!);
      if (adapter == null) {
        _isLoadingMore = false;
        return;
      }
      
      final result = await adapter.listFolder(
        currentFolderNode!.cloudId,
        pageToken: _nextPageToken,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw TimeoutException("Timeout fetching more cloud items", const Duration(seconds: 15));
        },
      );
      
      // Append new nodes to current list
      _currentNodes.addAll(result.nodes);
      
      // Update pagination state
      _nextPageToken = result.nextPageToken;
      _hasMore = result.hasMore;
      
      // Cache the updated list
      final cacheKey = currentFolderId ?? 'root';
      _nodeCache[cacheKey] = _currentNodes;
      _cacheTimestamps[cacheKey] = DateTime.now();
      
      
    } catch (e) {
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  Future<void> createFolder(String name) async {
    if (currentFolderNode == null) return;
    
    try {
      final newNode = CloudNode(
        id: const Uuid().v4(),
        parentId: currentFolderId,
        name: name,
        isFolder: true,
        provider: currentFolderNode!.provider,
        accountId: currentFolderNode!.accountId,
        updatedAt: DateTime.now(),
      );

      // Handle different providers
      if (currentFolderNode!.provider == 'local') {
        // Local folder - just create DB record
        await HiveStorageService.instance.createNode(newNode);
      } else if (currentFolderNode!.provider == 'gdrive' || currentFolderNode!.provider == 'onedrive') {
        // Cloud folder - create in cloud first, then DB
        final adapter = _getAdapterForNode(currentFolderNode!);
        if (adapter != null) {
          final cloudId = await adapter.createFolder(name, currentFolderNode!.cloudId, checkDuplicates: false);
          // Create new node with updated cloud ID
          final updatedNode = CloudNode(
            id: newNode.id,
            parentId: newNode.parentId,
            cloudId: cloudId,
            accountId: newNode.accountId,
            name: newNode.name,
            isFolder: newNode.isFolder,
            provider: newNode.provider,
            updatedAt: newNode.updatedAt,
          );
          await HiveStorageService.instance.createNode(updatedNode);
          final account = await HiveStorageService.instance.getAccount(newNode.accountId!);
          if (account != null) {
            await SearchService.instance.addEntry(updatedNode, account);
          }
        } else {
          throw Exception("No adapter found for cloud account");
        }
      } else if (currentFolderNode!.provider == 'virtual') {
        // Virtual RAID - create in first available account with round-robin logic
        await _createFolderInVirtualRaid(name, newNode);
      }
      
      _invalidateCache();
      await loadNodes();
    } catch (e) {
      rethrow;
    }
  }

  // --- CLOUD SYNC FUNCTIONALITY ---
  
  /// Sync all existing files and folders from a cloud drive to the local database
  Future<void> syncCloudDrive(String accountId, String dbRootFolderId) async {
    final adapter = _adapters[accountId];
    if (adapter == null) {
      throw Exception("No adapter found for account $accountId");
    }
    
    
    // Start recursive sync from root
    await _syncFolderRecursively(adapter, accountId, 'root', dbRootFolderId);
    
  }
  
  /// Recursively sync a cloud folder and all its contents to the database
  Future<void> _syncFolderRecursively(ICloudAdapter adapter, String accountId, String? cloudFolderId, String? dbParentId) async {
    try {
      
      // Get files from cloud
      final result = await adapter.listFolder(cloudFolderId);
      final cloudFiles = result.nodes;
      
      // Process each file/folder
      for (final cloudFile in cloudFiles) {
        try {
          // Check if this file already exists in database
          final existingNode = await findExistingNode(dbParentId, cloudFile.name, cloudFile.isFolder);
          
          String dbNodeId;
          if (existingNode != null) {
            // Update existing node with cloud info
            dbNodeId = existingNode.id;
            
            // Update the node with cloud ID and other info
            final updatedNode = CloudNode(
              id: existingNode.id,
              parentId: existingNode.parentId,
              cloudId: cloudFile.cloudId,
              accountId: accountId,
              name: cloudFile.name,
              isFolder: cloudFile.isFolder,
              provider: cloudFile.provider,
              updatedAt: cloudFile.updatedAt,
            );
            
            await HiveStorageService.instance.createNode(updatedNode);
            final account = await HiveStorageService.instance.getAccount(accountId);
            if (account != null) {
              await SearchService.instance.addEntry(updatedNode, account);
            }
          } else {
            // Create new node in database
            dbNodeId = const Uuid().v4();
            
            final newNode = CloudNode(
              id: dbNodeId,
              parentId: dbParentId,
              cloudId: cloudFile.cloudId,
              accountId: accountId,
              name: cloudFile.name,
              isFolder: cloudFile.isFolder,
              provider: cloudFile.provider,
              updatedAt: cloudFile.updatedAt,
            );
            
            await HiveStorageService.instance.createNode(newNode);
            final account = await HiveStorageService.instance.getAccount(accountId);
            if (account != null) {
              await SearchService.instance.addEntry(newNode, account);
            }
          }
          
          // Recursively sync subfolders
          if (cloudFile.isFolder) {
            await _syncFolderRecursively(adapter, accountId, cloudFile.cloudId, dbNodeId);
          }
          
        } catch (e) {
          // Continue with other items even if one fails
        }
      }
      
    } catch (e) {
      rethrow;
    }
  }
  
  /// Find an existing node in the database by parent, name, and type
  Future<CloudNode?> findExistingNode(String? parentId, String name, bool isFolder) async {
    // Use Hive to find existing node by filtering
    final allNodes = HiveStorageService.instance.getAllNodes();
    
    for (final node in allNodes) {
      final matchesParent = (parentId == null && node.parentId == null) || node.parentId == parentId;
      final matchesName = node.name == name;
      final matchesType = node.isFolder == isFolder;
      
      if (matchesParent && matchesName && matchesType) {
        return node;
      }
    }
    
    return null;
  }
  
  /// Manual sync option for users to refresh cloud content
  Future<void> refreshCurrentCloudDrive() async {
    // For virtual drive folders, use sourceAccountId if accountId is null
    final accountId = currentFolderNode?.accountId ?? currentFolderNode?.sourceAccountId;
    if (currentFolderNode == null || accountId == null) {
      throw Exception("No cloud drive selected");
    }
    
    
    // Find the root folder for this account
    final account = await HiveStorageService.instance.getAccount(accountId);
    if (account == null) {
      throw Exception("Account not found");
    }
    
    // Find the root node for this account
    // Find the root node for this account using Hive
    final allNodes = HiveStorageService.instance.getAllNodes();
    
    CloudNode? rootNode;
    for (final node in allNodes) {
      if (node.accountId == accountId && node.cloudId == 'root') {
        rootNode = node;
        break;
      }
    }
    
    if (rootNode == null) {
      throw Exception("Root folder not found for account");
    }
    
    // Sync the cloud drive
    await syncCloudDrive(accountId, rootNode.id);
    
    // Invalidate cache and reload current view
    _invalidateCache();
    await loadNodes();
    
  }



  Future<void> _createFolderInVirtualRaid(String name, CloudNode newNode) async {
    // Get all accounts linked to this virtual drive
    final linkedAccountIds = await HiveStorageService.instance.getLinkedAccounts(currentFolderNode!.id);
    if (linkedAccountIds.isEmpty) {
      throw Exception("No accounts linked to virtual drive");
    }

    // For now, virtual raid only supports root folder creation
    // In the future, this should handle subfolder navigation
    const cloudParentId = 'root';

    // Use round-robin: create in first available account
    for (final accountId in linkedAccountIds) {
      final adapter = _adapters[accountId];
      if (adapter != null) {
        try {
          final cloudId = await adapter.createFolder(name, cloudParentId, checkDuplicates: false);
          
          // Create new node with updated cloud information from the account where it was created
          final updatedNode = CloudNode(
            id: newNode.id,
            parentId: newNode.parentId,
            cloudId: cloudId,
            accountId: accountId,
            name: newNode.name,
            isFolder: newNode.isFolder,
            provider: adapter?.providerId ?? 'unknown', // Use actual provider from adapter
            updatedAt: newNode.updatedAt,
          );
          
          await HiveStorageService.instance.createNode(updatedNode);
          return; // Successfully created
        } catch (e) {
          continue; // Try next account
        }
      }
    }
    
    throw Exception("Failed to create folder in any linked account");
  }

  /// Get detailed information about accounts linked to the current virtual drive
  Future<List<VirtualDriveAccountInfo>> getVirtualDriveAccountDetails() async {
    
    if (currentFolderNode?.provider != 'virtual') {
      return [];
    }

    
    final linkedAccountIds = await HiveStorageService.instance.getLinkedAccounts(currentFolderNode!.id);
    
    final List<VirtualDriveAccountInfo> accountDetails = [];

    for (final accountId in linkedAccountIds) {
      try {
        
        final account = await HiveStorageService.instance.getAccount(accountId);
        final adapter = _adapters[accountId];
        
        if (account != null && adapter != null) {
          accountDetails.add(VirtualDriveAccountInfo(
            accountId: accountId,
            account: account,
            adapter: adapter,
            isAvailable: true, // For now, assume available if we have an adapter
          ));
        } else {
        }
      } catch (e) {
      }
    }

    return accountDetails;
  }

  /// Upload multiple files to a specific drive (for regular cloud drives)
  Future<void> uploadMultipleFilesToRegularDrive(
    List<String> filePaths,
    List<String> fileNames
  ) async {
    if (currentFolderNode == null) {
      throw Exception("No current folder selected");
    }
    
    final targetAdapter = _getAdapterForNode(currentFolderNode!);
    if (targetAdapter == null) {
      throw Exception("No adapter found for current drive");
    }
    
    // For virtual drive folders, use sourceAccountId if accountId is null
    final accountId = currentFolderNode!.accountId ?? currentFolderNode!.sourceAccountId!;
    await _uploadMultipleFilesToSingleDrive(
      filePaths,
      fileNames,
      targetAdapter,
      currentFolderNode!.cloudId,
      accountId,
      currentFolderNode!.provider,
      currentFolderId
    );
  }

  /// Helper method to upload multiple files to a single cloud drive using TaskService with parallel processing
  Future<void> _uploadMultipleFilesToSingleDrive(
    List<String> filePaths,
    List<String> fileNames,
    ICloudAdapter targetAdapter,
    String? targetParentId,
    String accountId,
    String provider,
    String? currentFolderId, // Add this parameter
  ) async {
    
    bool shouldEncrypt = await shouldEncryptForAccount(accountId);
    final tempFiles = <String, File>{}; // Track temp encrypted files for cleanup
    
    try {
      // Create a batch upload task that will handle parallel processing
      final batchUploadTask = QueuedTask(
        id: const Uuid().v4(),
        type: TaskType.upload, // Use upload type but will handle multiple files
        name: "${filePaths.length} files", // Display count
        accountId: accountId,
        payload: {
          'batchUpload': true, // Flag to indicate this is a batch upload
          'filePaths': filePaths,
          'fileNames': fileNames,
          'parentId': targetParentId,
          'shouldEncrypt': shouldEncrypt,
          'currentFolderId': currentFolderId,
          'provider': provider,
        },
      );

      // Add batch task to TaskService
      TaskService.instance.addTask(batchUploadTask);

    } catch (e) {
      rethrow;
    }
  }

  /// Create folder in Virtual RAID with user-selected accounts
  Future<void> createFolderInVirtualRaidWithSelection(
    String name, 
    List<String> selectedAccountIds
  ) async {
    
    if (selectedAccountIds.isEmpty) {
      throw Exception("No accounts selected for folder creation");
    }

    const cloudParentId = 'root';
    final createdFolders = <String, String>{}; // accountId -> cloudId mapping
    final errors = <String, String>{}; // accountId -> error message

    // Try to create folder in each selected account
    for (final accountId in selectedAccountIds) {
      
      final adapter = _adapters[accountId];
      if (adapter != null) {
        try {
          final cloudId = await adapter.createFolder(name, cloudParentId, checkDuplicates: false);
          createdFolders[accountId] = cloudId;
        } catch (e, stackTrace) {
          errors[accountId] = e.toString();
        }
      } else {
        errors[accountId] = "No adapter found for account";
      }
    }


    if (createdFolders.isEmpty) {
      final errorSummary = errors.entries.map((e) => "${e.key}: ${e.value}").join(', ');
      throw Exception("Failed to create folder in any selected account. Errors: $errorSummary");
    }

    
    // Create database entries for successfully created folders
    for (final entry in createdFolders.entries) {
      final accountId = entry.key;
      final cloudId = entry.value;

      
      final adapter = _adapters[accountId];
      final newNode = CloudNode(
        id: const Uuid().v4(), // Each folder gets a unique ID
        parentId: currentFolderId,
        cloudId: cloudId,
        accountId: currentFolderNode!.accountId, // Virtual drive's accountId
        sourceAccountId: accountId, // The actual account where folder is stored
        name: name,
        isFolder: true,
        provider: adapter?.providerId ?? 'unknown', // Use actual provider from adapter
        updatedAt: DateTime.now(),
      );

      await HiveStorageService.instance.createNode(newNode);
      final account = await HiveStorageService.instance.getAccount(accountId);
      if (account != null) {
        await SearchService.instance.addEntry(newNode, account);
      }
    }

    _invalidateCache();
    await loadNodes();
  }

  // --- 6. UPLOAD (Generic) ---
  Future<void> uploadFile({List<String>? filePaths, List<String>? fileNames}) async {
    // 0. Safety Checks
    if (currentFolderNode == null) return;

    // --- A. VIRTUAL RAID ALLOCATION LOGIC ---
    ICloudAdapter? targetAdapter;
    String? targetAccountId;
    String? targetParentId; 

    if (currentFolderNode!.provider == 'virtual') {
      // Logic: We are in a Virtual Drive, so we must pick a PHYSICAL account to store the file.
      final linkedAccountIds = await HiveStorageService.instance.getLinkedAccounts(currentFolderNode!.id);
      
      if (linkedAccountIds.isEmpty) {
        throw Exception("Virtual Drive is empty! No accounts linked.");
      }

      // For Virtual RAID, we'll use the selection dialog approach
      // Get account details and let user choose which drives to upload to
      final accountDetails = await getVirtualDriveAccountDetails();
      if (accountDetails.isEmpty) {
        throw Exception("No available accounts in virtual drive");
      }

      // We'll handle the selection in the UI layer - for now, pick first account as fallback
      // This maintains backward compatibility until UI is updated
      targetAccountId = linkedAccountIds.first; 
      targetAdapter = _adapters[targetAccountId];
      
      // When uploading to the root of a Virtual Drive, it goes to the root of the physical drive
      targetParentId = null; 
    } else {
      // Logic: Standard Upload (Directly inside a Google/Dropbox folder)
      targetAdapter = _getAdapterForNode(currentFolderNode!);
      targetAccountId = currentFolderNode!.accountId;
      targetParentId = currentFolderNode!.cloudId;
      
      // Special handling for root folders (cloudId is null)
      if (targetParentId == null && currentFolderNode!.isFolder) {
        targetParentId = 'root'; // Use 'root' for cloud root folders
      }
      
    }

    if (targetAdapter == null) {
      return;
    }

    // --- B. FILE SELECTION LOGIC ---
    List<String> uploadFilePaths;
    List<String> uploadFileNames;
    
    // Check if files were already provided (from UI layer)
    if (filePaths != null && fileNames != null && filePaths.isNotEmpty) {
      // Files were pre-selected by UI layer - no need to show file picker
      uploadFilePaths = filePaths;
      uploadFileNames = fileNames;
    } else {
      // Show file picker for backward compatibility
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true, // Enable multiple file selection
      );
      if (result == null) return; // User canceled
      
      uploadFilePaths = result.files.map((file) => file.path!).toList();
      uploadFileNames = result.files.map((file) => file.name).toList();
    }

    // Handle multiple files
    if (uploadFilePaths.length > 1) {
      // Multiple files selected - use the new multiple file upload method
      
      // For Virtual RAID, we need to handle drive selection in UI layer
      if (currentFolderNode!.provider == 'virtual') {
        // Return the file information for UI handling
        throw MultipleFilesSelectedException(uploadFilePaths, uploadFileNames);
      } else {
        // For regular drives, upload to the current drive only
        await _uploadMultipleFilesToSingleDrive(uploadFilePaths, uploadFileNames, targetAdapter, targetParentId, targetAccountId!, currentFolderNode!.provider, currentFolderId);
        return;
      }
    }
    
    // Single file upload - create task for TaskService
    File originalFile = File(uploadFilePaths.first);
    String uploadName = uploadFileNames.first;
    File fileToUpload = originalFile;
    
    // --- STORAGE CHECK ---
    // Get the file size for storage check
    final fileSize = await originalFile.length();
    
    // Check if there's enough storage space
    if (targetAccountId != null) {
      final storageCheck = await checkStorageForUpload(targetAccountId, fileSize);
      
      if (!storageCheck.canUpload) {
        // Show error but don't throw - just return
        return;
      }
    } else {
    }
    
    bool shouldEncrypt = await shouldEncryptForAccount(targetAccountId);

    // --- C. ENCRYPTION (The Vault) ---
    if (shouldEncrypt) {
      if (!SecurityService.instance.isUnlocked) throw Exception("Vault locked!");
      
      final tempDir = await getTemporaryDirectory();
      uploadName = "$uploadName.enc"; // Append extension so we know to decrypt later
      final tempFile = File('${tempDir.path}/$uploadName');
      
      // Encrypt Source -> Temp (FEK is now embedded in the file)
      await SecurityService.instance.encryptFile(
        originalFile,
        tempFile,
      );
      
      fileToUpload = tempFile;
      
    }

    // --- D. CREATE UPLOAD TASK ---
    final uploadTask = QueuedTask(
      id: const Uuid().v4(),
      type: TaskType.upload,
      name: uploadFileNames.first, // Use original name for display
      accountId: targetAccountId!,
      payload: {
        'filePath': fileToUpload.path,
        'parentId': targetParentId,
        'originalFileName': uploadFileNames.first,
        'isEncrypted': shouldEncrypt,
        'originalFilePath': originalFile.path,
        'currentFolderId': currentFolderId,
        'provider': targetAdapter.providerId,
      },
    );

    // Add task to TaskService
    TaskService.instance.addTask(uploadTask);
  }

  /// Upload file to Virtual RAID with user-selected accounts using TaskService
  Future<void> uploadFileToVirtualRaidWithSelection(
    String filePath,
    String fileName,
    List<String> selectedAccountIds
  ) async {
    
    // Get current upload strategy
    final strategy = await getUploadStrategy();
    
    List<String> accountsToUse;
    
    if (strategy != VirtualRaidUploadStrategy.manual) {
      // Automatic selection - get file size and select drive based on strategy
      
      final file = File(filePath);
      final fileSize = await file.length();
      
      String? selectedAccountId;
      
      if (strategy == VirtualRaidUploadStrategy.mostFreeStorage) {
        selectedAccountId = await selectDriveWithMostFreeStorage(fileSize, currentFolderId!);
      } else if (strategy == VirtualRaidUploadStrategy.lowestFullPercentage) {
        selectedAccountId = await selectDriveWithLowestFullPercentage(fileSize, currentFolderId!);
      }
      
      if (selectedAccountId == null) {
        throw Exception("No drive has enough storage space for this file. Please free up space or try a different file.");
      }
      
      accountsToUse = [selectedAccountId];
    } else {
      // Manual strategy - use provided selectedAccountIds
      
      if (selectedAccountIds.isEmpty) {
        throw Exception("No accounts selected for file upload");
      }
      
      accountsToUse = selectedAccountIds;
    }

    const cloudParentId = 'root'; // Upload to root of selected drives
    File originalFile = File(filePath);
    File fileToUpload = originalFile;
    String uploadName = fileName;
    
    // Check encryption for each account individually
    bool shouldEncrypt = await shouldEncryptForAccount(accountsToUse.isNotEmpty ? accountsToUse.first : null);

    try {
      // --- ENCRYPTION (The Vault) ---
      if (shouldEncrypt) {
        if (!SecurityService.instance.isUnlocked) throw Exception("Vault locked!");
        
        final tempDir = await getTemporaryDirectory();
        uploadName = "$fileName.enc"; // Append extension so we know to decrypt later
        final tempFile = File('${tempDir.path}/$uploadName');
        
        // Encrypt Source -> Temp (FEK is now embedded in the file)
        await SecurityService.instance.encryptFile(
          originalFile,
          tempFile,
        );
        
        fileToUpload = tempFile;
        
      }

      // Create upload task for each selected account
      for (final accountId in accountsToUse) {
        
        final adapter = _adapters[accountId];
        if (adapter != null && (adapter is GoogleDriveAdapter || adapter is OneDriveAdapter)) {
          // Create upload task for this account
          final uploadTask = QueuedTask(
            id: const Uuid().v4(),
            type: TaskType.upload,
            name: fileName, // Use original name for display
            accountId: accountId,
            payload: {
              'filePath': fileToUpload.path,
              'parentId': cloudParentId,
              'originalFileName': fileName,
              'isEncrypted': shouldEncrypt,
              'originalFilePath': originalFile.path,
              'currentFolderId': currentFolderId,
              'provider': adapter.providerId,
            },
          );

          // Add task to TaskService
          TaskService.instance.addTask(uploadTask);
        } else {
        }
      }


    } catch (e, stackTrace) {
      rethrow;
    }
    // Note: No cleanup here - temp files will be cleaned up by TaskService after upload
  }

  /// Upload multiple files to Virtual RAID with user-selected accounts using TaskService
  Future<Map<String, dynamic>> uploadMultipleFilesToVirtualRaidWithSelection(
    List<String> filePaths,
    List<String> fileNames,
    List<String> selectedAccountIds
  ) async {
    
    // Get current upload strategy
    final strategy = await getUploadStrategy();
    
    List<String> accountsToUse;
    
    if (strategy != VirtualRaidUploadStrategy.manual) {
      // Automatic selection - select drive based on strategy
      
      // Get file sizes for all files
      final fileSizes = <int>[];
      for (final filePath in filePaths) {
        final file = File(filePath);
        fileSizes.add(await file.length());
      }
      final totalSize = fileSizes.reduce((a, b) => a + b);
      
      String? selectedAccountId;
      
      if (strategy == VirtualRaidUploadStrategy.mostFreeStorage) {
        selectedAccountId = await selectDriveWithMostFreeStorage(totalSize, currentFolderId!);
      } else if (strategy == VirtualRaidUploadStrategy.lowestFullPercentage) {
        selectedAccountId = await selectDriveWithLowestFullPercentage(totalSize, currentFolderId!);
      }
      
      if (selectedAccountId == null) {
        throw Exception("No drive has enough storage space for these files. Please free up space or try different files.");
      }
      
      accountsToUse = [selectedAccountId];
    } else {
      // Manual strategy - use provided selectedAccountIds
      
      if (selectedAccountIds.isEmpty) {
        throw Exception("No accounts selected for file upload");
      }
      
      accountsToUse = selectedAccountIds;
    }

    if (filePaths.isEmpty || fileNames.isEmpty || filePaths.length != fileNames.length) {
      throw Exception("Invalid file paths or names provided");
    }

    const cloudParentId = 'root'; // Upload to root of selected drives
    bool shouldEncrypt = await shouldEncryptForAccount(accountsToUse.isNotEmpty ? accountsToUse.first : null);
    final tempFiles = <String, File>{}; // Track temp encrypted files for cleanup
    int totalTasksCreated = 0;

    try {
      // Process each file one by one
      for (int i = 0; i < filePaths.length; i++) {
        final filePath = filePaths[i];
        final fileName = fileNames[i];
        
        
        File originalFile = File(filePath);
        File fileToUpload = originalFile;
        String uploadName = fileName;
        
        // --- ENCRYPTION (The Vault) ---
        if (shouldEncrypt) {
          if (!SecurityService.instance.isUnlocked) {
            throw Exception("Vault locked!");
          }
          
          final tempDir = await getTemporaryDirectory();
          uploadName = "$fileName.enc"; // Append extension so we know to decrypt later
          final tempFile = File('${tempDir.path}/$uploadName');
          
          // Encrypt Source -> Temp (FEK is now embedded in the file)
          await SecurityService.instance.encryptFile(
            originalFile,
            tempFile,
          );
          
          fileToUpload = tempFile;
          tempFiles[filePath] = fileToUpload; // Track for cleanup
          
        }

        // Create upload task for each selected account
        for (final accountId in accountsToUse) {
          
          final adapter = _adapters[accountId];
          if (adapter != null && (adapter is GoogleDriveAdapter || adapter is OneDriveAdapter)) {
            // Create upload task for this file/account combination
            final uploadTask = QueuedTask(
              id: const Uuid().v4(),
              type: TaskType.upload,
              name: fileName, // Use original name for display
              accountId: accountId,
              payload: {
                'filePath': fileToUpload.path,
                'parentId': cloudParentId,
                'originalFileName': fileName,
                'isEncrypted': shouldEncrypt,
                'originalFilePath': originalFile.path,
                'currentFolderId': currentFolderId,
                'provider': adapter.providerId,
              },
            );

            // Add task to TaskService
            TaskService.instance.addTask(uploadTask);
            totalTasksCreated++;
          } else {
          }
        }
      }


      // Return comprehensive results
      return {
        'total_tasks_created': totalTasksCreated,
        'total_files': filePaths.length,
        'selected_accounts': selectedAccountIds.length,
        'successful_files': filePaths.length, // All files were successfully queued
        'files_with_errors': 0, // No errors during task creation
      };

    } catch (e, stackTrace) {
      rethrow;
    }
    // Note: No cleanup here - temp files will be cleaned up by TaskService after upload
  }

  // --- 7. DOWNLOAD (Generic) ---
  
  /// Download multiple files in parallel
  Future<void> downloadMultipleNodes(List<CloudNode> nodes) async {
    if (nodes.isEmpty) return;
    
    
    // Filter out folders and nodes without cloud IDs
    final validNodes = nodes.where((node) =>
      !node.isFolder && node.cloudId != null
    ).toList();
    
    if (validNodes.isEmpty) {
      return;
    }
    
    if (validNodes.length != nodes.length) {
    }
    
    // Get the first node's adapter (assuming all nodes are from the same account)
    final firstNode = validNodes.first;
    final adapter = _getAdapterForNode(firstNode);
    if (adapter == null) {
      return;
    }
    
    final downloadsDir = await getDownloadsDirectory();
    final accountId = firstNode.accountId!;
    
    // Prepare file information for batch download
    final fileIds = <String>[];
    final fileNames = <String>[];
    
    for (final node in validNodes) {
      fileIds.add(node.cloudId!);
      fileNames.add(node.name);
    }
    
    // Check if any files need decryption
    final shouldDecrypt = validNodes.any((node) => node.name.endsWith('.enc'));
    
    try {
      // Create a batch download task
      final batchDownloadTask = QueuedTask(
        id: const Uuid().v4(),
        type: TaskType.download, // Use download type but will handle multiple files
        name: "${validNodes.length} files", // Display count
        accountId: accountId,
        payload: {
          'batchDownload': true, // Flag to indicate this is a batch download
          'fileIds': fileIds,
          'fileNames': fileNames,
          'saveDirectory': downloadsDir?.path ?? '',
          'shouldDecrypt': shouldDecrypt,
        },
      );

      // Add batch task to TaskService
      TaskService.instance.addTask(batchDownloadTask);

    } catch (e) {
      rethrow;
    }
  }
  
  Future<void> downloadNode(CloudNode node) async {
    
    if (node.isFolder || node.cloudId == null) {
      return;
    }
    
    final adapter = _getAdapterForNode(node);
    if (adapter == null) {
      return;
    }

    final downloadsDir = await getDownloadsDirectory();
    final isEncrypted = node.name.endsWith('.enc');
    String finalFileName = isEncrypted ? node.name.replaceAll('.enc', '') : node.name;
    String savePath = '${downloadsDir?.path ?? ''}/$finalFileName';

    final tempDir = await getTemporaryDirectory();
    final downloadPath = isEncrypted ? '${tempDir.path}/${node.name}' : savePath;


    try {
      // GENERIC DOWNLOAD CALL
      await adapter.downloadFile(node.cloudId!, downloadPath);

      if (isEncrypted) {
        if (!SecurityService.instance.isUnlocked) {
          throw Exception("Unlock Vault!");
        }
        
        // Decrypt the file (FEK is embedded in the file)
        await SecurityService.instance.decryptFile(
          File(downloadPath),
          File(savePath),
        );
        await File(downloadPath).delete();
      }
      
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteNode(CloudNode node) async {
    if (node.cloudId != null) {
       final adapter = _getAdapterForNode(node);
       if (adapter != null) {
         // Try to delete with exponential backoff for cloud files
         bool deleted = false;
         int attempts = 0;
         const maxAttempts = 5;
         
         while (!deleted && attempts < maxAttempts) {
           attempts++;
           try {
             if (attempts > 1) {
               // Exponential backoff: 1s, 2s, 4s, 8s, 16s
               final delay = Duration(seconds: pow(2, attempts - 1).toInt());
               await Future.delayed(delay);
             }
             
             await adapter.deleteNode(node.cloudId!);
             deleted = true;
           } catch (deleteError) {
             if (attempts >= maxAttempts) {
               throw Exception("Failed to delete file after $maxAttempts attempts: $deleteError");
             }
           }
         }
       }
    }
    await HiveStorageService.instance.deleteNode(node.id);
    await SearchService.instance.removeEntry(node.id);
    _currentNodes.removeWhere((n) => n.id == node.id);
    _invalidateCache();
    _debouncedNotify();
  }

  /// Delete an account and all its associated nodes
  /// Returns true if successful, false if account is part of a Virtual RAID
  Future<bool> deleteAccount(CloudNode accountNode) async {
    // Check if this node represents an account root folder
    if (!accountNode.isFolder || accountNode.parentId != null || accountNode.accountId == null) {
      throw Exception("Invalid account node for deletion");
    }
    
    final accountId = accountNode.accountId!;
    
    // Check if account is linked to any virtual drives
    final linkedVirtualDrives = await HiveStorageService.instance.getVirtualDrivesForAccount(accountId);
    if (linkedVirtualDrives.isNotEmpty) {
      // Account is part of one or more Virtual RAID drives
      return false;
    }
    
    // Remove adapter
    _adapters.remove(accountId);
    
    // Delete the account from storage
    await HiveStorageService.instance.deleteAccount(accountId);
    
    // Delete all nodes associated with this account
    final allNodes = HiveStorageService.instance.getAllNodes();
    final nodesToDelete = allNodes.where((node) => node.accountId == accountId).toList();
    
    // Delete nodes from storage and search index
    for (final node in nodesToDelete) {
      await HiveStorageService.instance.deleteNode(node.id);
      await SearchService.instance.removeEntry(node.id);
    }
    
    // Update current nodes list
    _currentNodes.removeWhere((n) => n.accountId == accountId);
    
    // Clear cache
    _invalidateCache();
    _debouncedNotify();
    
    return true;
  }

  void enterFolder(CloudNode folder) {
    if (!folder.isFolder) return;
    _breadcrumbs.add(folder);
    
    // Check if this folder is already cached (instant navigation)
    final folderId = folder.cloudId ?? folder.id;
    if (_isCacheValid(folderId) && _nodeCache.containsKey(folderId)) {
      _currentNodes = _nodeCache[folderId]!;
      _isLoading = false;
      notifyListeners();
    } else {
      // Need to fetch from API
      loadNodes();
    }
  }

  /// Force refresh - always fetch from API, ignoring cache
  /// Also refreshes storage quotas for all connected accounts
  Future<void> forceRefresh() async {
    
    // Clear cache for current folder to ensure fresh data
    final cacheKey = currentFolderId ?? 'root';
    _invalidateCacheForFolder(cacheKey);
    
    // Show loading state
    _isLoading = true;
    _loadingFolderId = cacheKey;
    _currentNodes = [];
    _debouncedNotify();
    
    
    // Create the request future
    final requestFuture = _loadNodesInternal(cacheKey);
    _pendingRequests[cacheKey] = requestFuture;
    
    try {
      _currentNodes = await requestFuture;
      
      // Cache the results
      _nodeCache[cacheKey] = _currentNodes;
      _cacheTimestamps[cacheKey] = DateTime.now();
      
      
    } catch (e) {
      _currentNodes = [];
    } finally {
      // Remove from pending requests
      _cancelPendingRequest(cacheKey);
      _isLoading = false;
      _loadingFolderId = null;
    }
    
    _debouncedNotify();
    
    // Also refresh storage quotas for all accounts
    await _refreshAllStorageQuotas();
  }

  /// Refresh storage quotas for all connected accounts
  Future<void> _refreshAllStorageQuotas() async {
    
    try {
      final accounts = await HiveStorageService.instance.getAccounts();
      
      // Refresh quota for each account in parallel
      final futures = accounts.map((account) async {
        try {
          await refreshStorageQuota(account.id);
        } catch (e) {
        }
      }).toList();
      
      await Future.wait(futures);
      
    } catch (e) {
    }
  }

  /// Navigate to a specific node (file or folder) from search results
  Future<void> navigateToNode(SearchIndexEntry entry) async {
    
    // Clear current breadcrumbs
    _breadcrumbs.clear();
    
    // Build breadcrumb chain from search index
    final chain = <CloudNode>[];
    String? currentParentId = entry.parentId;
    
    // If it's a file, we want to navigate to its parent folder
    // If it's a folder, we want to navigate inside it
    if (!entry.isFolder) {
      // For files, the target is the parent folder
      if (currentParentId == null) {
        // File is at root of account
        await _navigateToAccountRoot(entry.accountId!);
        return;
      }
    } else {
      // For folders, the target is the folder itself
      currentParentId = entry.nodeId;
    }

    // Build the chain up to the root
    while (currentParentId != null) {
      final parentEntry = await _getSearchEntry(currentParentId);
      if (parentEntry != null) {
        chain.insert(0, _convertEntryToNode(parentEntry));
        currentParentId = parentEntry.parentId;
      } else {
        // Might be the account root node which isn't in search index as a child
        break;
      }
    }

    // Add the account root node to the beginning of the chain
    final allNodes = HiveStorageService.instance.getAllNodes();
    
    CloudNode? rootNode;
    try {
      rootNode = allNodes.firstWhere(
        (node) => node.accountId == entry.accountId && node.parentId == null,
      );
    } catch (e) {
      try {
        rootNode = allNodes.firstWhere(
          (node) => node.accountId == entry.accountId && node.cloudId == 'root',
        );
      } catch (e2) {
        throw Exception("Root folder not found for account");
      }
    }
    
    if (rootNode != null) {
      chain.insert(0, rootNode);
    }

    // Set breadcrumbs and load
    _breadcrumbs = chain;
    await loadNodes();
    
    
    // TODO: Highlight the file if it was a file search
    notifyListeners();
  }

  Future<void> _navigateToAccountRoot(String accountId) async {
    final allNodes = HiveStorageService.instance.getAllNodes();
    
    // Root nodes (mount points) have parentId == null
    CloudNode? rootNode;
    try {
      rootNode = allNodes.firstWhere(
        (node) => node.accountId == accountId && node.parentId == null,
      );
    } catch (e) {
      try {
        rootNode = allNodes.firstWhere(
          (node) => node.accountId == accountId && node.cloudId == 'root',
        );
      } catch (e2) {
        // Log some nodes for debugging
        if (allNodes.isNotEmpty) {
          for (var i = 0; i < min(5, allNodes.length); i++) {
            final n = allNodes[i];
          }
        }
        throw Exception("Root folder not found for account $accountId");
      }
    }
    
    _breadcrumbs = [rootNode];
    await loadNodes();
    notifyListeners();
  }

  Future<SearchIndexEntry?> _getSearchEntry(String nodeId) async {
    final box = await Hive.openBox<SearchIndexEntry>('search_index');
    return box.get(nodeId);
  }

  CloudNode _convertEntryToNode(SearchIndexEntry entry) {
    return CloudNode(
      id: entry.nodeId,
      parentId: entry.parentId,
      cloudId: entry.cloudId,
      accountId: entry.accountId,
      name: entry.nodeName,
      isFolder: entry.isFolder,
      provider: entry.provider,
      updatedAt: DateTime.now(),
      sourceAccountId: entry.sourceAccountId,
    );
  }

  void goBack() {
    if (_breadcrumbs.isNotEmpty) {
      _breadcrumbs.removeLast();
      loadNodes();
    }
  }

  /// Clear all breadcrumbs and return to home (root) state
  /// Used when creating a new tab to ensure it starts fresh
  void clearBreadcrumbs() {
    _breadcrumbs.clear();
    notifyListeners();
  }

  /// Set breadcrumbs to a specific list (used for tab switching)
  void setBreadcrumbs(List<CloudNode> newBreadcrumbs) {
    _breadcrumbs = List.from(newBreadcrumbs);
    loadNodes();
    notifyListeners();
  }

  bool _vaultMode = false;
  bool get isVaultMode => _vaultMode;
  Future<bool> get hasVaultConfigured => SecurityService.instance.hasVault();
  void toggleVault(bool enable) {
    _vaultMode = enable;
    notifyListeners();
  }

  /// Check if encryption should be enabled for a specific account
  /// Returns true if the account has encryption enabled (per-drive setting)
  Future<bool> shouldEncryptForAccount(String? accountId) async {
    
    if (accountId == null) {
      return false;
    }
    
    final account = await HiveStorageService.instance.getAccount(accountId);
    final encryptUploads = account?.encryptUploads ?? false;
    return encryptUploads;
  }

  /// Set encryption enabled/disabled for a specific account
  /// Updates the encryptUploads field in the account and saves to Hive
  Future<void> setAccountEncryption(String accountId, bool enabled) async {
    
    final account = await HiveStorageService.instance.getAccount(accountId);
    if (account == null) {
      return;
    }
    
    // Use updateAccountEncryption which properly preserves orderIndex
    await HiveStorageService.instance.updateAccountEncryption(accountId, enabled);
    
    // Notify listeners so UI updates
    notifyListeners();
  }

  // --- CLIPBOARD STATE (Simplified for Rust-based operations) ---
  CloudNode? _clipboardNode;
  List<CloudNode> _clipboardNodes = [];
  CloudNode? get clipboardNode => _clipboardNode;
  List<CloudNode> get clipboardNodes => _clipboardNodes;

  bool hasClipboardContent() {
    return _clipboardNode != null || _clipboardNodes.isNotEmpty;
  }

  void copyNode(CloudNode node) {
    _clipboardNode = node;
    _clipboardNodes = [node];
    _debouncedNotify();
  }

  void copyNodes(List<CloudNode> nodes) {
    _clipboardNode = null;
    _clipboardNodes = List.from(nodes);
    _debouncedNotify();
  }

  void clearClipboard() {
    _clipboardNode = null;
    _clipboardNodes = [];
    _debouncedNotify();
  }

  // --- PASTE LOGIC (Delegated to Rust-based services) ---
  Future<void> pasteNode() async {
    
    if (!hasClipboardContent()) {
      return;
    }
    
    // Check if we're pasting into the same folder
    if (_clipboardNode != null && currentFolderId == _clipboardNode!.parentId) {
      return;
    }
    if (_clipboardNodes.isNotEmpty) {
      bool allInSameFolder = _clipboardNodes.every((node) => node.parentId == currentFolderId);
      if (allInSameFolder) {
        return;
      }
    }
    
    try {
      // Use TaskService's unified copy method for all scenarios
      final currentProvider = currentFolderNode?.provider;
      
      if (currentFolderNode == null || currentFolderNode!.provider == 'local') {
        // Local destination
        await _pasteViaTaskService();
      } else if (currentFolderNode!.provider == 'virtual') {
        // Virtual drive destination
        await _pasteViaTaskService();
      } else {
        // Cloud drive destination
        await _pasteViaTaskService();
      }
      
      clearClipboard();

    } catch (e) {
      rethrow;
    }
  }
  
  /// Paste items through TaskService (unified approach)
  Future<void> _pasteViaTaskService() async {
    final destAdapter = _getAdapterForNode(currentFolderNode!);
    if (destAdapter == null) {
      throw Exception("No adapter found for destination");
    }
    
    final destAccountId = currentFolderNode!.accountId;
    final destParentId = currentFolderNode!.cloudId ?? 'root';
    final currentProvider = currentFolderNode!.provider;
    
    // Gather items to copy
    final itemsToCopy = <CloudNode>[];
    if (_clipboardNode != null) {
      itemsToCopy.add(_clipboardNode!);
    } else {
      itemsToCopy.addAll(_clipboardNodes);
    }
    
    // Use TaskService's unified copy method
    await TaskService.instance.copyItemsUnified(
      itemsToCopy,
      destAdapter,
      destParentId,
      destAccountId!,
      currentProvider!,
    );
  }

  /// Resolve duplicate names by adding ' (#)' pattern like Windows
  Future<String> _resolveDuplicateName(String originalName) async {
    if (currentFolderNode == null) return originalName;
    
    // Get existing items in current folder
    List<CloudNode> existingItems = <CloudNode>[];
    if (currentFolderNode!.provider == 'local') {
      existingItems = await HiveStorageService.instance.getChildren(currentFolderId);
    } else if (currentFolderNode!.provider == 'virtual') {
      // For virtual drives, check all linked accounts
      final linkedAccountIds = await HiveStorageService.instance.getLinkedAccounts(currentFolderNode!.id);
      for (final accountId in linkedAccountIds) {
        final adapter = _adapters[accountId];
        if (adapter != null) {
          final result = await adapter.listFolder('root');
          existingItems.addAll(result.nodes);
        }
      }
    } else {
      // For cloud drives, check the current folder
      final adapter = _getAdapterForNode(currentFolderNode!);
      if (adapter != null) {
        final result = await adapter.listFolder(currentFolderNode!.cloudId);
        existingItems.addAll(result.nodes);
      }
    }
    
    return _generateUniqueName(originalName, existingItems);
  }
  
  /// Generate a unique name by adding ' (#)' pattern like Windows
  String _generateUniqueName(String originalName, List<CloudNode> existingItems) {
    // Check for exact match first
    final exactMatch = existingItems.where((item) =>
      item.name.toLowerCase() == originalName.toLowerCase()
    ).toList();
    
    if (exactMatch.isEmpty) {
      // No exact match, return original name
      return originalName;
    }
    
    // Extract base name and extension
    final String baseName;
    final String? extension;
    
    if (originalName.contains('.')) {
      final lastDot = originalName.lastIndexOf('.');
      baseName = originalName.substring(0, lastDot);
      extension = originalName.substring(lastDot + 1); // Extract without the dot
    } else {
      baseName = originalName;
      extension = null;
    }
    
    // Find the highest number in existing duplicates with the same base name
    int highestNumber = 0;
    final pattern = RegExp(r'\((\d+)\)$');
    
    for (final item in existingItems) {
      // Only check items that start with the same base name
      if (item.name.toLowerCase().startsWith(baseName.toLowerCase() + ' (')) {
        final match = pattern.firstMatch(item.name);
        if (match != null) {
          final number = int.parse(match.group(1)!);
          if (number > highestNumber) {
            highestNumber = number;
          }
        }
      }
    }
    
    // Generate new name - extension already includes the dot from original
    final newNumber = highestNumber + 1;
    final newName = extension != null
      ? '$baseName ($newNumber).$extension'
      : '$baseName ($newNumber)';
    
    return newName;
  }
  

  // Create a unified folder that combines multiple accounts
  Future<void> createVirtualDrive(String name, List<String> accountIds) async {
    if (accountIds.isEmpty) return;

    final newVirtualId = const Uuid().v4();

    // 1. Create the Virtual Root Node
    final virtualNode = CloudNode(
      id: newVirtualId,
      parentId: null, // It sits at Root
      name: name,
      isFolder: true,
      provider: 'virtual', // SPECIAL PROVIDER
      updatedAt: DateTime.now(),
      // It doesn't belong to one account, so accountId is null or specific marker
      accountId: null, 
    );

    // 2. Save to Nodes Table
    await HiveStorageService.instance.createNode(virtualNode);
    final virtualAccount = CloudAccount(id: 'virtual', provider: 'virtual', name: 'Virtual Drive', email: 'virtual');
    await SearchService.instance.addEntry(virtualNode, virtualAccount);

    // 3. Save Links
    for (var accId in accountIds) {
      await HiveStorageService.instance.linkAccountToVirtualDrive(newVirtualId, accId);
    }

    await loadNodes();
  }

  Future<List<CloudAccount>> getAvailableAccounts() async {
    return await HiveStorageService.instance.getAccounts();
  }


  // Use singleton instance
  final OneDriveAuthManager _oneDriveAuth = OneDriveAuthManager.instance;

  // ADD THIS METHOD
  Future<void> connectOneDrive() async {
    
    // Sign in and get auth info (returns Map with email, name, credentials)
    final authInfo = await _oneDriveAuth.signIn();
    
    if (authInfo == null) {
      return;
    }
    
    final email = authInfo['email'] as String;
    final name = authInfo['name'] as String;
    final credentials = authInfo['credentials'] as String;


    // Create a new account ID
    final newAccountId = const Uuid().v4();
    
    // Create CloudAccount with credentials
    final newAccount = CloudAccount(
      id: newAccountId,
      provider: 'onedrive',
      name: name,
      email: email,
      credentials: credentials, // Store credentials in the account
    );
    
    // Save account to Hive
    await HiveStorageService.instance.createAccount(newAccount);
    
    // Verify the account was saved with credentials
    final savedAccount = await HiveStorageService.instance.getAccount(newAccountId);
    if (savedAccount?.credentials == null) {
    } else {
    }
    
    // Get access token for this account using stored credentials
    final accessToken = await _oneDriveAuth.getAccessTokenForAccount(newAccountId);
    if (accessToken == null) {
      return;
    }

    // Create and store the adapter
    _adapters[newAccountId] = OneDriveAdapter(newAccountId);

    // Create Root Folder
    final mountPoint = CloudNode(
      id: const Uuid().v4(),
      name: "$email (OneDrive)",
      isFolder: true,
      provider: 'onedrive',
      accountId: newAccountId,
      updatedAt: DateTime.now(),
      cloudId: null, // Root - original behavior
    );
    
    await HiveStorageService.instance.createNode(mountPoint);
    await SearchService.instance.addEntry(mountPoint, newAccount);
    await loadNodes();
    
    
    // Note: RClone service has been removed from project
  }

  // REFACTOR UPLOAD: "Enqueue" instead of "Await"
  Future<void> queueUpload(String filePath, String fileName) async {
    if (currentFolderNode == null) return;
    
    // ... resolve target adapter/account logic ...
    // For virtual drive folders, use sourceAccountId if accountId is null
    String targetAccountId = currentFolderNode!.accountId ?? currentFolderNode!.sourceAccountId!;
    String? targetParentId = currentFolderNode!.cloudId;

    // Create Task
    final task = QueuedTask(
      id: const Uuid().v4(),
      type: TaskType.upload,
      name: fileName,
      accountId: targetAccountId,
      payload: {
        'filePath': filePath,
        'parentId': targetParentId
      }
    );

    // Send to Service
    TaskService.instance.addTask(task);
    
    // Note: We do NOT await here. The UI returns immediately.
  }

  // Get list of virtual drives
  List<CloudNode> getVirtualDrives() {
    return _currentNodes.where((node) => node.provider == 'virtual').toList();
  }

  // Get connected accounts with their details for sidebar display
  Future<List<Map<String, dynamic>>> getConnectedAccountsWithDetails() async {
    final accounts = await HiveStorageService.instance.getAccounts();
    final connectedAccounts = <Map<String, dynamic>>[];
    
    for (final account in accounts) {
      final accountInfo = {
        'id': account.id,
        'name': account.name ?? 'Unknown',
        'email': account.email ?? 'No email',
        'provider': account.provider,
        'providerName': _getProviderDisplayName(account.provider),
        'icon': _getProviderIcon(account.provider),
        'color': _getProviderColor(account.provider),
      };
      connectedAccounts.add(accountInfo);
    }
    
    return connectedAccounts;
  }

  String _getProviderDisplayName(String provider) {
    switch (provider) {
      case 'gdrive':
        return 'Google Drive';
      case 'onedrive':
        return 'OneDrive';
      case 'dropbox':
        return 'Dropbox';
      case 'local':
        return 'Local Storage';
      case 'virtual':
        return 'Virtual Drive';
      default:
        return provider;
    }
  }

  IconData _getProviderIcon(String provider) {
    switch (provider) {
      case 'gdrive':
        return Icons.add_to_drive;
      case 'onedrive':
        return Icons.cloud;
      case 'dropbox':
        return Icons.folder;
      case 'local':
        return Icons.computer;
      case 'virtual':
        return Icons.storage;
      default:
        return Icons.cloud;
    }
  }

  Color _getProviderColor(String provider) {
    switch (provider) {
      case 'gdrive':
        return Colors.green;
      case 'onedrive':
        return Colors.blue;
      case 'dropbox':
        return Colors.blue.shade800;
      case 'local':
        return Colors.amber;
      case 'virtual':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  // --- FOLDER UPLOAD FUNCTIONALITY ---
  
  /// Upload a folder with a specific path (for UI integration)
  Future<void> uploadFolderWithContext(BuildContext context) async {
    if (currentFolderNode == null) {
      throw Exception("No current folder selected");
    }
    
    // Pick folder using the folder picker utility
    final folderPath = await FolderPicker.pickDirectory(context);
    if (folderPath == null) {
      return; // User cancelled
    }
    
    await uploadFolderWithPath(folderPath);
  }
  
  /// Upload folder with a specific path
  Future<String> uploadFolderWithPath(String folderPath) async {
    if (currentFolderNode == null) {
      throw Exception("No current folder selected");
    }
    
    // Determine target adapter and account first
    ICloudAdapter? targetAdapter;
    String? targetAccountId;
    String? targetParentId;
    
    if (currentFolderNode!.provider == 'virtual') {
      // For virtual drives, use the first available account
      final linkedAccountIds = await HiveStorageService.instance.getLinkedAccounts(currentFolderNode!.id);
      if (linkedAccountIds.isEmpty) {
        throw Exception("No accounts linked to virtual drive");
      }
      targetAccountId = linkedAccountIds.first;
      targetAdapter = _adapters[targetAccountId];
      targetParentId = 'root';
    } else {
      // For regular cloud drives
      targetAdapter = _getAdapterForNode(currentFolderNode!);
      // FIX: Use sourceAccountId as fallback for virtual drive subfolders
      targetAccountId = currentFolderNode!.accountId ?? currentFolderNode!.sourceAccountId;
      targetParentId = currentFolderNode!.cloudId ?? 'root';
    }
    
    if (targetAdapter == null) {
      throw Exception("No adapter found for upload");
    }
    
    // FIX: Ensure targetAccountId is not null
    if (targetAccountId == null) {
      throw Exception("Cannot determine account ID for upload. Current folder: ${currentFolderNode!.name}");
    }
    
    // --- STORAGE CHECK FOR FOLDER ---
    // Use Rust scanner to get folder size efficiently
    int totalSize = 0;
    int fileCount = 0;
    int folderCount = 0;
    
    try {
      // Use Rust scanner for fast folder scanning
      final scanResult = await RustFolderScanner.scanFolderQuick(folderPath);
      totalSize = scanResult.totalSize;
      fileCount = scanResult.fileCount;
      folderCount = scanResult.folderCount;
      
      
      if (fileCount == 0) {
        throw Exception("Folder is empty");
      }
    } catch (e) {
      // Fallback to Dart scanner
      final folderInfo = await FolderPicker.getFolderInfo(folderPath);
      if (folderInfo.fileCount == 0) {
        throw Exception("Folder is empty");
      }
      totalSize = folderInfo.totalSize;
      fileCount = folderInfo.fileCount;
      folderCount = folderInfo.folderCount;
    }
    
    // Check if there's enough storage space for the entire folder
    final storageCheck = await checkStorageForUpload(targetAccountId!, totalSize);
    
    if (!storageCheck.canUpload) {
      throw Exception("Insufficient storage space to upload folder. Required: ${_formatBytes(totalSize)}, Available: ${storageCheck.quota?.remainingFormatted ?? 'unknown'}");
    }
    
    
    // DEBUG: Log current folder details
    
    // DEBUG: Log target details
    
    // Get folder name from the path
    final folderName = folderPath.split(Platform.pathSeparator).last;
    
    // Create a task for folder upload
    // TaskService will handle the entire upload process including progress tracking
    final task = QueuedTask(
      id: const Uuid().v4(),
      type: TaskType.uploadFolder,
      name: folderName,
      accountId: targetAccountId!,
      status: TaskStatus.pending,
      progress: 0.0,
      payload: {
        'folderPath': folderPath,
        'parentFolderId': targetParentId,
        'accountId': targetAccountId,
        'provider': currentFolderNode!.provider,
        'fileCount': fileCount,
        'folderCount': folderCount,
        'totalSize': totalSize,
      },
    );
    
    // Add task to TaskService - this will trigger the active task widget
    // TaskService will automatically process the task through _executeUploadFolder
    TaskService.instance.addTask(task);
    
    // Return the task ID for tracking
    return task.id;
  }

  // --- STORAGE QUOTA ---

  /// Cache for storage quotas per account (30 minute expiry)
  final Map<String, StorageQuota> _quotaCache = {};
  final Map<String, DateTime> _quotaCacheTimestamps = {};
  static const Duration _quotaCacheDuration = Duration(minutes: 30);

  /// Get storage quota for a specific account
  /// Uses cached data if available and not expired
  Future<StorageQuota?> getStorageQuotaForAccount(String accountId) async {
    // Check cache first
    final cachedTimestamp = _quotaCacheTimestamps[accountId];
    if (cachedTimestamp != null) {
      final age = DateTime.now().difference(cachedTimestamp);
      if (age < _quotaCacheDuration && _quotaCache.containsKey(accountId)) {
        return _quotaCache[accountId];
      }
    }

    // Get adapter for account
    final adapter = _adapters[accountId];
    if (adapter == null) {
      return null;
    }

    
    try {
      final quota = await adapter.getStorageQuota();
      if (quota != null) {
        _quotaCache[accountId] = quota;
        _quotaCacheTimestamps[accountId] = DateTime.now();
        // Notify listeners so StorageBar widgets rebuild with new data
        notifyListeners();
      }
      return quota;
    } catch (e) {
      return null;
    }
  }

  /// Force refresh storage quota for a specific account
  /// Clears cache and fetches fresh data from API
  Future<StorageQuota?> refreshStorageQuota(String accountId) async {
    
    // Clear cache for this account
    _quotaCache.remove(accountId);
    _quotaCacheTimestamps.remove(accountId);
    
    // Get adapter for account
    final adapter = _adapters[accountId];
    if (adapter == null) {
      return null;
    }
    
    try {
      final quota = await adapter.getStorageQuota();
      if (quota != null) {
        _quotaCache[accountId] = quota;
        _quotaCacheTimestamps[accountId] = DateTime.now();
        // Notify listeners so StorageBar widgets rebuild with new data
        notifyListeners();
      }
      return quota;
    } catch (e) {
      return null;
    }
  }
  
  /// Check if a file of the given size can fit in the account's storage.
    /// Returns a StorageCheckResult with the check status and quota info.
    ///
    /// [accountId] The account ID to check storage for.
    /// [fileSizeBytes] The size of the file in bytes.
    /// [refreshQuota] If true, force-refresh the quota from API before checking.
    Future<StorageCheckResult> checkStorageForUpload(
      String accountId,
      int fileSizeBytes,
      {bool refreshQuota = false}
    ) async {
      
      // Get the adapter for this account
      final adapter = _adapters[accountId];
      if (adapter == null) {
        return StorageCheckResult(
          canUpload: false,
          error: StorageCheckError.noAdapter,
          quota: null,
          fileSizeBytes: fileSizeBytes,
        );
      }
  
      // Get storage quota (optionally refresh from API)
      StorageQuota? quota;
      if (refreshQuota) {
        quota = await refreshStorageQuota(accountId);
      } else {
        quota = await getStorageQuotaForAccount(accountId);
      }
  
      if (quota == null) {
        return StorageCheckResult(
          canUpload: false,
          error: StorageCheckError.quotaFetchFailed,
          quota: null,
          fileSizeBytes: fileSizeBytes,
        );
      }
  
      
      // Check if file can fit (with 1MB buffer for metadata overhead)
      final bufferBytes = 1024 * 1024;
      final canFit = quota.canFit(fileSizeBytes, bufferBytes: bufferBytes);
      
      if (canFit) {
        return StorageCheckResult(
          canUpload: true,
          error: StorageCheckError.none,
          quota: quota,
          fileSizeBytes: fileSizeBytes,
        );
      } else {
        return StorageCheckResult(
          canUpload: false,
          error: StorageCheckError.insufficientStorage,
          quota: quota,
          fileSizeBytes: fileSizeBytes,
        );
      }
    }
   
  /// Get storage quotas for all connected accounts
  Future<Map<String, StorageQuota?>> getAllStorageQuotas() async {
    final accounts = await HiveStorageService.instance.getAccounts();
    final Map<String, StorageQuota?> quotas = {};
    
    // Fetch quotas for all accounts in parallel
    final futures = accounts.map((account) async {
      final quota = await getStorageQuotaForAccount(account.id);
      quotas[account.id] = quota;
    }).toList();
    
    await Future.wait(futures);
    return quotas;
  }

  /// Clear all quota caches
  void clearQuotaCache() {
    _quotaCache.clear();
    _quotaCacheTimestamps.clear();
  }

  /// Get cached storage quota synchronously (returns null if not cached)
  StorageQuota? getStorageQuotaForAccountSync(String accountId) {
    final cachedTimestamp = _quotaCacheTimestamps[accountId];
    if (cachedTimestamp != null) {
      final age = DateTime.now().difference(cachedTimestamp);
      if (age < _quotaCacheDuration && _quotaCache.containsKey(accountId)) {
        return _quotaCache[accountId];
      }
    }
    return null;
  }

  // --- VIRTUAL RAID UPLOAD ---

  /// Get the current upload strategy for Virtual RAID drives
  Future<VirtualRaidUploadStrategy> getUploadStrategy() async {
    return await HiveStorageService.instance.getUploadStrategy();
  }

  /// Select the drive with the most free storage for Virtual RAID upload
  /// Returns the account ID of the drive with most available space, or null if no drive has space
  Future<String?> selectDriveWithMostFreeStorage(
    int fileSizeBytes,
    String virtualDriveId
  ) async {
    
    // Get all linked accounts with storage info
    final drives = await _getLinkedAccountsWithStorage(virtualDriveId);
    
    if (drives.isEmpty) {
      return null;
    }
    
    // Sort drives by remaining bytes (descending)
    drives.sort((a, b) => b.remainingBytes.compareTo(a.remainingBytes));
    
    // Check if the drive with most space can fit the file
    final bestDrive = drives.first;
    
    if (bestDrive.canFit(fileSizeBytes)) {
      return bestDrive.accountId;
    } else {
      return null;
    }
  }

  /// Select the drive with the lowest full percentage for Virtual RAID upload
  /// Tries drives in order from least full to most full, returning the first that can fit
  /// Returns the account ID of a suitable drive, or null if no drive has space
  Future<String?> selectDriveWithLowestFullPercentage(
    int fileSizeBytes,
    String virtualDriveId
  ) async {
    
    // Get all linked accounts with storage info
    final drives = await _getLinkedAccountsWithStorage(virtualDriveId);
    
    if (drives.isEmpty) {
      return null;
    }
    
    // Sort drives by usage percentage (ascending)
    drives.sort((a, b) => a.usagePercentage.compareTo(b.usagePercentage));
    
    // Try each drive in order, starting with least full
    for (final drive in drives) {
      
      if (drive.canFit(fileSizeBytes)) {
        return drive.accountId;
      } else {
      }
    }
    
    return null;
  }

  /// Get all linked accounts with their storage info for Virtual RAID
  Future<List<DriveUploadInfo>> _getLinkedAccountsWithStorage(String virtualDriveId) async {
    final linkedAccountIds = await HiveStorageService.instance.getLinkedAccounts(virtualDriveId);
    final drives = <DriveUploadInfo>[];

    for (final accountId in linkedAccountIds) {
      final account = await HiveStorageService.instance.getAccount(accountId);
      if (account == null) continue;

      final quota = await getStorageQuotaForAccount(accountId);
      
      drives.add(DriveUploadInfo(
        accountId: accountId,
        accountName: account.name ?? 'Unknown',
        provider: account.provider,
        usedBytes: quota?.usedBytes ?? 0,
        totalBytes: quota?.totalBytes ?? 0,
        remainingBytes: quota?.effectiveRemainingBytes ?? 0,
      ));
    }

    return drives;
  }

  /// Validate selected drives for Virtual RAID upload
  /// Returns a DriveSelectionResult with validated account IDs or error message
  Future<DriveSelectionResult> validateSelectedDrives({
    required String virtualDriveId,
    required int fileSizeBytes,
    required List<String> selectedDrives,
  }) async {

    // Get all linked accounts with their storage info
    final drives = await _getLinkedAccountsWithStorage(virtualDriveId);
    
    if (drives.isEmpty) {
      return DriveSelectionResult(
        selectedAccountIds: [],
        errorMessage: 'No accounts linked to this virtual drive',
      );
    }

    if (selectedDrives.isEmpty) {
      return DriveSelectionResult(
        selectedAccountIds: [],
        errorMessage: 'No drives selected for upload',
      );
    }

    final validated = <String>[];
    final insufficientIds = <String>[];
    final insufficientNames = <String>[];

    for (final drive in drives) {
      if (selectedDrives.contains(drive.accountId)) {
        if (drive.canFit(fileSizeBytes)) {
          validated.add(drive.accountId);
        } else {
          insufficientIds.add(drive.accountId);
          insufficientNames.add('${drive.accountName} (${drive.provider}) - ${_formatBytes(drive.remainingBytes)} remaining');
        }
      }
    }

    if (insufficientIds.isNotEmpty) {
      return DriveSelectionResult(
        selectedAccountIds: [],
        insufficientStorageIds: insufficientIds,
        insufficientStorageNames: insufficientNames,
        errorMessage: 'Upload cancelled: ${insufficientIds.length} drive(s) have insufficient storage. '
            'Please deselect these drives or free up storage space.',
      );
    }

    return DriveSelectionResult(selectedAccountIds: validated);
  }

  /// Set the sort option and sort the current nodes
  /// If the same option is selected, toggle between ascending and descending
  void setSortOption(SortOption option, {bool? ascending}) {
    if (option == _currentSortOption && ascending == null) {
      // Toggle ascending/descending if same option is selected
      _sortAscending = !_sortAscending;
    } else {
      // Set new option
      _currentSortOption = option;
      if (ascending != null) {
        _sortAscending = ascending;
      }
    }
    
    _sortCurrentNodes();
    notifyListeners();
  }

  /// Sort the current nodes based on the current sort option
  void _sortCurrentNodes() {
    switch (_currentSortOption) {
      case SortOption.name:
        _currentNodes.sort((a, b) {
          // Folders first, then files
          if (a.isFolder != b.isFolder) {
            return a.isFolder ? -1 : 1;
          }
          // Case-insensitive name comparison
          final comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return _sortAscending ? comparison : -comparison;
        });
        break;
        
      case SortOption.size:
        _currentNodes.sort((a, b) {
          // Folders first, then files by size
          if (a.isFolder != b.isFolder) {
            return a.isFolder ? -1 : 1;
          }
          // Compare by size (folders have size 0)
          final comparison = (a.size ?? 0).compareTo(b.size ?? 0);
          return _sortAscending ? comparison : -comparison;
        });
        break;
        
      case SortOption.dateModified:
        _currentNodes.sort((a, b) {
          // Folders first, then files by date
          if (a.isFolder != b.isFolder) {
            return a.isFolder ? -1 : 1;
          }
          // Compare by updated date
          final comparison = a.updatedAt.compareTo(b.updatedAt);
          return _sortAscending ? comparison : -comparison;
        });
        break;
        
      case SortOption.type:
        _currentNodes.sort((a, b) {
          // Folders first, then files by type (extension)
          if (a.isFolder != b.isFolder) {
            return a.isFolder ? -1 : 1;
          }
          // Compare by file extension
          final aExt = _getFileExtension(a.name);
          final bExt = _getFileExtension(b.name);
          final comparison = aExt.toLowerCase().compareTo(bExt.toLowerCase());
          return _sortAscending ? comparison : -comparison;
        });
        break;
    }
    
  }

  /// Extract file extension from filename
  String _getFileExtension(String filename) {
    final lastDot = filename.lastIndexOf('.');
    if (lastDot == -1 || lastDot == filename.length - 1) {
      return ''; // No extension
    }
    return filename.substring(lastDot + 1);
  }

  // --- ACCOUNT REORDERING ---

  /// Reorder accounts by their IDs
  /// Updates the orderIndex for each account and saves to Hive
  Future<void> reorderAccounts(List<String> accountIds) async {
    try {
      await HiveStorageService.instance.reorderAccounts(accountIds);
      // Notify listeners to update UI
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  /// Get accounts in their current order
  Future<List<CloudAccount>> getAccountsInOrder() async {
    return await HiveStorageService.instance.getAccounts();
  }
  
  /// Refresh profile names for all accounts at startup
  /// Fetches current display name from cloud providers and updates existing accounts
  Future<void> refreshAccountProfileNames() async {
    try {
      final accounts = await HiveStorageService.instance.getAccounts();
      
      for (final account in accounts) {
        String? newDisplayName;
        
        // Get fresh display name based on provider
        if (account.provider == 'gdrive') {
          final authClient = await GoogleAuthManager.instance.getAuthClient(account.id);
          if (authClient == null) continue;
          
          try {
            final driveApi = drive.DriveApi(authClient);
            final about = await driveApi.about.get($fields: "user(emailAddress,displayName)");
            newDisplayName = about.user?.displayName;
          } catch (e) {
            // Keep existing name if fetch fails
          }
        } else if (account.provider == 'onedrive') {
          final accessToken = await OneDriveAuthManager.instance.getAccessTokenForAccount(account.id);
          if (accessToken == null) continue;
          
          try {
            final response = await http.get(
              Uri.parse('https://graph.microsoft.com/v1.0/me?select=displayName'),
              headers: {'Authorization': 'Bearer $accessToken'},
            );
            
            if (response.statusCode == 200) {
              final data = jsonDecode(response.body);
              newDisplayName = data['displayName'];
            }
          } catch (e) {
            // Keep existing name if fetch fails
          }
        }
        
        // Only update if we got a new name and it's different from current
        if (newDisplayName != null && newDisplayName != account.name) {
          final updatedAccount = CloudAccount(
            id: account.id,
            provider: account.provider,
            name: newDisplayName,
            email: account.email,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            tokenExpiry: account.tokenExpiry,
            credentials: account.credentials,
            encryptUploads: account.encryptUploads,
            orderIndex: account.orderIndex,
          );
          
          await HiveStorageService.instance.createAccount(updatedAccount);
        }
      }
      
      // Notify listeners to update UI
      notifyListeners();
    } catch (e) {
      // Silently fail - don't block startup
    }
  }
}