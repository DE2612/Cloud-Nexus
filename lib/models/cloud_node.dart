import 'package:hive/hive.dart';

part 'cloud_node.g.dart';

@HiveType(typeId: 0)
class CloudNode extends HiveObject {
  @HiveField(0)
  final String id;
  
  @HiveField(1)
  final String? parentId;
  
  @HiveField(2)
  final String? cloudId;
  
  @HiveField(3)
  final String? accountId; // Links to CloudAccount
  
  @HiveField(4)
  final String name;
  
  @HiveField(5)
  final bool isFolder;
  
  @HiveField(6)
  final String provider;
  
  @HiveField(7)
  final DateTime updatedAt;
  
  @HiveField(8)
  final int size; // File size in bytes (0 for folders)
  
  @HiveField(9, defaultValue: null)
  final String? sourceAccountId; // For virtual drives: the actual account where the file is stored

  CloudNode({
    required this.id,
    this.parentId,
    this.cloudId,
    this.accountId,
    required this.name,
    required this.isFolder,
    required this.provider,
    required this.updatedAt,
    this.size = 0, // Default to 0 for folders or when size is unknown
    this.sourceAccountId, // For virtual drives
  });

  // Keep existing methods for compatibility during migration
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'parent_id': parentId,
      'cloud_id': cloudId,
      'account_id': accountId,
      'name': name,
      'is_folder': isFolder ? 1 : 0,
      'provider': provider,
      'updated_at': updatedAt.toIso8601String(),
      'size': size,
      'source_account_id': sourceAccountId,
    };
  }

  factory CloudNode.fromMap(Map<String, dynamic> map) {
    return CloudNode(
      id: map['id'],
      parentId: map['parent_id'],
      cloudId: map['cloud_id'],
      accountId: map['account_id'],
      name: map['name'],
      isFolder: map['is_folder'] == 1,
      provider: map['provider'],
      updatedAt: DateTime.parse(map['updated_at']),
      size: map['size'] ?? 0, // Default to 0 if not present
      sourceAccountId: map['source_account_id'], // For virtual drives
    );
  }
}