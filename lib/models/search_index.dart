import 'package:hive/hive.dart';

part 'search_index.g.dart';

@HiveType(typeId: 30)
class SearchIndexEntry extends HiveObject {
  @HiveField(0)
  final String provider;        // 'gdrive', 'onedrive', 'virtual', 'local'
  
  @HiveField(1)
  final String email;           // Account email (for same email across providers)
  
  @HiveField(2)
  final String nodeId;          // CloudNode.id
  
  @HiveField(3)
  final String? parentId;       // CloudNode.parentId (for hierarchy traversal)
  
  @HiveField(4)
  final String nodeName;        // CloudNode.name (for search matching)
  
  @HiveField(5)
  final bool isFolder;         // CloudNode.isFolder
  
  @HiveField(6)
  final String? cloudId;         // CloudNode.cloudId (for navigation)
  
  @HiveField(7)
  final String? accountId;       // CloudNode.accountId (for adapter retrieval)
  
  @HiveField(8)
  final String? sourceAccountId; // CloudNode.sourceAccountId (for virtual drives)

  SearchIndexEntry({
    required this.provider,
    required this.email,
    required this.nodeId,
    this.parentId,
    required this.nodeName,
    required this.isFolder,
    this.cloudId,
    this.accountId,
    this.sourceAccountId,
  });
}