import 'dart:convert';

/// Represents a mapping between encrypted (random) filenames and original filenames
/// This allows files to be stored with random names on cloud storage while
/// the app displays the original filenames
class EncryptedFileMapping {
  final String encryptedFileName; // e.g., "a1b2-c3d4-e5f6-7890.enc"
  final String originalFileName; // e.g., "my_document.pdf"
  final String cloudFileId; // Cloud provider's file ID
  final String accountId; // Which account this belongs to
  final String parentId; // Parent folder ID in cloud
  final DateTime createdAt;
  final int originalFileSize; // Original file size in bytes (unencrypted), for sync comparison

  EncryptedFileMapping({
    required this.encryptedFileName,
    required this.originalFileName,
    required this.cloudFileId,
    required this.accountId,
    required this.parentId,
    required this.createdAt,
    required this.originalFileSize,
  });

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'encryptedFileName': encryptedFileName,
      'originalFileName': originalFileName,
      'cloudFileId': cloudFileId,
      'accountId': accountId,
      'parentId': parentId,
      'createdAt': createdAt.toIso8601String(),
      'originalFileSize': originalFileSize,
    };
  }

  /// Create from JSON
  factory EncryptedFileMapping.fromJson(Map<String, dynamic> json) {
    return EncryptedFileMapping(
      encryptedFileName: json['encryptedFileName'] as String,
      originalFileName: json['originalFileName'] as String,
      cloudFileId: json['cloudFileId'] as String,
      accountId: json['accountId'] as String,
      parentId: json['parentId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      originalFileSize: json['originalFileSize'] as int? ?? 0,
    );
  }

  /// Convert to JSON string
  String toJsonString() => json.encode(toJson());

  /// Create from JSON string
  factory EncryptedFileMapping.fromJsonString(String jsonStr) {
    return EncryptedFileMapping.fromJson(json.decode(jsonStr));
  }

  @override
  String toString() {
    return 'EncryptedFileMapping(encrypted: $encryptedFileName, original: $originalFileName)';
  }
}