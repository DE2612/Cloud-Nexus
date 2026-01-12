import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart';
import 'package:uuid/uuid.dart';
import '../models/cloud_node.dart';
import '../models/storage_quota.dart';
import '../models/cancellation_token.dart';
import '../models/paginated_result.dart';
import 'cloud_adapter.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';

/// Custom exception for transfer operations
class TransferException implements Exception {
  final String message;
  TransferException(this.message);
  @override
  String toString() => message;
}

class GoogleDriveAdapter implements ICloudAdapter {
  final drive.DriveApi _api;
  final AuthClient _authClient;
  final String accountId;

  /// Constructor takes the authenticated client and account ID
  GoogleDriveAdapter(AuthClient client, this.accountId)
      : _api = drive.DriveApi(client),
        _authClient = client;

  @override
  String get providerId => 'gdrive';

  @override
  Future<bool> authenticate() async {
    return true; // Already authenticated when passed in
  }

  @override
  Future<PaginatedResult> listFolder(String? folderId, {int pageSize = 100, String? pageToken}) async {
    final queryId = folderId ?? 'root';

    // Build list request with pagination parameters
    // Google Drive API supports named parameters for pagination
    final fileList = await _api.files.list(
      q: "'$queryId' in parents and trashed = false",
      pageSize: pageSize > 0 && pageSize <= 1000 ? pageSize : 100,
      pageToken: pageToken,
      $fields: "files(id, name, mimeType, modifiedTime, size), nextPageToken",
    );

    if (fileList.files == null) {
      return PaginatedResult(
        nodes: [],
        nextPageToken: null,
        totalItems: null,
      );
    }

    final nodes = fileList.files!.map((f) {
      final isFolder = f.mimeType == "application/vnd.google-apps.folder";
      final fileSize = isFolder ? 0 : (int.tryParse(f.size ?? '0') ?? 0);

      return CloudNode(
        id: const Uuid().v4(),
        parentId: folderId,
        cloudId: f.id,
        accountId: accountId,
        name: f.name ?? "Unknown",
        isFolder: isFolder,
        provider: 'gdrive',
        updatedAt: f.modifiedTime ?? DateTime.now(),
        size: fileSize,
      );
    }).toList();

    return PaginatedResult(
      nodes: nodes,
      nextPageToken: fileList.nextPageToken,
      totalItems: null, // Google Drive doesn't provide total count
    );
  }

