import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/tab_data.dart';
import '../models/cloud_node.dart';
import '../services/search_service.dart';
import 'package:hive/hive.dart';

// OPTIMIZATION: Helper function for list equality checks
bool _listsEqual<T>(List<T>? a, List<T>? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  if (a!.length != b!.length) return false;
  for (int i = 0; i < a!.length; i++) {
    if (a![i] != b![i]) return false;
  }
  return true;
}

/// Manages tab state and persistence for the file explorer.
/// Each tab maintains its own breadcrumbs, current folder, and search state.
class TabsProvider extends ChangeNotifier {
  final List<TabData> _tabs = [];
  int _activeTabIndex = 0;
  static const String _tabsBoxName = 'tabs';
  Box? _tabsBox;
  
  // OPTIMIZATION: Debounce save operations to reduce unnecessary I/O
  Timer? _saveDebounceTimer;
  static const Duration _saveDebounceDelay = Duration(milliseconds: 500);
  bool _saveScheduled = false;

  // OPTIMIZATION: ValueNotifier for active tab index to allow selective rebuilding
  // Widgets can listen to this instead of the entire provider when only tab index changes
  final ValueNotifier<int> activeTabIndexNotifier = ValueNotifier<int>(0);

  /// Getters
  List<TabData> get tabs => _tabs;
  int get activeTabIndex => _activeTabIndex;
  TabData? get activeTab => _tabs.isNotEmpty ? _tabs[_activeTabIndex] : null;
  bool get hasTabs => _tabs.isNotEmpty;
  bool get canCreateTab => _tabs.length < 20;

  /// Creates a new tab at root/home location.
  void createNewTab({TabData? initialState}) {
    final newTab = initialState ?? TabData(
      id: _generateTabId(),
      title: 'CloudNexus',
      breadcrumbs: const [],
      currentFolder: null,
    );
    
    _tabs.add(newTab);
    _activeTabIndex = _tabs.length - 1;
    
    notifyListeners();
    _scheduleSave();
  }

  /// Closes the tab at the specified index.
  void closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    
    final tabToClose = _tabs[index];
    _tabs.removeAt(index);
    
    // Adjust active index if needed
    if (_activeTabIndex >= _tabs.length) {
      _activeTabIndex = _tabs.length - 1;
    } else if (_activeTabIndex > index) {
      _activeTabIndex = _activeTabIndex - 1;
    }
    
    // Create new root tab if last tab was closed
    if (_tabs.isEmpty) {
      createNewTab();
    }
    
