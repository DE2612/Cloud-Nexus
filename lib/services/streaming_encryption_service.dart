import 'dart:io';
import 'dart:typed_data';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:cloud_nexus/generated/cloud_nexus_encryption_bindings.dart';
import '../utils/throttled_logger.dart';

/// Progress callback for streaming encryption/decryption operations
typedef StreamingProgressCallback = void Function(int bytesProcessed, int totalBytes);

/// Extension to allocate native pointer from Uint8List
extension Uint8ListPointer on Uint8List {
  ffi.Pointer<ffi.Uint8> allocatePointer() {
    final ptr = calloc<ffi.Uint8>(length);
    for (int i = 0; i < length; i++) {
      ptr[i] = this[i];
    }
    return ptr;
  }
}

/// Streaming Encryption Service for large files
///
/// This service uses the native streaming encryption functions to encrypt/decrypt
/// files in chunks (1MB each) without loading the entire file into memory.
/// 
/// Memory usage: ~2-5MB regardless of file size (1MB chunk buffer + encryption overhead)
/// 
/// Format:
/// [Main Header 12 bytes] + [Wrapped FEK] + [Chunk Header 20 bytes] + [Encrypted Data] + ...
/// Main Header: [Magic 4 bytes: CNER] + [Version 1 byte] + [Reserved 3 bytes] + [FEK Length 4 bytes]
/// Chunk Header: [Index 4 bytes] + [Size 4 bytes] + [Nonce 12 bytes]
/// Encrypted Data: Ciphertext + MAC (16 bytes)
class StreamingEncryptionService {
  static const int _magic = 0x434E4552;
  static const int _version = 1;
  static const int _magicSize = 4;
  static const int _versionSize = 1;
  static const int _reservedSize = 3;
  static const int _fekLengthSize = 4;
  static const int _nonceSize = 12;
  static const int _macSize = 16;
  static const int _chunkHeaderSize = 20; // index(4) + size(4) + nonce(12)
  static const int _headerSize = _magicSize + _versionSize + _reservedSize + _fekLengthSize;
  static const int _keySize = 32;
  
  // Chunk size for streaming (1MB)
  static const int _chunkSize = 1024 * 1024;
  
  static CloudNexusEncryption? _nativeLib;
  
  /// Initialize the native encryption library
  static Future<void> initialize() async {
    if (_nativeLib != null) return;
    
    try {
      String libraryPath = '';
      
      if (Platform.isWindows) {
        final currentDir = Directory.current.path;
        final currentPath = '$currentDir\\cloud_nexus_encryption.dll';
        final currentFile = File(currentPath);
        
        if (await currentFile.exists()) {
          libraryPath = currentPath;
        } else {
          libraryPath = 'cloud_nexus_encryption.dll';
        }
      } else if (Platform.isLinux) {
        libraryPath = 'libcloud_nexus_encryption.so';
      } else {
        libraryPath = 'libcloud_nexus_encryption.dylib';
      }
      
      final library = ffi.DynamicLibrary.open(libraryPath);
      _nativeLib = CloudNexusEncryption(library);
      
      logger.debug('[StreamingEncryptionService] Native library loaded');
    } catch (e) {
      logger.error('[StreamingEncryptionService] Failed to load native library: $e');
      rethrow;
    }
  }
  
