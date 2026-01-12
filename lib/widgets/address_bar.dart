import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../providers/file_system_provider.dart';
import '../providers/tabs_provider.dart';
import '../models/cloud_node.dart';
import '../services/search_service.dart';
import '../widgets/search_results_dropdown.dart';
import '../themes/ubuntu_theme.dart';

class SearchTextbox extends StatefulWidget {
  final Function(String query) onSearch;
  final String? hintText;
  final LayerLink? layerLink;
  final SearchScope currentScope;
  final Function(SearchScope) onScopeChange;
  final VoidCallback? onFocusLost;

  const SearchTextbox({
    super.key,
    required this.onSearch,
    this.hintText,
    this.layerLink,
    required this.currentScope,
    required this.onScopeChange,
    this.onFocusLost,
  });

  @override
  State<SearchTextbox> createState() => _SearchTextboxState();
}

class _SearchTextboxState extends State<SearchTextbox> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounceTimer;

  static const Duration _debounceDuration = Duration(milliseconds: 300);

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    setState(() {}); // Rebuild to show/hide clear button
  }

  void _clearSearch() {
    _controller.clear();
    widget.onSearch('');
    _focusNode.unfocus();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      // When search bar gains focus, trigger search if query has >= 2 characters
      final query = _controller.text;
      if (query.length >= 2) {
        widget.onSearch(query);
      }
    } else {
      // Notify parent when focus is lost
      widget.onFocusLost?.call();
    }
  }

  void _onChanged(String value) {
    _debounceTimer?.cancel();
    
    if (value.isEmpty) {
      widget.onSearch('');
      return;
    }

    if (value.length >= 2) {
      _debounceTimer = Timer(_debounceDuration, () {
        widget.onSearch(value);
      });
    }
  }


  @override
  Widget build(BuildContext context) {
    final hasText = _controller.text.isNotEmpty;
    
    return CompositedTransformTarget(
      link: widget.layerLink!,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        onChanged: _onChanged,
        style: const TextStyle(
          fontSize: 13,
          color: UbuntuColors.darkGrey,
        ),
        decoration: InputDecoration(
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 12, right:8),
            child: Icon(
              Icons.search,
              size: 14,
              color: UbuntuColors.textGrey,
            ),
          ),
          prefixIconColor: UbuntuColors.textGrey,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasText)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: InkWell(
                    onTap: _clearSearch,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: UbuntuColors.textGrey,
                      ),
                    ),
                  ),
                ),
              _buildScopeDropdown(),
            ],
          ),
          suffixIconColor: UbuntuColors.textGrey,
          hintText: widget.hintText ?? 'Search...',
          hintStyle: TextStyle(
            fontSize: 13,
            color: UbuntuColors.textGrey.withValues(alpha: 0.6),
          ),
          filled: true,
          fillColor: UbuntuColors.lightGrey.withValues(alpha: 0.2),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(
              color: UbuntuColors.orange.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildScopeDropdown() {
    return PopupMenuButton<SearchScope>(
      icon: Icon(
        _getScopeIcon(widget.currentScope),
        size: 14,
        color: UbuntuColors.textGrey,
      ),
      iconSize: 14,
      padding: EdgeInsets.zero,
      offset: const Offset(0, 32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      onSelected: (scope) {
        widget.onScopeChange(scope);
        HapticFeedback.lightImpact();
      },
      itemBuilder: (context) => [
        _buildScopeMenuItem(SearchScope.global, Icons.public, 'Global', 'Search all accounts'),
        _buildScopeMenuItem(SearchScope.drive, Icons.folder, 'Drive', 'Search current drive'),
        _buildScopeMenuItem(SearchScope.local, Icons.folder_open, 'Folder', 'Search current folder'),
      ],
    );
  }

  PopupMenuItem<SearchScope> _buildScopeMenuItem(
    SearchScope scope,
    IconData icon,
    String label,
    String subtitle,
  ) {
    final isSelected = widget.currentScope == scope;
    return PopupMenuItem<SearchScope>(
      value: scope,
      height: 48,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: isSelected ? UbuntuColors.orange.withValues(alpha: 0.1) : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isSelected ? UbuntuColors.orange : UbuntuColors.lightGrey,
                width: isSelected ? 1 : 1,
              ),
            ),
            child: Icon(
              icon,
              size: 14,
              color: isSelected ? UbuntuColors.orange : UbuntuColors.textGrey,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected ? UbuntuColors.orange : UbuntuColors.darkGrey,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 10,
                  color: UbuntuColors.textGrey,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _getScopeIcon(SearchScope scope) {
    switch (scope) {
      case SearchScope.global:
        return Icons.public;
      case SearchScope.drive:
        return Icons.folder;
      case SearchScope.local:
        return Icons.folder_open;
    }
  }
}

/// Minimal modern address bar with navigation and search
class AddressBar extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback onHome;
  final Function(String query)? onSearch;
  final String? searchHintText;
  final LayerLink? layerLink;
  final VoidCallback? onSyncManagement;
  final VoidCallback? onSettings;
  final SearchScope currentScope;
  final Function(SearchScope) onScopeChange;

  const AddressBar({
    super.key,
    this.onBack,
    required this.onHome,
    this.onSearch,
    this.searchHintText,
    this.layerLink,
    this.onSyncManagement,
    this.onSettings,
    required this.currentScope,
    required this.onScopeChange,
  });

  @override
  State<AddressBar> createState() => _AddressBarState();
}

class _AddressBarState extends State<AddressBar> {
  void _handleSearch(String query) {
    widget.onSearch?.call(query);
  }

  void _handleScopeChange(SearchScope scope) {
    widget.onScopeChange(scope);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Navigation controls
        _buildNavButton(
          icon: Icons.arrow_back,
          onPressed: widget.onBack,
          tooltip: 'Back',
        ),
        const SizedBox(width: 4),
        _buildNavButton(
          icon: Icons.home,
          onPressed: widget.onHome,
          tooltip: 'Home',
        ),
        const SizedBox(width: 12),
        
        // Search textbox
        Expanded(
          child: SearchTextbox(
              onSearch: _handleSearch,
              hintText: widget.searchHintText,
              layerLink: widget.layerLink,
              currentScope: widget.currentScope,
              onScopeChange: _handleScopeChange,
            ),
        ),
        
        const SizedBox(width: 12),
        
        // Sync Management button
        _buildActionButton(
          icon: Icons.sync,
          tooltip: 'Sync Management',
          onPressed: widget.onSyncManagement,
        ),
        
        const SizedBox(width: 4),
        
        // Settings button
        _buildActionButton(
          icon: Icons.settings,
          tooltip: 'Settings',
          onPressed: widget.onSettings,
        ),
      ],
    );
  }

  Widget _buildNavButton({
    required IconData icon,
    required VoidCallback? onPressed,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onPressed != null ? () {
              HapticFeedback.lightImpact();
              onPressed!();
            } : null,
            child: Icon(
              icon,
              size: 16,
              color: onPressed != null
                  ? UbuntuColors.darkGrey
                  : UbuntuColors.lightGrey,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback? onPressed,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onPressed != null ? () {
              HapticFeedback.lightImpact();
              onPressed!();
            } : null,
            child: Icon(
              icon,
              size: 16,
              color: onPressed != null
                  ? UbuntuColors.darkGrey
                  : UbuntuColors.lightGrey,
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact breadcrumb navigation
class CompactBreadcrumb extends StatelessWidget {
  final List<CloudNode> breadcrumbs;
  final CloudNode? currentFolder;
  final Function(CloudNode) onNavigate;
  final VoidCallback onHome;

  const CompactBreadcrumb({
    super.key,
    required this.breadcrumbs,
    this.currentFolder,
    required this.onNavigate,
    required this.onHome,
  });

  @override
  Widget build(BuildContext context) {
    final displayItems = _getDisplayItems();
    
    if (displayItems.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: displayItems.map((item) {
          final isLast = item == displayItems.last;
          final isFirst = item == displayItems.first;
          
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isFirst) ...[
                const Icon(
                  Icons.chevron_right,
                  size: 12,
                  color: UbuntuColors.mediumGrey,
                ),
                const SizedBox(width: 4),
              ],
              _buildBreadcrumbItem(
                label: item.name,
                icon: item.isFolder ? Icons.folder : Icons.insert_drive_file,
                isClickable: !isLast,
                onTap: isLast ? null : () => onNavigate(item),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  List<CloudNode> _getDisplayItems() {
    if (breadcrumbs.isEmpty) return [];
    final maxItems = 3;
    final startIndex = breadcrumbs.length > maxItems
        ? breadcrumbs.length - maxItems
        : 0;
    return breadcrumbs.sublist(startIndex);
  }

  Widget _buildBreadcrumbItem({
    required String label,
    required IconData icon,
    required bool isClickable,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: isClickable ? UbuntuColors.orange : UbuntuColors.darkGrey,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isClickable ? FontWeight.w500 : FontWeight.w600,
              color: isClickable ? UbuntuColors.orange : UbuntuColors.darkGrey,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Complete address bar container with search
class AddressBarContainer extends StatefulWidget {
  final FileSystemProvider fileSystemProvider;
  final TabsProvider tabsProvider;
  final VoidCallback? onSyncManagement;
  final VoidCallback? onSettings;

  const AddressBarContainer({
    super.key,
    required this.fileSystemProvider,
    required this.tabsProvider,
    this.onSyncManagement,
    this.onSettings,
  });

  /// GlobalKey for positioning the search dropdown
  /// Use this to get the position of the address bar
  static GlobalKey get addressBarKey => _AddressBarContainerState.addressBarKey;

  @override
  State<AddressBarContainer> createState() => _AddressBarContainerState();
}

class _AddressBarContainerState extends State<AddressBarContainer> {
  static final GlobalKey addressBarKey = GlobalKey();
  
  OverlayEntry? _dropdownOverlay;
  final LayerLink _layerLink = LayerLink();
  SearchScope _currentScope = SearchScope.global;
  String? _lastSearchQuery;
  bool? _lastSearchActive;

  @override
  void initState() {
    super.initState();
    widget.tabsProvider.addListener(_onTabsProviderChanged);
  }

  @override
  void dispose() {
    _removeDropdownOverlay();
    widget.tabsProvider.removeListener(_onTabsProviderChanged);
    super.dispose();
  }

  void _onTabsProviderChanged() {
    final currentTab = widget.tabsProvider.activeTab;
    final currentSearchQuery = currentTab?.searchQuery ?? '';
    final currentSearchActive = currentTab?.isSearchActive ?? false;
    
    // Only sync if search state actually changed
    if (currentSearchQuery != _lastSearchQuery || currentSearchActive != _lastSearchActive) {
      _lastSearchQuery = currentSearchQuery;
      _lastSearchActive = currentSearchActive;
      _syncOverlayWithSearchState();
    }
  }

  void _removeDropdownOverlay() {
    _dropdownOverlay?.remove();
    _dropdownOverlay = null;
  }

  void _showDropdownOverlay(
    List<SearchResult> results,
    String query,
    FileSystemProvider fs,
    TabsProvider tabs,
  ) {
    _removeDropdownOverlay();
    
    // Use the LayerLink's leaderSize which is the actual search textbox size
    final leaderSize = _layerLink.leaderSize;
    final dropdownWidth = leaderSize?.width ?? 400.0;
    
    
    _dropdownOverlay = OverlayEntry(
      builder: (context) => Align(
        alignment: Alignment.topRight,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 36),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            color: Colors.white,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: 260, maxWidth: dropdownWidth),
              child: SearchResultsDropdown(
                results: results,
                isLoading: false,
                query: query,
                maxVisibleItems: 6,
                constraints: BoxConstraints(maxWidth: dropdownWidth),
                onResultSelected: (result) {
                  _removeDropdownOverlay();
                  _handleSearchResultNavigation(result, fs, tabs);
                },
              ),
            ),
          ),
        ),
      ),
    );
    
    
    Overlay.of(context).insert(_dropdownOverlay!);
  }

  void _handleSearch(String query) async {
    if (query.isEmpty) {
      widget.tabsProvider.updateActiveTabSearch(
        '',
        _currentScope,
        <SearchResult>[],
        false,
      );
      return;
    }

    try {
      final fs = widget.fileSystemProvider;
      final results = await SearchService.instance.search(
        query: query,
        scope: _currentScope,
        currentFolderId: fs.currentFolderId,
        currentAccountId: fs.currentFolderNode?.accountId,
      );

      widget.tabsProvider.updateActiveTabSearch(
        query,
        _currentScope,
        results,
        true,
      );
    } catch (e) {
    }
  }

  void _handleBack() {
    final fs = widget.fileSystemProvider;
    final tabs = widget.tabsProvider;
    
    if (fs.breadcrumbs.isEmpty) return;
    
    fs.goBack();
    tabs.updateActiveTabBreadcrumbs(fs.breadcrumbs);
    tabs.updateActiveTabCurrentFolder(fs.currentFolderNode);
  }

  void _handleHome() {
    final fs = widget.fileSystemProvider;
    final tabs = widget.tabsProvider;
    
    while (fs.breadcrumbs.isNotEmpty) {
      fs.goBack();
    }
    tabs.updateActiveTabBreadcrumbs(fs.breadcrumbs);
    tabs.updateActiveTabCurrentFolder(fs.currentFolderNode);
  }

  void _handleScopeChange(SearchScope scope) {
    setState(() {
      _currentScope = scope;
    });
    // Update the current tab's search scope
    final currentTab = widget.tabsProvider.activeTab;
    if (currentTab != null) {
      widget.tabsProvider.updateActiveTabSearch(
        currentTab.searchQuery,
        scope,
        currentTab.searchResults,
        currentTab.isSearchActive,
      );
    }
  }

  void _handleBreadcrumbNavigate(CloudNode folder) {
    final fs = widget.fileSystemProvider;
    final tabs = widget.tabsProvider;
    
    final targetIndex = fs.breadcrumbs.indexWhere((f) => f.id == folder.id);
    if (targetIndex == -1) return;
    
    final stepsBack = fs.breadcrumbs.length - targetIndex - 1;
    for (int i = 0; i < stepsBack; i++) {
      if (fs.breadcrumbs.isNotEmpty) {
        fs.goBack();
      }
    }
    
    tabs.updateActiveTabBreadcrumbs(fs.breadcrumbs);
    tabs.updateActiveTabCurrentFolder(fs.currentFolderNode);
  }

  /// Handle search result navigation
  Future<void> _handleSearchResultNavigation(
    SearchResult result,
    FileSystemProvider fs,
    TabsProvider tabs,
  ) async {
    
    // Close the search dropdown first
    tabs.updateActiveTabSearch(
      '',
      tabs.activeTab?.searchScope ?? SearchScope.global,
      <SearchResult>[],
      false,
    );
    
    // Navigate to the node
    await fs.navigateToNode(result.entry);
    
    // Update the active tab's state
    final currentTab = tabs.activeTab;
    if (currentTab != null) {
      final newBreadcrumbs = List<CloudNode>.from(fs.breadcrumbs);
      final updatedTab = currentTab.copyWith(
        breadcrumbs: newBreadcrumbs,
        currentFolder: fs.currentFolderNode,
        searchQuery: '',
        searchResults: const [],
        isSearchActive: false,
      );
      tabs.updateTab(tabs.activeTabIndex, updatedTab);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fs = widget.fileSystemProvider;
    final tabs = widget.tabsProvider;
    final currentTab = tabs.activeTab;
    
    // Get search state from current tab
    final isSearchActive = currentTab?.isSearchActive ?? false;
    final searchQuery = currentTab?.searchQuery ?? '';
    final searchResults = currentTab?.searchResults ?? <SearchResult>[];

    return Container(
      key: addressBarKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Address bar with search
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: AddressBar(
                  onBack: fs.breadcrumbs.isNotEmpty ? _handleBack : null,
                  onHome: _handleHome,
                  onSearch: _handleSearch,
                  searchHintText: 'Search files...',
                  layerLink: _layerLink,
                  onSyncManagement: widget.onSyncManagement,
                  onSettings: widget.onSettings,
                  currentScope: _currentScope,
                  onScopeChange: _handleScopeChange,
                ),
              ),
            ],
          ),
        );
      }
}

extension on _AddressBarContainerState {
  void _syncOverlayWithSearchState() {
    final fs = widget.fileSystemProvider;
    final tabs = widget.tabsProvider;
    final currentTab = tabs.activeTab;
    
    final isSearchActive = currentTab?.isSearchActive ?? false;
    final searchQuery = currentTab?.searchQuery ?? '';
    final searchResults = currentTab?.searchResults ?? <SearchResult>[];
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isSearchActive && searchQuery.isNotEmpty) {
        _showDropdownOverlay(searchResults, searchQuery, fs, tabs);
      } else {
        _removeDropdownOverlay();
      }
    });
  }
}