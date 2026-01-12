import 'dart:typed_data';
import 'dart:io';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:cloud_nexus/generated/cloud_nexus_encryption_bindings.dart';
import 'dart:math' show Random;
import '../utils/throttled_logger.dart';

/// Progress callback for encryption/decryption operations
typedef EncryptionProgressCallback = void Function(int bytesProcessed, int totalBytes);

/// Self-contained encrypted file format with embedded FEK (Option 2: Streaming Encryption)
///
/// File format:
/// [Main Header 12 bytes] + [Wrapped FEK] + [Chunk Header 36 bytes] + [Chunk Data] + ...
/// Main Header: [Magic 4 bytes: CNER] + [Version 1 byte] + [Reserved 3 bytes] + [FEK Length 4 bytes]
/// Chunk Header: [Index 4 bytes] + [Size 4 bytes] + [Nonce 12 bytes] + [MAC 16 bytes]
///
/// Each chunk is encrypted independently with its own nonce, allowing files larger than RAM.
class EncryptedFileFormat {
  // Magic bytes: "CNER" (CloudNexus Encrypted Resource)
  static const int _magic = 0x434E4552;
  static const int _version = 1;
  
  // Header sizes
  static const int _magicSize = 4;
  static const int _versionSize = 1;
  static const int _reservedSize = 3;
  static const int _fekLengthSize = 4;
  static const int _nonceSize = 12;
  static const int _macSize = 16;
  
  // Total header size (before wrapped FEK)
  static const int _headerSize = _magicSize + _versionSize + _reservedSize + _fekLengthSize;
  
  // Key sizes
  static const int _keySize = 32;
  
  // Native encryption library
  static CloudNexusEncryption? _nativeLib;
  
  /// Initialize the native encryption library
  static Future<void> initialize() async {
    if (_nativeLib != null) {
      return;
    }
    
    try {
      // Load the native library
      String libraryPath = '';
      
      if (Platform.isWindows) {
        // Try current directory first
        final currentDir = Directory.current.path;
        final currentPath = '$currentDir\\cloud_nexus_encryption.dll';
        final currentFile = File(currentPath);
        
        if (await currentFile.exists()) {
          libraryPath = currentPath;
        } else {
          // Try assets folder
          final assetsPath = '$currentDir\\assets\\cloud_nexus_encryption.dll';
          final assetsFile = File(assetsPath);
          
          if (await assetsFile.exists()) {
            libraryPath = assetsPath;
          } else {
            // Try executable directory
            final exePath = Platform.resolvedExecutable;
            final exeDir = File(exePath).parent.path;
            final exePathDll = '$exeDir\\cloud_nexus_encryption.dll';
            final exeFile = File(exePathDll);
            
            if (await exeFile.exists()) {
              libraryPath = exePathDll;
            }
                    }
        }
        
        // Fallback to relative path (if libraryPath is still empty)
        if (libraryPath.isEmpty) {
          libraryPath = 'cloud_nexus_encryption.dll';
        }
      } else if (Platform.isLinux) {
        libraryPath = 'libcloud_nexus_encryption.so';
      } else {
        libraryPath = 'libcloud_nexus_encryption.dylib';
      }
      
      
      // Check if file exists
      final dllFile = File(libraryPath);
      if (await dllFile.exists()) {
        logger.debug('DLL file exists at: ${dllFile.absolute.path}');
        logger.debug('DLL size: ${await dllFile.length()} bytes');
      } else {
        logger.error('DLL file NOT found at: ${dllFile.absolute.path}');
        // Try assets path
        final assetsPath = 'assets/$libraryPath';
        final assetsFile = File(assetsPath);
        if (await assetsFile.exists()) {
          logger.debug('DLL found in assets: ${assetsFile.absolute.path}');
        } else {
          logger.error('DLL NOT found in assets either: ${assetsFile.absolute.path}');
        }
      }
      
      final library = ffi.DynamicLibrary.open(libraryPath);
      
      _nativeLib = CloudNexusEncryption(library);
    } catch (e) {
      throw Exception('Failed to load native encryption library: $e');
    }
  }
  
  /// Check if file is in new format
  static bool isValidFormat(Uint8List data) {
    if (data.length < _magicSize) return false;
    final magic = ByteData.sublistView(data, 0, _magicSize).getUint32(0, Endian.little);
    return magic == _magic;
  }
  
