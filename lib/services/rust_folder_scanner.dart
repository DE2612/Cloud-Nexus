import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:convert';
import 'package:cloud_nexus/generated/cloud_nexus_encryption_bindings.dart';
import 'package:ffi/ffi.dart' show calloc;

/// Represents a single file or folder in a folder scan
class FolderScanItem {
  final String name;
  final String path;
  final bool isFolder;
  final int size;
  final int depth;

  FolderScanItem({
    required this.name,
    required this.path,
    required this.isFolder,
    required this.size,
    required this.depth,
  });

  factory FolderScanItem.fromJson(Map<String, dynamic> json) {
    return FolderScanItem(
      name: json['name'] as String,
      path: json['path'] as String,
      isFolder: json['isFolder'] as bool,
      size: json['size'] as int,
      depth: json['depth'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'path': path,
      'isFolder': isFolder,
      'size': size,
      'depth': depth,
    };
  }

  String get sizeHuman => RustFolderScanner._formatBytes(size);
}

/// Result of a folder scan operation
class FolderScanResult {
  final String rootPath;
  final List<FolderScanItem> items;
  final int fileCount;
  final int folderCount;
  final int totalSize;
  final int durationMs;
  final bool success;
  final String? error;

  FolderScanResult({
    required this.rootPath,
    required this.items,
    required this.fileCount,
    required this.folderCount,
    required this.totalSize,
    required this.durationMs,
    required this.success,
    this.error,
  });

  factory FolderScanResult.fromJson(Map<String, dynamic> json) {
    return FolderScanResult(
      rootPath: json['rootPath'] as String,
      items: (json['items'] as List<dynamic>)
          .map((item) => FolderScanItem.fromJson(item as Map<String, dynamic>))
          .toList(),
      fileCount: json['fileCount'] as int,
      folderCount: json['folderCount'] as int,
      totalSize: json['totalSize'] as int,
      durationMs: json['durationMs'] as int,
      success: json['success'] as bool,
      error: json['error'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'rootPath': rootPath,
      'items': items.map((item) => item.toJson()).toList(),
      'fileCount': fileCount,
      'folderCount': folderCount,
      'totalSize': totalSize,
      'durationMs': durationMs,
      'success': success,
      if (error != null) 'error': error,
    };
  }

  String get totalSizeHuman => RustFolderScanner._formatBytes(totalSize);

  List<FolderScanItem> get files => items.where((item) => !item.isFolder).toList();

  List<FolderScanItem> get folders => items.where((item) => item.isFolder).toList();
}

/// Scanner service for fast folder scanning using Rust
class RustFolderScanner {
  static CloudNexusEncryption? _nativeLib;

  /// Initialize native library
  static Future<void> initialize() async {
    if (_nativeLib != null) return;

    try {
      final dylib = ffi.DynamicLibrary.open('cloud_nexus_encryption.dll');
      _nativeLib = CloudNexusEncryption(dylib);
    } catch (e) {
      rethrow;
    }
  }

  /// Convert String to native UTF-8 char pointer
  static ffi.Pointer<ffi.Char> _stringToNativeChar(String str) {
    final units = utf8.encode(str);
    final result = calloc<ffi.Char>(units.length + 1);
    for (int i = 0; i < units.length; i++) {
      result.elementAt(i).value = units[i];
    }
    result.elementAt(units.length).value = 0; // Null terminator
    return result;
  }

  /// Scan a folder using Rust
  ///
  /// Returns a [FolderScanResult] with file/folder information
  static Future<FolderScanResult> scanFolder(
    String folderPath, {
    int? maxDepth,
  }) async {
    await initialize();
    if (_nativeLib == null) {
      throw Exception('Native library not initialized');
    }

    // Convert maxDepth to u32 (0 = unlimited)
    final maxDepthValue = maxDepth != null && maxDepth > 0 ? maxDepth : 0;

    final pathPtr = _stringToNativeChar(folderPath);
    final outputLenPtr = calloc<ffi.Size>();

    try {
      final contextPtr = _nativeLib!.scan_folder_init(pathPtr, maxDepthValue);

      if (contextPtr == ffi.nullptr) {
        throw Exception('Failed to initialize folder scan');
      }

      try {
        final jsonPtr = _nativeLib!.scan_folder_get_json(contextPtr, outputLenPtr);

        if (jsonPtr == ffi.nullptr) {
          // Check for error
          final errorLenPtr = calloc<ffi.Size>();
          final errorPtr = _nativeLib!.scan_folder_get_error(contextPtr, errorLenPtr);
          if (errorPtr != ffi.nullptr) {
            final errorLen = errorLenPtr.value;
            final errorBytes = Uint8List(errorLen);
            for (int i = 0; i < errorLen; i++) {
              errorBytes[i] = errorPtr.cast<ffi.Uint8>().elementAt(i).value;
            }
            final errorStr = utf8.decode(errorBytes);
            _nativeLib!.scan_folder_free_string(errorPtr);
            calloc.free(errorLenPtr);
            throw Exception('Folder scan failed: $errorStr');
          }
          calloc.free(errorLenPtr);
          throw Exception('Folder scan failed: unknown error');
        }

        final jsonLen = outputLenPtr.value;
        final jsonBytes = Uint8List(jsonLen);
        for (int i = 0; i < jsonLen; i++) {
          jsonBytes[i] = jsonPtr.cast<ffi.Uint8>().elementAt(i).value;
        }

        final jsonStr = utf8.decode(jsonBytes);
        _nativeLib!.scan_folder_free_string(jsonPtr);

        final Map<String, dynamic> jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
        final result = FolderScanResult.fromJson(jsonMap);


        return result;
      } finally {
        _nativeLib!.scan_folder_free(contextPtr);
      }
    } finally {
      calloc.free(outputLenPtr);
      calloc.free(pathPtr);
    }
  }

  /// Quick folder scan - returns JSON directly
  ///
  /// More efficient than [scanFolder] for simple operations
  static Future<FolderScanResult> scanFolderQuick(
    String folderPath, {
    int? maxDepth,
  }) async {
    await initialize();
    if (_nativeLib == null) {
      throw Exception('Native library not initialized');
    }

    // Convert maxDepth to u32 (0 = unlimited)
    final maxDepthValue = maxDepth != null && maxDepth > 0 ? maxDepth : 0;

    final pathPtr = _stringToNativeChar(folderPath);
    final outputLenPtr = calloc<ffi.Size>();

    try {
      final jsonPtr = _nativeLib!.scan_folder_quick(
        pathPtr,
        maxDepthValue,
        outputLenPtr,
      );

      if (jsonPtr == ffi.nullptr) {
        throw Exception('Folder scan failed: unknown error');
      }

      try {
        final jsonLen = outputLenPtr.value;
        final jsonBytes = Uint8List(jsonLen);
        for (int i = 0; i < jsonLen; i++) {
          jsonBytes[i] = jsonPtr.cast<ffi.Uint8>().elementAt(i).value;
        }

        final jsonStr = utf8.decode(jsonBytes);
        final Map<String, dynamic> jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
        final result = FolderScanResult.fromJson(jsonMap);


        return result;
      } finally {
        _nativeLib!.scan_folder_free_string(jsonPtr);
      }
    } finally {
      calloc.free(outputLenPtr);
      calloc.free(pathPtr);
    }
  }

  /// Format bytes to human-readable string
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}