    notifyListeners();
    _scheduleSave();
  }

  /// Switches to the tab at the specified index.
  void switchToTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    
    if (_activeTabIndex == index) return;
    
    // Save current tab state before switching
    _saveTabs();
    
    _activeTabIndex = index;
    // OPTIMIZATION: Update ValueNotifier for selective rebuilding
    activeTabIndexNotifier.value = index;
    notifyListeners();
    _scheduleSave();
  }

  /// Gets the breadcrumbs for the tab at the specified index.
  List<CloudNode> getTabBreadcrumbs(int index) {
    if (index < 0 || index >= _tabs.length) return [];
    return _tabs[index].breadcrumbs;
  }

  /// Gets the current folder for the tab at the specified index.
  CloudNode? getTabCurrentFolder(int index) {
    if (index < 0 || index >= _tabs.length) return null;
    return _tabs[index].currentFolder;
  }

  /// Updates the tab at the specified index with new data.
  void updateTab(int index, TabData updatedTab) {
    if (index < 0 || index >= _tabs.length) return;
    
    _tabs[index] = updatedTab;
    if (index == _activeTabIndex) {
      notifyListeners();
    }
    // Don't save here - only save on tab creation or switch
  }

  /// Updates the active tab with new data.
  void updateActiveTab(TabData updatedTab) {
    if (_tabs.isEmpty) return;
    updateTab(_activeTabIndex, updatedTab);
  }

  /// Updates the active tab's breadcrumbs.
  /// Creates a new list instance to avoid shared mutable state.
  void updateActiveTabBreadcrumbs(List<CloudNode> breadcrumbs) {
    if (_tabs.isEmpty) return;
    
    // Create a new list instance to avoid reference sharing
    // OPTIMIZATION: Check equality before creating new list
    final currentBreadcrumbs = _tabs[_activeTabIndex].breadcrumbs;
    if (_listsEqual(currentBreadcrumbs, breadcrumbs)) {
      return;
    }
    final newBreadcrumbs = List<CloudNode>.from(breadcrumbs);
    final updatedTab = _tabs[_activeTabIndex].copyWith(breadcrumbs: newBreadcrumbs);
    _tabs[_activeTabIndex] = updatedTab;
    
    // Auto-update title based on breadcrumbs
    final newTitle = TabData.generateTitle(
      currentFolder: updatedTab.currentFolder,
      searchQuery: updatedTab.searchQuery,
      isSearchActive: updatedTab.isSearchActive,
      hasBreadcrumbs: breadcrumbs.isNotEmpty,
    );
    _tabs[_activeTabIndex] = updatedTab.copyWith(title: newTitle);
    
    notifyListeners();
    // Don't save here - only save on tab creation or switch
  }

  /// Updates the active tab's current folder.
  void updateActiveTabCurrentFolder(CloudNode? folder) {
    if (_tabs.isEmpty) return;
    
    final updatedTab = _tabs[_activeTabIndex].copyWith(currentFolder: folder);
    
    // Auto-update title based on current folder
    final newTitle = TabData.generateTitle(
      currentFolder: folder,
      searchQuery: _tabs[_activeTabIndex].searchQuery,
      isSearchActive: _tabs[_activeTabIndex].isSearchActive,
      hasBreadcrumbs: _tabs[_activeTabIndex].breadcrumbs.isNotEmpty,
    );
    _tabs[_activeTabIndex] = updatedTab.copyWith(title: newTitle);
    
    notifyListeners();
    // Don't save here - only save on tab creation or switch
  }

  /// Updates the active tab's search state.
  void updateActiveTabSearch(String query, SearchScope scope, List<SearchResult> results, bool isActive) {
    if (_tabs.isEmpty) return;
    
    final updatedTab = _tabs[_activeTabIndex].copyWith(
      searchQuery: query,
      searchScope: scope,
      searchResults: results,
      isSearchActive: isActive,
    );
    
    // Auto-update title based on search state
    final newTitle = TabData.generateTitle(
      currentFolder: _tabs[_activeTabIndex].currentFolder,
      searchQuery: query,
      isSearchActive: isActive,
      hasBreadcrumbs: _tabs[_activeTabIndex].breadcrumbs.isNotEmpty,
    );
    _tabs[_activeTabIndex] = updatedTab.copyWith(title: newTitle);
    
    notifyListeners();
    // Don't save here - only save on tab creation or switch
  }

  /// Updates the active tab's title.
  void updateActiveTabTitle(String title) {
    if (_tabs.isEmpty) return;
    
    _tabs[_activeTabIndex] = _tabs[_activeTabIndex].copyWith(title: title);
    notifyListeners();
    // Don't save here - only save on tab creation or switch
  }

  /// Clears all tabs and creates a new root tab.
  void clearTabs() {
    _tabs.clear();
    createNewTab();
  }

  /// Saves tabs to persistent storage with debouncing to reduce I/O
  Future<void> _saveTabs() async {
    // OPTIMIZATION: Check if save is already scheduled
    if (_saveScheduled || _tabsBox == null) return;
    _saveScheduled = false;
    
    
    try {
      final tabsMap = <String, dynamic>{};
      
      for (int i = 0; i < _tabs.length; i++) {
        final tab = _tabs[i];
        tabsMap['tab_$i'] = tab.toJson();
      }
      
      // Also store count
      tabsMap['count'] = _tabs.length;
      
      // Clear and put all at once for better performance
      await _tabsBox?.clear();
      await _tabsBox?.putAll(tabsMap);
      
    } catch (e) {
    }
  }

  /// Loads tabs from persistent storage.
  Future<void> loadTabs() async {
    if (_tabsBox == null) {
      _tabsBox = await Hive.openBox(_tabsBoxName);
    }
    
    try {
      // Load tabs from storage
      final savedTabs = <TabData>[];
      
      // First get the count
      final count = _tabsBox?.get('count') as int? ?? 0;
      
      // Load each tab
      for (int i = 0; i < count; i++) {
        final key = 'tab_$i';
        final tabJson = _tabsBox?.get(key);
        if (tabJson != null && tabJson is Map<String, dynamic>) {
          final tab = TabData.fromJson(tabJson as Map<String, dynamic>);
          if (tab != null) {
            savedTabs.add(tab!);
          }
        }
      }
      
      if (savedTabs.isNotEmpty) {
        _tabs.clear();
        _tabs.addAll(savedTabs);
        _activeTabIndex = 0;
        
        // Validate tabs and update titles if needed
        for (int i = 0; i < _tabs.length; i++) {
          final expectedTitle = TabData.generateTitle(
            currentFolder: _tabs[i].currentFolder,
            searchQuery: _tabs[i].searchQuery,
            isSearchActive: _tabs[i].isSearchActive,
            hasBreadcrumbs: _tabs[i].breadcrumbs.isNotEmpty,
          );
          if (_tabs[i].title != expectedTitle) {
            _tabs[i] = _tabs[i].copyWith(title: expectedTitle);
          }
        }
        
        notifyListeners();
      } else {
        // No saved tabs, create a default root tab
        createNewTab();
      }
    } catch (e) {
      // Create default tab on error
      createNewTab();
    }
  }

  /// Generates a unique tab ID.
  String _generateTabId() {
    return 'tab_${DateTime.now().millisecondsSinceEpoch}_${_tabs.length}';
  }

  /// Closes the active tab.
  void closeActiveTab() {
    if (_tabs.isEmpty) return;
    closeTab(_activeTabIndex);
  }

  /// Switches to the next tab.
  void switchToNextTab() {
    if (_tabs.isEmpty) return;
    
    final nextIndex = (_activeTabIndex + 1) % _tabs.length;
    switchToTab(nextIndex);
  }

  /// Switches to the previous tab.
  void switchToPreviousTab() {
    if (_tabs.isEmpty) return;
    
    final prevIndex = (_activeTabIndex - 1 + _tabs.length) % _tabs.length;
    switchToTab(prevIndex);
  }

  /// Disposes the Hive box and cleanup resources when no longer needed.
  @override
  void dispose() {
    // OPTIMIZATION: Cancel any pending save timer
    _saveDebounceTimer?.cancel();
    
    // Final save before disposing
    if (_saveScheduled) {
      _saveTabs();
    }
    
    // OPTIMIZATION: Dispose ValueNotifier
    activeTabIndexNotifier.dispose();
    
    _tabsBox?.close();
    super.dispose();
  }
  
  /// Schedules a debounced save operation
  void _scheduleSave() {
    // OPTIMIZATION: Cancel previous timer if exists
    _saveDebounceTimer?.cancel();
    
    // Schedule new save
    _saveDebounceTimer = Timer(_saveDebounceDelay, () async {
      await _saveTabs();
    });
    
    // Mark that a save has been scheduled
    _saveScheduled = true;
  }
}