  /// Encrypt file with embedded FEK using Rust
  static Future<Uint8List> encryptFile(
    Uint8List plaintext,
    Uint8List masterKey,
  ) async {
    logger.debug('Starting encryption...');
    await initialize();
    if (_nativeLib == null) {
      throw Exception('Native encryption library not initialized');
    }
    
    if (masterKey.length != _keySize) {
      throw Exception('Master key must be 32 bytes, got ${masterKey.length}');
    }
    
    logger.debug('Plaintext size: ${plaintext.length} bytes');
    logger.debug('Master key size: ${masterKey.length} bytes');
    
    // Generate a new FEK for this file
    final fek = _generateRandomKey();
    logger.debug('Generated FEK: ${fek.length} bytes');
    
    // Allocate native pointers
    final fileDataPtr = plaintext.allocatePointer();
    final fekPtr = fek.allocatePointer();
    final masterKeyPtr = masterKey.allocatePointer();
    final outputLenPtr = calloc<ffi.Size>();
    
    try {
      logger.debug('Calling native encryptFile (streaming)...');
      
      // Encrypt file using streaming encryption (generates FEK internally)
      final encryptedPtr = _nativeLib!.encrypt_file(
        fileDataPtr,
        plaintext.length,
        masterKeyPtr,
        masterKey.length,
        outputLenPtr,
      );
      
      if (encryptedPtr == ffi.nullptr) {
        logger.error('Native encryption returned nullptr');
        throw Exception('Encryption failed - native function returned nullptr');
      }
      
      // Copy result to Dart
      final outputLen = outputLenPtr.value;
      logger.debug('Encrypted data size: $outputLen bytes');
      final encryptedData = Uint8List(outputLen);
      for (int i = 0; i < outputLen; i++) {
        encryptedData[i] = encryptedPtr.cast<ffi.Uint8>()[i];
      }
      
      // Free native memory
      _nativeLib!.free_buffer(encryptedPtr);
      
      logger.success('Encryption completed successfully');
      return encryptedData;
    } catch (e, stackTrace) {
      logger.error('Encryption failed: $e');
      logger.error('Stack trace: $stackTrace');
      rethrow;
    } finally {
      // Free allocated pointers
      calloc.free(fileDataPtr);
      calloc.free(fekPtr);
      calloc.free(masterKeyPtr);
      calloc.free(outputLenPtr);
    }
  }
  
  /// Decrypt file with embedded FEK using Rust
  static Future<Uint8List> decryptFile(
    Uint8List encryptedData,
    Uint8List masterKey,
  ) async {
    await initialize();
    if (_nativeLib == null) {
      throw Exception('Native encryption library not initialized');
    }
    
    if (masterKey.length != _keySize) {
      throw Exception('Master key must be 32 bytes');
    }
    
    // Validate minimum size
    if (encryptedData.length < _headerSize + _nonceSize + _macSize) {
      throw Exception('Invalid encrypted file: too small');
    }
    
    // Validate magic bytes
    final magic = ByteData.sublistView(encryptedData, 0, _magicSize).getUint32(0, Endian.little);
    if (magic != _magic) {
      throw Exception('Invalid encrypted file: wrong magic bytes');
    }
    
    // Validate version
    final version = encryptedData[_magicSize];
    if (version != _version) {
      throw Exception('Unsupported encrypted file version: $version');
    }
    
    // Allocate native pointers
    final encryptedDataPtr = encryptedData.allocatePointer();
    final masterKeyPtr = masterKey.allocatePointer();
    final outputLenPtr = calloc<ffi.Size>();
    
    try {
      // Decrypt file using streaming decryption
      final decryptedPtr = _nativeLib!.decrypt_file(
        encryptedDataPtr,
        encryptedData.length,
        masterKeyPtr,
        masterKey.length,
        outputLenPtr,
      );
      
      if (decryptedPtr == ffi.nullptr) {
        throw Exception('Decryption failed - wrong password or corrupted file');
      }
      
      // Copy result to Dart
      final outputLen = outputLenPtr.value;
      final decryptedData = Uint8List(outputLen);
      for (int i = 0; i < outputLen; i++) {
        decryptedData[i] = decryptedPtr.cast<ffi.Uint8>()[i];
      }
      
      // Free native memory
      _nativeLib!.free_buffer(decryptedPtr);
      
      return decryptedData;
    } finally {
      // Free allocated pointers
      calloc.free(encryptedDataPtr);
      calloc.free(masterKeyPtr);
      calloc.free(outputLenPtr);
    }
  }
  
  /// Derive key from password using PBKDF2-HMAC-SHA256
  static Future<Uint8List> deriveKeyFromPassword(
    String password,
    Uint8List salt,
    int iterations,
  ) async {
    
    await initialize();
    
    if (_nativeLib == null) {
      throw Exception('Native encryption library not initialized');
    }
    
    // Allocate native pointers
    final passwordPtr = password.toNativeUtf8().cast<ffi.Char>();
    
    final saltPtr = salt.allocatePointer();
    
    final outputKeyPtr = calloc<ffi.Uint8>(_keySize);
    
    try {
      // Derive key
      final result = _nativeLib!.derive_key_from_password(
        passwordPtr,
        saltPtr,
        salt.length,
        iterations,
        outputKeyPtr,
      );
      
      if (result != 0) {  // 0 = SUCCESS
        throw Exception('Key derivation failed with code: $result');
      }
      
      // Copy result to Dart
      final derivedKey = Uint8List(_keySize);
      for (int i = 0; i < _keySize; i++) {
        derivedKey[i] = outputKeyPtr[i];
      }
      
      return derivedKey;
    } catch (e) {
      rethrow;
    } finally {
      // Free allocated pointers
      calloc.free(passwordPtr);
      calloc.free(saltPtr);
      calloc.free(outputKeyPtr);
    }
  }
  
  /// Generate a random 32-byte key
  static Uint8List _generateRandomKey() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(_keySize, (_) => random.nextInt(256)));
  }
}

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