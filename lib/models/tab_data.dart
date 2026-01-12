import '../models/cloud_node.dart';
import '../services/search_service.dart';

/// Represents the state of a single tab in the file explorer.
/// Each tab maintains its own navigation and search state.
class TabData {
  final String id;
  String title;
  final List<CloudNode> breadcrumbs;
  CloudNode? currentFolder;
  String searchQuery;
  SearchScope searchScope;
  final List<SearchResult> searchResults;
  bool isSearchActive;

  TabData({
    required this.id,
    required this.title,
    required this.breadcrumbs,
    this.currentFolder,
    this.searchQuery = '',
    this.searchScope = SearchScope.global,
    List<SearchResult>? searchResults,
    this.isSearchActive = false,
  }) : searchResults = searchResults ?? const [];

  /// Creates a copy of this tab with optional fields updated.
  /// IMPORTANT: Always creates new list instances to avoid shared mutable state.
  TabData copyWith({
    String? id,
    String? title,
    List<CloudNode>? breadcrumbs,
    CloudNode? currentFolder,
    String? searchQuery,
    SearchScope? searchScope,
    List<SearchResult>? searchResults,
    bool? isSearchActive,
  }) {
    return TabData(
      id: id ?? this.id,
      title: title ?? this.title,
      // Create new list instances to avoid reference sharing between tabs
      breadcrumbs: breadcrumbs != null
          ? List<CloudNode>.from(breadcrumbs)
          : List<CloudNode>.from(this.breadcrumbs),
      currentFolder: currentFolder, // CloudNode is immutable, direct reference is OK
      searchQuery: searchQuery ?? this.searchQuery,
      searchScope: searchScope ?? this.searchScope,
      searchResults: searchResults != null
          ? List<SearchResult>.from(searchResults)
          : List<SearchResult>.from(this.searchResults),
      isSearchActive: isSearchActive ?? this.isSearchActive,
    );
  }

  /// Converts this tab data to a JSON-compatible map for persistence.
  /// Note: Search results are not persisted to avoid circular dependencies.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'breadcrumbs': breadcrumbs.map((node) => node.toMap()).toList(),
      'currentFolder': currentFolder?.toMap(),
      'searchQuery': searchQuery,
      'searchScope': searchScope.name,
      'searchResults': [], // Empty - search results recreated by search service
      'isSearchActive': isSearchActive,
    };
  }

  /// Creates a TabData instance from a JSON map.
  /// Returns null if required fields are missing or invalid.
  static TabData? fromJson(Map<String, dynamic> json) {
    try {
      final String id = json['id'] as String;
      final String title = json['title'] as String;
      
      // Parse breadcrumbs
      final List<dynamic> breadcrumbsJson = json['breadcrumbs'] as List<dynamic>;
      final List<CloudNode> breadcrumbs = breadcrumbsJson
          .map((item) => CloudNode.fromMap(item as Map<String, dynamic>))
          .toList();
      
      // Parse current folder
      final dynamic currentFolderJson = json['currentFolder'];
      final CloudNode? currentFolder = currentFolderJson != null
          ? CloudNode.fromMap(currentFolderJson as Map<String, dynamic>)
          : null;
      
      // Parse search scope
      final String searchScopeName = json['searchScope'] as String;
      final SearchScope searchScope = SearchScope.values.firstWhere(
        (scope) => scope.name == searchScopeName,
        orElse: () => SearchScope.global,
      );
      
      return TabData(
        id: id,
        title: title,
        breadcrumbs: breadcrumbs,
        currentFolder: currentFolder,
        searchQuery: json['searchQuery'] as String? ?? '',
        searchScope: searchScope,
        searchResults: const [], // Will be recreated by search service
        isSearchActive: json['isSearchActive'] as bool? ?? false,
      );
    } catch (e) {
      return null;
    }
  }

  /// Generates a tab title based on current state.
  static String generateTitle({
    required CloudNode? currentFolder,
    required String searchQuery,
    required bool isSearchActive,
    required bool hasBreadcrumbs,
  }) {
    if (isSearchActive && searchQuery.isNotEmpty) {
      return 'Search: $searchQuery';
    }
    if (currentFolder != null) {
      return currentFolder.name;
    }
    if (hasBreadcrumbs) {
      return 'Folder';
    }
    return 'CloudNexus';
  }
}