import 'dart:math';
import 'package:hive/hive.dart';
import '../models/encrypted_file_mapping.dart';
import 'hive_storage_service.dart';

/// Service for managing encrypted filename mappings
/// Files uploaded to cloud get random names like "XXXX-XXXX-XXXX-XXXX.enc"
/// while the app stores the mapping to display original filenames
class EncryptionNameService {
  static final EncryptionNameService instance = EncryptionNameService._init();
  
  // Hive box for storing mappings
  late Box<String> _mappingsBox;
  
  // In-memory cache for session persistence (avoids repeated Hive reads during scrolling)
  final Map<String, String> _nameCache = {};
  
  // Random generator for creating unique filenames
  final Random _random = Random.secure();
  
  EncryptionNameService._init();

  /// Initialize the service and open the Hive box
  Future<void> initialize() async {
    if (!Hive.isBoxOpen('encrypted_file_mappings')) {
      _mappingsBox = await Hive.openBox<String>('encrypted_file_mappings');
    } else {
      _mappingsBox = Hive.box<String>('encrypted_file_mappings');
    }
  }

  /// Check if initialized
  bool get isInitialized => Hive.isBoxOpen('encrypted_file_mappings');

  /// Generate a random encrypted filename: XXXX-XXXX-XXXX-XXXX.enc
  /// Format: 16 hex characters separated by dashes, with .enc extension
  String generateRandomFilename() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    
    // Format as XXXX-XXXX-XXXX-XXXX.enc
    return '${hex.substring(0, 4)}-${hex.substring(4, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}.enc';
  }

  /// Save a mapping between encrypted filename and original filename
  Future<void> saveMapping(EncryptedFileMapping mapping) async {
    if (!isInitialized) {
      await initialize();
    }
    
    await _mappingsBox.put(mapping.encryptedFileName, mapping.toJsonString());
    
    // Also cache in memory for fast access during scrolling
    _nameCache[mapping.encryptedFileName] = mapping.originalFileName;
    
  }

  /// Get the original filename from an encrypted filename
  /// Returns null if no mapping exists
  /// Uses in-memory cache for instant lookups after first load
  Future<String?> getOriginalName(String encryptedFileName) async {
    if (!isInitialized) {
      await initialize();
    }
    
    // First check in-memory cache (instant - for scrolling)
    if (_nameCache.containsKey(encryptedFileName)) {
      return _nameCache[encryptedFileName];
    }
    
    final jsonStr = _mappingsBox.get(encryptedFileName);
    if (jsonStr == null) {
      return null;
    }
    
    final mapping = EncryptedFileMapping.fromJsonString(jsonStr);
    
    // Cache for future lookups
    _nameCache[encryptedFileName] = mapping.originalFileName;
    
    return mapping.originalFileName;
  }

  /// Get the full mapping from an encrypted filename
  /// Returns null if no mapping exists
  Future<EncryptedFileMapping?> getMapping(String encryptedFileName) async {
    if (!isInitialized) {
      await initialize();
    }
    
    final jsonStr = _mappingsBox.get(encryptedFileName);
    if (jsonStr == null) {
      return null;
    }
    
    return EncryptedFileMapping.fromJsonString(jsonStr);
  }

  /// Get all mappings for a specific account
  Future<List<EncryptedFileMapping>> getMappingsForAccount(String accountId) async {
    if (!isInitialized) {
      await initialize();
    }
    
    final mappings = <EncryptedFileMapping>[];
    final keys = _mappingsBox.keys.toList();
    
    for (final key in keys) {
      try {
        final jsonStr = _mappingsBox.get(key);
        if (jsonStr != null) {
          final mapping = EncryptedFileMapping.fromJsonString(jsonStr);
          if (mapping.accountId == accountId) {
            mappings.add(mapping);
          }
        }
      } catch (e) {
      }
    }
    
    return mappings;
  }

  /// Get all mappings for a specific parent folder
  Future<List<EncryptedFileMapping>> getMappingsForParent(String parentId) async {
    if (!isInitialized) {
      await initialize();
    }
    
    final mappings = <EncryptedFileMapping>[];
    final keys = _mappingsBox.keys.toList();
    
    for (final key in keys) {
      try {
        final jsonStr = _mappingsBox.get(key);
        if (jsonStr != null) {
          final mapping = EncryptedFileMapping.fromJsonString(jsonStr);
          if (mapping.parentId == parentId) {
            mappings.add(mapping);
          }
        }
      } catch (e) {
      }
    }
    
    return mappings;
  }

  /// Delete a mapping when a file is deleted
  Future<void> deleteMapping(String encryptedFileName) async {
    if (!isInitialized) {
      await initialize();
    }
    
    await _mappingsBox.delete(encryptedFileName);
    
    // Also remove from cache
    _nameCache.remove(encryptedFileName);
    
  }

  /// Delete all mappings for a specific account
  Future<void> deleteMappingsForAccount(String accountId) async {
    if (!isInitialized) {
      await initialize();
    }
    
    final keysToDelete = <String>[];
    final keys = _mappingsBox.keys.toList();
    
    for (final key in keys) {
      try {
        final jsonStr = _mappingsBox.get(key);
        if (jsonStr != null) {
          final mapping = EncryptedFileMapping.fromJsonString(jsonStr);
          if (mapping.accountId == accountId) {
            keysToDelete.add(key as String);
          }
        }
      } catch (e) {
        // Skip invalid entries
      }
    }
    
    await _mappingsBox.deleteAll(keysToDelete);
  }

  /// Delete all mappings for a specific parent folder
  Future<void> deleteMappingsForParent(String parentId) async {
    if (!isInitialized) {
      await initialize();
    }
    
    final keysToDelete = <String>[];
    final keys = _mappingsBox.keys.toList();
    
    for (final key in keys) {
      try {
        final jsonStr = _mappingsBox.get(key);
        if (jsonStr != null) {
          final mapping = EncryptedFileMapping.fromJsonString(jsonStr);
          if (mapping.parentId == parentId) {
            keysToDelete.add(key as String);
          }
        }
      } catch (e) {
        // Skip invalid entries
      }
    }
    
    await _mappingsBox.deleteAll(keysToDelete);
  }

  /// Check if a filename is an encrypted filename (matches our pattern)
  bool isEncryptedFilename(String fileName) {
    // Check if it ends with .enc and matches our pattern
    if (!fileName.endsWith('.enc')) {
      return false;
    }
    
    // Remove .enc extension
    final baseName = fileName.substring(0, fileName.length - 4);
    
    // Check format: XXXX-XXXX-XXXX-XXXX (4 groups of 4 hex chars)
    final parts = baseName.split('-');
    if (parts.length != 4) {
      return false;
    }
    
    // Each part should be exactly 4 hex characters
    return parts.every((part) => part.length == 4 && int.tryParse(part, radix: 16) != null);
  }

  /// Get all encrypted filenames in the mappings
  List<String> getAllEncryptedFilenames() {
    if (!isInitialized) {
      return [];
    }
    return _mappingsBox.keys.cast<String>().toList();
  }

  /// Get total number of mappings
  int get mappingsCount {
    if (!isInitialized) {
      return 0;
    }
    return _mappingsBox.length;
  }

  /// Clear all mappings (use with caution!)
  Future<void> clearAll() async {
    if (!isInitialized) {
      await initialize();
    }
    await _mappingsBox.clear();
    
    // Also clear the cache
    _nameCache.clear();
    
  }

  /// Close the Hive box
  Future<void> close() async {
    if (isInitialized) {
      await _mappingsBox.close();
    }
  }
}