  @override
  Future<void> downloadFile(String cloudId, String savePath) async {
    final drive.Media media = await _api.files.get(
      cloudId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final saveFile = File(savePath);
    final sink = saveFile.openWrite();
    await media.stream.pipe(sink);
  }

  @override
  Future<void> uploadFile(String localPath, String? parentFolderId) async {
    final localFile = File(localPath);
    final fileName = localFile.uri.pathSegments.last;
    final length = await localFile.length();
    final stream = localFile.openRead();
    final media = drive.Media(stream, length);

    final driveFile = drive.File();
    driveFile.name = fileName;
    if (parentFolderId != null) {
      driveFile.parents = [parentFolderId];
    }

    await _api.files.create(driveFile, uploadMedia: media);
  }

  @override
  Future<void> renameNode(String cloudId, String newName) async {
    // Validate Google Drive naming constraints
    final validationError = _validateGoogleDriveName(newName);
    if (validationError != null) {
      throw Exception(validationError);
    }

    // Check for name conflicts in the same parent folder
    final metadata = await getFileMetadata(cloudId);
    if (metadata == null) {
      throw Exception("File not found: $cloudId");
    }

    // Get parent folder ID
    final parentId = metadata.parentId;

    // Check if a file/folder with the new name already exists
    if (parentId != null) {
      final queryId = 'root';
      final existingFiles = await _api.files.list(
        q: "'$queryId' in parents and trashed = false and name = '$newName'",
        $fields: "files(id, name)",
      );

      if (existingFiles.files != null && existingFiles.files!.isNotEmpty) {
        // Check if any existing file is not the same file
        drive.File? existingFile;
        for (final file in existingFiles.files!) {
          if (file.id != cloudId) {
            existingFile = file;
            break;
          }
        }

        if (existingFile != null) {
          throw Exception("A file or folder with the name '$newName' already exists");
        }
      }
    }

    // Perform the rename
    final driveFile = drive.File()
      ..name = newName;

    await _api.files.update(driveFile, cloudId);

  }

  // ===========================================================================
  // MOVE NODE
  // ===========================================================================

  @override
  Future<void> moveNode(String cloudId, String newParentId, {String? newName}) async {
    // Get current node metadata
    final metadata = await getFileMetadata(cloudId);
    if (metadata == null) {
      throw Exception("File not found: $cloudId");
    }

    // If new name is provided, validate it first
    if (newName != null) {
      final validationError = _validateGoogleDriveName(newName);
      if (validationError != null) {
        throw Exception(validationError);
      }

      // Check for name conflicts in the new parent folder
      final queryId = 'root';
      final existingFiles = await _api.files.list(
        q: "'$queryId' in parents and trashed = false and name = '$newName'",
        $fields: "files(id, name)",
      );

      if (existingFiles.files != null && existingFiles.files!.isNotEmpty) {
        // Check if any existing file is not the same file
        drive.File? existingFile;
        for (final file in existingFiles.files!) {
          if (file.id != cloudId) {
            existingFile = file;
            break;
          }
        }

        if (existingFile != null) {
          throw Exception("A file or folder with name '$newName' already exists in the destination folder");
        }
      }
    }

    // Perform move by updating the file's parent and optionally name
    final driveFile = drive.File()
      ..parents = ['root'];

    if (newName != null) {
      driveFile.name = newName;
    }

    await _api.files.update(driveFile, cloudId);

  }

  /// Validate Google Drive naming constraints
  /// Returns error message if invalid, null if valid
  String? _validateGoogleDriveName(String name) {
    // Check for empty name
    if (name.trim().isEmpty) {
      return "Name cannot be empty";
    }

    // Check length (max 1000 characters for Google Drive)
    if (name.length > 1000) {
      return "Name cannot exceed 1000 characters";
    }

    // Google Drive is more lenient than OneDrive
    // It allows most characters including spaces, dots, etc.
    // However, we should still check for some basic issues

    // Check for leading/trailing spaces
    if (name != name.trim()) {
      return "Name cannot start or end with a space";
    }

    return null; // Name is valid
  }

  // ===========================================================================
  // DELETE NODE
  // ===========================================================================

  @override
  Future<void> deleteNode(String cloudId) async {
    // Try to delete with exponential backoff for locked files
    bool deleted = false;
    int attempts = 0;
    const maxAttempts = 5;

    while (!deleted && attempts < maxAttempts) {
      attempts++;
      try {
        if (attempts > 1) {
          // Exponential backoff: 1s, 2s, 4s, 8s, 16s
          final delay = Duration(seconds: pow(2, attempts - 1).toInt());
          await Future.delayed(delay);
        }

        await _api.files.delete(cloudId);
        deleted = true;
      } catch (deleteError) {
        if (attempts >= maxAttempts) {
          throw Exception("Failed to delete Google Drive file after $maxAttempts attempts: $deleteError");
        }
      }
    }
  }

  // ===========================================================================
  // CREATE FOLDER
  // ===========================================================================

  @override
  Future<String> createFolder(String name, String? parentFolderId, {bool checkDuplicates = true}) async {
    String finalName = name;

    // Only check for duplicates if requested
    if (checkDuplicates) {
      // First, check if a folder with this name already exists
      final queryId = parentFolderId ?? 'root';
      final fileList = await _api.files.list(
        q: "'$queryId' in parents and trashed = false and name = '$name' and mimeType = 'application/vnd.google-apps.folder'",
        $fields: "files(id, name)",
      );

      if (fileList.files != null && fileList.files!.isNotEmpty) {
        // Found existing folder, apply duplicate resolution
        // For folders, we don't split on dots since dots are part of folder names
        final String baseName = name;

        // Find highest number in existing duplicates
        int highestNumber = 0;
        // Pattern to match (number) at end
        final pattern = RegExp(r'\((\d+)\)$');

        // Get all folders with similar names to find the highest number
        final similarFolders = await _api.files.list(
          q: "'$queryId' in parents and trashed = false and name contains '$baseName' and mimeType = 'application/vnd.google-apps.folder'",
          $fields: "files(id, name)",
        );

        if (similarFolders.files != null) {
          for (final file in similarFolders.files!) {
            final folderName = file.name!;
            // Check if this item matches our base name pattern
            final basePattern = RegExp('^${RegExp.escape(baseName)}\\s*\\(\\d+\\)', caseSensitive: false);
            if (basePattern.hasMatch(folderName)) {
              final match = pattern.firstMatch(folderName);
              if (match != null) {
                final number = int.parse(match.group(1)!);
                if (number > highestNumber) {
                  highestNumber = number;
                }
              }
            }
          }
        }

        final newNumber = highestNumber + 1;
        finalName = '$baseName ($newNumber)';

      }
    } else {
    }

    final driveFile = drive.File()
      ..name = finalName
      ..mimeType = "application/vnd.google-apps.folder"
      ..parents = parentFolderId != null ? [parentFolderId] : null;

    final created = await _api.files.create(driveFile);
    return created.id!;
  }

  // ===========================================================================
  // STREAMING IMPLEMENTATION
  // ===========================================================================

  @override
  Future<Stream<List<int>>> downloadStream(String fileId) async {
    // Request stream from Google (acknowledge we want 'fullMedia' raw bytes)
    final drive.Media media = await _api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    return media.stream;
  }

  // ===========================================================================
  // UPLOAD STREAM
  // ===========================================================================

  @override
  Future<String> uploadStream(String name, Stream<List<int>> dataStream, int length, String? parentId, {bool overwrite = false, CancellationToken? cancellationToken}) async {

    // Check for cancellation before starting
    if (cancellationToken?.isCancelled == true) {
      throw Exception("Upload cancelled by user");
    }

    String finalName = name;
    String? uploadedFileId; // Store the file ID for return

    // Only check for duplicates if overwrite is false
    if (!overwrite) {
      // Check if file with same name exists
      final queryId = parentId ?? 'root';
      final fileList = await _api.files.list(
        q: "'$queryId' in parents and trashed = false and name = '$name'",
        $fields: "files(id, name)",
      );

      if (fileList.files != null && fileList.files!.isNotEmpty) {
        // Found existing file, apply duplicate resolution
        final String baseName;
        final String? extension;

        if (name.contains('.')) {
          final lastDot = name.lastIndexOf('.');
          baseName = name.substring(0, lastDot);
          extension = name.substring(lastDot + 1); // Extract extension without dot
        } else {
          baseName = name;
          extension = null;
        }

        // Find highest number in existing duplicates
        int highestNumber = 0;
        // Pattern to match (number) before the extension or at the end
        final pattern = RegExp(r'\((\d+)\)(?=\.[^.]+|$)');

        // Get all files with similar names to find the highest number
        final similarFiles = await _api.files.list(
          q: "'$queryId' in parents and trashed = false and name contains '$baseName'",
          $fields: "files(id, name)",
        );

        if (similarFiles.files != null) {
          for (final file in similarFiles.files!) {
            final fileName = file.name!;
            // Check if this item matches our base name pattern
            final basePattern = RegExp('^${RegExp.escape(baseName)}\\s*\\(\\d+\\)', caseSensitive: false);
            if (basePattern.hasMatch(fileName)) {
              final match = pattern.firstMatch(fileName);
              if (match != null) {
                final number = int.parse(match.group(1)!);
                if (number > highestNumber) {
                  highestNumber = number;
                }
              }
            }
          }
        }

        // Generate new name with extension preserved
        final newNumber = highestNumber + 1;
        finalName = extension != null
          ? '$baseName ($newNumber).$extension'
          : '$baseName ($newNumber)';

      }
    } else {

      // If overwrite is true, delete existing file with same name
      final queryId = parentId ?? 'root';
      final existingFiles = await _api.files.list(
        q: "'$queryId' in parents and trashed = false and name = '$name'",
        $fields: "files(id, name)",
      );

      if (existingFiles.files != null && existingFiles.files!.isNotEmpty) {
        for (final existingFile in existingFiles.files!) {

          // Try to delete with exponential backoff
          bool deleted = false;
          int attempts = 0;
          const maxAttempts = 5;

          while (!deleted && attempts < maxAttempts) {
            attempts++;
            try {
              if (attempts > 1) {
                // Exponential backoff: 1s, 2s, 4s, 8s, 16s
                final delay = Duration(seconds: pow(2, attempts - 1).toInt());
                await Future.delayed(delay);
              }

              await _api.files.delete(existingFile.id!);
              deleted = true;
            } catch (deleteError) {
              if (attempts >= maxAttempts) {
                throw Exception("Failed to delete file after $maxAttempts attempts: $deleteError");
              }
            }
          }
        }
      } else {
      }
    }

    // Use true streaming with larger chunks for better performance
    // Google Drive SDK handles chunking internally, but larger chunks = fewer requests
    const int chunkSize = 60 * 1024 * 1024; // 60 MB chunks (Google Drive's recommended max)

    // Create a Media object from the stream - Google Drive SDK handles chunking internally
    final media = drive.Media(dataStream, length);

    final driveFile = drive.File();
    driveFile.name = finalName;
    if (parentId != null) {
      driveFile.parents = [parentId];
    }

    // Upload the stream directly with retry logic
    drive.File? response;
    int uploadAttempts = 0;
    const maxUploadAttempts = 3;

    while (uploadAttempts < maxUploadAttempts) {
      uploadAttempts++;
      try {
        // Check for cancellation before each retry
        if (cancellationToken?.isCancelled == true) {
          throw Exception("Upload cancelled by user");
        }

        if (uploadAttempts > 1) {
          await Future.delayed(Duration(seconds: 2));
        }

        final tempResponse = await _api.files.create(
          driveFile,
          uploadMedia: media,
        );

        if (tempResponse.id == null) {
          if (uploadAttempts >= maxUploadAttempts) {
            throw Exception("Google Drive upload failed: No file ID returned after $maxUploadAttempts attempts");
          }
          continue;
        }

        response = tempResponse;
        break;
      } catch (uploadError) {
        if (uploadAttempts >= maxUploadAttempts) {
          throw Exception("Google Drive upload failed after $maxUploadAttempts attempts: $uploadError");
        }
      }
    }

    if (response == null || response.id == null) {
      throw Exception("Google Drive upload failed: No file ID returned after all retry attempts");
    }

    uploadedFileId = response.id;
    return response.id!;
  }

  // ===========================================================================
  // COPY FOLDER
  // ===========================================================================

  @override
  Future<String> copyFolder(String sourceFolderId, String? destinationParentId, String newName, {bool checkDuplicates = true}) async {
    // Google Drive doesn't have a direct copy folder API, so we need to:
    // 1. Create a new folder with the desired name (handling duplicates)
    // 2. Recursively copy all contents

    // Step 1: Create the new folder with duplicate handling
    final newFolderId = await createFolder(newName, destinationParentId, checkDuplicates: checkDuplicates);

    // Step 2: Recursively copy all contents
    await _copyFolderContents(sourceFolderId, newFolderId, checkDuplicates: checkDuplicates);

    return newFolderId;
  }

  /// Recursively copy all files and folders from source to destination
  Future<void> _copyFolderContents(String sourceFolderId, String destinationFolderId, {bool checkDuplicates = true}) async {
    try {
      // List all files in the source folder
      final fileList = await _api.files.list(
        q: "'$sourceFolderId' in parents and trashed = false",
        $fields: "files(id, name, mimeType)",
      );

      if (fileList.files == null) {
        return;
      }


      // Process items in parallel using Future.wait
      final futures = <Future<void>>[];

      for (final file in fileList.files!) {
        if (file.mimeType == "application/vnd.google-apps.folder") {
          // It's a folder - create it recursively with duplicate handling
          futures.add(_createAndCopySubfolder(file.name!, file.id!, destinationFolderId, checkDuplicates: checkDuplicates));
        } else {
          // It's a file - use Google Drive's copy API in parallel
          futures.add(_copyFileToDestination(file.name!, file.id!, destinationFolderId));
        }
      }

      // Wait for all copy operations to complete in parallel
      if (futures.isNotEmpty) {
        await Future.wait(futures, eagerError: false);
      }

    } catch (e) {
    }
  }

  /// Helper method to create and copy a subfolder (for parallel execution)
  Future<void> _createAndCopySubfolder(String folderName, String sourceFolderId, String destinationParentId, {bool checkDuplicates = true}) async {
    try {
      await createFolder(folderName, destinationParentId, checkDuplicates: checkDuplicates);

      // Get the newly created folder ID to continue recursion
      final newSubFolderList = await _api.files.list(
        q: "'$destinationParentId' in parents and trashed = false and name = '$folderName' and mimeType = 'application/vnd.google-apps.folder'",
        $fields: "files(id, name)",
      );
      if (newSubFolderList.files != null && newSubFolderList.files!.isNotEmpty) {
        await _copyFolderContents(sourceFolderId, newSubFolderList.files!.first.id!);
      }
    } catch (e) {
    }
  }

  /// Helper method to copy a file to destination (for parallel execution)
  Future<void> _copyFileToDestination(String fileName, String sourceFileId, String destinationFolderId) async {
    try {
      final copiedFile = drive.File()
        ..name = fileName
        ..parents = [destinationFolderId];

      await _api.files.copy(copiedFile, sourceFileId);
    } catch (e) {
    }
  }

  // ===========================================================================
  // FILE METADATA
  // ===========================================================================

  @override
  Future<CloudNode?> getFileMetadata(String fileId) async {
    try {
      // Get file metadata from Google Drive API
      final file = await _api.files.get(
        fileId,
        $fields: "id, name, mimeType, modifiedTime, size",
      ) as drive.File;


      final isFolder = file.mimeType == "application/vnd.google-apps.folder";
      final fileSize = isFolder ? 0 : (int.tryParse(file.size ?? '0') ?? 0);

      return CloudNode(
        id: const Uuid().v4(),
        parentId: null,
        cloudId: file.id,
        accountId: accountId,
        name: file.name ?? "Unknown",
        isFolder: isFolder,
        provider: 'gdrive',
        updatedAt: file.modifiedTime ?? DateTime.now(),
        size: fileSize,
      );
    } catch (e) {
      return null;
    }
  }

  // ===========================================================================
  // FILE ID LOOKUP (For Encrypted Filename Mapping)
  // ===========================================================================

  @override
  Future<String?> getFileIdByName(String fileName, String? parentFolderId) async {
    try {
      final queryId = parentFolderId ?? 'root';

      // Search for file by name in the parent folder
      final fileList = await _api.files.list(
        q: "'$queryId' in parents and trashed = false and name = '$fileName'",
        $fields: "files(id, name)",
      );

      if (fileList.files != null && fileList.files!.isNotEmpty) {
        final fileId = fileList.files!.first.id;
        return fileId;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  // ===========================================================================
  // PATH RESOLUTION (For Rclone)
  // ===========================================================================

  @override
  Future<String?> getPathFromId(String fileId) async {
    try {

      // Build the path by traversing parent hierarchy
      final pathSegments = <String>[];
      String? currentId = fileId;

      // Traverse up to root, collecting path segments
      while (currentId != null && currentId != 'root') {
        // Get the file's metadata including its parent
        final file = await _api.files.get(
          currentId,
          $fields: "id, name, parents",
        ) as drive.File;

        if (file.name == null) {
          break;
        }

        // Add this segment to the beginning of the path
        pathSegments.insert(0, file.name!);

        // Move to parent
        if (file.parents != null && file.parents!.isNotEmpty) {
          currentId = file.parents!.first;
        } else {
          // No more parents - this is a root-level item
          currentId = null;
        }
      }

      // Build the full path
      final path = "/${pathSegments.join('/')}";

      return path;
    } catch (e) {
      return null;
    }
  }

  // ===========================================================================
  // STORAGE QUOTA
  // ===========================================================================

  /// Cache for storage quota to avoid excessive API calls
  StorageQuota? _cachedQuota;
  DateTime? _quotaCacheTime;
  static const Duration _quotaCacheDuration = Duration(minutes: 30);

  @override
  Future<StorageQuota?> getStorageQuota() async {
    // Check cache first
    if (_cachedQuota != null && _quotaCacheTime != null) {
      final age = DateTime.now().difference(_quotaCacheTime!);
      if (age < _quotaCacheDuration) {
        return _cachedQuota;
      }
    }


    try {
      // Call the About API to get storage quota
      final about = await _api.about.get(
        $fields: "storageQuota",
      );

      if (about.storageQuota == null) {
        return null;
      }

      final totalBytes = int.tryParse(about.storageQuota!.limit ?? '0') ?? 0;
      final usedBytes = int.tryParse(about.storageQuota!.usage ?? '0') ?? 0;

      // Calculate remaining bytes (total - used)
      final remainingBytes = totalBytes - usedBytes;

      _cachedQuota = StorageQuota(
        totalBytes: totalBytes,
        usedBytes: usedBytes,
        remainingBytes: remainingBytes > 0 ? remainingBytes : 0,
        lastUpdated: DateTime.now(),
      );
      _quotaCacheTime = DateTime.now();

      return _cachedQuota;
    } catch (e) {
      return null;
    }
  }

  // ===========================================================================
  // GOOGLE DRIVE TRANSFER API IMPLEMENTATION
  // ===========================================================================

  /// Get the drive ID for this adapter (needed for transfers)
  Future<String> getDriveId() async {
    // For Google Drive, the drive ID is the account ID
    return accountId;
  }

  /// SAFETY WRAPPER: Execute transfer with proper error handling
  /// This prevents crashes from "failed to post message to main thread" errors
  @override
  Future<String?> transferFileOwnership({
    required String fileId,
    required String targetDriveId,
    String? destinationFolderId,
  }) async {
    try {
      return await _executeTransferFileOwnership(
        fileId: fileId,
        targetDriveId: targetDriveId,
        destinationFolderId: destinationFolderId,
      );
    } catch (e, stack) {
      // Re-throw with context for better debugging
      throw TransferException('Failed to transfer file ownership: $e');
    }
  }

  /// Internal implementation - executes the actual transfer
  Future<String?> _executeTransferFileOwnership({
    required String fileId,
    required String targetDriveId,
    String? destinationFolderId,
  }) async {

    // Step 1: Create transfer request
    final transferRequest = {
      'driveId': targetDriveId,
      'itemIds': [fileId],
      if (destinationFolderId != null) 'parentId': destinationFolderId,
    };

    // Step 2: Execute transfer using REST API with _authClient
    final response = await _authClient.post(
      Uri.parse('https://www.googleapis.com/drive/v3/transfers'),
      body: jsonEncode(transferRequest),
    );

    if (response.statusCode != 200) {
      throw Exception('Transfer failed with status ${response.statusCode}: ${response.body}');
    }

    final responseData = jsonDecode(response.body) as Map<String, dynamic>;
    final transferId = responseData['id'] as String?;

    if (transferId == null) {
      throw Exception('Transfer failed: No transfer ID returned');
    }

    // Step 3: Wait for transfer completion
    await _waitForTransferCompletion(transferId);

    // Step 4: Get the transferred file ID
    final transferStatus = await _authClient.get(
      Uri.parse('https://www.googleapis.com/drive/v3/transfers/$transferId'),
    );

    if (transferStatus.statusCode != 200) {
      throw Exception('Failed to get transfer status: ${transferStatus.body}');
    }

    final statusData = jsonDecode(transferStatus.body) as Map<String, dynamic>;
    final status = statusData['status'] as String?;

    if (status == 'COMPLETED') {
      final resourceId = statusData['resourceId'] as String?;
      return resourceId;
    } else if (status == 'FAILED') {
      final error = statusData['error'] as String?;
      throw Exception('Transfer failed: $error');
    } else {
      throw Exception('Transfer in unexpected status: $status');
    }
  }

  /// Wait for transfer to complete
  Future<void> _waitForTransferCompletion(String transferId) async {
    int attempts = 0;
    const maxAttempts = 60; // 1 minute timeout

    while (attempts < maxAttempts) {
      final response = await _authClient.get(
        Uri.parse('https://www.googleapis.com/drive/v3/transfers/$transferId'),
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to check transfer status: ${response.body}');
      }

      final statusData = jsonDecode(response.body) as Map<String, dynamic>;
      final status = statusData['status'] as String?;

      if (status == 'COMPLETED') {
        return;
      }

      if (status == 'FAILED') {
        final error = statusData['error'] as String?;
        throw Exception('Transfer failed: $error');
      }

      await Future.delayed(Duration(seconds: 1));
      attempts++;
    }

    throw TimeoutException('Transfer timed out after $maxAttempts seconds');
  }

  @override
  Future<List<String>> transferMultipleFiles({
    required List<String> fileIds,
    required String targetDriveId,
    String? destinationFolderId,
    Function(int, int)? onProgress,
  }) async {
    try {

      final results = <String>[];
      int completed = 0;

      // Google Drive allows up to 100 items per transfer
      for (var i = 0; i < fileIds.length; i += 100) {
        final batch = fileIds.skip(i).take(100).toList();

        final transferRequest = {
          'driveId': targetDriveId,
          'itemIds': batch,
          if (destinationFolderId != null) 'parentId': destinationFolderId,
        };

        // Execute transfer
        final response = await _authClient.post(
          Uri.parse('https://www.googleapis.com/drive/v3/transfers'),
          body: jsonEncode(transferRequest),
        );

        if (response.statusCode != 200) {
          throw Exception('Batch transfer failed with status ${response.statusCode}: ${response.body}');
        }

        final responseData = jsonDecode(response.body) as Map<String, dynamic>;
        final transferId = responseData['id'] as String?;

        if (transferId == null) {
          throw Exception('Batch transfer failed: No transfer ID returned');
        }

        // Wait for batch completion
        await _waitForTransferCompletion(transferId);

        // Get transfer status
        final transferStatus = await _authClient.get(
          Uri.parse('https://www.googleapis.com/drive/v3/transfers/$transferId'),
        );

        if (transferStatus.statusCode != 200) {
          throw Exception('Failed to get batch transfer status: ${transferStatus.body}');
        }

        final statusData = jsonDecode(transferStatus.body) as Map<String, dynamic>;
        final status = statusData['status'] as String?;

        if (status == 'COMPLETED') {
          final resourceIds = statusData['resourceId'] as List<dynamic>?;
          if (resourceIds == null) {
            throw Exception('Batch transfer failed: No resource IDs returned');
          }

          final newFileIds = resourceIds.map((id) => id.toString()).toList();
          results.addAll(newFileIds);
          completed += batch.length;

          onProgress?.call(completed, fileIds.length);
        } else if (status == 'FAILED') {
          final error = statusData['error'] as String?;
          throw Exception('Batch transfer failed: $error');
        } else {
          throw Exception('Batch transfer in unexpected status: $status');
        }
      }

      return results;
    } catch (e) {
      throw Exception('Batch transfer failed: $e');
    }
  }

  // ===========================================================================
  // NATIVE COPY (Same-Provider Only)
  // ===========================================================================

  @override
  Future<String?> copyFileNative({
    required String sourceFileId,
    required String destinationParentId,
    String? newName,
  }) async {
    try {

      // Get source file metadata to get the name
      final sourceFile = await _api.files.get(
        sourceFileId,
        $fields: "id, name, mimeType",
      ) as drive.File;

      final String finalName = newName ?? sourceFile.name ?? "Untitled";

      // Use Google Drive's native copy API
      // This is instant and doesn't use bandwidth
      final drive.File copiedFile = drive.File()
        ..name = finalName
        ..parents = [destinationParentId];

      final response = await _api.files.copy(copiedFile, sourceFileId);

      if (response.id == null) {
        return null;
      }

      return response.id;
    } catch (e) {
      return null;
    }
  }

  // ===========================================================================
  // TOKEN FOR RCLONE
  // ===========================================================================

  /// Get the OAuth access token for Rclone configuration
  /// Returns the current access token string
  Future<String?> getAccessToken() async {
    try {
      // The _authClient has credentials that include the access token
      // We need to ensure the token is fresh first
      if (_authClient.credentials.accessToken.expiry.isBefore(DateTime.now())) {
        return null;
      }
      return _authClient.credentials.accessToken.data;
    } catch (e) {
      return null;
    }
  }

  // ===========================================================================
  // CHUNK-BASED DOWNLOAD/UPLOAD (For UnifiedCopyService)
  // ===========================================================================

  /// Download a specific chunk of a file using Range header
  ///
  /// This method is used by UnifiedCopyService for chunked cloud-to-cloud copy.
  ///
  /// [fileId] - The file ID to download from
  /// [buffer] - The buffer to fill with downloaded data
  /// [offset] - The byte offset to start reading from
  /// [length] - The number of bytes to read
  ///
  /// Returns the number of bytes actually read (0 for EOF, negative for error)
  Future<int> downloadChunk({
    required String fileId,
    required Uint8List buffer,
    required int offset,
    required int length,
  }) async {
    try {
      // Calculate the actual bytes to read (min of requested and available)
      final bytesToRead = length.clamp(0, buffer.length);
      if (bytesToRead == 0) return 0;

      // Get file metadata to check size
      final metadata = await getFileMetadata(fileId);
      if (metadata == null) {
        return -1;
      }

      if (offset >= metadata.size) {
        // Offset is at or past EOF
        return 0;
      }

      final actualBytesToRead = (offset + bytesToRead > metadata.size)
          ? (metadata.size - offset)
          : bytesToRead;

      // Use HTTP Range header for partial download
      final rangeEnd = offset + actualBytesToRead - 1;
      final rangeHeader = 'bytes=$offset-$rangeEnd';


      final response = await _authClient.get(
        Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?alt=media'),
        headers: {'Range': rangeHeader},
      );

      if (response.statusCode == 200 || response.statusCode == 206) {
        final bytes = response.bodyBytes;
        buffer.setRange(0, bytes.length, bytes);
        return bytes.length;
      } else if (response.statusCode == 416) {
        // Range not satisfiable - we're past EOF
        return 0;
      } else {
        return -response.statusCode;
      }
    } catch (e) {
      return -1;
    }
  }

  /// Upload a chunk of data to a file using PATCH
  ///
  /// This method is used by UnifiedCopyService for chunked cloud-to-cloud copy.
  /// For new files, use [createUploadSession] first to get an upload URL.
  ///
  /// [fileId] - The file ID to upload to (or upload URL for new files)
  /// [data] - The chunk data to upload
  /// [offset] - The byte offset in the file
  /// [isNewFile] - If true, creates a new file; if false, updates existing
  /// [contentType] - The MIME type of the file
  ///
  /// Returns 0 on success, negative error code on failure
  Future<int> uploadChunk({
    required String fileId,
    required Uint8List data,
    required int offset,
    bool isNewFile = false,
    String contentType = 'application/octet-stream',
  }) async {
    try {
      if (data.isEmpty) return 0;

      final contentLength = data.length;
      final rangeEnd = offset + contentLength - 1;


      if (isNewFile) {
        // For new files, use the simple upload API
        final response = await _authClient.post(
          Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=media'),
          headers: {
            'Content-Type': contentType,
            'Content-Length': contentLength.toString(),
            'Content-Range': 'bytes $offset-$rangeEnd/*',
          },
          body: data,
        );

        if (response.statusCode == 200 || response.statusCode == 201) {
          return 0;
        } else {
          return -response.statusCode;
        }
      } else {
        // For existing files, use PATCH with Content-Range
        final response = await _authClient.patch(
          Uri.parse('https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=media'),
          headers: {
            'Content-Type': contentType,
            'Content-Length': contentLength.toString(),
            'Content-Range': 'bytes $offset-$rangeEnd/*',
          },
          body: data,
        );

        if (response.statusCode == 200) {
          return 0;
        } else {
          return -response.statusCode;
        }
      }
    } catch (e) {
      return -1;
    }
  }

  /// Create a new file upload session and return the file ID
  ///
  /// This is the first step for uploading a new file in chunks.
  ///
  /// [name] - The name of the new file
  /// [parentId] - The parent folder ID (null for root)
  /// [totalSize] - The total size of the file in bytes
  /// [contentType] - The MIME type of the file
  ///
  /// Returns the new file ID, or null on error
  Future<String?> createUploadSession({
    required String name,
    String? parentId,
    required int totalSize,
    String contentType = 'application/octet-stream',
  }) async {
    try {

      final driveFile = drive.File()
        ..name = name
        ..parents = parentId != null ? [parentId] : null;

      final response = await _api.files.create(
        driveFile,
        uploadMedia: drive.Media(Stream.empty(), totalSize),
      );

      if (response.id != null) {
        return response.id;
      } else {
        return null;
      }
    } catch (e) {
      return null;
    }
  }
}