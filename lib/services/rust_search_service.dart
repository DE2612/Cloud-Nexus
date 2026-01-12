import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

final _logger = Logger('RustSearchService');

/// C-compatible search result structure (matches Rust CSearchResult)
final class CSearchResult extends ffi.Struct {
  external ffi.Pointer<ffi.Char> node_id;
  external ffi.Pointer<ffi.Char> name;
  @ffi.Double()
  external double score;
  external ffi.Pointer<ffi.Char> account_id;
  external ffi.Pointer<ffi.Char> provider;
}

/// C-compatible search document structure for batch operations (matches Rust CSearchDocument)
final class CSearchDocument extends ffi.Struct {
  external ffi.Pointer<ffi.Char> node_id;
  external ffi.Pointer<ffi.Char> account_id;
  external ffi.Pointer<ffi.Char> provider;
  external ffi.Pointer<ffi.Char> email;
  external ffi.Pointer<ffi.Char> name;
  @ffi.Uint8()
  external int is_folder; // 0 = false, 1 = true
  external ffi.Pointer<ffi.Char> parent_id;
}

/// Rust Search Service - Pure FFI Implementation
/// All search operations are delegated to Rust via FFI
/// Replaces the previous Dart-only implementation

class RustSearchService {
  static final RustSearchService instance = RustSearchService._();
  
  late final ffi.DynamicLibrary _lib;
  bool _initialized = false;
  bool _ffiAvailable = false;
  
  // Index pointer
  int _indexPtr = 0;
  
  RustSearchService._();
  
  bool get isInitialized => _initialized;
  bool get isFfiAvailable => _ffiAvailable;
  int get indexPtr => _indexPtr;
  
  /// Initialize FFI and load Rust library
  bool initialize() {
    
    if (_initialized) {
      _logger.info('[RustSearchService][FFI] Already initialized, ffiAvailable=$_ffiAvailable');
      return _ffiAvailable;
    }
    
    _logger.info('[RustSearchService][FFI] Initializing Rust FFI...');
    
    try {
      
      String dllPath;
      if (io.Platform.isWindows) {
        
        // Try multiple locations for the DLL
        final possiblePaths = [
          'cloud_nexus_encryption.dll',  // Current directory
          'build/windows/x64/runner/Debug/cloud_nexus_encryption.dll',  // Debug build
          'assets/cloud_nexus_encryption.dll',  // Assets folder
          'native/target/release/cloud_nexus_encryption.dll',  // Build output
        ];
        
        dllPath = 'cloud_nexus_encryption.dll';  // Default - let OS search PATH
        for (final path in possiblePaths) {
          final file = io.File(path);
          if (file.existsSync()) {
            dllPath = file.absolute.path;
            break;
          } else {
          }
        }
        
        _lib = ffi.DynamicLibrary.open(dllPath);
        _logger.info('[RustSearchService][FFI] Loaded Windows DLL from: $dllPath');
      } else if (io.Platform.isMacOS) {
        _lib = ffi.DynamicLibrary.open('libcloud_nexus_encryption.dylib');
        _logger.info('[RustSearchService][FFI] Loaded macOS dylib');
      } else if (io.Platform.isLinux) {
        _lib = ffi.DynamicLibrary.open('libcloud_nexus_encryption.so');
        _logger.info('[RustSearchService][FFI] Loaded Linux so');
      } else {
        _logger.warning('[RustSearchService][FFI] Unsupported platform: ${io.Platform.operatingSystem}');
        _initialized = true;
        return false;
      }
      
      // Verify search functions exist
      _logger.info('[RustSearchService][FFI] Looking up create_search_index...');
      try {
        final create = _lib.lookupFunction<
          ffi.Pointer<ffi.Void> Function(),
          ffi.Pointer<ffi.Void> Function()
        >('create_search_index');
        _logger.info('[RustSearchService][FFI] create_search_index found: $create');
      } catch (e) {
        _logger.severe('[RustSearchService][FFI] create_search_index NOT FOUND: $e');
        throw e;
      }
      
      // Create the index immediately
      _createIndex();
      _ffiAvailable = true;
      _logger.info('[RustSearchService][FFI] Initialized successfully - using Rust FFI');
    } catch (e, stack) {
      _logger.severe('[RustSearchService][FFI] Failed to load FFI library', e, stack);
      _ffiAvailable = false;
    }
    
    _initialized = true;
    return _ffiAvailable;
  }
  