  /// Encrypt a file using streaming encryption
  ///
  /// This method reads the input file in chunks and encrypts each chunk
  /// separately, keeping memory usage low (~5MB).
  ///
  /// Parameters:
  /// - inputFile: Source file to encrypt
  /// - outputFile: Destination file for encrypted data
  /// - masterKey: 32-byte master encryption key
  /// - onProgress: Optional progress callback
  static Future<void> encryptFileStreaming(
    File inputFile,
    File outputFile,
    Uint8List masterKey, {
    StreamingProgressCallback? onProgress,
  }) async {
    
    await initialize();
    
    if (_nativeLib == null) {
      throw Exception('Native encryption library not initialized');
    }
    
    if (masterKey.length != _keySize) {
      throw Exception('Master key must be 32 bytes, got ${masterKey.length}');
    }
    
    logger.info('🔐 [StreamingEncryptionService] Encrypting file: ${inputFile.path}');
    
    // Get file size
    final fileSize = await inputFile.length();
    
    logger.debug('[StreamingEncryptionService] File size: ${_formatBytes(fileSize)}');
    
    // Initialize encryption context
    final masterKeyPtr = masterKey.allocatePointer();
    final outputLenPtr = calloc<ffi.Size>();
    
    ffi.Pointer<EncryptionContext>? initResult;
    
    try {
      // Initialize encryption context (generates FEK and wraps it)
      initResult = _nativeLib!.encrypt_file_init(
        masterKeyPtr,
        masterKey.length,
        outputLenPtr,
      );
      
      if (initResult == ffi.nullptr) {
        throw Exception('Failed to initialize encryption context');
      }
      
      // Get wrapped FEK bytes from the encryption context
      final wrappedFekLenPtr = calloc<ffi.Size>();
      final wrappedFekPtr = _nativeLib!.encrypt_file_get_wrapped_fek(
        initResult,
        wrappedFekLenPtr,
      );
      
      if (wrappedFekPtr == ffi.nullptr) {
        throw Exception('Failed to retrieve wrapped FEK');
      }
      
      final wrappedFekLen = wrappedFekLenPtr.value;
      logger.debug('[StreamingEncryptionService] Wrapped FEK size: $wrappedFekLen bytes');
      
      // Copy wrapped FEK bytes
      final wrappedFek = Uint8List(wrappedFekLen);
      for (int i = 0; i < wrappedFekLen; i++) {
        wrappedFek[i] = wrappedFekPtr.cast<ffi.Uint8>()[i];
      }
      
      // Free the wrapped FEK buffer
      _nativeLib!.free_buffer(wrappedFekPtr);
      calloc.free(wrappedFekLenPtr);
      
      // Create output sink
      final sink = outputFile.openWrite();
      int totalBytesWritten = 0;
      
      try {
        // Write main header
        final headerBuilder = BytesBuilder();
        
        // Magic bytes (little-endian)
        headerBuilder.addByte(_magic & 0xFF);
        headerBuilder.addByte((_magic >> 8) & 0xFF);
        headerBuilder.addByte((_magic >> 16) & 0xFF);
        headerBuilder.addByte((_magic >> 24) & 0xFF);
        
        // Version
        headerBuilder.addByte(_version);
        
        // Reserved (3 bytes)
        headerBuilder.addByte(0);
        headerBuilder.addByte(0);
        headerBuilder.addByte(0);
        
        // FEK length (little-endian) - use actual wrapped FEK length
        headerBuilder.addByte(wrappedFekLen & 0xFF);
        headerBuilder.addByte((wrappedFekLen >> 8) & 0xFF);
        headerBuilder.addByte((wrappedFekLen >> 16) & 0xFF);
        headerBuilder.addByte((wrappedFekLen >> 24) & 0xFF);
        
        final headerBytes = headerBuilder.toBytes();
        sink.add(headerBytes);
        await sink.flush();
        totalBytesWritten += headerBytes.length;
        
        // Write wrapped FEK
        sink.add(wrappedFek);
        await sink.flush();
        totalBytesWritten += wrappedFekLen;
        
        // Process all chunks
        int bytesProcessed = 0;
        int chunkIndex = 0;
        
        while (bytesProcessed < fileSize) {
          final remainingBytes = fileSize - bytesProcessed;
          final chunkSize = _chunkSize.min(remainingBytes);
          
          
          // Read chunk - use RandomAccessFile for precise chunk reading
          final raf = await inputFile.open(mode: FileMode.read);
          await raf.setPosition(bytesProcessed);
          final chunkBytes = await raf.read(chunkSize);
          await raf.close();
          
          
          // Encrypt chunk
          final chunkPtr = chunkBytes.allocatePointer();
          final chunkOutputLenPtr = calloc<ffi.Size>();
          
          final encryptedChunk = _nativeLib!.encrypt_chunk(
            initResult,
            chunkPtr,
            chunkBytes.length,
            chunkIndex,
            chunkOutputLenPtr,
          );
          
          if (encryptedChunk == ffi.nullptr) {
            throw Exception('Failed to encrypt chunk $chunkIndex');
          }
          
          final encryptedLen = chunkOutputLenPtr.value;
          
          // Log encryption details
          
          // Write encrypted chunk
          final encryptedChunkBytes = Uint8List(encryptedLen);
          for (int i = 0; i < encryptedLen; i++) {
            encryptedChunkBytes[i] = encryptedChunk.cast<ffi.Uint8>()[i];
          }
          
          sink.add(encryptedChunkBytes);
          await sink.flush();
          totalBytesWritten += encryptedLen;
          
          
          // Free chunk
          _nativeLib!.free_buffer(encryptedChunk);
          calloc.free(chunkPtr);
          calloc.free(chunkOutputLenPtr);
          
          bytesProcessed += chunkSize;
          chunkIndex++;
          
          // Progress callback
          onProgress?.call(bytesProcessed, fileSize);
          
          if (chunkIndex % 100 == 0) {
          }
        }
        
        
        // Close sink
        await sink.close();
        
        final outputSize = await outputFile.length();
        final expectedSize = fileSize + _headerSize + wrappedFekLen + (chunkIndex * (_chunkHeaderSize + _macSize));
        
        onProgress?.call(fileSize, fileSize);
        logger.success('[StreamingEncryptionService] File encrypted successfully');
        
      } catch (e) {
        await sink.close();
        rethrow;
      }
      
    } finally {
      // Finalize encryption context
      if (initResult != null && initResult != ffi.nullptr) {
        _nativeLib!.encrypt_file_finalize(initResult);
      }
      
      calloc.free(masterKeyPtr);
      calloc.free(outputLenPtr);
    }
  }
  
