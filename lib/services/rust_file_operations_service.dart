/// Rust File Operations Service
///
/// This service provides a simplified Dart wrapper around the Rust FFI bindings
/// for file operations (upload, download, copy).
///
/// Key features:
/// - Throttled progress updates
/// - Cancellation support
/// - Memory-efficient streaming
import 'dart:ffi';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart' as ffi;
import 'package:path/path.dart' as path;
import '../generated/cloud_nexus_encryption_bindings.dart';

/// Error codes matching Rust definitions
const int SUCCESS = 0;
const int ERROR_NULL_POINTER = -1;
const int ERROR_FILE_NOT_FOUND = -2;
const int ERROR_PERMISSION_DENIED = -3;
const int ERROR_DISK_FULL = -4;
const int ERROR_INVALID_PATH = -5;
const int ERROR_IO_FAILED = -6;
const int ERROR_CANCELLED = -7;

/// Main service class for Rust file operations
class RustFileOperationsService {
  static CloudNexusEncryption? _nativeLib;
  static bool _initialized = false;

  // Operation cancellation flags
  static final Map<String, Pointer<Int32>> _cancelFlags = {};

  /// Initialize the native library
  static Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      _nativeLib = await _loadNativeLibrary();
      _initialized = true;
    } catch (e) {
      throw RustFileOperationException(
        'Failed to load native library: $e',
        ERROR_IO_FAILED,
      );
    }
  }

  static Future<CloudNexusEncryption> _loadNativeLibrary() async {
    try {
      final dylib = DynamicLibrary.open('cloud_nexus_encryption.dll');
      return CloudNexusEncryption(dylib);
    } catch (e) {
      try {
        final dylib = DynamicLibrary.open('assets/cloud_nexus_encryption.dll');
        return CloudNexusEncryption(dylib);
      } catch (e2) {
        rethrow;
      }
    }
  }

  /// Upload a file using Rust for I/O and encryption
  ///
  /// Returns a stream of encrypted chunks for HTTP upload
  static Stream<Uint8List> uploadFileStream({
    required String localPath,
    Uint8List? masterKey,
    bool shouldEncrypt = false,
    void Function(int bytesProcessed, int totalBytes)? onProgress,
    String? cancelToken,
  }) async* {
    
    await initialize();
    final lib = _nativeLib!;
    final operationId = cancelToken ?? DateTime.now().millisecondsSinceEpoch.toString();
    
    // Create cancellation flag
    final cancelFlag = ffi.calloc<Int32>();
    cancelFlag.value = 0;
    _cancelFlags[operationId] = cancelFlag;
    
    final pathPointer = localPath.toNativeUtf8().cast<Char>();
    final keyPointer = masterKey != null 
        ? (ffi.calloc<Uint8>(masterKey.length)..asTypedList(masterKey.length).setAll(0, masterKey))
        : nullptr;
    
    try {
      // Initialize upload context
      final context = lib.upload_init(
        pathPointer,
        keyPointer,
        masterKey?.length ?? 0,
        1024 * 1024, // 1MB chunks
        shouldEncrypt ? 1 : 0,
        nullptr, // No progress callback in simple mode
        nullptr, // No data callback in simple mode
        cancelFlag.cast(),
        nullptr,
      );
      
      if (context == nullptr) {
        throw RustFileOperationException(
          'Failed to initialize upload context',
          ERROR_IO_FAILED,
        );
      }
      
      // Allocate buffer for encrypted chunks
      final buffer = ffi.calloc<Uint8>(2 * 1024 * 1024);
      
      try {
        // Get file size for progress
        final totalBytes = lib.upload_get_total_bytes(context);
        var bytesProcessed = 0;
        var lastProgressUpdate = 0;
        
        // Process chunks until done
        while (true) {
          if (cancelFlag.value != 0) {
            throw RustFileOperationException('Upload cancelled', ERROR_CANCELLED);
          }
          
          final result = lib.upload_process_chunk(
            context,
            buffer,
            2 * 1024 * 1024,
            nullptr,
            nullptr,
            nullptr,
          );
          
          if (result <= 0) {
            if (result < 0) {
              throw RustFileOperationException(
                'Upload chunk failed with error: $result',
                result.toInt(),
              );
            }
            break;
          }
          
          // Yield encrypted chunk
          final chunk = Uint8List(result);
          buffer.asTypedList(result).setAll(0, chunk);
          yield chunk;
          
          // Update progress
          bytesProcessed += result;
          if (totalBytes > 0 && bytesProcessed - lastProgressUpdate >= totalBytes ~/ 100) {
            lastProgressUpdate = bytesProcessed;
            onProgress?.call(bytesProcessed, totalBytes);
          }
        }
        
        // Final progress update
        onProgress?.call(bytesProcessed, totalBytes);
        
      } finally {
        ffi.calloc.free(buffer);
      }
      
      // Finalize
      lib.upload_finalize(context);
      lib.upload_free(context);
      
    } finally {
      _cancelFlags.remove(operationId);
      ffi.calloc.free(cancelFlag);
      ffi.calloc.free(pathPointer);
      if (keyPointer != nullptr) {
        ffi.calloc.free(keyPointer);
      }
    }
  }

  /// Download a file using Rust for I/O and decryption
  static Future<void> downloadFile({
    required String localPath,
    Uint8List? masterKey,
    bool shouldDecrypt = false,
    void Function(int bytesWritten, int totalBytes)? onProgress,
    String? cancelToken,
    Stream<Uint8List>? encryptedChunks,
  }) async {
    
    await initialize();
    final lib = _nativeLib!;
    final operationId = cancelToken ?? DateTime.now().millisecondsSinceEpoch.toString();
    
    final cancelFlag = ffi.calloc<Int32>();
    cancelFlag.value = 0;
    _cancelFlags[operationId] = cancelFlag;
    
    final pathPointer = localPath.toNativeUtf8().cast<Char>();
    final keyPointer = masterKey != null 
        ? (ffi.calloc<Uint8>(masterKey.length)..asTypedList(masterKey.length).setAll(0, masterKey))
        : nullptr;
    
    try {
      final context = lib.download_init(
        pathPointer,
        keyPointer,
        masterKey?.length ?? 0,
        shouldDecrypt ? 1 : 0,
        nullptr,
        cancelFlag.cast(),
        nullptr,
      );
      
      if (context == nullptr) {
        throw RustFileOperationException(
          'Failed to initialize download context',
          ERROR_IO_FAILED,
        );
      }
      
      var bytesWritten = 0;
      
      if (encryptedChunks != null) {
        await for (final chunk in encryptedChunks) {
          if (cancelFlag.value != 0) {
            throw RustFileOperationException('Download cancelled', ERROR_CANCELLED);
          }
          
          final buffer = ffi.calloc<Uint8>(chunk.length);
          buffer.asTypedList(chunk.length).setAll(0, chunk);
          
          try {
            final result = lib.download_append_chunk(
              context,
              buffer,
              chunk.length,
              nullptr,
              nullptr,
            );
            
            if (result < 0) {
              throw RustFileOperationException(
                'Download chunk failed: $result',
                result,
              );
            }
            
            bytesWritten += chunk.length;
            onProgress?.call(bytesWritten, 0);
          } finally {
            ffi.calloc.free(buffer);
          }
        }
      }
      
      lib.download_finalize(context);
      lib.download_free(context);
      
      final total = lib.download_get_total_bytes(context);
      onProgress?.call(bytesWritten, total > 0 ? total : bytesWritten);
      
    } finally {
      _cancelFlags.remove(operationId);
      ffi.calloc.free(cancelFlag);
      ffi.calloc.free(pathPointer);
      if (keyPointer != nullptr) {
        ffi.calloc.free(keyPointer);
      }
    }
  }

  /// Copy a file using Rust for I/O
  static Future<void> copyFile({
    required String sourcePath,
    required String destPath,
    int chunkSize = 1024 * 1024,
    void Function(int bytesCopied, int totalBytes)? onProgress,
    String? cancelToken,
  }) async {
    
    await initialize();
    final lib = _nativeLib!;
    final operationId = cancelToken ?? DateTime.now().millisecondsSinceEpoch.toString();
    
    final cancelFlag = ffi.calloc<Int32>();
    cancelFlag.value = 0;
    _cancelFlags[operationId] = cancelFlag;
    
    final sourcePointer = sourcePath.toNativeUtf8().cast<Char>();
    final destPointer = destPath.toNativeUtf8().cast<Char>();
    
    try {
      final result = lib.copy_file_streaming(
        sourcePointer,
        destPointer,
        chunkSize,
        nullptr,
        cancelFlag.cast(),
        nullptr,
      );
      
      if (result < 0) {
        throw RustFileOperationException('File copy failed: $result', result);
      }
      
      
    } finally {
      _cancelFlags.remove(operationId);
      ffi.calloc.free(cancelFlag);
      ffi.calloc.free(sourcePointer);
      ffi.calloc.free(destPointer);
    }
  }

  /// Copy a folder recursively using Rust
  static Future<void> copyFolder({
    required String sourcePath,
    required String destPath,
    int chunkSize = 1024 * 1024,
    void Function(int bytesCopied, int totalBytes)? onProgress,
    String? cancelToken,
  }) async {
    
    await initialize();
    final lib = _nativeLib!;
    final operationId = cancelToken ?? DateTime.now().millisecondsSinceEpoch.toString();
    
    final cancelFlag = ffi.calloc<Int32>();
    cancelFlag.value = 0;
    _cancelFlags[operationId] = cancelFlag;
    
    final sourcePointer = sourcePath.toNativeUtf8().cast<Char>();
    final destPointer = destPath.toNativeUtf8().cast<Char>();
    final destBuffer = ffi.calloc<Char>(4096);
    
    try {
      final context = lib.folder_copy_init(
        sourcePointer,
        destPointer,
        cancelFlag.cast(),
      );
      
      if (context == nullptr) {
        throw RustFileOperationException(
          'Failed to initialize folder copy',
          ERROR_IO_FAILED,
        );
      }
      
      int filesCopied = 0;
      while (true) {
        if (cancelFlag.value != 0) {
          throw RustFileOperationException('Folder copy cancelled', ERROR_CANCELLED);
        }
        
        final result = lib.folder_copy_next_file(context, destBuffer, 4096);
        
        if (result == 0) break;
        if (result < 0) {
          final currentFile = destBuffer.cast<ffi.Utf8>().toDartString();
          throw RustFileOperationException(
            'Folder copy failed at: $currentFile',
            result,
          );
        }
        filesCopied++;
      }
      
      lib.folder_copy_finalize(context);
      lib.copy_free(context);
      
      
    } finally {
      _cancelFlags.remove(operationId);
      ffi.calloc.free(cancelFlag);
      ffi.calloc.free(sourcePointer);
      ffi.calloc.free(destPointer);
      ffi.calloc.free(destBuffer);
    }
  }

  /// Scan a directory and return list of entries
  Future<List<Map<String, dynamic>>> scanDirectory(String folderPath) async {
    await initialize();
    
    final entries = <Map<String, dynamic>>[];
    final folder = Directory(folderPath);
    
    if (!await folder.exists()) {
      throw RustFileOperationException('Folder not found: $folderPath', ERROR_FILE_NOT_FOUND);
    }
    
    await for (final entity in folder.list(recursive: true, followLinks: false)) {
      final relativePath = path.relative(entity.path, from: folderPath);
      
      if (entity is File) {
        final fileSize = await entity.length();
        entries.add({
          'path': entity.path,
          'relativePath': relativePath,
          'isFolder': false,
          'size': fileSize,
        });
      } else if (entity is Directory) {
        entries.add({
          'path': entity.path,
          'relativePath': relativePath,
          'isFolder': true,
          'size': 0,
        });
      }
    }
    
    // Sort: folders first, then files
    entries.sort((a, b) {
      if (a['isFolder'] && !b['isFolder']) return -1;
      if (!a['isFolder'] && b['isFolder']) return 1;
      return (a['relativePath'] as String).compareTo(b['relativePath'] as String);
    });
    
    return entries;
  }

  /// Encrypt a file using existing Rust upload stream (encrypted chunks)
  Stream<Uint8List> createEncryptedUploadStream({
    required String localPath,
    required Uint8List masterKey,
    void Function(int bytesProcessed, int totalBytes)? onProgress,
    String? cancelToken,
  }) {
    // Use the existing uploadFileStream method which handles encryption
    return uploadFileStream(
      localPath: localPath,
      masterKey: masterKey,
      shouldEncrypt: true,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Create an upload stream for a file (non-encrypted)
  Future<Stream<Uint8List>> createUploadStream(String filePath) async {
    final file = File(filePath);
    final fileSize = await file.length();
    
    return _createChunkedUploadStream(file, fileSize);
  }

  /// Create a chunked upload stream
  Stream<Uint8List> _createChunkedUploadStream(File file, int fileSize) async* {
    const chunkSize = 1024 * 1024; // 1MB chunks
    final buffer = BytesBuilder();
    
    await for (final chunk in file.openRead()) {
      buffer.add(chunk);
      
      while (buffer.length >= chunkSize) {
        final data = buffer.takeBytes();
        yield Uint8List.fromList(data.sublist(0, chunkSize));
        buffer.add(data.sublist(chunkSize));
      }
    }
    
    // Yield remaining data
    if (buffer.length > 0) {
      yield Uint8List.fromList(buffer.takeBytes());
    }
  }

  /// Get file metadata
  Future<Map<String, dynamic>> getFileMetadata(String filePath) async {
    final file = File(filePath);
    final stat = await file.stat();
    
    return {
      'path': filePath,
      'size': stat.size,
      'modified': stat.modified.millisecondsSinceEpoch,
      'exists': await file.exists(),
      'isFile': stat.type == FileSystemEntityType.file,
      'isDirectory': stat.type == FileSystemEntityType.directory,
    };
  }

  /// Cancel an ongoing operation
  static void cancelOperation(String cancelToken) {
    final cancelFlag = _cancelFlags[cancelToken];
    if (cancelFlag != null) {
      cancelFlag.value = 1;
    }
  }

  /// Clean up resources
  static void dispose() {
    for (final cancelFlag in _cancelFlags.values) {
      cancelFlag.value = 1;
      ffi.calloc.free(cancelFlag);
    }
    _cancelFlags.clear();
    _initialized = false;
    _nativeLib = null;
  }
}

/// Exception for Rust file operation errors
class RustFileOperationException implements Exception {
  final String message;
  final int errorCode;

  RustFileOperationException(this.message, this.errorCode);

  @override
  String toString() => 'RustFileOperationException: $message (code: $errorCode)';
}