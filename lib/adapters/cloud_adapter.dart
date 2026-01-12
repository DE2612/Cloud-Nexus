import '../models/cloud_node.dart';
import '../models/storage_quota.dart';
import '../models/cancellation_token.dart';
import '../models/paginated_result.dart';

abstract class ICloudAdapter {
  /// The unique ID for the provider, like 'gdrive' or 'onedrive'.
  String get providerId;

  /// Handles user login. Returns true if successful.
  Future<bool> authenticate();

  /// Lists folder contents. Defaults to root if folderId is null.
  /// Use [pageSize] and [pageToken] to manage pagination.
  Future<PaginatedResult> listFolder(String? folderId, {int pageSize = 100, String? pageToken});

  /// Saves a cloud file to your local device.
  Future<void> downloadFile(String fileId, String savePath);

  /// Deletes a file or folder from the cloud.
  Future<void> deleteNode(String cloudId);

  /// Renames a cloud file or folder.
  Future<void> renameNode(String cloudId, String newName);

  /// Moves an item to a new folder and optionally renames it.
  Future<void> moveNode(String cloudId, String newParentId, {String? newName});

  /// Uploads a local file to the cloud.
  Future<void> uploadFile(String localPath, String? parentFolderId);

  /// Creates a folder. Set checkDuplicates to true to avoid naming conflicts.
  Future<String> createFolder(String name, String? parentFolderId, {bool checkDuplicates = true});

  // ===========================================================================
  // STREAMING (For large files or Virtual RAID)
  // ===========================================================================

  /// Streams file data to save memory on large downloads.
  Future<Stream<List<int>>> downloadStream(String fileId);

  /// Streams an upload. Includes a token to cancel the process if needed.
  /// Returns the uploaded file's ID (for saving encrypted filename mappings).
  Future<String> uploadStream(String name, Stream<List<int>> dataStream, int length, String? parentId, {bool overwrite = false, CancellationToken? cancellationToken});

  /// Deep copies a folder and its contents. Returns the new folder ID.
  Future<String> copyFolder(String sourceFolderId, String? destinationParentId, String newName, {bool checkDuplicates = true});

  // ===========================================================================
  // NATIVE COPY (Same provider only)
  // ===========================================================================

  /// Performs a fast, server-side copy within the same cloud service.
  Future<String?> copyFileNative({
    required String sourceFileId,
    required String destinationParentId,
    String? newName,
  });

  // ===========================================================================
  // TRANSFER (Google Drive specific)
  // ===========================================================================

  /// Instantly moves file ownership to another Drive account.
  Future<String?> transferFileOwnership({
    required String fileId,
    required String targetDriveId,
    String? destinationFolderId,
  });

  /// Batches multiple file transfers (max 100). Tracks progress via callback.
  Future<List<String>> transferMultipleFiles({
    required List<String> fileIds,
    required String targetDriveId,
    String? destinationFolderId,
    Function(int, int)? onProgress,
  });

  /// Gets specific metadata for a file.
  Future<CloudNode?> getFileMetadata(String fileId);

  // ===========================================================================
  // FILE ID LOOKUP
  // ===========================================================================

  /// Finds a file ID by its name. Useful for mapping after encrypted uploads.
  Future<String?> getFileIdByName(String fileName, String? parentFolderId);

  // ===========================================================================
  // PATH RESOLUTION
  // ===========================================================================

  Future<String?> getPathFromId(String fileId);

  // ===========================================================================
  // STORAGE QUOTA
  // ===========================================================================

  /// Fetches storage usage. Results are cached.
  Future<StorageQuota?> getStorageQuota();
}