  void _createIndex() {
    _logger.info('[RustSearchService][FFI] Creating search index via Rust...');
    try {
      final create = _lib.lookupFunction<
        ffi.Pointer<ffi.Void> Function(),
        ffi.Pointer<ffi.Void> Function()
      >('create_search_index');
      
      _logger.info('[RustSearchService][FFI] Calling create_search_index()...');
      final result = create();
      _indexPtr = result.address;
      _logger.info('[RustSearchService][FFI] Created search index: ptr=$_indexPtr (result=$result)');
    } catch (e, stack) {
      _logger.severe('[RustSearchService][FFI] Failed to create index: $e');
      _logger.severe('[RustSearchService][FFI] Stack: $stack');
      _indexPtr = 0;
    }
  }
  
  void dispose() {
    _logger.info('[RustSearchService][FFI] Disposing search index via Rust...');
    if (_indexPtr != 0) {
      try {
        final free = _lib.lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)
        >('free_search_index');
        free(ffi.Pointer.fromAddress(_indexPtr));
        _logger.info('[RustSearchService][FFI] Disposed search index');
      } catch (e) {
        _logger.warning('[RustSearchService][FFI] Failed to free index', e);
      }
      _indexPtr = 0;
    }
  }
  
  // ============================================================================
  // Index Operations
  // ============================================================================
  
  /// Add document to index
  bool addDocument({
    required String nodeId,
    required String accountId,
    required String provider,
    required String email,
    required String name,
    required bool isFolder,
    String? parentId,
  }) {
    if (!_ffiAvailable) {
      _logger.warning('[RustSearchService][FFI] FFI not available');
      return false;
    }
    if (_indexPtr == 0) {
      _logger.warning('[RustSearchService][FFI] Index not created');
      return false;
    }
    
    try {
      final add = _lib.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>,
          ffi.Bool,
          ffi.Pointer<ffi.Char>,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>,
          bool,
          ffi.Pointer<ffi.Char>,
        )
      >('add_document_to_index');
      
      final result = add(
        ffi.Pointer.fromAddress(_indexPtr),
        nodeId.toNativeUtf8().cast(),
        accountId.toNativeUtf8().cast(),
        provider.toNativeUtf8().cast(),
        email.toNativeUtf8().cast(),
        name.toNativeUtf8().cast(),
        isFolder,
        (parentId ?? '').toNativeUtf8().cast(),
      );
      
      return result == 1;
    } catch (e) {
      _logger.severe('[RustSearchService][FFI] addDocument failed', e);
      return false;
    }
  }
  
  /// Add multiple documents to index in a single FFI call (batch operation)
  /// More efficient than calling addDocument individually
  int addDocumentsBatch(List<Map<String, dynamic>> documents) {
    if (!_ffiAvailable || _indexPtr == 0) {
      _logger.warning('[RustSearchService][FFI] addDocumentsBatch: FFI not available');
      return 0;
    }
    
    if (documents.isEmpty) {
      return 0;
    }
    
    try {
      final batchAdd = _lib.lookupFunction<
        ffi.Size Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<CSearchDocument>,
          ffi.Size,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<CSearchDocument>,
          int,
        )
      >('add_documents_batch');
      
      // Allocate memory for documents array
      final docsPtr = malloc<CSearchDocument>(documents.length);
      
      try {
        // Fill the documents array
        for (int i = 0; i < documents.length; i++) {
          final doc = documents[i];
          final cDoc = docsPtr.elementAt(i).ref;
          
          cDoc.node_id = doc['nodeId'].toString().toNativeUtf8().cast();
          cDoc.account_id = (doc['accountId'] ?? '').toString().toNativeUtf8().cast();
          cDoc.provider = doc['provider'].toString().toNativeUtf8().cast();
          cDoc.email = doc['email'].toString().toNativeUtf8().cast();
          cDoc.name = doc['name'].toString().toNativeUtf8().cast();
          cDoc.is_folder = doc['isFolder'] == true ? 1 : 0;
          cDoc.parent_id = (doc['parentId'] ?? '').toString().toNativeUtf8().cast();
        }
        
        final added = batchAdd(
          ffi.Pointer.fromAddress(_indexPtr),
          docsPtr,
          documents.length,
        );
        
        return added;
      } finally {
        // Free the allocated memory
        for (int i = 0; i < documents.length; i++) {
          final cDoc = docsPtr.elementAt(i).ref;
          malloc.free(cDoc.node_id);
          malloc.free(cDoc.account_id);
          malloc.free(cDoc.provider);
          malloc.free(cDoc.email);
          malloc.free(cDoc.name);
          malloc.free(cDoc.parent_id);
        }
        malloc.free(docsPtr);
      }
    } catch (e) {
      _logger.severe('[RustSearchService][FFI] addDocumentsBatch failed', e);
      return 0;
    }
  }
  
  /// Get document count
  int get documentCount {
    if (!_ffiAvailable || _indexPtr == 0) {
      _logger.warning('[RustSearchService][FFI] documentCount: FFI not available');
      return 0;
    }
    
    try {
      final getCount = _lib.lookupFunction<
        ffi.Size Function(ffi.Pointer<ffi.Void>),
        int Function(ffi.Pointer<ffi.Void>)
      >('get_index_count');
      
      final count = getCount(ffi.Pointer.fromAddress(_indexPtr));
      return count;
    } catch (e) {
      _logger.severe('[RustSearchService][FFI] documentCount failed', e);
      return 0;
    }
  }
  
  /// Clear index
  void clear() {
    _logger.info('[RustSearchService][FFI] Clearing index via Rust FFI...');
    if (!_ffiAvailable || _indexPtr == 0) {
      _logger.warning('[RustSearchService][FFI] Cannot clear: FFI not available');
      return;
    }
    
    try {
      final clear = _lib.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>),
        int Function(ffi.Pointer<ffi.Void>)
      >('clear_search_index');
      
      clear(ffi.Pointer.fromAddress(_indexPtr));
      _logger.info('[RustSearchService][FFI] Cleared index via Rust FFI');
    } catch (e) {
      _logger.severe('[RustSearchService][FFI] clear failed', e);
    }
  }
  
  // ============================================================================
  // Search Operations
  // ============================================================================
  
  /// Search exact match
  List<RustSearchResult> searchExact(String query, [int limit = 50]) {
    
    if (!_ffiAvailable || _indexPtr == 0) {
      return [];
    }
    
    try {
      final search = _lib.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Char>,
          ffi.Size,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
          ffi.Pointer<ffi.Size>,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Char>,
          int,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
          ffi.Pointer<ffi.Size>,
        )
      >('search_index');
      
      final resultsOut = malloc<ffi.Pointer<ffi.Void>>();
      final countOut = malloc<ffi.Size>();
      
      try {
        final result = search(
          ffi.Pointer.fromAddress(_indexPtr),
          query.toNativeUtf8().cast(),
          limit,
          resultsOut,
          countOut,
        );
        
        if (result != 1) {
          return [];
        }
        
        final count = countOut.value;
        
        // Parse results from CSearchResult array
        final results = <RustSearchResult>[];
        final resultsArray = resultsOut.value.cast<CSearchResult>();
        
        for (int i = 0; i < count; i++) {
          final cResult = resultsArray[i];
          
          // Read node_id
          String? nodeId;
          if (cResult.node_id.address != 0) {
            nodeId = cResult.node_id.cast<Utf8>().toDartString();
          }
          
          // Read name
          String? name;
          if (cResult.name.address != 0) {
            name = cResult.name.cast<Utf8>().toDartString();
          }
          
          // Read account_id
          String? accountId;
          if (cResult.account_id.address != 0) {
            accountId = cResult.account_id.cast<Utf8>().toDartString();
          }
          
          // Read provider
          String? provider;
          if (cResult.provider.address != 0) {
            provider = cResult.provider.cast<Utf8>().toDartString();
          }
          
          if (nodeId != null && name != null) {
            results.add(RustSearchResult(
              nodeId: nodeId,
              name: name,
              score: cResult.score,
              accountId: accountId ?? '',
              provider: provider ?? '',
            ));
          }
        }
        
        
        // Free results
        final freeResults = _lib.lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Size),
          void Function(ffi.Pointer<ffi.Void>, int)
        >('free_search_results');
        freeResults(resultsOut.value, count);
        
        return results;
      } finally {
        malloc.free(resultsOut);
        malloc.free(countOut);
      }
    } catch (e, stack) {
      return [];
    }
  }
  
  /// Search by account
  List<RustSearchResult> searchByAccount(String query, String accountId, [int limit = 50]) {
    
    if (!_ffiAvailable || _indexPtr == 0) {
      _logger.warning('[RustSearchService][FFI] searchByAccount: FFI not available');
      return [];
    }
    
    try {
      final search = _lib.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>,
          ffi.Size,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
          ffi.Pointer<ffi.Size>,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>,
          int,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
          ffi.Pointer<ffi.Size>,
        )
      >('search_index_by_account');
      
      final resultsOut = malloc<ffi.Pointer<ffi.Void>>();
      final countOut = malloc<ffi.Size>();
      
      try {
        final result = search(
          ffi.Pointer.fromAddress(_indexPtr),
          query.toNativeUtf8().cast(),
          accountId.toNativeUtf8().cast(),
          limit,
          resultsOut,
          countOut,
        );
        
        if (result != 1) {
          _logger.warning('[RustSearchService][FFI] searchByAccount: Rust returned $result');
          return [];
        }
        
        final count = countOut.value;
        
        // Parse results from CSearchResult array
        final results = <RustSearchResult>[];
        final resultsArray = resultsOut.value.cast<CSearchResult>();
        
        for (int i = 0; i < count; i++) {
          final cResult = resultsArray[i];
          
          // Read node_id
          String? nodeId;
          if (cResult.node_id.address != 0) {
            nodeId = cResult.node_id.cast<Utf8>().toDartString();
          }
          
          // Read name
          String? name;
          if (cResult.name.address != 0) {
            name = cResult.name.cast<Utf8>().toDartString();
          }
          
          // Read account_id
          String? accountIdResult;
          if (cResult.account_id.address != 0) {
            accountIdResult = cResult.account_id.cast<Utf8>().toDartString();
          }
          
          // Read provider
          String? provider;
          if (cResult.provider.address != 0) {
            provider = cResult.provider.cast<Utf8>().toDartString();
          }
          
          if (nodeId != null && name != null) {
            results.add(RustSearchResult(
              nodeId: nodeId,
              name: name,
              score: cResult.score,
              accountId: accountIdResult ?? '',
              provider: provider ?? '',
            ));
          }
        }
        
        
        // Free results
        final freeResults = _lib.lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Size),
          void Function(ffi.Pointer<ffi.Void>, int)
        >('free_search_results');
        freeResults(resultsOut.value, count);
        
        return results;
      } finally {
        malloc.free(resultsOut);
        malloc.free(countOut);
      }
    } catch (e) {
      _logger.severe('[RustSearchService][FFI] searchByAccount failed', e);
      return [];
    }
  }
  
  // ============================================================================
  // Fuzzy Matching
  // ============================================================================
  
  /// Fuzzy match two strings
  bool fuzzyMatch(String query, String target, [double threshold = 0.7]) {
    
    if (!_ffiAvailable) {
      _logger.warning('[RustSearchService][FFI] fuzzyMatch: FFI not available');
      return false;
    }
    
    try {
      final fuzzy = _lib.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Double),
        int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, double)
      >('fuzzy_match_strings');
      
      final result = fuzzy(
        query.toNativeUtf8().cast(),
        target.toNativeUtf8().cast(),
        threshold,
      );
      
      final matched = result == 1;
      return matched;
    } catch (e) {
      _logger.severe('[RustSearchService][FFI] fuzzyMatch failed', e);
      return false;
    }
  }
  
  /// Calculate similarity score
  double similarityScore(String query, String target) {
    
    if (!_ffiAvailable) {
      _logger.warning('[RustSearchService][FFI] similarityScore: FFI not available');
      return 0.0;
    }
    
    try {
      final similarity = _lib.lookupFunction<
        ffi.Double Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>),
        double Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>)
      >('similarity_score');
      
      final score = similarity(
        query.toNativeUtf8().cast(),
        target.toNativeUtf8().cast(),
      );
      
      return score;
    } catch (e) {
      _logger.severe('[RustSearchService][FFI] similarityScore failed', e);
      return 0.0;
    }
  }
  
  /// Calculate Levenshtein distance
  int levenshteinDistance(String s1, String s2) {
    
    if (!_ffiAvailable) {
      _logger.warning('[RustSearchService][FFI] levenshteinDistance: FFI not available');
      return 0;
    }
    
    try {
      final lev = _lib.lookupFunction<
        ffi.Size Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>),
        int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>)
      >('levenshtein');
      
      final distance = lev(s1.toNativeUtf8().cast(), s2.toNativeUtf8().cast());
      return distance;
    } catch (e) {
      _logger.severe('[RustSearchService][FFI] levenshteinDistance failed', e);
      return 0;
    }
  }
  
  /// Calculate Soundex code
  String soundexCode(String word) {
    _logger.fine('[RustSearchService][FFI] soundexCode("$word") via Rust FFI...');
    
    if (!_ffiAvailable) {
      _logger.warning('[RustSearchService][FFI] soundexCode: FFI not available');
      return '0000';
    }
    
    try {
      final soundex = _lib.lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>)
      >('soundex_code');
      
      final result = soundex(word.toNativeUtf8().cast());
      final code = result.cast<Utf8>().toDartString();
      
      final freeStr = _lib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Char>),
        void Function(ffi.Pointer<ffi.Char>)
      >('free_c_string');
      freeStr(result);
      
      _logger.fine('[RustSearchService][FFI] soundexCode => $code');
      return code;
    } catch (e) {
      _logger.severe('[RustSearchService][FFI] soundexCode failed', e);
      return '0000';
    }
  }
  
  /// Calculate Metaphone code
  String metaphoneCode(String word) {
    _logger.fine('[RustSearchService][FFI] metaphoneCode("$word") via Rust FFI...');
    
    if (!_ffiAvailable) {
      _logger.warning('[RustSearchService][FFI] metaphoneCode: FFI not available');
      return '';
    }
    
    try {
      final metaphone = _lib.lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>)
      >('metaphone_code');
      
      final result = metaphone(word.toNativeUtf8().cast());
      final code = result.cast<Utf8>().toDartString();
      
      final freeStr = _lib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Char>),
        void Function(ffi.Pointer<ffi.Char>)
      >('free_c_string');
      freeStr(result);
      
      _logger.fine('[RustSearchService][FFI] metaphoneCode => $code');
      return code;
    } catch (e) {
      _logger.severe('[RustSearchService][FFI] metaphoneCode failed', e);
      return '';
    }
  }
}

/// Search result
class RustSearchResult {
  final String nodeId;
  final String name;
  final double score;
  final String accountId;
  final String provider;
  
  const RustSearchResult({
    required this.nodeId,
    required this.name,
    required this.score,
    required this.accountId,
    required this.provider,
  });
}