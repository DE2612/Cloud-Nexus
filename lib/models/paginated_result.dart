import '../models/cloud_node.dart';

/// Result of a paginated folder listing operation
/// 
/// Contains the list of files/folders and optional pagination info
class PaginatedResult {
  /// List of files and folders in the current page
  final List<CloudNode> nodes;
  
  /// Token for the next page (null if no more pages)
  /// Pass this token to the next listFolder call to get the next page
  final String? nextPageToken;
  
  /// Total number of items available (null if unknown)
  /// This is provided by some APIs to show total count
  final int? totalItems;
  
  /// Whether there are more items to load
  bool get hasMore => nextPageToken != null;

  PaginatedResult({
    required this.nodes,
    this.nextPageToken,
    this.totalItems,
  });

  /// Creates a result with no more pages available
  factory PaginatedResult.complete(List<CloudNode> nodes) {
    return PaginatedResult(
      nodes: nodes,
      nextPageToken: null,
      totalItems: nodes.length,
    );
  }

  /// Creates a result with more pages available
  factory PaginatedResult.hasMore({
    required List<CloudNode> nodes,
    required String pageToken,
    int? totalItems,
  }) {
    return PaginatedResult(
      nodes: nodes,
      nextPageToken: pageToken,
      totalItems: totalItems,
    );
  }
}