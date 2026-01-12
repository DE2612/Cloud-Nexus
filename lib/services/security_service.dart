import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:async';
import '../utils/throttled_logger.dart';
import 'encrypted_file_format.dart';
import 'streaming_encryption_service.dart';

/// Encryption progress callback
typedef EncryptionProgressCallback = void Function(int bytesProcessed, int totalBytes);

/// Decrypted file metadata
class FileMetadata {
  final String name;
  final String path;
  final int size;
  final String mimeType;
  final DateTime modifiedTime;

  FileMetadata({
    required this.name,
    required this.path,
    required this.size,
    required this.mimeType,
    required this.modifiedTime,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'path': path,
      'size': size,
      'mimeType': mimeType,
      'modifiedTime': modifiedTime.toIso8601String(),
    };
  }

  factory FileMetadata.fromJson(Map<String, dynamic> json) {
    return FileMetadata(
      name: json['name'] as String,
      path: json['path'] as String,
      size: json['size'] as int,
      mimeType: json['mimeType'] as String,
      modifiedTime: DateTime.parse(json['modifiedTime'] as String),
    );
  }
}

/// Security Service using Rust-based AES-256-GCM encryption with embedded FEK (Approach 1)
/// 
/// This service provides self-contained encryption where each encrypted file
/// contains its own File Encryption Key (FEK) embedded in the file header.
/// Files can be decrypted on any device with the same password.
class SecurityService {
  static final SecurityService instance = SecurityService._();
  SecurityService._();

  final _storage = const FlutterSecureStorage();
  
  // The Master Key (MEK) used to encrypt files
  Uint8List? _masterKey;
  
  // Key sizes
  static const int _keySize = 32;
  static const int _saltSize = 16;
  
  // PBKDF2 iterations (NIST recommended minimum)
  static const int _pbkdf2Iterations = 100000;

  bool get isUnlocked => _masterKey != null;
  
  /// Get the master key (for use by streaming encryption service)
  Uint8List? get masterKey => _masterKey;

  /// Initialize the native encryption library
  static Future<void> initialize() async {
    await EncryptedFileFormat.initialize();
  }

  /// Checks if a vault has ever been set up on this device
  Future<bool> hasVault() async {
    final value = await readSecureValue('wrapped_key');
    if (value == null) {
      return false;
    }
    
    
    // Validate that the vault is in the correct format
    // Old vaults may have different formats that won't work with the new system
    try {
      final bytes = _hexToBytes(value);
      
      // New vault format should have at least the magic header (4 bytes) + wrapped FEK (60 bytes) + nonce (12 bytes) + MAC (16 bytes) = 92 bytes minimum
      // For the wrapped key itself, it should be at least 92 bytes
      if (bytes.length < 92) {
        await clearVault();
        return false;
      }
      // Check for magic header (little-endian: 0x434E4552 = "CNER" → [0x52, 0x45, 0x4E, 0x43])
      if (bytes[0] != 0x52 || bytes[1] != 0x45 || bytes[2] != 0x4E || bytes[3] != 0x43) {
        await clearVault();
        return false;
      }
      return true;
    } catch (e) {
      await clearVault();
      return false;
    }
  }

  /// SETUP: Create a NEW Vault (Runs only once)
  Future<void> createVault(String password) async {
    
    // 1. Generate a random Master Key (32 bytes)
    final masterKey = _generateRandomKey();
    
    // 2. Encrypt this Master Key with the Password
    await _saveMasterKey(masterKey, password);
    
    // 3. Keep it in memory so we are unlocked
    _masterKey = masterKey;
    
  }

  /// UNLOCK: Open existing Vault
  Future<bool> unlockVault(String password) async {
    try {
      final wrappedDataHex = await readSecureValue('wrapped_key');
      if (wrappedDataHex == null) return false;

      // Convert Hex string back to bytes
      final allBytes = _hexToBytes(wrappedDataHex);
      
      // 1. Derive Key from Password (KEK)
      final kek = await _deriveKeyFromPassword(password);
      
      // 2. Decrypt the Master Key using Rust
      final masterKeyBytes = await EncryptedFileFormat.decryptFile(Uint8List.fromList(allBytes), kek);
      
      // Success! Load into memory.
      _masterKey = masterKeyBytes;
      
      logger.success('Vault unlocked successfully');
      return true;
    } catch (e) {
      logger.error('Unlock failed: $e');
      return false; // Wrong password
    }
  }

  /// CHANGE PASSWORD: Re-wrap the key
  Future<void> changePassword(String newPassword) async {
    if (_masterKey == null) throw Exception("Must be unlocked to change password");
    
    // Re-encrypt the EXISTING Master Key with the NEW password
    await _saveMasterKey(_masterKey!, newPassword);
    
    logger.success('Password changed successfully');
  }

  /// CLEAR VAULT: Remove all vault data from storage and memory
  Future<void> clearVault() async {
    // Clear in-memory keys
    _masterKey = null;
    
    // Clear all vault-related data from secure storage
    await deleteSecureValue('wrapped_key');
    await deleteSecureValue('key_salt');
    
    logger.success('Vault cleared successfully');
  }

  // --- FILE OPERATIONS ---