  /// Decrypt a file using streaming decryption
  ///
  /// This method reads the encrypted file in chunks and decrypts each chunk
  /// separately, keeping memory usage low (~5MB).
  ///
  /// Parameters:
  /// - encryptedFile: Encrypted source file
  /// - outputFile: Destination file for decrypted data
  /// - masterKey: 32-byte master encryption key
  /// - onProgress: Optional progress callback
  static Future<void> decryptFileStreaming(
    File encryptedFile,
    File outputFile,
    Uint8List masterKey, {
    StreamingProgressCallback? onProgress,
  }) async {
    await initialize();
    if (_nativeLib == null) {
      throw Exception('Native encryption library not initialized');
    }
    
    if (masterKey.length != _keySize) {
      throw Exception('Master key must be 32 bytes');
    }
    
    logger.info('[StreamingEncryptionService] Decrypting file: ${encryptedFile.path}');
    
    // Get file size
    final fileSize = await encryptedFile.length();
    logger.debug('[StreamingEncryptionService] Encrypted file size: ${_formatBytes(fileSize)}');
    
    // Read header using RandomAccessFile
    final raf = await encryptedFile.open(mode: FileMode.read);
    final header = await raf.read(_headerSize);
    await raf.close();
    
    // Validate magic bytes
    final magic = ByteData.sublistView(header, 0, _magicSize).getUint32(0, Endian.little);
    if (magic != _magic) {
      throw Exception('Invalid encrypted file: wrong magic bytes');
    }
    
    // Validate version
    final version = header[_magicSize];
    if (version != _version) {
      throw Exception('Unsupported encrypted file version: $version');
    }
    
    // Get wrapped FEK length
    final fekLen = ByteData.sublistView(header, _headerSize - 4, _headerSize).getUint32(0, Endian.little);
    logger.debug('[StreamingEncryptionService] Wrapped FEK length: $fekLen bytes');
    
    // Read header + wrapped FEK using RandomAccessFile
    final headerAndFekSize = _headerSize + fekLen;
    final raf2 = await encryptedFile.open(mode: FileMode.read);
    final headerAndFek = await raf2.read(headerAndFekSize);
    await raf2.close();
    
    
    // Initialize decryption context
    final headerAndFekPtr = headerAndFek.allocatePointer();
    final masterKeyPtr = masterKey.allocatePointer();
    
    ffi.Pointer<DecryptionContext>? initResult;
    
    try {
      initResult = _nativeLib!.decrypt_file_init(
        headerAndFekPtr,
        headerAndFek.length,
        masterKeyPtr,
        masterKey.length,
      );
      
      if (initResult == ffi.nullptr) {
        throw Exception('Failed to initialize decryption context - wrong password or corrupted file');
      }
      
      // Create output sink
      final sink = outputFile.openWrite();
      
      try {
        // Read and decrypt chunks
        int bytesProcessed = headerAndFekSize;
        int totalDecrypted = 0;
        
        while (bytesProcessed < fileSize) {
          // Read chunk header using RandomAccessFile
          final raf = await encryptedFile.open(mode: FileMode.read);
          await raf.setPosition(bytesProcessed);
          final chunkHeader = await raf.read(_chunkHeaderSize);
          
          // Parse chunk header
          final chunkIndex = ByteData.sublistView(chunkHeader, 0, 4).getUint32(0, Endian.little);
          final chunkSize = ByteData.sublistView(chunkHeader, 4, 8).getUint32(0, Endian.little);
          
          // Read encrypted chunk (header + data)
          // Note: chunkSize already includes the MAC tag (ciphertext + MAC from AES-GCM)
          final encryptedChunkSize = _chunkHeaderSize + chunkSize;
          await raf.setPosition(bytesProcessed);
          final encryptedChunk = await raf.read(encryptedChunkSize);
          await raf.close();
          
          
          // Decrypt chunk
          final encryptedChunkPtr = encryptedChunk.allocatePointer();
          final outputLenPtr = calloc<ffi.Size>();
          
          final decryptedChunk = _nativeLib!.decrypt_chunk(
            initResult,
            encryptedChunkPtr,
            encryptedChunk.length,
            outputLenPtr,
          );
          
          if (decryptedChunk == ffi.nullptr) {
            throw Exception('Failed to decrypt chunk $chunkIndex');
          }
          
          final decryptedLen = outputLenPtr.value;
          
          // Write decrypted chunk
          final decryptedChunkBytes = Uint8List(decryptedLen);
          for (int i = 0; i < decryptedLen; i++) {
            decryptedChunkBytes[i] = decryptedChunk.cast<ffi.Uint8>()[i];
          }
          sink.add(decryptedChunkBytes);
          
          // Free chunk
          _nativeLib!.free_buffer(decryptedChunk);
          calloc.free(encryptedChunkPtr);
          calloc.free(outputLenPtr);
          
          bytesProcessed += encryptedChunkSize;
          totalDecrypted += decryptedLen;
          
          // Progress callback
          onProgress?.call(totalDecrypted, fileSize);
          
          if (chunkIndex % 10 == 0) {
            logger.debug('[StreamingEncryptionService] Decrypted: ${_formatBytes(totalDecrypted)} bytes');
          }
        }
        
        // Close sink
        await sink.close();
        
        onProgress?.call(totalDecrypted, fileSize);
        logger.success('[StreamingEncryptionService] File decrypted successfully');
        
      } catch (e) {
        await sink.close();
        rethrow;
      }
      
    } finally {
      // Finalize decryption context
      if (initResult != null && initResult != ffi.nullptr) {
        _nativeLib!.decrypt_file_finalize(initResult);
      }
      
      calloc.free(headerAndFekPtr);
      calloc.free(masterKeyPtr);
    }
  }
  
  /// Check if a file is in the new encrypted format
  static Future<bool> isEncryptedFile(File file) async {
    if (await file.length() < _magicSize) return false;
    
    final bytes = await file.openRead(0, _magicSize).first;
    final data = Uint8List.fromList(bytes);
    final magic = ByteData.sublistView(data, 0, _magicSize).getUint32(0, Endian.little);
    
    return magic == _magic;
  }
  
  /// Format bytes to human-readable string
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Extension to find minimum of two integers
extension IntExtension on int {
  int min(int other) => this < other ? this : other;
}
