import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/file_system_provider.dart';
import '../providers/selection_provider.dart';
import '../providers/tabs_provider.dart';
import '../models/cloud_node.dart';
import '../models/cloud_account.dart';
import '../models/tab_data.dart';
import '../models/queued_task.dart';
import '../models/virtual_raid_upload_strategy.dart';
import '../services/search_service.dart';
import '../services/task_service.dart';
import '../services/security_service.dart';
import '../services/notification_service.dart';
import '../services/hive_storage_service.dart';
import '../widgets/tab_bar.dart' as tabs_widget;
import '../themes/ubuntu_theme.dart' as theme;
import '../widgets/file_item.dart';
import 'sidebar.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/sync_management_widget.dart';
import '../widgets/task_progress_widget.dart';
import '../widgets/virtual_drive_creation_dialog.dart';
import '../widgets/file_context_menu.dart';
import '../widgets/file_preview_dialog.dart';
import 'address_bar.dart' as address_bar;
import '../widgets/file_list_header.dart';
import '../utils/svg_icon_cache.dart';

class FileExplorer extends StatefulWidget {
  const FileExplorer({Key? key}) : super(key: key);

  @override
  State<FileExplorer> createState() => _FileExplorerState();
}

class _FileExplorerState extends State<FileExplorer>
    with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _slideController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  final FocusNode _focusNode = FocusNode();
  final FocusNode _searchFocusNode = FocusNode();
  final GlobalKey _addressBarKey = GlobalKey();
  final ScrollController _fileListScrollController = ScrollController();
  
  bool _isGridView = false;
  String? _renamingFileId;
  final TextEditingController _renameController = TextEditingController();
  final FocusNode _renameFocusNode = FocusNode();
  int _accountsRefreshKey = 0; // Key to force sidebar rebuild when accounts change
  
  int _maxSearchResults = 50; // Default: 50 results
  bool _showCustomLimitInput = false; // Show custom limit input field
  final TextEditingController _customLimitController = TextEditingController();
  bool _isCustomLimitSelected = false; // Track if custom option is selected

  // Search state is now per-tab (managed by TabsProvider)
  final TextEditingController _searchController = TextEditingController();
  
  // Flag to prevent _restoreFileSystemStateFromTab from interfering during navigation
  bool _isNavigating = false;
  
  // Debounce flag to prevent repeated restore calls
  bool _restorePending = false;
  
  // Track last restored tab index to avoid repeated restores
  int _lastRestoredTabIndex = -1;

  @override
  void initState() {
    super.initState();
    
    _fadeController = AnimationController(
      duration: theme.UbuntuAnimations.medium,
      vsync: this,
    );
    
    _slideController = AnimationController(
      duration: theme.UbuntuAnimations.slow,
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: theme.UbuntuAnimations.smooth,
    ));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: theme.UbuntuAnimations.easeOut,
    ));

    // Start animations
    _fadeController.forward();
    _slideController.forward();
    
    // Setup scroll listener for pagination
    _fileListScrollController.addListener(_onScroll);

    // Initialize file system and load tabs
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final fs = context.read<FileSystemProvider>();
      final tabsProvider = context.read<TabsProvider>();
      
      fs.loadNodes();
      
      // Load saved tabs
      await tabsProvider.loadTabs();
      
      // If no tabs exist, create initial tab
      if (tabsProvider.tabs.isEmpty) {
        tabsProvider.createNewTab();
      }
      
      // Load saved settings
      await _loadSavedSettings();
      
      // Request focus to enable keyboard shortcuts
      _focusNode.requestFocus();
    });
  }
  
  /// Handle scroll events to load more items when near bottom
  void _onScroll() {
    final fs = context.read<FileSystemProvider>();
    
    // Only load more if there are more items to load and not already loading
    if (!fs.hasMore || fs.isLoadingMore) {
      return;
    }
    
    // Calculate how close to bottom (0.0 = at bottom, 1.0 = at top)
    if (_fileListScrollController.position.pixels >=
        _fileListScrollController.position.maxScrollExtent * 0.8) {
      // Load more when scrolled to 80% of content
      fs.loadMoreNodes();
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _slideController.dispose();
    _fileListScrollController.dispose();
    _renameController.dispose();
    _renameFocusNode.dispose();
    _focusNode.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _customLimitController.dispose();
    super.dispose();
  }

  /// Load saved settings from storage
  Future<void> _loadSavedSettings() async {
    try {
      // Load search results limit
      final savedLimit = await HiveStorageService.instance.getSearchResultsLimit();
      final savedCustomSelected = await HiveStorageService.instance.isCustomLimitSelected();
      
      if (mounted) {
        setState(() {
          _maxSearchResults = savedLimit;
          _isCustomLimitSelected = savedCustomSelected;
          SearchService.instance.maxResultsLimit = savedLimit;
        });
      }
      
      // Load task limits
      final taskLimits = await HiveStorageService.instance.getTaskLimits();
      if (taskLimits != null) {
        await TaskService.instance.setTaskLimits(
          maxConcurrentTasks: taskLimits['maxConcurrentTasks']!,
          maxConcurrentTransfersPerAccount: taskLimits['maxConcurrentTransfersPerAccount']!,
          maxConcurrentTransfersSameAccount: taskLimits['maxConcurrentTransfersSameAccount']!,
        );
      }
      
    } catch (e) {
    }
  }

  /// Get the current tab's state
  Map<String, dynamic> _getTabState(TabsProvider tabsProvider) {
    final activeTab = tabsProvider.activeTab;
    if (activeTab == null) {
      return {
        'searchQuery': '',
        'searchScope': SearchScope.global,
        'searchResults': <SearchResult>[],
        'isSearchActive': false,
      };
    }
    return {
      'searchQuery': activeTab.searchQuery,
      'searchScope': activeTab.searchScope,
      'searchResults': activeTab.searchResults,
      'isSearchActive': activeTab.isSearchActive,
    };
  }

  void _handleFileSelection(CloudNode file, bool selected) {
    final selectionProvider = context.read<SelectionProvider>();
    if (selected) {
      selectionProvider.selectFile(file.id);
    } else {
      selectionProvider.deselectFile(file.id);
    }
  }

  void _handleFileTap(CloudNode file, FileSystemProvider fs, TabsProvider tabsProvider, SelectionProvider selectionProvider) {
    if (selectionProvider.areAnySelected == true) {
      // If files are selected, toggle selection for files only
      // For folders, always navigate when tapped (not checkbox)
      if (!file.isFolder) {
        _handleFileSelection(file, !selectionProvider.isSelected(file.id));
      } else {
        // Always navigate to folders, even when files are selected
        selectionProvider.clearSelection();
        _navigateToFolder(fs, tabsProvider, file);
      }
    } else {
      // If no files selected, navigate
      if (file.isFolder) {
        _navigateToFolder(fs, tabsProvider, file);
      }
    }
  }

  /// Navigate to a folder and update the current tab's breadcrumbs
  void _navigateToFolder(FileSystemProvider fs, TabsProvider tabsProvider, CloudNode folder) {
    
    // Clear selection when navigating to a folder
    final selectionProvider = context.read<SelectionProvider>();
    selectionProvider.clearSelection();
    
    // Update the file system provider
    fs.enterFolder(folder);
    
    
    // Update the current tab's breadcrumbs
    tabsProvider.updateActiveTabBreadcrumbs(fs.breadcrumbs);
    tabsProvider.updateActiveTabCurrentFolder(fs.currentFolderNode);
    
  }

  void _handleFileCtrlClick(CloudNode file, SelectionProvider selectionProvider) {
    // Ctrl+Click: Toggle selection without clearing other selections
    if (selectionProvider.isSelected(file.id)) {
      selectionProvider.deselectFile(file.id);
    } else {
      selectionProvider.selectFile(file.id);
    }
    HapticFeedback.lightImpact();
  }

  void _handleFileSecondaryTap(CloudNode file, Offset position, FileSystemProvider fs, SelectionProvider selectionProvider) {
    // Show context menu at tap position
    _showContextMenu(file, position, fs, selectionProvider);
  }

  void _showContextMenu(CloudNode file, Offset position, FileSystemProvider fs, SelectionProvider selectionProvider) {
    final selectedNodes = selectionProvider.selectedCount > 0
        ? fs.currentNodes.where((node) => selectionProvider.isSelected(node.id)).toList()
        : [file];
    
    FileContextMenu.show(
      context: context,
      position: position,
      selectedNodes: selectedNodes,
      fileSystemProvider: fs,
      onPreview: () => _handleContextMenuPreview(selectedNodes.first, fs),
      onCopy: () => _handleContextMenuCopy(selectedNodes, fs),
      onDownload: () => _handleContextMenuDownload(selectedNodes, fs, selectionProvider),
      onRename: selectedNodes.length == 1 ? () => _handleContextMenuRename(selectedNodes.first, fs) : null,
      onDelete: () => _handleContextMenuDelete(selectedNodes, fs, selectionProvider),
    );
  }

  /// Handle preview from context menu
  Future<void> _handleContextMenuPreview(CloudNode file, FileSystemProvider fs) async {
    if (file.isFolder) return;
    
    // Check if vault needs to be unlocked for encrypted files
    final accountId = file.accountId;
    if (accountId != null) {
      final shouldEncrypt = await fs.shouldEncryptForAccount(accountId);
      if (shouldEncrypt && !SecurityService.instance.isUnlocked) {
        final dialogUnlocked = await _showVaultUnlockDialog();
        if (dialogUnlocked != true) return;
      }
    }
    
    final adapter = fs.getAdapterForAccount(
      file.accountId ?? file.sourceAccountId ?? ''
    );
    
    if (adapter == null) {
      _showQuickNotification(
        'Preview Error',
        'No adapter available for this file',
        Icons.error_outline,
        Colors.red,
      );
      return;
    }
    
    showDialog(
      context: context,
      builder: (context) => FilePreviewDialog(
        file: file,
        adapter: adapter!,
      ),
    );
  }

  /// Handle copy from context menu
  void _handleContextMenuCopy(List<CloudNode> nodes, FileSystemProvider fs) {
    HapticFeedback.lightImpact();
    fs.copyNodes(nodes);
    _showQuickNotification(
      'Copied',
      '${nodes.length} item${nodes.length == 1 ? '' : 's'} copied',
      Icons.copy,
      Colors.green,
    );
  }

  /// Handle download from context menu
  Future<void> _handleContextMenuDownload(List<CloudNode> nodes, FileSystemProvider fs, SelectionProvider selectionProvider) async {
    HapticFeedback.lightImpact();
    
    // Set selected files for download
    selectionProvider.selectFiles(nodes.map((node) => node.id).toSet());
    
    // Trigger download
    _handleDownload(fs, selectionProvider);
  }

  /// Handle rename from context menu
  void _handleContextMenuRename(CloudNode node, FileSystemProvider fs) {
    HapticFeedback.lightImpact();
    showDialog(
      context: context,
      builder: (context) => RenameDialog(
        node: node,
        onRename: (newName) async {
          try {
            final adapter = fs.getAdapterForAccount(
              node.accountId ?? node.sourceAccountId ?? ''
            );
             
            if (adapter == null) {
              throw Exception("No adapter available for this file");
            }
             
            await adapter.renameNode(node.cloudId ?? node.id, newName);
            await fs.loadNodes();
             
            if (mounted) {
              _showQuickNotification(
                'Renamed',
                'Successfully renamed to $newName',
                Icons.edit,
                theme.UbuntuColors.orange,
              );
            }
          } catch (e) {
            if (mounted) {
              NotificationService().error(
                '$e',
                title: 'Rename Error',
              );
            }
          }
        },
      ),
    );
  }

  /// Handle delete from context menu
  Future<void> _handleContextMenuDelete(List<CloudNode> nodes, FileSystemProvider fs, SelectionProvider selectionProvider) async {
    HapticFeedback.lightImpact();
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${nodes.length} item${nodes.length == 1 ? '' : 's'}?'),
        content: Text('Are you sure you want to delete the selected item${nodes.length == 1 ? '' : 's'}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      int successfullyDeleted = 0;
      bool hasAccountInVirtualRaid = false;
      
      for (final node in nodes) {
        try {
          // Check if this is an account root folder
          if (_isAccountNode(node)) {
            final success = await fs.deleteAccount(node);
            if (success) {
              successfullyDeleted++;
            } else {
              // Account is part of a Virtual RAID - get the list of Virtual RAID drives
              final linkedDrives = await HiveStorageService.instance.getVirtualDrivesForAccount(node.accountId!);
              if (mounted) {
                _showVirtualRaidWarningNotification(node, linkedDrives);
                hasAccountInVirtualRaid = true;
              }
            }
          } else {
            await fs.deleteNode(node);
            successfullyDeleted++;
          }
        } catch (e) {
        }
      }
      
      if (mounted) {
        selectionProvider.clearSelection();
        // Only show success notification if items were actually deleted
        // and no account was blocked due to Virtual RAID
        if (successfullyDeleted > 0 && !hasAccountInVirtualRaid) {
          _showQuickNotification(
            'Deleted',
            '$successfullyDeleted item${successfullyDeleted == 1 ? '' : 's'} deleted',
            Icons.delete,
            Colors.red,
          );
        }
      }
    }
  }

  void _toggleViewMode() {
    setState(() {
      _isGridView = !_isGridView;
    });
    HapticFeedback.lightImpact();
  }

  void _startRenaming(CloudNode file) {
    setState(() {
      _renamingFileId = file.id;
      _renameController.text = file.name;
    });
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renameFocusNode.requestFocus();
      _renameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: file.name.lastIndexOf('.'),
      );
    });
  }

  void _finishRenaming() {
    if (_renamingFileId != null && _renameController.text.isNotEmpty) {
    }
    
    setState(() {
      _renamingFileId = null;
    });
    _renameFocusNode.unfocus();
  }

  void _cancelRenaming() {
    setState(() {
      _renamingFileId = null;
    });
    _renameFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer3<FileSystemProvider, TabsProvider, SelectionProvider>(
      builder: (context, fs, tabsProvider, selectionProvider, child) {
        // Get current tab's search state
        final tabState = _getTabState(tabsProvider);
        final _isSearchActive = tabState['isSearchActive'] as bool;
        final _searchQuery = tabState['searchQuery'] as String;
        final _searchScope = tabState['searchScope'] as SearchScope;
        final _searchResults = tabState['searchResults'] as List<SearchResult>;

        // Get current tab's breadcrumbs if available
        final currentTab = tabsProvider.activeTab;
        final breadcrumbs = currentTab?.breadcrumbs ?? fs.breadcrumbs;
        final currentFolder = currentTab?.currentFolder ?? fs.currentFolderNode;

        // Restore file system state from tab's breadcrumbs if they don't match
        // Only run once per tab change, not on every rebuild
        if (!_restorePending && tabsProvider.activeTabIndex != _lastRestoredTabIndex) {
          _restorePending = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _restoreFileSystemStateFromTab(fs, tabsProvider);
            _lastRestoredTabIndex = tabsProvider.activeTabIndex;
            _restorePending = false;
          });
        }

        return Stack(
          children: [
            // Main content with drag and drop support
            DropTarget(
              onDragEntered: (details) {
              },
              onDragExited: (details) {
              },
              onDragDone: (details) async {
                await _handleDroppedItems(details.files, fs);
              },
              child: Scaffold(
                backgroundColor: theme.UbuntuColors.veryLightGrey,
                body: Column(
                  children: [
                    // TAB BAR - Browser-style tabs
                    tabs_widget.TabBar(
                      tabs: tabsProvider.tabs,
                      activeTabIndex: tabsProvider.activeTabIndex,
                      onTabTap: (index) {
                        final oldTabIndex = tabsProvider.activeTabIndex;
                        if (index == -1) {
                          // -1 means create new tab
                          // IMPORTANT: Reset file system to home for the new tab
                          // This ensures the new tab starts fresh instead of showing the previous tab's location
                          selectionProvider.clearSelection();
                          fs.clearBreadcrumbs();
                          fs.loadNodes();
                          
                          tabsProvider.createNewTab();
                        } else {
                          // Switch to the tab first
                          tabsProvider.switchToTab(index);
                          // Clear selection when switching tabs (per-tab selection model)
                          selectionProvider.clearSelection();
                          final newTab = tabsProvider.tabs[index];
                          
                          // IMMEDIATELY restore file system state to match this tab's state
                          // This prevents any race conditions with the delayed _restoreFileSystemStateFromTab
                          if (newTab.breadcrumbs.isEmpty) {
                            // New tab - reset to home
                            fs.clearBreadcrumbs();
                            fs.loadNodes();
                          } else {
                            // Restore to tab's saved breadcrumbs FIRST
                            // Then set currentFolder to match the last breadcrumb
                            fs.setBreadcrumbs(newTab.breadcrumbs);
                            
                            // Also ensure currentFolder matches the last breadcrumb
                            // This fixes inconsistency between breadcrumbs and currentFolder
                            if (newTab.currentFolder != null &&
                                (fs.currentFolderNode == null || fs.currentFolderNode!.id != newTab.currentFolder!.id)) {
                              // Force update currentFolder to match
                              tabsProvider.updateActiveTabCurrentFolder(newTab.currentFolder);
                            }
                          }
                        }
                      },
                      onTabClose: (index) => tabsProvider.closeTab(index),
                    ),

                    // Combined Top Bar (Title + Toolbar + Actions + Breadcrumb)
                    Container(
                      decoration: BoxDecoration(
                        color: theme.UbuntuColors.white,
                        border: Border(
                          bottom: BorderSide(color: theme.UbuntuColors.lightGrey, width: 1),
                        ),
                      ),
                      child: Column(
                        children: [
                            // Minimal Address Bar (new lightweight implementation)
                              address_bar.AddressBarContainer(
                                fileSystemProvider: fs,
                                tabsProvider: tabsProvider,
                                onSyncManagement: _showSyncManagement,
                                onSettings: () => _showSettingsDialog(fs),
                              ),
                        ],
                      ),
                    ),
                      
                    // Breadcrumb - uses tab-specific breadcrumbs
                    theme.UbuntuBreadcrumbNav(
                      breadcrumbs: breadcrumbs,
                      currentFolder: currentFolder,
                      onNavigate: (folder) => _navigateToFolder(fs, tabsProvider, folder),
                      onNavigateToFolder: (folder) {
                        _navigateToBreadcrumbFolder(fs, tabsProvider, folder);
                      },
                      onHomeClicked: () {
                        _goHome(fs, tabsProvider);
                      },
                    ),
                      
                    // Main content
                    Expanded(
                      child: SlideTransition(
                        position: _slideAnimation,
                        child: FadeTransition(
                          opacity: _fadeAnimation,
                          child: Focus(
                            focusNode: _focusNode,
                            autofocus: true,
                            onKeyEvent: (node, event) => _handleKeyEvent(event, fs, tabsProvider, selectionProvider),
                            child: Row(
                              children: [
                                // Sidebar
                                _buildSidebar(fs, tabsProvider, selectionProvider),
                                  
                                // File list
                                Expanded(
                                  child: _buildFileList(fs, tabsProvider, selectionProvider),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                      
                    // Status bar
                    _buildStatusBar(fs, selectionProvider),
                  ],
                ),
              ),
            ),
              
            // Floating Task Progress Widget (independent of UI layout)
            // OPTIMIZATION: TaskProgressWidget uses AnimatedBuilder internally to listen to TaskService.instance
            const Positioned(
              bottom: 24,
              right: 24,
              child: TaskProgressWidget(),
            ),
            // Search dropdown is now built directly in MinimalAddressBarContainer
          ],
        );
      },
    );
  }

  /// Go back and update the current tab's breadcrumbs
  void _goBack(FileSystemProvider fs, TabsProvider tabsProvider) {
    if (fs.breadcrumbs.isEmpty) return;
    
    // Clear selection when going back
    final selectionProvider = context.read<SelectionProvider>();
    selectionProvider.clearSelection();
    
    fs.goBack();
    tabsProvider.updateActiveTabBreadcrumbs(fs.breadcrumbs);
    tabsProvider.updateActiveTabCurrentFolder(fs.currentFolderNode);
  }

  /// Navigate home and update the current tab's breadcrumbs
  void _goHome(FileSystemProvider fs, TabsProvider tabsProvider) {
    // Clear selection when going home
    final selectionProvider = context.read<SelectionProvider>();
    selectionProvider.clearSelection();
    
    while (fs.breadcrumbs.isNotEmpty) {
      fs.goBack();
    }
    tabsProvider.updateActiveTabBreadcrumbs(fs.breadcrumbs);
    tabsProvider.updateActiveTabCurrentFolder(fs.currentFolderNode);
  }

  /// Navigate to a breadcrumb folder and update the current tab
  void _navigateToBreadcrumbFolder(FileSystemProvider fs, TabsProvider tabsProvider, CloudNode targetFolder) {
    // Clear selection when navigating via breadcrumbs
    final selectionProvider = context.read<SelectionProvider>();
    selectionProvider.clearSelection();
    
    // Find the index of the target folder in the current breadcrumbs
    final targetIndex = fs.breadcrumbs.indexWhere((folder) => folder.id == targetFolder.id);
    
    if (targetIndex == -1) {
      return;
    }
    
    // Go back until we reach the target folder
    final stepsBack = fs.breadcrumbs.length - targetIndex - 1;
    
    for (int i = 0; i < stepsBack; i++) {
      if (fs.breadcrumbs.isNotEmpty) {
        fs.goBack();
      }
    }
    
    // Update the current tab's breadcrumbs
    tabsProvider.updateActiveTabBreadcrumbs(fs.breadcrumbs);
    tabsProvider.updateActiveTabCurrentFolder(fs.currentFolderNode);
  }

  /// Restore file system state from the current tab's breadcrumbs
  void _restoreFileSystemStateFromTab(FileSystemProvider fs, TabsProvider tabsProvider) {
    // Skip restoration during navigation to avoid race conditions
    if (_isNavigating) {
      return;
    }
    
    final currentTab = tabsProvider.activeTab;
    if (currentTab == null) return;

    final tabBreadcrumbs = currentTab.breadcrumbs;
    final fsBreadcrumbs = fs.breadcrumbs;

    // Handle empty breadcrumbs case - this is normal for home tab, no need to spam logs
    if (tabBreadcrumbs.isEmpty) {
      // Already at home, no action needed
      return;
    }
    
    // If tab has breadcrumbs but FS doesn't match, restore from tab's breadcrumbs
    // This handles the case where tab was saved with a location but FS is showing a different location
    // (e.g., after a search result navigation, FS is at one location but tab wasn't updated yet)

    // Check if file system state matches tab state
    if (tabBreadcrumbs.length == fsBreadcrumbs.length) {
      bool matches = true;
      for (int i = 0; i < tabBreadcrumbs.length; i++) {
        if (tabBreadcrumbs[i].id != fsBreadcrumbs[i].id) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return; // Already in sync
      }
    }

    // Restore file system state from tab's breadcrumbs
    
    // Use setBreadcrumbs to atomically replace breadcrumbs (fixes cross-account switching)
    fs.setBreadcrumbs(tabBreadcrumbs);

  }

  Future<void> _handleSearch(String query, FileSystemProvider fs, TabsProvider tabsProvider) async {
    final currentTab = tabsProvider.activeTab;
    final searchScope = currentTab?.searchScope ?? SearchScope.global;
    
    try {
      final results = await SearchService.instance.search(
        query: query,
        scope: searchScope,
        currentFolderId: fs.currentFolderId,
        currentAccountId: fs.currentFolderNode?.accountId,
      );

      // Update the current tab's search state
      tabsProvider.updateActiveTabSearch(
        query,
        searchScope,
        results,
        true,
      );
    } catch (e) {
    }
  }

  /// Handle dropped files and folders
  Future<void> _handleDroppedItems(List<XFile> droppedFiles, FileSystemProvider fs) async {
    if (droppedFiles.isEmpty) {
      return;
    }


    // Separate files and folders
    final List<XFile> files = [];
    final List<XFile> folders = [];

    for (final file in droppedFiles) {
      final path = file.path;
      if (await Directory(path).exists()) {
        folders.add(file);
      } else {
        files.add(file);
      }
    }

    // Show upload started notification immediately
    if (mounted) {
      final totalItems = folders.length + files.length;
      _showQuickNotification(
        'Upload Started',
        'Uploading $totalItems item${totalItems == 1 ? '' : 's'}',
        Icons.cloud_upload,
        Colors.green,
      );
    }

    // Handle folders first
    if (folders.isNotEmpty) {
      for (final folder in folders) {
        try {
          await _handleDroppedFolder(folder.path, fs);
        } catch (e) {
          if (mounted) {
            _showQuickNotification(
              'Upload Error',
              'Failed to upload folder ${folder.name}: $e',
              Icons.error,
              Colors.red,
            );
          }
        }
      }
    }

    // Handle files
    if (files.isNotEmpty) {
      try {
        await _handleDroppedFiles(files, fs);
      } catch (e) {
        if (mounted) {
          _showQuickNotification(
            'Upload Error',
            'Failed to upload files: $e',
            Icons.error,
            Colors.red,
          );
        }
      }
    }
  }

  /// Handle a dropped folder
  Future<void> _handleDroppedFolder(String folderPath, FileSystemProvider fs) async {

    if (fs.currentFolderNode == null) {
      throw Exception("No current folder selected");
    }

    final folderName = folderPath.split(Platform.pathSeparator).last;

    final task = QueuedTask(
      id: const Uuid().v4(),
      type: TaskType.uploadFolder,
      name: folderName,
      accountId: fs.currentFolderNode!.accountId,
      status: TaskStatus.pending,
      progress: 0.0,
      payload: {
        'folderPath': folderPath,
        'parentFolderId': fs.currentFolderNode!.cloudId ?? 'root',
        'accountId': fs.currentFolderNode!.accountId,
        'provider': fs.currentFolderNode!.provider,
      },
    );

    TaskService.instance.addTask(task);
  }

  /// Handle dropped files
  Future<void> _handleDroppedFiles(List<XFile> files, FileSystemProvider fs) async {

    if (fs.currentFolderNode == null) {
      throw Exception("No current folder selected");
    }

    final filePaths = files.map((file) => file.path).toList();
    final fileNames = files.map((file) => file.name).toList();

    if (fs.currentFolderNode!.provider == 'virtual') {
      await _handleVirtualRaidDroppedFiles(filePaths, fileNames, fs);
    } else {
      await fs.uploadMultipleFilesToRegularDrive(filePaths, fileNames);
    }
  }

  /// Handle dropped files for Virtual RAID with drive selection (Manual Only)
  Future<void> _handleVirtualRaidDroppedFiles(
    List<String> filePaths,
    List<String> fileNames,
    FileSystemProvider fs,
  ) async {

    final accountDetails = await fs.getVirtualDriveAccountDetails();

    if (accountDetails.isEmpty) {
      throw Exception("No accounts available in this virtual drive");
    }

    // Manual strategy: show drive selection dialog
    final dialogTitle = filePaths.length == 1
        ? "Upload '${fileNames.first}' to drives"
        : "Upload ${filePaths.length} files to drives";

    final selectedAccountIds = (await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => VirtualDriveSelectionDialog(
        accountDetails: accountDetails,
        folderName: fileNames.first,
        customTitle: dialogTitle,
      ),
    )) ?? [];
    
    if (selectedAccountIds.isEmpty) {
      if (mounted) {
        NotificationService().warning(
          'File upload was cancelled',
          title: 'Upload Cancelled',
        );
      }
      return;
    }


    if (mounted) {
      NotificationService().info(
        'Uploading ${filePaths.length} file(s) to ${selectedAccountIds.length} drive(s)...',
        title: 'Uploading Files',
      );
    }

    final uploadResults = await fs.uploadMultipleFilesToVirtualRaidWithSelection(
      filePaths,
      fileNames,
      selectedAccountIds,
    );

    if (mounted) {
      final successfulFiles = uploadResults['successful_files'] as int;
      final totalFiles = uploadResults['total_files'] as int;

      if (successfulFiles == totalFiles) {
        NotificationService().success(
          'All $successfulFiles file(s) uploaded to ${selectedAccountIds.length} drive(s)',
          title: 'Upload Complete',
        );
      } else {
        NotificationService().warning(
          '$successfulFiles of $totalFiles file(s) uploaded to ${selectedAccountIds.length} drive(s)',
          title: 'Partial Upload',
        );
      }
    }
  }

  // OPTIMIZATION: Use const constructors for static widgets where possible
  Widget _buildToolbarButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 36,
        height: 36,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: Icon(
              icon,
              size: 18,
              color: onPressed != null ? theme.UbuntuColors.darkGrey : theme.UbuntuColors.lightGrey,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbarAction({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
    bool isActive = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 36,
        height: 36,
        margin: const EdgeInsets.only(left: 4),
        child: Material(
          color: isActive ? theme.UbuntuColors.orange.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: Icon(
              icon,
              size: 18,
              color: onPressed != null
                  ? (isActive ? theme.UbuntuColors.orange : theme.UbuntuColors.darkGrey)
                  : theme.UbuntuColors.lightGrey,
            ),
          ),
        ),
      ),
    );
  }

  void _showSettingsDialog(FileSystemProvider fs) {
    HapticFeedback.lightImpact();
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: SettingsContentDialog(
          initialMaxResults: _maxSearchResults,
          initialCustomLimitSelected: _isCustomLimitSelected,
          onSettingsChanged: (newMaxResults, newCustomLimitSelected) {
            setState(() {
              _maxSearchResults = newMaxResults;
              _isCustomLimitSelected = newCustomLimitSelected;
              SearchService.instance.maxResultsLimit = newMaxResults;
            });
          },
        ),
      ),
    );
  }

  Widget _buildSettingsSection({
    required IconData icon,
    required String title,
    required Color color,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: theme.UbuntuColors.darkGrey,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _buildSettingItem({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: theme.UbuntuColors.darkGrey,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 12,
            color: theme.UbuntuColors.textGrey,
          ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _buildScopeOption({
    required SearchScope value,
    required IconData icon,
    required String label,
    required String description,
  }) {
    final tabsProvider = context.read<TabsProvider>();
    final currentScope = tabsProvider.activeTab?.searchScope ?? SearchScope.global;
    final isSelected = currentScope == value;

    return InkWell(
      onTap: () {
        final tab = tabsProvider.activeTab;
        if (tab != null) {
          tabsProvider.updateActiveTabSearch(
            tab.searchQuery,
            value,
            tab.searchResults,
            tab.isSearchActive,
          );
        }
        // Don't close dialog - just update the setting
        _showQuickNotification(
          'Search Scope Updated',
          'Now searching: $label',
          Icons.search,
          theme.UbuntuColors.orange,
        );
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.UbuntuColors.orange.withOpacity(0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                  ? theme.UbuntuColors.orange
                  : Colors.grey.shade300,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.UbuntuColors.orange
                    : Colors.grey.shade300,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 14,
                color: isSelected ? Colors.white : Colors.grey.shade600,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected
                          ? theme.UbuntuColors.orange
                          : theme.UbuntuColors.darkGrey,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.UbuntuColors.textGrey,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                size: 18,
                color: theme.UbuntuColors.orange,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRadioOption({
    required int value,
    required String label,
  }) {
    return InkWell(
      onTap: () {
        setState(() {
          _maxSearchResults = value;
          SearchService.instance.maxResultsLimit = value;
        });
        _showQuickNotification(
          'Search Limit Updated',
          'Maximum results set to ${value == -1 ? "all" : value}',
          Icons.settings,
          theme.UbuntuColors.orange,
        );
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _maxSearchResults == value
              ? theme.UbuntuColors.orange.withOpacity(0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: _maxSearchResults == value
                ? theme.UbuntuColors.orange
                : Colors.grey.shade300,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _maxSearchResults == value
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 16,
              color: _maxSearchResults == value
                  ? theme.UbuntuColors.orange
                  : Colors.grey.shade400,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: _maxSearchResults == value ? FontWeight.w500 : FontWeight.w400,
                color: theme.UbuntuColors.darkGrey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomLimitOption() {
    final isSelected = _isCustomLimitSelected;
    return InkWell(
      onTap: () {
        setState(() {
          _isCustomLimitSelected = true;
          _showCustomLimitInput = !_showCustomLimitInput;
        });
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.UbuntuColors.orange.withOpacity(0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected
                ? theme.UbuntuColors.orange
                : Colors.grey.shade300,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 16,
              color: isSelected
                  ? theme.UbuntuColors.orange
                  : Colors.grey.shade400,
            ),
            const SizedBox(width: 8),
            Icon(
              _showCustomLimitInput ? Icons.edit : Icons.edit,
              size: 16,
              color: isSelected
                  ? theme.UbuntuColors.orange
                  : Colors.grey.shade400,
            ),
            const SizedBox(width: 8),
            Text(
              'Custom...',
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                color: isSelected
                    ? theme.UbuntuColors.orange
                    : theme.UbuntuColors.darkGrey,
              ),
            ),
            if (_showCustomLimitInput) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_drop_up,
                size: 16,
                color: theme.UbuntuColors.orange,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInlineCustomLimitInput() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.UbuntuColors.lightGrey.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.UbuntuColors.orange),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _customLimitController,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Custom limit',
                hintText: 'Enter number (1-10000)',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              autofocus: true,
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              final value = int.tryParse(_customLimitController.text);
              if (value != null && value > 0 && value <= 10000) {
                setState(() {
                  _maxSearchResults = value;
                  _isCustomLimitSelected = true;
                  SearchService.instance.maxResultsLimit = value;
                });
                _showQuickNotification(
                  'Search Limit Updated',
                  'Maximum results set to $value',
                  Icons.settings,
                  theme.UbuntuColors.orange,
                );
              } else {
                _showQuickNotification(
                  'Invalid Value',
                  'Please enter a number between 1 and 10000',
                  Icons.error_outline,
                  Colors.red,
                );
              }
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
  }

  Widget _buildViewModeButton({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? theme.UbuntuColors.orange.withOpacity(0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? theme.UbuntuColors.orange
                  : Colors.grey.shade300,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 24,
                color: isSelected
                    ? theme.UbuntuColors.orange
                    : theme.UbuntuColors.mediumGrey,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected
                      ? theme.UbuntuColors.orange
                      : theme.UbuntuColors.darkGrey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  

  Widget _buildFileOperationButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    required bool isEnabled,
  }) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 32,
        height: 32,
        margin: const EdgeInsets.only(right: 4),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: Icon(
              icon,
              size: 16,
              color: isEnabled ? theme.UbuntuColors.darkGrey : theme.UbuntuColors.lightGrey,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar(FileSystemProvider fs, TabsProvider tabsProvider, SelectionProvider selectionProvider) {
    return FutureBuilder<List<CloudAccount>>(
      key: ValueKey(_accountsRefreshKey),
      future: fs.getAvailableAccounts(),
      builder: (context, snapshot) {
        final accounts = snapshot.data ?? [];
        final virtualDrives = HiveStorageService.instance.getAllNodes()
            .where((node) => node.provider == 'virtual' && node.parentId == null)
            .toList();
        
        return Sidebar(
          breadcrumbs: fs.breadcrumbs,
          accounts: accounts,
          virtualDrives: virtualDrives,
          currentFolder: fs.currentFolderNode,
          onNavigate: (folder) {
            _goHome(fs, tabsProvider);
            _navigateToFolder(fs, tabsProvider, folder);
          },
          onAccountSelected: (account) {
            // Clear file selection when switching accounts
            selectionProvider.clearSelection();
            
            _goHome(fs, tabsProvider);
            
            CloudNode? rootNode;
            try {
              rootNode = fs.currentNodes.firstWhere(
                (node) => node.accountId == account.id,
              );
            } catch (e) {
              fs.loadNodes().then((_) {
                try {
                  rootNode = fs.currentNodes.firstWhere(
                    (node) => node.accountId == account.id,
                  );
                  if (rootNode != null) {
                    _navigateToFolder(fs, tabsProvider, rootNode!);
                  }
                } catch (e) {
                  if (mounted) {
                    NotificationService().error(
                      "Could not access ${account.name ?? 'account'}",
                      title: 'Access Error',
                    );
                  }
                }
              });
              return;
            }
            
            if (rootNode != null) {
              _navigateToFolder(fs, tabsProvider, rootNode);
            } else {
              if (mounted) {
                NotificationService().error(
                  "Could not access ${account.name ?? 'account'}",
                  title: 'Access Error',
                );
              }
            }
          },
          onHomeClicked: () {
            _goHome(fs, tabsProvider);
          },
          onAddCloudDrive: () => _showAddDriveDialog(fs),
          onRefresh: () => fs.forceRefresh(),
          onEncryptionChanged: () {
            setState(() {
              _accountsRefreshKey++;
            });
          },
          onCreateVirtualDrive: () => _showCreateVirtualDriveDialog(),
          onRefreshSearchIndex: _handleRefreshSearchIndex,
          onRefreshStorageQuota: (accountId) => fs.refreshStorageQuota(accountId),
        );
      },
    );
  }

  Widget _buildFileList(FileSystemProvider fs, TabsProvider tabsProvider, SelectionProvider selectionProvider) {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.UbuntuColors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.UbuntuColors.lightGrey),
      ),
      child: Column(
        children: [
          // Header with view toggle and file operations
          // OPTIMIZATION: FileListHeader uses Selector to only rebuild when selectedCount changes
          FileListHeader(
            fileSystemProvider: fs,
            selectionProvider: selectionProvider,
            onSelectAll: () => _handleSelectAll(fs, selectionProvider),
            onDownload: selectionProvider.selectedCount > 0 ? () => _handleDownload(fs, selectionProvider) : null,
            onCopy: selectionProvider.selectedCount > 0 ? () => _handleCopy(fs, selectionProvider) : null,
            onCut: selectionProvider.selectedCount > 0 ? () => _handleCut(fs, selectionProvider) : null,
            onPaste: () => _handlePaste(fs),
            onDelete: selectionProvider.selectedCount > 0 ? () => _handleDelete(fs, selectionProvider) : null,
            onUpload: () => _handleUpload(fs),
            onFolderUpload: () => _handleFolderUpload(fs),
            onNewFolder: () => _handleNewFolder(fs),
            onViewToggle: _toggleViewMode,
            onUnlockVault: () => _showVaultUnlockDialog(),
            isGridView: _isGridView,
          ),
          
          // File list
          Expanded(
            child: FutureBuilder<Map<String, CloudAccount>>(
              future: _getSourceAccounts(fs),
              builder: (context, snapshot) {
                final sourceAccounts = snapshot.data ?? {};
                
                // Show loading indicator when fetching from API
                if (fs.isLoading && fs.currentNodes.isEmpty) {
                  return const Center(
                    child: LoadingIndicator(
                      message: 'Loading folder contents...',
                      size: 48,
                      showBackground: true,
                    ),
                  );
                }
                
                return UbuntuFileList(
                  files: fs.currentNodes,
                  selectedFiles: selectionProvider.selectedFiles,
                  onFileTap: (file) => _handleFileTap(file, fs, tabsProvider, selectionProvider),
                  onFileSecondaryTap: (file, position) => _handleFileSecondaryTap(file, position, fs, selectionProvider),
                  onSelectionChanged: _handleFileSelection,
                  onFileCtrlClick: (file) => _handleFileCtrlClick(file, selectionProvider),
                  isGridView: _isGridView,
                  scrollController: _fileListScrollController,
                  isVirtualDrive: fs.currentFolderNode?.provider == 'virtual',
                  sourceAccounts: sourceAccounts,
                  hasMore: fs.hasMore,
                  isLoadingMore: fs.isLoadingMore,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewToggle(IconData icon, bool isGrid) {
    return GestureDetector(
      onTap: () {
        if (_isGridView != isGrid) {
          _toggleViewMode();
        }
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: _isGridView == isGrid ? theme.UbuntuColors.orange.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(
          icon,
          size: 16,
          color: _isGridView == isGrid ? theme.UbuntuColors.orange : theme.UbuntuColors.mediumGrey,
        ),
      ),
    );
  }

  Widget _buildStatusBar(FileSystemProvider fs, SelectionProvider selectionProvider) {
    return theme.UbuntuStatusBarWidget(
      leftItems: [
        if (selectionProvider.selectedCount > 0)
          theme.UbuntuStatusItem(
            text: '${selectionProvider.selectedCount} selected',
            color: theme.UbuntuColors.orange,
          ),
      ],
      rightItems: [
        theme.UbuntuStatusItem(
          icon: Icons.storage,
          text: '${fs.currentNodes.length} items',
        ),
        theme.UbuntuStatusItem(
          icon: Icons.folder,
          text: '${fs.currentNodes.where((n) => n.isFolder).length} folders',
        ),
      ],
    );
  }

  String _getCurrentPath(FileSystemProvider fs) {
    if (fs.breadcrumbs.isEmpty) {
      return 'CloudNexus';
    }
    return fs.breadcrumbs.map((node) => node.name).join(' / ');
  }

  void _handleWindowAction(String action) {
    HapticFeedback.lightImpact();
  }

  void _handleUpload(FileSystemProvider fs) async {
    HapticFeedback.lightImpact();
    try {
      final accountId = fs.currentFolderNode?.accountId;
      if (accountId != null) {
        final shouldEncrypt = await fs.shouldEncryptForAccount(accountId);
        if (shouldEncrypt && !SecurityService.instance.isUnlocked) {
          final dialogUnlocked = await _showVaultUnlockDialog();
          if (dialogUnlocked != true) {
            return;
          }
        }
      }
      
      if (fs.currentFolderNode?.provider == 'virtual') {
        await _handleVirtualRaidFileUpload(fs);
      } else {
        await _handleRegularDriveUpload(fs);
      }
    } catch (e) {
      if (mounted) {
        NotificationService().error(
          '$e',
          title: 'Upload Error',
        );
      }
    }
  }

  void _handleNewFolder(FileSystemProvider fs) {
    HapticFeedback.lightImpact();
    _showNewFolderDialog(fs);
  }

  void _handleFolderUpload(FileSystemProvider fs) async {
    HapticFeedback.lightImpact();
    try {
      await fs.uploadFolderWithContext(context);
      _showQuickNotification('Upload Started', 'Folder upload initiated', Icons.cloud_upload, Colors.green);
    } catch (e) {
      if (mounted) {
        _showQuickNotification('Upload Error', 'Failed to start folder upload: $e', Icons.error, Colors.red);
      }
    }
  }

  /// Handle search index refresh - uses parallel indexing for better performance
  Future<void> _handleRefreshSearchIndex() async {
    
    try {
      final fs = context.read<FileSystemProvider>();
      final accounts = await fs.getAvailableAccounts();
      
      if (accounts.isEmpty) {
        if (mounted) {
          _showQuickNotification(
            'Search Index',
            'No accounts available',
            Icons.info_outline,
            Colors.orange,
          );
        }
        return;
      }
      
      
      // Use parallel indexing for better performance - all accounts indexed concurrently
      await fs.buildSearchIndexInParallel(accounts);
      
      if (mounted) {
        _showQuickNotification(
          'Search Index Refreshed',
          'Indexed ${accounts.length} account${accounts.length == 1 ? '' : 's'}',
          Icons.refresh,
          Colors.green,
        );
      }
      
    } catch (e) {
      if (mounted) {
        _showQuickNotification(
          'Search Index Error',
          'Failed to refresh search index: $e',
          Icons.error_outline,
          Colors.red,
        );
      }
    }
  }

  void _handleCopy(FileSystemProvider fs, SelectionProvider selectionProvider) {
    HapticFeedback.lightImpact();
    if (selectionProvider.selectedCount > 0) {
      final selectedNodes = fs.currentNodes.where((node) => selectionProvider.isSelected(node.id)).toList();
      fs.copyNodes(selectedNodes);
      _showQuickNotification('Copied', '${selectedNodes.length} item${selectedNodes.length == 1 ? '' : 's'} copied', Icons.copy, Colors.green);
    }
  }

  void _handleCut(FileSystemProvider fs, SelectionProvider selectionProvider) {
    HapticFeedback.lightImpact();
    if (selectionProvider.selectedCount > 0) {
      final selectedNodes = fs.currentNodes.where((node) => selectionProvider.isSelected(node.id)).toList();
      fs.copyNodes(selectedNodes);
      _showQuickNotification('Cut', '${selectedNodes.length} item${selectedNodes.length == 1 ? '' : 's'} cut', Icons.cut, theme.UbuntuColors.orange);
    }
  }

  void _handlePaste(FileSystemProvider fs) async {
    HapticFeedback.lightImpact();
    
    if (!fs.hasClipboardContent()) {
      _showQuickNotification('Clipboard Empty', 'No files copied to paste', Icons.content_paste_off, Colors.orange);
      return;
    }
    
    try {
      await fs.pasteNode();
      
      final content = fs.clipboardNodes.isNotEmpty
          ? fs.clipboardNodes.length
          : (fs.clipboardNode != null ? 1 : 0);
      
      _showQuickNotification(
        'Pasted',
        '$content item${content == 1 ? '' : 's'} pasted successfully',
        Icons.content_paste,
        Colors.green
      );
    } catch (e) {
      if (mounted) {
        NotificationService().error(
          '$e',
          title: 'Paste Error',
        );
      }
    }
  }

  void _handleDelete(FileSystemProvider fs, SelectionProvider selectionProvider) async {
    HapticFeedback.lightImpact();
    if (selectionProvider.selectedCount == 0) return;
    
    final selectedNodes = fs.currentNodes.where((node) => selectionProvider.isSelected(node.id)).toList();
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${selectedNodes.length} item${selectedNodes.length == 1 ? '' : 's'}?'),
        content: Text('Are you sure you want to delete the selected item${selectedNodes.length == 1 ? '' : 's'}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      int successfullyDeleted = 0;
      bool hasAccountInVirtualRaid = false;
      
      for (final node in selectedNodes) {
        try {
          // Check if this is an account root folder
          if (_isAccountNode(node)) {
            final success = await fs.deleteAccount(node);
            if (success) {
              successfullyDeleted++;
            } else {
              // Account is part of a Virtual RAID - get the list of Virtual RAID drives
              final linkedDrives = await HiveStorageService.instance.getVirtualDrivesForAccount(node.accountId!);
              if (mounted) {
                _showVirtualRaidWarningNotification(node, linkedDrives);
                hasAccountInVirtualRaid = true;
              }
            }
          } else {
            await fs.deleteNode(node);
            successfullyDeleted++;
          }
        } catch (e) {
        }
      }
      
      if (mounted) {
        selectionProvider.clearSelection();
        // Only show success notification if items were actually deleted
        // and no account was blocked due to Virtual RAID
        if (successfullyDeleted > 0 && !hasAccountInVirtualRaid) {
          _showQuickNotification('Deleted', '$successfullyDeleted item${successfullyDeleted == 1 ? '' : 's'} deleted', Icons.delete, Colors.red);
        }
      }
    }
  }

  void _handleSelectAll(FileSystemProvider fs, SelectionProvider selectionProvider) {
    HapticFeedback.lightImpact();
    if (selectionProvider.selectedCount == fs.currentNodes.length) {
      selectionProvider.clearSelection();
    } else {
      selectionProvider.selectAll(fs.currentNodes.map((node) => node.id).toSet());
    }
  }

  /// Handle search result navigation - clicks on search results
  /// Updates breadcrumbs and navigates to the correct folder
  Future<void> _handleSearchResultNavigation(
    SearchResult result,
    FileSystemProvider fs,
    TabsProvider tabsProvider,
  ) async {
    
    // Clear selection when navigating via search results
    final selectionProvider = context.read<SelectionProvider>();
    selectionProvider.clearSelection();
    
    // Set navigating flag to prevent _restoreFileSystemStateFromTab from interfering
    _isNavigating = true;
    
    try {
      // Close the search dropdown first
      tabsProvider.updateActiveTabSearch(
        '',
        tabsProvider.activeTab?.searchScope ?? SearchScope.global,
        <SearchResult>[],
        false,
      );
      
      // Navigate to the node
      // For files: navigates to parent folder and highlights the file
      // For folders: navigates into the folder
      await fs.navigateToNode(result.entry);
      
      
      // Update the active tab's state with the new navigation state
      // This is the key: update both breadcrumbs AND currentFolder together
      final currentTab = tabsProvider.activeTab;
      if (currentTab != null) {
        // Create new list instances to avoid reference sharing
        final newBreadcrumbs = List<CloudNode>.from(fs.breadcrumbs);
        
        final updatedTab = currentTab.copyWith(
          breadcrumbs: newBreadcrumbs,
          currentFolder: fs.currentFolderNode,
          searchQuery: '',
          searchResults: const [],
          isSearchActive: false,
        );
        
        // Generate title based on new state
        final newTitle = TabData.generateTitle(
          currentFolder: fs.currentFolderNode,
          searchQuery: '',
          isSearchActive: false,
          hasBreadcrumbs: newBreadcrumbs.isNotEmpty,
        );
        
        final finalTab = updatedTab.copyWith(title: newTitle);
        
        // Update the tab
        tabsProvider.updateTab(tabsProvider.activeTabIndex, finalTab);
        
      }
    } finally {
      // Clear navigating flag to re-enable _restoreFileSystemStateFromTab
      _isNavigating = false;
    }
  }

  /// Get icon for search scope
  IconData _getScopeIcon(SearchScope scope) {
    switch (scope) {
      case SearchScope.global:
        return Icons.public;
      case SearchScope.drive:
        return Icons.folder;
      case SearchScope.local:
        return Icons.subdirectory_arrow_right;
    }
  }

  /// Get short name for search scope
  String _getScopeShortName(SearchScope scope) {
    switch (scope) {
      case SearchScope.global:
        return 'Global';
      case SearchScope.drive:
        return 'Drive';
      case SearchScope.local:
        return 'Folder';
    }
  }

  void _handleDownload(FileSystemProvider fs, SelectionProvider selectionProvider) async {
    HapticFeedback.lightImpact();
    if (selectionProvider.selectedCount == 0) return;
    
    final selectedNodes = fs.currentNodes.where((node) => selectionProvider.isSelected(node.id)).toList();
    
    final filesToDownload = selectedNodes.where((node) => !node.isFolder).toList();
    final foldersToDownload = selectedNodes.where((node) => node.isFolder).toList();
    
    if (filesToDownload.isEmpty && foldersToDownload.isEmpty) {
      if (mounted) {
        NotificationService().warning(
          'No items selected for download',
          title: 'No Selection',
        );
      }
      return;
    }
    
    final accountId = fs.currentFolderNode?.accountId;
    if (accountId != null) {
      final shouldEncrypt = await fs.shouldEncryptForAccount(accountId);
      if (shouldEncrypt && !SecurityService.instance.isUnlocked) {
        final dialogUnlocked = await _showVaultUnlockDialog();
        if (dialogUnlocked != true) {
          return;
        }
      }
    }
    
    String downloadMessage = '';
    int totalItems = filesToDownload.length + foldersToDownload.length;
    
    if (filesToDownload.isNotEmpty && foldersToDownload.isNotEmpty) {
      downloadMessage = 'Downloading ${filesToDownload.length} file${filesToDownload.length == 1 ? '' : 's'} and ${foldersToDownload.length} folder${foldersToDownload.length == 1 ? '' : 's'}';
    } else if (filesToDownload.isNotEmpty) {
      downloadMessage = 'Downloading ${filesToDownload.length} file${filesToDownload.length == 1 ? '' : 's'}';
    } else {
      downloadMessage = 'Downloading ${foldersToDownload.length} folder${foldersToDownload.length == 1 ? '' : 's'}';
    }
    
    _showQuickNotification('Download Started', downloadMessage, Icons.download, Colors.green);
    
    try {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir == null) {
        throw Exception("Could not access downloads directory");
      }
      
      for (final folder in foldersToDownload) {
        try {
          final folderSavePath = '${downloadsDir.path}/${folder.name}';
          
          final task = QueuedTask(
            id: const Uuid().v4(),
            type: TaskType.downloadFolder,
            name: folder.name,
            accountId: folder.accountId,
            status: TaskStatus.pending,
            progress: 0.0,
            payload: {
              'folderId': folder.cloudId ?? folder.id,
              'savePath': folderSavePath,
              'accountId': folder.accountId,
              'provider': folder.provider,
            },
          );
          
          TaskService.instance.addTask(task);
          
        } catch (e) {
        }
      }
      
      if (filesToDownload.isNotEmpty) {
        try {
          final fileIds = filesToDownload.map((file) => file.cloudId ?? file.id).toList();
          final fileNames = filesToDownload.map((file) => file.name).toList();
          
          final task = QueuedTask(
            id: const Uuid().v4(),
            type: TaskType.download,
            name: '${filesToDownload.length} file${filesToDownload.length == 1 ? '' : 's'}',
            accountId: filesToDownload.first.accountId,
            status: TaskStatus.pending,
            progress: 0.0,
            payload: {
              'batchDownload': true,
              'fileIds': fileIds,
              'fileNames': fileNames,
              'saveDirectory': downloadsDir.path,
              'accountId': filesToDownload.first.accountId,
              'provider': filesToDownload.first.provider,
              'shouldDecrypt': await fs.shouldEncryptForAccount(filesToDownload.first.accountId),
            },
          );
          
          TaskService.instance.addTask(task);
          
        } catch (e) {
          
          for (final file in filesToDownload) {
            try {
              final fileSavePath = '${downloadsDir.path}/${file.name}';
              
              final task = QueuedTask(
                id: const Uuid().v4(),
                type: TaskType.download,
                name: file.name,
                accountId: file.accountId,
                status: TaskStatus.pending,
                progress: 0.0,
                payload: {
                  'fileId': file.cloudId ?? file.id,
                  'savePath': fileSavePath,
                  'accountId': file.accountId,
                  'provider': file.provider,
                  'isEncrypted': file.name.endsWith('.enc'),
                  'originalFileName': file.name.endsWith('.enc')
                      ? file.name.replaceAll('.enc', '')
                      : file.name,
                },
              );
              
              TaskService.instance.addTask(task);
              
            } catch (e) {
            }
          }
        }
      }
      
      if (mounted) {
        selectionProvider.clearSelection();
        
        String completionMessage = '';
        if (filesToDownload.isNotEmpty && foldersToDownload.isNotEmpty) {
          completionMessage = 'Download tasks created for ${totalItems} items';
        } else if (filesToDownload.isNotEmpty) {
          completionMessage = 'Download tasks created for ${filesToDownload.length} file${filesToDownload.length == 1 ? '' : 's'}';
        } else {
          completionMessage = 'Download tasks created for ${foldersToDownload.length} folder${foldersToDownload.length == 1 ? '' : 's'}';
        }
        
        _showQuickNotification('Download Queued', completionMessage, Icons.download_done, Colors.green);
      }
      
    } catch (e) {
      if (mounted) {
        NotificationService().error(
          '$e',
          title: 'Download Error',
        );
      }
    }
  }

  Future<void> _handleRegularDriveUpload(FileSystemProvider fs) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
      );
      
      if (result == null) {
        if (mounted) {
          NotificationService().info(
            'File selection was cancelled',
            title: 'Cancelled',
          );
        }
        return;
      }

      final filePaths = result.files.map((file) => file.path!).toList();
      final fileNames = result.files.map((file) => file.name).toList();
      

      if (filePaths.isEmpty) {
        if (mounted) {
          NotificationService().warning(
            'No files were selected',
            title: 'No Files',
          );
        }
        return;
      }

      if (filePaths.length == 1) {
        await fs.uploadFile(filePaths: [filePaths.first], fileNames: [fileNames.first]);
        if (mounted) {
          NotificationService().success(
            'File uploaded successfully',
            title: 'Upload Complete',
          );
        }
      } else {
        await fs.uploadMultipleFilesToRegularDrive(filePaths, fileNames);
        if (mounted) {
          NotificationService().success(
            "Uploaded ${fileNames.length} file(s) to ${fs.currentFolderNode?.name ?? 'drive'}",
            title: 'Upload Complete',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        NotificationService().error(
          '$e',
          title: 'Upload Error',
        );
      }
    }
  }

  /// Handle file upload for Virtual RAID (Manual Only)
  Future<void> _handleVirtualRaidFileUpload(FileSystemProvider fs) async {
    try {
      
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
      );
      
      if (result == null) {
        if (mounted) {
          NotificationService().info(
            'File selection was cancelled',
            title: 'Cancelled',
          );
        }
        return;
      }

      final filePaths = result.files.map((file) => file.path!).toList();
      final fileNames = result.files.map((file) => file.name).toList();
      

      if (filePaths.isEmpty) {
        if (mounted) {
          NotificationService().warning(
            'No files were selected',
            title: 'No Files',
          );
        }
        return;
      }

      final accountDetails = await fs.getVirtualDriveAccountDetails();
      
      if (accountDetails.isEmpty) {
        if (mounted) {
          NotificationService().warning(
            'No accounts available in this virtual drive',
            title: 'No Accounts',
          );
        }
        return;
      }

      // Manual strategy: show drive selection dialog
      final dialogTitle = filePaths.length == 1
          ? "Upload '${fileNames.first}' to drives"
          : "Upload ${filePaths.length} files to drives";

      final selectedAccountIds = (await showDialog<List<String>>(
        context: context,
        barrierDismissible: false,
        builder: (context) => VirtualDriveSelectionDialog(
          accountDetails: accountDetails,
          folderName: fileNames.first,
          customTitle: dialogTitle,
        ),
      )) ?? [];
      
      if (selectedAccountIds.isEmpty) {
        if (mounted) {
          NotificationService().warning(
            'File upload was cancelled',
            title: 'Upload Cancelled',
          );
        }
        return;
      }

      
      if (mounted) {
        NotificationService().info(
          'Uploading ${filePaths.length} file(s) to ${selectedAccountIds.length} drive(s)...',
          title: 'Uploading Files',
        );
      }

      Map<String, dynamic> uploadResults;
      if (filePaths.length == 1) {
        await fs.uploadFileToVirtualRaidWithSelection(filePaths.first, fileNames.first, selectedAccountIds);
        uploadResults = {
          'successful_uploads': {fileNames.first: selectedAccountIds},
          'total_files': 1,
          'successful_files': 1,
        };
      } else {
        uploadResults = await fs.uploadMultipleFilesToVirtualRaidWithSelection(filePaths, fileNames, selectedAccountIds);
      }
      
      if (mounted) {
        final successfulFiles = uploadResults['successful_files'] as int;
        final totalFiles = uploadResults['total_files'] as int;
        
        if (successfulFiles == totalFiles) {
          NotificationService().success(
            'All $successfulFiles file(s) uploaded to ${selectedAccountIds.length} drive(s)',
            title: 'Upload Complete',
          );
        } else {
          NotificationService().warning(
            '$successfulFiles of $totalFiles file(s) uploaded to ${selectedAccountIds.length} drive(s)',
            title: 'Partial Upload',
          );
        }
      }
    } catch (e, stackTrace) {
      
      if (mounted) {
        NotificationService().error(
          'Failed to upload file: $e',
          title: 'Upload Failed',
        );
      }
    }
  }

  void _showNewFolderDialog(FileSystemProvider fs) {
    String dialogTitle = "New Folder";
    if (fs.currentFolderNode != null) {
      switch (fs.currentFolderNode!.provider) {
        case 'local':
          dialogTitle = "New Local Folder";
          break;
        case 'gdrive':
          dialogTitle = "New Google Drive Folder";
          break;
        case 'virtual':
          dialogTitle = "New Virtual RAID Folder";
          break;
      }
    }

    showDialog(context: context, builder: (ctx) {
      final controller = TextEditingController();
      return AlertDialog(
        title: Text(dialogTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: "Enter folder name",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel")
          ),
          TextButton(
            onPressed: () async {
              try {
                if (fs.currentFolderNode?.provider == 'virtual') {
                  Navigator.pop(ctx);
                  await _handleVirtualRaidFolderCreation(fs, controller.text);
                } else {
                  await fs.createFolder(controller.text);
                  Navigator.pop(ctx);
                  if (mounted) {
                    NotificationService().success(
                      "Folder '${controller.text}' created successfully",
                      title: 'Folder Created',
                    );
                  }
                }
              } catch (e) {
                Navigator.pop(ctx);
                if (mounted) {
                  NotificationService().error(
                    'Failed to create folder: $e',
                    title: 'Create Failed',
                  );
                }
              }
            },
            child: const Text("Create")
          )
        ],
      );
    });
  }

  /// Handle folder creation for Virtual RAID (Manual Only)
  Future<void> _handleVirtualRaidFolderCreation(FileSystemProvider fs, String folderName) async {
    try {
      
      final accountDetails = await fs.getVirtualDriveAccountDetails();
      
      if (accountDetails.isEmpty) {
        if (mounted) {
          NotificationService().warning(
            'No accounts available in this virtual drive',
            title: 'No Accounts',
          );
        }
        return;
      }

      // Manual strategy: show drive selection dialog
      final selectedAccountIds = (await showDialog<List<String>>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) => VirtualDriveSelectionDialog(
          accountDetails: accountDetails,
          folderName: folderName,
        ),
      )) ?? [];
      
      if (selectedAccountIds.isEmpty) {
        if (mounted) {
          NotificationService().warning(
            'Folder creation was cancelled',
            title: 'Creation Cancelled',
          );
        }
        return;
      }

      
      await fs.createFolderInVirtualRaidWithSelection(folderName, selectedAccountIds);
      
      if (mounted) {
        NotificationService().success(
          "Folder '$folderName' created in ${selectedAccountIds.length} drive(s)",
          title: 'Folder Created',
        );
      }
    } catch (e, stackTrace) {
      
      if (mounted) {
        NotificationService().error(
          'Failed to create folder: $e',
          title: 'Create Failed',
        );
      }
    }
  }

  void _showQuickNotification(String title, String message, IconData icon, Color color) {
    if (!mounted) return;
    
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    
    entry = OverlayEntry(
      builder: (context) => Positioned(
        top: 80,
        right: 20,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          color: theme.UbuntuColors.white,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.UbuntuColors.lightGrey),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: theme.UbuntuColors.darkGrey,
                      ),
                    ),
                    Text(
                      message,
                      style: const TextStyle(
                        fontSize: 12,
                        color: theme.UbuntuColors.textGrey,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    
    overlay.insert(entry);
    
    Future.delayed(const Duration(seconds: 2), () {
      entry.remove();
    });
  }

  /// Get source accounts for virtual drive files
  Future<Map<String, CloudAccount>> _getSourceAccounts(FileSystemProvider fs) async {
    if (fs.currentFolderNode?.provider != 'virtual') {
      return {};
    }

    final sourceAccounts = <String, CloudAccount>{};
    
    final sourceAccountIds = fs.currentNodes
        .map((node) => node.sourceAccountId)
        .where((id) => id != null)
        .toSet()
        .cast<String>();

    for (final accountId in sourceAccountIds) {
      final account = await HiveStorageService.instance.getAccount(accountId);
      if (account != null) {
        sourceAccounts[accountId] = account;
      }
    }

    return sourceAccounts;
  }

  void _showAddDriveDialog(FileSystemProvider fs) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.cloud_upload, color: theme.UbuntuColors.orange),
            const SizedBox(width: 8),
            const Text('Add Cloud Drive'),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 350,
            minHeight: 200,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose a cloud provider to connect:',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    width: 40,
                    height: 40,
                    child: SvgIconCache.get(
                      path: 'assets/icons/gdrive.svg',
                      size: 24,
                    ),
                  ),
                  title: const Text('Google Drive', style: TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: const Text('Connect your Google Drive account', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                  onTap: () {
                    Navigator.pop(context);
                    fs.connectGoogleDrive();
                    NotificationService().info(
                      'Connecting to Google Drive...',
                      title: 'Connecting',
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    width: 40,
                    height: 40,
                    child: SvgIconCache.get(
                      path: 'assets/icons/onedrive.svg',
                      size: 24,
                    ),
                  ),
                  title: const Text('OneDrive', style: TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: const Text('Connect your OneDrive account', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                  onTap: () {
                    Navigator.pop(context);
                    fs.connectOneDrive();
                    NotificationService().info(
                      'Connecting to OneDrive...',
                      title: 'Connecting',
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: Colors.purple.withOpacity(0.3)),
                ),
                child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.purple.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.merge_type, color: Colors.purple, size: 24),
                  ),
                  title: const Text('Create Virtual Drive', style: TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: const Text('Combine multiple cloud drives', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                  onTap: () {
                    Navigator.pop(context);
                    _showCreateVirtualDriveDialog();
                  },
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
        ],
      ),
    );
  }

  void _showCreateVirtualDriveDialog() async {
    final fs = context.read<FileSystemProvider>();
    final availableAccounts = await fs.getAvailableAccounts();
    
    if (availableAccounts.isEmpty) {
      if (mounted) {
        NotificationService().warning(
          'Please connect at least one cloud account first',
          title: 'No Accounts',
        );
      }
      return;
    }
    
    showDialog(
      context: context,
      builder: (context) => VirtualDriveCreationDialog(
        availableAccounts: availableAccounts,
        onCreate: (name, selectedAccountIds) async {
          try {
            await fs.createVirtualDrive(name, selectedAccountIds);
            if (mounted) {
              NotificationService().success(
                'Virtual drive "$name" created successfully',
                title: 'Virtual Drive Created',
              );
            }
          } catch (e) {
            if (mounted) {
              NotificationService().error(
                'Failed to create virtual drive: $e',
                title: 'Create Failed',
              );
            }
          }
        },
      ),
    );
  }

  /// Show vault unlock/create dialog
  /// Returns true if vault was successfully unlocked, false otherwise
  /// Returns null if dialog was cancelled
  Future<bool?> _showVaultUnlockDialog() async {
    
    // Check vault state once - don't loop
    final hasVault = await SecurityService.instance.hasVault();
    
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _VaultUnlockDialog(hasVault: hasVault),
    );
    
    // Trigger rebuild to update the Unlock Vault button state
    if (result == true && mounted) {
      setState(() {});
    }
    
    return result;
  }

  void _showSyncManagement() {
    HapticFeedback.lightImpact();
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: screenWidth * 0.9,
          height: screenHeight * 0.8,
          constraints: BoxConstraints(
            minWidth: 600,
            minHeight: 400,
            maxWidth: screenWidth * 0.9,
            maxHeight: screenHeight * 0.8,
          ),
          decoration: BoxDecoration(
            color: theme.UbuntuColors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: theme.UbuntuColors.lightGrey)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.sync, color: theme.UbuntuColors.orange, size: 24),
                    const SizedBox(width: 12),
                    const Text(
                      'Sync Management',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: theme.UbuntuColors.darkGrey,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: theme.UbuntuColors.mediumGrey),
                    ),
                  ],
                ),
              ),
              
              const Expanded(
                child: SyncManagementWidget(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Handle keyboard events including tab shortcuts
  KeyEventResult _handleKeyEvent(KeyEvent event, FileSystemProvider fs, TabsProvider tabsProvider, SelectionProvider selectionProvider) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Debug: Log all key events to diagnose keyboard issues

    // Check if Ctrl or Meta (Command on Mac) is pressed
    final isCtrlPressed = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.controlLeft) ||
                        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.controlRight) ||
                        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.metaLeft) ||
                        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.metaRight);

    if (!isCtrlPressed) return KeyEventResult.ignored;

    // Handle Ctrl+T - New Tab
    if (event.logicalKey == LogicalKeyboardKey.keyT) {
      tabsProvider.createNewTab();
      return KeyEventResult.handled;
    }

    // Handle Ctrl+W - Close Tab
    if (event.logicalKey == LogicalKeyboardKey.keyW) {
      tabsProvider.closeTab(tabsProvider.activeTabIndex);
      return KeyEventResult.handled;
    }

    // Handle Ctrl+Tab - Next Tab
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final nextIndex = (tabsProvider.activeTabIndex + 1) % tabsProvider.tabs.length;
      tabsProvider.switchToTab(nextIndex);
      return KeyEventResult.handled;
    }

    // Handle Ctrl+Shift+Tab - Previous Tab
    final isShiftPressed = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
                          HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);
    if (event.logicalKey == LogicalKeyboardKey.tab && isShiftPressed) {
      final prevIndex = (tabsProvider.activeTabIndex - 1 + tabsProvider.tabs.length) % tabsProvider.tabs.length;
      tabsProvider.switchToTab(prevIndex);
      return KeyEventResult.handled;
    }

    // Handle Ctrl+F - Search
    if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _searchFocusNode.requestFocus();
      return KeyEventResult.handled;
    }

    // Handle Ctrl+A - Select All
    if (event.logicalKey == LogicalKeyboardKey.keyA) {
      _handleSelectAll(fs, selectionProvider);
      return KeyEventResult.handled;
    }

    // Handle Ctrl+C - Copy
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      if (selectionProvider.selectedCount > 0) {
        _handleCopy(fs, selectionProvider);
        return KeyEventResult.handled;
      }
    }

    // Handle Ctrl+V - Paste
    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      _handlePaste(fs);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// Check if a node represents an account root folder
  bool _isAccountNode(CloudNode node) {
    // An account node is a folder with no parent and has an accountId
    return node.isFolder && node.parentId == null && node.accountId != null;
  }

  /// Show a warning notification when trying to delete an account that's part of a Virtual RAID
  void _showVirtualRaidWarningNotification(CloudNode node, List<String> linkedDrives) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    
    // Format the list of Virtual RAID drives
    final drivesList = linkedDrives.take(3).join(', ');
    final moreText = linkedDrives.length > 3 ? ' and ${linkedDrives.length - 3} more' : '';
    
    entry = OverlayEntry(
      builder: (context) => Positioned(
        top: 80,
        right: 20,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          color: theme.UbuntuColors.white,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warning_amber, color: Colors.orange, size: 24),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Cannot Delete Account',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: theme.UbuntuColors.darkGrey,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: 300,
                      child: Text(
                        'This account is part of Virtual RAID drive${linkedDrives.length == 1 ? '' : 's'}: $drivesList$moreText. Remove it from Virtual RAID${linkedDrives.length == 1 ? '' : 's'} first.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: theme.UbuntuColors.textGrey,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    
    overlay.insert(entry);
    
    // Keep the notification visible longer (4 seconds) so users can read the full message
    Future.delayed(const Duration(seconds: 4), () {
      entry.remove();
    });
  }
}

/// Dialog for selecting which drives to create a folder in for Virtual RAID
class VirtualDriveSelectionDialog extends StatefulWidget {
  final List<dynamic> accountDetails;
  final String folderName;
  final String? customTitle;

  const VirtualDriveSelectionDialog({
    Key? key,
    required this.accountDetails,
    required this.folderName,
    this.customTitle,
  }) : super(key: key);

  @override
  State<VirtualDriveSelectionDialog> createState() => _VirtualDriveSelectionDialogState();
}

class _VirtualDriveSelectionDialogState extends State<VirtualDriveSelectionDialog> {
  final Set<String> _selectedAccountIds = {};

  String _getProviderIconPath(String provider) {
    switch (provider) {
      case 'gdrive':
        return 'assets/icons/gdrive.svg';
      case 'onedrive':
        return 'assets/icons/onedrive.svg';
      default:
        return 'assets/icons/gdrive.svg';
    }
  }

  @override
  void initState() {
    super.initState();
    _selectedAccountIds.addAll(
      widget.accountDetails.where((acc) => acc.isAvailable ?? true).map((acc) => acc.accountId)
    );
  }

  @override
  Widget build(BuildContext context) {
    final dialogTitle = widget.customTitle ?? "Create '${widget.folderName}' in drives";
    
    return AlertDialog(
      title: Text(dialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Select which drives to create the folder in:",
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          Flexible(
            child: Container(
              width: double.maxFinite,
              constraints: const BoxConstraints(maxHeight: 300),
              child: Scrollbar(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.accountDetails.length,
                  itemBuilder: (context, index) {
                    final accountInfo = widget.accountDetails[index];
                    return _buildAccountTile(accountInfo);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "Selected: ${_selectedAccountIds.length} of ${widget.accountDetails.length} drives",
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
          },
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          onPressed: _selectedAccountIds.isEmpty
              ? null
              : () {
                  Navigator.pop(context, _selectedAccountIds.toList());
                }
          ,
          child: const Text("Create"),
        ),
      ],
    );
  }

  Widget _buildAccountTile(dynamic accountInfo) {
    try {
      
      final isSelected = _selectedAccountIds.contains(accountInfo.accountId);
      final isAvailable = accountInfo.isAvailable ?? true;
      
      return Card(
        elevation: isSelected ? 4 : 1,
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: InkWell(
          onTap: isAvailable
              ? () {
                  setState(() {
                    if (isSelected) {
                      _selectedAccountIds.remove(accountInfo.accountId);
                    } else {
                      _selectedAccountIds.add(accountInfo.accountId);
                    }
                  });
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Checkbox(
                  value: isSelected,
                  onChanged: isAvailable
                      ? (value) {
                          setState(() {
                            if (value == true) {
                              _selectedAccountIds.add(accountInfo.accountId);
                            } else {
                              _selectedAccountIds.remove(accountInfo.accountId);
                            }
                          });
                        }
                      : null,
                ),
                const SizedBox(width: 12),
                 
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (accountInfo.providerColor ?? Colors.grey).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  width: 40,
                  height: 40,
                  child: SvgIconCache.get(
                    path: _getProviderIconPath(accountInfo.account.provider ?? ''),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                 
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        accountInfo.displayName ?? 'Unknown Account',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        accountInfo.providerDisplayName ?? 'Unknown Provider',
                        style: TextStyle(
                          fontSize: 12,
                          color: accountInfo.providerColor ?? Colors.grey,
                        ),
                      ),
                      if (accountInfo.account?.email != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          accountInfo.account.email,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                 
                if (!isAvailable)
                  const Tooltip(
                    message: "Drive not available",
                    child: Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 20,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    } catch (e, stackTrace) {
      
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          leading: const Icon(Icons.error, color: Colors.red),
          title: const Text('Error loading account'),
          subtitle: Text('Details: $e'),
        ),
      );
    }
  }
}

/// Vault unlock/create dialog
class _VaultUnlockDialog extends StatefulWidget {
  final bool hasVault;

  const _VaultUnlockDialog({required this.hasVault});

  @override
  State<_VaultUnlockDialog> createState() => _VaultUnlockDialogState();
}

class _VaultUnlockDialogState extends State<_VaultUnlockDialog> {
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  bool _isResetting = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (widget.hasVault) {
        final success = await SecurityService.instance.unlockVault(_passwordController.text);
        if (success) {
          if (mounted) {
            Navigator.pop(context, true);
          }
        } else {
          setState(() {
            _errorMessage = 'Incorrect password';
          });
        }
      } else {
        if (_passwordController.text.length < 8) {
          setState(() {
            _errorMessage = 'Password must be at least 8 characters';
          });
          return;
        }
        if (_passwordController.text != _confirmPasswordController.text) {
          setState(() {
            _errorMessage = 'Passwords do not match';
          });
          return;
        }
        
        await SecurityService.instance.createVault(_passwordController.text);
        if (mounted) {
          Navigator.pop(context, true);
        }
      }
    } catch (e, stackTrace) {
      setState(() {
        _errorMessage = 'Error: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _resetVault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Vault'),
        content: const Text(
          'This will delete all vault data. Any encrypted files created with the old vault will no longer be decryptable.\n\nAre you sure you want to continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        _isResetting = true;
      });
      try {
        await SecurityService.instance.clearVault();
        if (mounted) {
          Navigator.pop(context, false);
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Failed to reset vault: $e';
            _isResetting = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            widget.hasVault ? Icons.lock_open : Icons.lock,
            color: theme.UbuntuColors.orange,
          ),
          const SizedBox(width: 12),
          Text(widget.hasVault ? 'Unlock Vault' : 'Create Vault'),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 320,
          minHeight: 150,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.hasVault
                  ? 'Enter your vault password to enable encryption for this upload.'
                  : 'Create a vault password to enable encryption for your uploads.',
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
            if (widget.hasVault) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.orange.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'If you\'ve never created a vault before, click "Reset Vault" to start fresh.',
                        style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              enabled: !_isLoading && !_isResetting,
              decoration: InputDecoration(
                labelText: widget.hasVault ? 'Password' : 'New Password',
                border: const OutlineInputBorder(),
                errorText: _errorMessage,
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (!widget.hasVault) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _confirmPasswordController,
                obscureText: true,
                enabled: !_isLoading && !_isResetting,
                decoration: const InputDecoration(
                  labelText: 'Confirm Password',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.hasVault)
          TextButton(
            onPressed: _isLoading || _isResetting ? null : _resetVault,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: _isResetting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Reset Vault'),
          ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: _isLoading || _isResetting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: (_isLoading || _isResetting) ? null : _submit,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.hasVault ? 'Unlock' : 'Create'),
        ),
      ],
    );
  }
}

/// Stateful settings dialog content with proper visual feedback for selections
class SettingsContentDialog extends StatefulWidget {
  final int initialMaxResults;
  final bool initialCustomLimitSelected;
  final void Function(int newMaxResults, bool newCustomLimitSelected) onSettingsChanged;

  const SettingsContentDialog({
    Key? key,
    required this.initialMaxResults,
    required this.initialCustomLimitSelected,
    required this.onSettingsChanged,
  }) : super(key: key);

  @override
  State<SettingsContentDialog> createState() => _SettingsContentDialogState();
}

class _SettingsContentDialogState extends State<SettingsContentDialog> {
  // Search results limit configuration
  static const List<int> _searchLimitOptions = [50, 100, 150];
  late int _maxSearchResults;
  late bool _showCustomLimitInput;
  late bool _isCustomLimitSelected;
  final TextEditingController _customLimitController = TextEditingController();
  
  // Password change dialog controllers
  final TextEditingController _currentPasswordController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  String? _passwordError;
  bool _isChangingPassword = false;
  bool _isResettingVault = false;

  // Task limits configuration
  late int _maxConcurrentTasks;
  late int _maxConcurrentTransfersPerAccount;
  late int _maxConcurrentTransfersSameAccount;

  // Virtual RAID upload strategy configuration
  VirtualRaidUploadStrategy _uploadStrategy = VirtualRaidUploadStrategy.manual;
  bool _isLoadingStrategy = false;

  @override
  void initState() {
    super.initState();
    _maxSearchResults = widget.initialMaxResults;
    _showCustomLimitInput = widget.initialCustomLimitSelected;
    _isCustomLimitSelected = widget.initialCustomLimitSelected;
    
    // Initialize task limits from TaskService
    _maxConcurrentTasks = TaskService.instance.MAX_CONCURRENT_TASKS;
    _maxConcurrentTransfersPerAccount = TaskService.instance.MAX_CONCURRENT_TRANSFERS_PER_ACCOUNT;
    _maxConcurrentTransfersSameAccount = TaskService.instance.MAX_CONCURRENT_TRANSFERS_SAME_ACCOUNT;

    // Load upload strategy from HiveStorageService
    _loadUploadStrategy();
  }

  /// Load the saved upload strategy from HiveStorageService
  Future<void> _loadUploadStrategy() async {
    try {
      final strategy = await HiveStorageService.instance.getUploadStrategy();
      if (mounted) {
        setState(() {
          _uploadStrategy = strategy;
        });
      }
    } catch (e) {
    }
  }

  @override
  void dispose() {
    _customLimitController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _showQuickNotification(String title, String message, IconData icon, Color color) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    
    entry = OverlayEntry(
      builder: (context) => Positioned(
        top: 80,
        right: 20,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          color: theme.UbuntuColors.white,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.UbuntuColors.lightGrey),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: theme.UbuntuColors.darkGrey,
                      ),
                    ),
                    Text(
                      message,
                      style: const TextStyle(
                        fontSize: 12,
                        color: theme.UbuntuColors.textGrey,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    
    overlay.insert(entry);
    
    Future.delayed(const Duration(seconds: 2), () {
      entry.remove();
    });
  }

  Future<void> _handleChangePassword() async {
    setState(() {
      _isChangingPassword = true;
      _passwordError = null;
    });

    try {
      // First verify current password by attempting to unlock
      // Note: unlockVault will fail if password is wrong
      final currentPassword = _currentPasswordController.text;
      final newPassword = _newPasswordController.text;
      final confirmPassword = _confirmPasswordController.text;

      // Validate new password length
      if (newPassword.length < 8) {
        setState(() {
          _passwordError = 'New password must be at least 8 characters';
          _isChangingPassword = false;
        });
        return;
      }

      // Validate passwords match
      if (newPassword != confirmPassword) {
        setState(() {
          _passwordError = 'New passwords do not match';
          _isChangingPassword = false;
        });
        return;
      }

      // Verify current password by trying to unlock the vault
      // This will set _masterKey if successful
      final isValid = await SecurityService.instance.unlockVault(currentPassword);
      if (!isValid) {
        setState(() {
          _passwordError = 'Current password is incorrect';
          _isChangingPassword = false;
        });
        return;
      }

      // Now the vault is unlocked, we can change the password
      await SecurityService.instance.changePassword(newPassword);
      
      if (mounted) {
        setState(() {
          _isChangingPassword = false;
          _currentPasswordController.clear();
          _newPasswordController.clear();
          _confirmPasswordController.clear();
        });
        Navigator.pop(context);
        _showQuickNotification(
          'Password Changed',
          'Your vault password has been updated successfully',
          Icons.check_circle,
          Colors.green,
        );
      }
    } catch (e) {
      setState(() {
        _passwordError = 'Failed to change password: $e';
        _isChangingPassword = false;
      });
    }
  }

  Future<void> _handleResetVault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.red),
            SizedBox(width: 12),
            Text('Reset Vault'),
          ],
        ),
        content: const Text(
          'This will delete all vault data. Any encrypted files created with the old vault will no longer be decryptable.\n\nAre you sure you want to continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isResettingVault = true;
    });

    try {
      await SecurityService.instance.clearVault();
      if (mounted) {
        setState(() {
          _isResettingVault = false;
        });
        Navigator.pop(context);
        _showQuickNotification(
          'Vault Reset',
          'Your vault has been reset. You can now create a new vault.',
          Icons.check_circle,
          Colors.green,
        );
      }
    } catch (e) {
      setState(() {
        _isResettingVault = false;
        _passwordError = 'Failed to reset vault: $e';
      });
    }
  }

  void _showChangePasswordDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.lock, color: theme.UbuntuColors.orange),
            const SizedBox(width: 12),
            const Text('Change Password'),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter your current password and new password to change your vault password.',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _currentPasswordController,
                obscureText: true,
                enabled: !_isChangingPassword,
                decoration: const InputDecoration(
                  labelText: 'Current Password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _newPasswordController,
                obscureText: true,
                enabled: !_isChangingPassword,
                decoration: const InputDecoration(
                  labelText: 'New Password',
                  border: OutlineInputBorder(),
                  helperText: 'Must be at least 8 characters',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _confirmPasswordController,
                obscureText: true,
                enabled: !_isChangingPassword,
                decoration: const InputDecoration(
                  labelText: 'Confirm New Password',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_passwordError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _passwordError!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _currentPasswordController.clear();
              _newPasswordController.clear();
              _confirmPasswordController.clear();
              _passwordError = null;
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: _isChangingPassword ? null : _handleChangePassword,
            child: _isChangingPassword
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Change Password'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    
    return Container(
      width: screenWidth * 0.5,
      height: screenHeight * 0.75,
      constraints: BoxConstraints(
        minWidth: 500,
        minHeight: 500,
        maxWidth: screenWidth * 0.5,
        maxHeight: screenHeight * 0.75,
      ),
      decoration: BoxDecoration(
        color: theme.UbuntuColors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.UbuntuColors.lightGrey.withOpacity(0.5)),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.settings, color: theme.UbuntuColors.orange, size: 28),
                const SizedBox(width: 16),
                const Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: theme.UbuntuColors.darkGrey,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: theme.UbuntuColors.mediumGrey),
                ),
              ],
            ),
          ),
          
          // Settings Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Task Limits Section
                  _buildSettingsSection(
                    icon: Icons.speed,
                    title: 'Task Limits',
                    color: Colors.green,
                    children: [
                      _buildSettingItem(
                        title: 'Global Concurrent Tasks',
                        subtitle: 'Maximum number of tasks running simultaneously across all accounts',
                        child: _buildTaskLimitSlider(
                          value: _maxConcurrentTasks,
                          min: 1,
                          max: 20,
                          onChanged: (value) async {
                            setState(() {
                              _maxConcurrentTasks = value;
                            });
                            await TaskService.instance.setTaskLimits(
                              maxConcurrentTasks: value,
                              maxConcurrentTransfersPerAccount: _maxConcurrentTransfersPerAccount,
                              maxConcurrentTransfersSameAccount: _maxConcurrentTransfersSameAccount,
                            );
                            // Save to storage
                            await HiveStorageService.instance.saveTaskLimits(
                              maxConcurrentTasks: value,
                              maxConcurrentTransfersPerAccount: _maxConcurrentTransfersPerAccount,
                              maxConcurrentTransfersSameAccount: _maxConcurrentTransfersSameAccount,
                            );
                            _showQuickNotification(
                              'Task Limit Updated',
                              'Global concurrent tasks set to $value',
                              Icons.speed,
                              Colors.green,
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildSettingItem(
                        title: 'Per-Account Concurrent Transfers',
                        subtitle: 'Maximum concurrent transfers per cloud account',
                        child: _buildTaskLimitSlider(
                          value: _maxConcurrentTransfersPerAccount,
                          min: 1,
                          max: 20,
                          onChanged: (value) async {
                            setState(() {
                              _maxConcurrentTransfersPerAccount = value;
                            });
                            await TaskService.instance.setTaskLimits(
                              maxConcurrentTasks: _maxConcurrentTasks,
                              maxConcurrentTransfersPerAccount: value,
                              maxConcurrentTransfersSameAccount: _maxConcurrentTransfersSameAccount,
                            );
                            // Save to storage
                            await HiveStorageService.instance.saveTaskLimits(
                              maxConcurrentTasks: _maxConcurrentTasks,
                              maxConcurrentTransfersPerAccount: value,
                              maxConcurrentTransfersSameAccount: _maxConcurrentTransfersSameAccount,
                            );
                            _showQuickNotification(
                              'Task Limit Updated',
                              'Per-account concurrent transfers set to $value',
                              Icons.speed,
                              Colors.green,
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildSettingItem(
                        title: 'Same-Account Concurrent Transfers',
                        subtitle: 'Maximum concurrent transfers for the same account',
                        child: _buildTaskLimitSlider(
                          value: _maxConcurrentTransfersSameAccount,
                          min: 1,
                          max: 20,
                          onChanged: (value) async {
                            setState(() {
                              _maxConcurrentTransfersSameAccount = value;
                            });
                            await TaskService.instance.setTaskLimits(
                              maxConcurrentTasks: _maxConcurrentTasks,
                              maxConcurrentTransfersPerAccount: _maxConcurrentTransfersPerAccount,
                              maxConcurrentTransfersSameAccount: value,
                            );
                            // Save to storage
                            await HiveStorageService.instance.saveTaskLimits(
                              maxConcurrentTasks: _maxConcurrentTasks,
                              maxConcurrentTransfersPerAccount: _maxConcurrentTransfersPerAccount,
                              maxConcurrentTransfersSameAccount: value,
                            );
                            _showQuickNotification(
                              'Task Limit Updated',
                              'Same-account concurrent transfers set to $value',
                              Icons.speed,
                              Colors.green,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Search Settings Section
                  _buildSettingsSection(
                    icon: Icons.search,
                    title: 'Search Settings',
                    color: theme.UbuntuColors.orange,
                    children: [
                      // Maximum Search Results
                      _buildSettingItem(
                        title: 'Maximum Search Results',
                        subtitle: 'Limit the number of results displayed',
                        child: Column(
                          children: [
                            _buildRadioOption(
                              value: 50,
                              label: '50 results',
                              showDivider: true,
                            ),
                            _buildRadioOption(
                              value: 100,
                              label: '100 results',
                              showDivider: true,
                            ),
                            _buildRadioOption(
                              value: 150,
                              label: '150 results',
                              showDivider: true,
                            ),
                            _buildRadioOption(
                              value: -1,
                              label: 'All results',
                              showDivider: true,
                            ),
                            _buildCustomLimitOption(showDivider: false),
                            if (_showCustomLimitInput) ...[
                              const SizedBox(height: 12),
                              _buildInlineCustomLimitInput(),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Virtual RAID Upload Strategy Section
                  _buildSettingsSection(
                    icon: Icons.cloud_upload,
                    title: 'Virtual RAID Upload Strategy',
                    color: Colors.blue,
                    children: [
                      _buildSettingItem(
                        title: 'Upload Strategy',
                        subtitle: 'Choose how files are uploaded to virtual RAID drives',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildUploadStrategyOption(
                              value: VirtualRaidUploadStrategy.manual,
                              label: VirtualRaidUploadStrategy.manual.displayName,
                              description: VirtualRaidUploadStrategy.manual.description,
                              icon: VirtualRaidUploadStrategy.manual.icon,
                            ),
                            const SizedBox(height: 12),
                            _buildUploadStrategyOption(
                              value: VirtualRaidUploadStrategy.mostFreeStorage,
                              label: VirtualRaidUploadStrategy.mostFreeStorage.displayName,
                              description: VirtualRaidUploadStrategy.mostFreeStorage.description,
                              icon: VirtualRaidUploadStrategy.mostFreeStorage.icon,
                            ),
                            const SizedBox(height: 12),
                            _buildUploadStrategyOption(
                              value: VirtualRaidUploadStrategy.lowestFullPercentage,
                              label: VirtualRaidUploadStrategy.lowestFullPercentage.displayName,
                              description: VirtualRaidUploadStrategy.lowestFullPercentage.description,
                              icon: VirtualRaidUploadStrategy.lowestFullPercentage.icon,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Vault Settings Section
                  _buildSettingsSection(
                    icon: Icons.security,
                    title: 'Vault Settings',
                    color: Colors.purple,
                    children: [
                      _buildSettingItem(
                        title: 'Encryption Vault',
                        subtitle: 'Manage your encryption vault settings',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildVaultActionButton(
                              icon: Icons.lock_outline,
                              label: 'Change Password',
                              description: 'Change your vault password',
                              onPressed: _showChangePasswordDialog,
                              isLoading: _isChangingPassword,
                            ),
                            const SizedBox(height: 12),
                            _buildVaultActionButton(
                              icon: Icons.delete_forever,
                              label: 'Reset Vault',
                              description: 'Delete all vault data and start fresh',
                              onPressed: _isResettingVault ? null : _handleResetVault,
                              isLoading: _isResettingVault,
                              isDangerous: true,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVaultActionButton({
    required IconData icon,
    required String label,
    required String description,
    required VoidCallback? onPressed,
    required bool isLoading,
    bool isDangerous = false,
  }) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDangerous
              ? (onPressed != null ? Colors.red.withOpacity(0.05) : Colors.red.withOpacity(0.02))
              : theme.UbuntuColors.orange.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDangerous
                ? (onPressed != null ? Colors.red.withOpacity(0.3) : Colors.red.withOpacity(0.1))
                : theme.UbuntuColors.orange.withOpacity(0.2),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isDangerous
                    ? (onPressed != null ? Colors.red.withOpacity(0.1) : Colors.red.withOpacity(0.05))
                    : theme.UbuntuColors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                size: 20,
                color: isDangerous
                    ? (onPressed != null ? Colors.red : Colors.red.shade300)
                    : theme.UbuntuColors.orange,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDangerous
                          ? (onPressed != null ? Colors.red : Colors.red.shade300)
                          : theme.UbuntuColors.darkGrey,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDangerous
                          ? (onPressed != null ? Colors.red.shade700 : Colors.red.shade300)
                          : theme.UbuntuColors.textGrey,
                    ),
                  ),
                ],
              ),
            ),
            if (isLoading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: isDangerous
                    ? (onPressed != null ? Colors.red : Colors.red.shade300)
                    : theme.UbuntuColors.orange,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsSection({
    required IconData icon,
    required String title,
    required Color color,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: theme.UbuntuColors.darkGrey,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _buildSettingItem({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: theme.UbuntuColors.darkGrey,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 12,
            color: theme.UbuntuColors.textGrey,
          ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _buildRadioOption({
    required int value,
    required String label,
    bool showDivider = true,
  }) {
    final isSelected = _maxSearchResults == value;
    
    return Column(
      children: [
        InkWell(
          onTap: () async {
            setState(() {
              _maxSearchResults = value;
              _isCustomLimitSelected = false;
              _showCustomLimitInput = false;
            });
            widget.onSettingsChanged(value, false);
            // Save to storage
            await HiveStorageService.instance.setSearchResultsLimit(value);
            await HiveStorageService.instance.setCustomLimitSelected(false);
            _showQuickNotification(
              'Search Limit Updated',
              'Maximum results set to ${value == -1 ? "all" : value}',
              Icons.settings,
              theme.UbuntuColors.orange,
            );
          },
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? theme.UbuntuColors.orange.withOpacity(0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected
                    ? theme.UbuntuColors.orange
                    : Colors.grey.shade300,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? theme.UbuntuColors.orange
                          : Colors.grey.shade400,
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    isSelected ? Icons.circle : Icons.radio_button_unchecked,
                    size: 14,
                    color: isSelected
                        ? theme.UbuntuColors.orange
                        : Colors.grey.shade400,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isSelected
                        ? theme.UbuntuColors.orange
                        : theme.UbuntuColors.darkGrey,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (showDivider) _buildDivider(),
      ],
    );
  }

  Widget _buildCustomLimitOption({bool showDivider = true}) {
    final isSelected = _isCustomLimitSelected;
    return Column(
      children: [
        InkWell(
          onTap: () {
            setState(() {
              _isCustomLimitSelected = true;
              _showCustomLimitInput = !_showCustomLimitInput;
            });
            if (!_showCustomLimitInput) {
              widget.onSettingsChanged(_maxSearchResults, false);
            }
          },
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? theme.UbuntuColors.orange.withOpacity(0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected
                    ? theme.UbuntuColors.orange
                    : Colors.grey.shade300,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? theme.UbuntuColors.orange
                          : Colors.grey.shade400,
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    isSelected ? Icons.circle : Icons.radio_button_unchecked,
                    size: 14,
                    color: isSelected
                        ? theme.UbuntuColors.orange
                        : Colors.grey.shade400,
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  Icons.edit,
                  size: 16,
                  color: isSelected
                      ? theme.UbuntuColors.orange
                      : Colors.grey.shade400,
                ),
                const SizedBox(width: 8),
                Text(
                  'Custom...',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isSelected
                        ? theme.UbuntuColors.orange
                        : theme.UbuntuColors.darkGrey,
                  ),
                ),
                const Spacer(),
                Icon(
                  _showCustomLimitInput ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                  size: 18,
                  color: isSelected
                      ? theme.UbuntuColors.orange
                      : Colors.grey.shade400,
                ),
              ],
            ),
          ),
        ),
        if (showDivider) _buildDivider(),
      ],
    );
  }

  Widget _buildInlineCustomLimitInput() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.UbuntuColors.lightGrey.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.UbuntuColors.orange, width: 2),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _customLimitController,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Custom limit',
                hintText: 'Enter number (1-10000)',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              autofocus: true,
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: () async {
              final value = int.tryParse(_customLimitController.text);
              if (value != null && value > 0 && value <= 10000) {
                setState(() {
                  _maxSearchResults = value;
                  _isCustomLimitSelected = true;
                });
                widget.onSettingsChanged(value, true);
                // Save to storage
                await HiveStorageService.instance.setSearchResultsLimit(value);
                await HiveStorageService.instance.setCustomLimitSelected(true);
                _showQuickNotification(
                  'Search Limit Updated',
                  'Maximum results set to $value',
                  Icons.settings,
                  theme.UbuntuColors.orange,
                );
              } else {
                _showQuickNotification(
                  'Invalid Value',
                  'Please enter a number between 1 and 10000',
                  Icons.error_outline,
                  Colors.red,
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.UbuntuColors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Set'),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 1,
      color: Colors.grey.shade200,
      margin: const EdgeInsets.symmetric(vertical: 8),
    );
  }

  Widget _buildTaskLimitSlider({
    required int value,
    required int min,
    required int max,
    required Function(int) onChanged,
  }) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                  activeTrackColor: Colors.green,
                  inactiveTrackColor: Colors.grey.shade300,
                  thumbColor: Colors.green,
                  overlayColor: Colors.green.withOpacity(0.2),
                  valueIndicatorColor: Colors.green,
                  valueIndicatorTextStyle: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Slider(
                  value: value.toDouble(),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  divisions: max - min,
                  label: value.toString(),
                  onChanged: (newValue) {
                    onChanged(newValue.toInt());
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 40,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.green.withOpacity(0.3)),
              ),
              alignment: Alignment.center,
              child: Text(
                value.toString(),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.green,
                ),
              ),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              min.toString(),
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
            Text(
              max.toString(),
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildUploadStrategyOption({
    required VirtualRaidUploadStrategy value,
    required String label,
    required String description,
    required IconData icon,
  }) {
    final isSelected = _uploadStrategy == value;
    
    return InkWell(
      onTap: () async {
        if (_isLoadingStrategy) return;
        
        setState(() {
          _isLoadingStrategy = true;
        });
        
        try {
          // Save the new strategy to HiveStorageService
          await HiveStorageService.instance.setUploadStrategy(value);
          
          if (mounted) {
            setState(() {
              _uploadStrategy = value;
              _isLoadingStrategy = false;
            });
            
            _showQuickNotification(
              'Upload Strategy Updated',
              'Now using: ${value.displayName}',
              value.icon,
              Colors.blue,
            );
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _isLoadingStrategy = false;
            });
            _showQuickNotification(
              'Update Failed',
              'Failed to update upload strategy: $e',
              Icons.error_outline,
              Colors.red,
            );
          }
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blue.withOpacity(0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? Colors.blue
                : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected
                      ? Colors.blue
                      : Colors.grey.shade400,
                  width: 2,
                ),
              ),
              child: Icon(
                isSelected ? Icons.circle : Icons.radio_button_unchecked,
                size: 16,
                color: isSelected
                    ? Colors.blue
                    : Colors.grey.shade400,
              ),
            ),
            const SizedBox(width: 16),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.blue.withOpacity(0.15)
                    : Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                size: 24,
                color: isSelected
                    ? Colors.blue
                    : Colors.grey.shade600,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected
                          ? Colors.blue
                          : theme.UbuntuColors.darkGrey,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 12,
                      color: isSelected
                          ? Colors.blue.shade700
                          : theme.UbuntuColors.textGrey,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.check_circle,
                size: 24,
                color: Colors.blue,
              ),
          ],
        ),
      ),
    );
  }
}