  /// Encrypt a file with embedded FEK (Approach 1)
  ///
  /// The encrypted file is self-contained and can be decrypted on any device
  /// with the same password. No external key storage needed.
  Future<void> encryptFile(
    File inputFile,
    File outputFile, {
    EncryptionProgressCallback? onProgress,
  }) async {
    if (_masterKey == null) throw Exception("Vault locked!");

    final fileSize = await inputFile.length();
    
    
    logger.info('Encrypting file: ${inputFile.path.split(Platform.pathSeparator).last} (${_formatBytes(fileSize)})');
    
    // Use streaming encryption for large files to prevent memory issues
    if (fileSize > 50 * 1024 * 1024) { // 50MB threshold
      logger.info('Using streaming encryption for large file');
      
      try {
        await StreamingEncryptionService.encryptFileStreaming(
          inputFile,
          outputFile,
          _masterKey!,
          onProgress: onProgress,
        );
      } catch (e, stackTrace) {
        rethrow;
      }
    } else {
      
      // Use regular encryption for small files
      final fileBytes = await inputFile.readAsBytes();
      
      // Encrypt file with embedded FEK using Rust
      final encryptedBytes = await EncryptedFileFormat.encryptFile(fileBytes, _masterKey!);
      
      // Write encrypted file
      await outputFile.writeAsBytes(encryptedBytes);
      
      // Send progress update
      onProgress?.call(fileSize, fileSize);
    }
    
    logger.success('File encrypted successfully');
  }

  /// Decrypt a file with embedded FEK (Approach 1)
  ///
  /// The file contains its own FEK in the header, so no external
  /// key lookup is needed.
  Future<void> decryptFile(
    File encryptedFile,
    File outputFile, {
    EncryptionProgressCallback? onProgress,
  }) async {
    if (_masterKey == null) throw Exception("Vault locked!");

    final fileSize = await encryptedFile.length();
    
    logger.info('Decrypting file: ${encryptedFile.path.split(Platform.pathSeparator).last} (${_formatBytes(fileSize)})');
    
    // Use streaming decryption for large files to prevent memory issues
    if (fileSize > 50 * 1024 * 1024) { // 50MB threshold
      logger.info('Using streaming decryption for large file');
      await StreamingEncryptionService.decryptFileStreaming(
        encryptedFile,
        outputFile,
        _masterKey!,
        onProgress: onProgress,
      );
    } else {
      // Use regular decryption for small files
      final encryptedBytes = await encryptedFile.readAsBytes();
      
      // Decrypt file with embedded FEK using Rust
      final decryptedBytes = await EncryptedFileFormat.decryptFile(encryptedBytes, _masterKey!);
      
      // Write decrypted file
      await outputFile.writeAsBytes(decryptedBytes);
      
      // Send progress update
      onProgress?.call(decryptedBytes.length, decryptedBytes.length);
    }
    
    logger.success('File decrypted successfully');
  }

  /// Check if a file is in the new encrypted format
  Future<bool> isEncryptedFile(File file) async {
    final bytes = await file.openRead(0, 4).first;
    return EncryptedFileFormat.isValidFormat(Uint8List.fromList(bytes));
  }

  // --- INTERNAL HELPERS ---

  /// Save Master Key encrypted with password
  Future<void> _saveMasterKey(Uint8List masterKey, String password) async {
    
    // Derive key from password
    final kek = await _deriveKeyFromPassword(password);
    
    // Encrypt master key with embedded FEK format
    final encryptedMasterKey = await EncryptedFileFormat.encryptFile(masterKey, kek);
    
    // Save as Hex String
    final hexString = _bytesToHex(encryptedMasterKey);
    await writeSecureValue('wrapped_key', hexString);
  }

  /// Derive key from password using PBKDF2-HMAC-SHA256
  Future<Uint8List> _deriveKeyFromPassword(String password) async {
    
    // Get or generate salt
    String? saltHex = await readSecureValue('key_salt');
    Uint8List salt;
    
    if (saltHex == null) {
      // Generate new random salt (16 bytes)
      salt = _generateRandomSalt();
      // Store salt for future use
      await writeSecureValue('key_salt', _bytesToHex(salt));
    } else {
      // Use existing salt
      salt = Uint8List.fromList(_hexToBytes(saltHex));
    }
    
    // Derive key from password using PBKDF2 via Rust
    final derivedKey = await EncryptedFileFormat.deriveKeyFromPassword(
      password,
      salt,
      _pbkdf2Iterations,
    );
    
    return derivedKey;
  }

  /// Generate a random 32-byte key
  Uint8List _generateRandomKey() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(_keySize, (_) => random.nextInt(256)));
  }

  /// Generate a random 16-byte salt
  Uint8List _generateRandomSalt() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(_saltSize, (_) => random.nextInt(256)));
  }

  // --- SECURE STORAGE HELPERS ---

  /// Protected secure storage read
  Future<String?> readSecureValue(String key) async {
    return await _storage.read(key: key);
  }
  
  /// Protected secure storage write
  Future<void> writeSecureValue(String key, String value) async {
    await _storage.write(key: key, value: value);
  }
  
  /// Protected secure storage delete
  Future<void> deleteSecureValue(String key) async {
    await _storage.delete(key: key);
  }
  
  /// Protected secure storage read all
  Future<Map<String, String>> readAllSecureValues() async {
    return await _storage.readAll();
  }

  // --- UTILS ---

  String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
  
  List<int> _hexToBytes(String hex) {
    List<int> bytes = [];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }
  
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}