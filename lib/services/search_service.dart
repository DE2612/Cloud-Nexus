import 'dart:async';
import 'package:hive/hive.dart';
import '../models/search_index.dart';
import '../models/cloud_node.dart';
import '../models/cloud_account.dart';
import '../adapters/cloud_adapter.dart';
import 'rust_search_service.dart';

enum SearchScope {
  global,    // Search all accounts
  local,     // Search within current folder
  drive      // Search within current drive/account
}

class SearchResult {
  final SearchIndexEntry entry;
  final String displayPath;

  SearchResult({
    required this.entry,
    required this.displayPath,
  });
}

class SearchService {
  static final SearchService instance = SearchService._init();
  static bool _initialized = false;
  late Box<SearchIndexEntry> _searchIndexBox;
  final RustSearchService _rustSearch = RustSearchService.instance;
  
  // Configurable maximum search results limit
  // Options: 50, 100, 150, Custom, or -1 for All
  int maxResultsLimit = 50;

  SearchService._init();

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    
    try {
      if (!Hive.isAdapterRegistered(30)) {
        Hive.registerAdapter(SearchIndexEntryAdapter());
      }
       
      _searchIndexBox = await Hive.openBox<SearchIndexEntry>('search_index');
      _initialized = true;
      
      // Initialize Rust Search Service
      try {
        final rustInitialized = _rustSearch.initialize();
      } catch (e, stack) {
      }
      
       // Sync existing entries to Rust index on startup using batch operation
       if (_rustSearch.isFfiAvailable && _searchIndexBox.isNotEmpty) {
         
         // Convert all entries to batch format
         final documents = <Map<String, dynamic>>[];
         for (final entry in _searchIndexBox.values) {
           documents.add({
             'nodeId': entry.nodeId,
             'accountId': entry.accountId ?? '',
             'provider': entry.provider,
             'email': entry.email,
             'name': entry.nodeName,
             'isFolder': entry.isFolder,
             'parentId': entry.parentId,
           });
         }
         
         // Use batch add (single FFI call instead of n calls)
         final synced = _rustSearch.addDocumentsBatch(documents);
       }
       
       // Log some sample entries if they exist
       if (_searchIndexBox.isNotEmpty) {
       }
     } catch (e) {
       rethrow;
     }
   }

  Future<void> buildAccountIndex(CloudAccount account, ICloudAdapter? adapter) async {
    if (adapter == null) {
      return;
    }
    
    final stopwatch = Stopwatch()..start();
    try {
      // Optimization: Use deleteAllFromIndex instead of individual get() calls
      // This is O(1) for finding keys (if we had an index), but Hive doesn't support
      // secondary indexes, so we still need to iterate. However, we only read entries
      // once and then delete.
      final keysToDelete = <dynamic>[];
      for (final key in _searchIndexBox.keys) {
        final entry = _searchIndexBox.get(key);
        if (entry?.accountId == account.id) {
          keysToDelete.add(key);
        }
      }
      
      if (keysToDelete.isNotEmpty) {
        await _searchIndexBox.deleteAll(keysToDelete);
      }

      int count = await _indexFolderRecursively(account, adapter, null, null);
      stopwatch.stop();
      
      if (_rustSearch.isFfiAvailable) {
      }
    } catch (e, stack) {
    }
  }

  Future<int> _indexFolderRecursively(
    CloudAccount account,
    ICloudAdapter adapter,
    String? cloudFolderId,
    String? parentId
  ) async {
    int totalAdded = 0;
    try {
      final result = await adapter.listFolder(cloudFolderId);
      final nodes = result.nodes;
      
      final entries = <String, SearchIndexEntry>{};
      final subfolderTasks = <Future<int>>[];
      int subfolderCount = 0;

      for (final node in nodes) {
        final entry = SearchIndexEntry(
          provider: account.provider,
          email: account.email ?? '',
          nodeId: node.id,
          parentId: parentId,
          nodeName: node.name,
          isFolder: node.isFolder,
          cloudId: node.cloudId,
          accountId: account.id,
          sourceAccountId: node.sourceAccountId,
        );
        entries[node.id] = entry;
        totalAdded++;

        if (node.isFolder) {
          subfolderCount++;
          // OPTIMIZATION: Start processing subfolders immediately for parallelism
          // Instead of collecting all tasks first, we process them as we discover them
          // This enables true depth-first parallelism
          subfolderTasks.add(_indexFolderRecursively(account, adapter, node.cloudId, node.id));
        }
      }

      if (entries.isNotEmpty) {
        await _searchIndexBox.putAll(entries);
        
        // Add to Rust index using batch operation
        if (_rustSearch.isFfiAvailable) {
          final documents = <Map<String, dynamic>>[];
          for (final entry in entries.values) {
            documents.add({
              'nodeId': entry.nodeId,
              'accountId': entry.accountId ?? '',
              'provider': entry.provider,
              'email': entry.email,
              'name': entry.nodeName,
              'isFolder': entry.isFolder,
              'parentId': entry.parentId,
            });
          }
          // Single FFI call instead of n calls
          _rustSearch.addDocumentsBatch(documents);
        }
      }

      // Process all subfolders in parallel
      if (subfolderTasks.isNotEmpty) {
        final results = await Future.wait(subfolderTasks);
        totalAdded += results.reduce((a, b) => a + b);
      }
    } catch (e) {
    }
    return totalAdded;
  }

  Future<List<SearchResult>> search({
    required String query,
    SearchScope scope = SearchScope.global,
    String? currentFolderId,
    String? currentAccountId,
  }) async {
    if (query.isEmpty) return [];
    
    final stopwatch = Stopwatch()..start();
    
    if (!_rustSearch.isFfiAvailable) {
      return [];
    }
    
    final results = <SearchResult>[];

    // Use Rust search with a higher limit to account for scope filtering
    // Then filter by scope and apply final limit
    final rustResults = _rustSearch.searchExact(query, 500);
    
    for (final rustResult in rustResults) {
      final entry = _searchIndexBox.get(rustResult.nodeId);
      if (entry != null) {
        final matchesScope = switch (scope) {
          SearchScope.global => true,
          SearchScope.local => entry.parentId == currentFolderId,
          SearchScope.drive => entry.accountId == currentAccountId,
        };
        
        if (matchesScope) {
          final path = await _buildDisplayPath(entry);
          results.add(SearchResult(entry: entry, displayPath: path));
        }
      }
    }
    
    // Apply final limit after scope filtering
    final finalResults = maxResultsLimit < 0
        ? results // All results
        : results.take(maxResultsLimit).toList();
    
    stopwatch.stop();
    return finalResults;
  }

  /// Search with fuzzy matching using RustSearchService
  Future<List<SearchResult>> searchWithFuzzy({
    required String query,
    SearchScope scope = SearchScope.global,
    String? currentFolderId,
    String? currentAccountId,
    double fuzzyThreshold = 0.7,
  }) async {
    if (query.isEmpty) return [];
    
    final stopwatch = Stopwatch()..start();
    
    if (query.length < 3) {
      return search(query: query, scope: scope, currentFolderId: currentFolderId, currentAccountId: currentAccountId);
    }
    
    if (!_rustSearch.isFfiAvailable) {
      return [];
    }
    
    final fuzzyResults = <SearchResult>[];

    final rustResults = _rustSearch.searchExact(query, 100);
    
    for (final rustResult in rustResults) {
      final entry = _searchIndexBox.get(rustResult.nodeId);
      if (entry != null) {
        final matchesScope = switch (scope) {
          SearchScope.global => true,
          SearchScope.local => entry.parentId == currentFolderId,
          SearchScope.drive => entry.accountId == currentAccountId,
        };
        
        if (matchesScope) {
          final isFuzzyMatch = _rustSearch.fuzzyMatch(query, entry.nodeName, fuzzyThreshold);
          
          if (isFuzzyMatch) {
            final path = await _buildDisplayPath(entry);
            fuzzyResults.add(SearchResult(entry: entry, displayPath: path));
          }
        }
      }
    }

    fuzzyResults.sort((a, b) {
      final scoreA = _rustSearch.similarityScore(query, a.entry.nodeName);
      final scoreB = _rustSearch.similarityScore(query, b.entry.nodeName);
      return scoreB.compareTo(scoreA);
    });

    stopwatch.stop();
    return fuzzyResults.take(50).toList();
  }

  /// Get similarity score between query and a name
  double getSimilarityScore(String query, String name) {
    return _rustSearch.similarityScore(query, name);
  }

  /// Check if two strings are similar enough (fuzzy match)
  bool isFuzzyMatch(String query, String name, [double threshold = 0.7]) {
    return _rustSearch.fuzzyMatch(query, name, threshold);
  }

  int _getMatchScore(String name, String query) {
    final lowerName = name.toLowerCase();
    if (lowerName == query) return 0;
    if (lowerName.startsWith(query)) return 1;
    return 2;
  }

  Future<String> _buildDisplayPath(SearchIndexEntry entry) async {
    final pathParts = <String>[];
    String? currentParentId = entry.parentId;

    while (currentParentId != null) {
      final parentEntry = _searchIndexBox.get(currentParentId);
      if (parentEntry != null) {
        pathParts.insert(0, parentEntry.nodeName);
        currentParentId = parentEntry.parentId;
      } else {
        break;
      }
    }

    // The account node name is [email] ([provider])
    final providerName = _getProviderDisplayName(entry.provider);
    final accountNodeName = "${entry.email} ($providerName)";
    pathParts.insert(0, accountNodeName);
    
    return pathParts.join(' / ');
  }

  String _getProviderDisplayName(String provider) {
    switch (provider) {
      case 'gdrive': return 'Google Drive';
      case 'onedrive': return 'OneDrive';
      case 'local': return 'Local';
      case 'virtual': return 'Virtual';
      default: return provider;
    }
  }

  Future<void> addEntry(CloudNode node, CloudAccount account) async {
    final entry = SearchIndexEntry(
      provider: account.provider,
      email: account.email ?? '',
      nodeId: node.id,
      parentId: node.parentId,
      nodeName: node.name,
      isFolder: node.isFolder,
      cloudId: node.cloudId,
      accountId: account.id,
      sourceAccountId: node.sourceAccountId,
    );
    await _searchIndexBox.put(node.id, entry);
  }

  Future<void> removeEntry(String nodeId) async {
    await _searchIndexBox.delete(nodeId);
  }

  Future<void> updateEntry(CloudNode node, CloudAccount account) async {
    await addEntry(node, account);
  }

  Future<void> clearIndex() async {
    await _searchIndexBox.clear();
    _rustSearch.clear();
  }
}