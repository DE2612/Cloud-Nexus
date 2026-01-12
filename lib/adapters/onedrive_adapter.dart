import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../models/cloud_node.dart';
import '../models/storage_quota.dart';
import '../models/cancellation_token.dart';
import '../models/paginated_result.dart';
import 'cloud_adapter.dart';
import '../services/onedrive_auth_manager.dart';

class OneDriveAdapter implements ICloudAdapter {
  final String _accountId;
  final String _baseUrl = "https://graph.microsoft.com/v1.0/me/drive";

  // In-memory token cache to avoid redundant Hive reads during indexing
  String? _cachedAccessToken;
  DateTime? _tokenCacheTime;
  static const Duration _tokenCacheDuration = Duration(minutes: 5);

  OneDriveAdapter(this._accountId);

  /// Get cached access token with in-memory caching
  /// Reduces Hive reads from O(n) to O(1) during recursive operations like indexing
  Future<String> _getAccessToken() async {
    // Check if we have a cached token that's still valid
    if (_cachedAccessToken != null && _tokenCacheTime != null) {
      final age = DateTime.now().difference(_tokenCacheTime!);
      if (age < _tokenCacheDuration) {
        return _cachedAccessToken!;
      }
    }

    // Get fresh token from auth manager
    final token = await OneDriveAuthManager.instance.getAccessTokenForAccount(_accountId);
    if (token == null) {
      throw Exception("OneDrive: Failed to get access token for account $_accountId");
    }

    // Cache it in memory
    _cachedAccessToken = token;
    _tokenCacheTime = DateTime.now();

    return token;
  }

  @override
  String get providerId => 'onedrive';

  @override
  Future<bool> authenticate() async => true; // Token assumed valid for session

  // ===========================================================================
  // LIST FILES
  // ===========================================================================

  @override
  Future<PaginatedResult> listFolder(String? folderId, {int pageSize = 100, String? pageToken}) async {
    // Get cached access token with in-memory caching
    final accessToken = await _getAccessToken();

    // OneDrive Root is '/root/children', others are '/items/{id}/children'
    String endpoint = (folderId == null || folderId == 'root')
        ? "$_baseUrl/root/children"
        : "$_baseUrl/items/$folderId/children";

    // Build query parameters for pagination
    final queryParams = <String, String>{
      '\$top': pageSize > 0 && pageSize <= 1000 ? pageSize.toString() : '100',
    };
    
    if (pageToken != null && pageToken.isNotEmpty) {
      // OneDrive uses '@odata.nextLink' which contains the full URL for next page
      // If a pageToken is provided, use it directly as it's the complete URL
      if (pageToken.startsWith('http')) {
        endpoint = pageToken;
      } else {
        // Fall back to skiptoken approach
        queryParams['\$skiptoken'] = pageToken;
      }
    }

    final uri = pageToken != null && pageToken.startsWith('http')
        ? Uri.parse(endpoint)
        : Uri.parse(endpoint).replace(queryParameters: queryParams);

    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode != 200) throw Exception("OneDrive List Error: ${response.body}");

    final data = jsonDecode(response.body);
    final List<dynamic> items = data['value'];
    
    // Extract next page token from @odata.nextLink
    String? nextPageToken = data['@odata.nextLink'] as String?;
    
    // Map items to CloudNode objects
    final nodes = items.map((item) {
      final isFolder = item['folder'] != null;
      final fileSize = isFolder ? 0 : (item['size'] as int? ?? 0);

      return CloudNode(
        id: item['id'], // Uses OneDrive ID
        parentId: folderId,
        cloudId: item['id'],
        accountId: _accountId,
        name: item['name'],
        isFolder: isFolder, // If 'folder' key exists, it's a folder
        provider: 'onedrive',
        updatedAt: DateTime.parse(item['lastModifiedDateTime']),
        size: fileSize, // Include file size
      );
    }).toList();

    return PaginatedResult(
      nodes: nodes,
      nextPageToken: nextPageToken,
    );
  }

  // ===========================================================================
  // DOWNLOAD STREAM
  // ===========================================================================

  @override
  Future<Stream<List<int>>> downloadStream(String fileId) async {
    // Get cached access token with in-memory caching
    final accessToken = await _getAccessToken();


    // Graph API: GET /items/{id}/content
    final request = http.Request('GET', Uri.parse("$_baseUrl/items/$fileId/content"));
    request.headers['Authorization'] = 'Bearer $accessToken';

    final response = await request.send();

    if (response.statusCode != 200) {
      throw Exception("Download Failed: ${response.statusCode}");
    }

    return response.stream;
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

    // Get cached access token
    final accessToken = await _getAccessToken();

    String finalName = name;
    String? uploadedFileId; // Store the file ID for return

    // Check for existing files and handle duplicates/overwrite
    if (!overwrite) {
      // Check if file with same name exists
      final listEndpoint = (parentId == null || parentId == 'root')
          ? "$_baseUrl/root/children"
          : "$_baseUrl/items/$parentId/children";

      final listResponse = await http.get(
        Uri.parse(listEndpoint),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (listResponse.statusCode == 200) {
        final data = jsonDecode(listResponse.body);
        final List<dynamic> items = data['value'];

        // Check for existing file with same name (case-insensitive)
        final existingFile = items.firstWhere(
          (item) => item['folder'] == null && item['name'].toString().toLowerCase() == name.toLowerCase(),
          orElse: () => null,
        );

        if (existingFile != null) {
          // Found existing file, apply duplicate resolution like Google Drive
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

          for (final item in items) {
            if (item['folder'] == null) {
              final itemName = item['name'].toString();
              // Check if this item matches our base name pattern
              final basePattern = RegExp('^${RegExp.escape(baseName)}\\s*\\(\\d+\\)', caseSensitive: false);
              if (basePattern.hasMatch(itemName)) {
                final match = pattern.firstMatch(itemName);
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
      }
    } else {

      // If overwrite is true, delete existing file with same name
      final listEndpoint = (parentId == null || parentId == 'root')
          ? "$_baseUrl/root/children"
          : "$_baseUrl/items/$parentId/children";

      final listResponse = await http.get(
        Uri.parse(listEndpoint),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (listResponse.statusCode == 200) {
        final data = jsonDecode(listResponse.body);
        final List<dynamic> items = data['value'];

        // Find and delete existing file
        final existingFile = items.firstWhere(
          (item) => item['folder'] == null && item['name'].toString().toLowerCase() == name.toLowerCase(),
          orElse: () => null,
        );

        if (existingFile != null) {
          final existingId = existingFile['id'];

          final deleteResponse = await http.delete(
            Uri.parse("$_baseUrl/items/$existingId"),
            headers: {'Authorization': 'Bearer $accessToken'},
          );

          if (deleteResponse.statusCode == 204) {
          } else {
          }
        } else {
        }
      }
    }

    // Use chunked upload with upload session (like Google Drive)
    const int chunkSize = 10 * 1024 * 1024; // 10 MB chunks

    // Create upload session
    final uploadUrl = await createUploadSession(
      name: finalName,
      parentId: parentId,
      totalSize: length,
    );

    if (uploadUrl == null) {
      throw Exception("Failed to create OneDrive upload session");
    }


    // TRUE STREAMING: Upload chunks as they arrive from stream
    // Use 50MB chunks for optimal performance (fewer HTTP requests)
    const int uploadChunkSize = 50 * 1024 * 1024; // 50 MB chunks
    const int bufferThreshold = 10 * 1024 * 1024; // 10MB buffer before starting upload
    final List<int> buffer = [];
    int totalUploaded = 0;
    int chunkIndex = 0;


    await for (final chunk in dataStream) {
      // Check for cancellation during data collection
      if (cancellationToken?.isCancelled == true) {
        throw Exception("Upload cancelled by user");
      }

      buffer.addAll(chunk);

      // Upload when buffer reaches threshold
      while (buffer.length >= bufferThreshold) {
        final chunkData = Uint8List.fromList(buffer.take(bufferThreshold).toList());
        buffer.removeRange(0, bufferThreshold);


        final result = await uploadChunkToSession(
          uploadUrl: uploadUrl,
          data: chunkData,
          offset: totalUploaded,
          totalSize: length,
        );

        if (result < 0) {
          throw Exception("Failed to upload chunk at offset $totalUploaded: error code $result");
        }

        totalUploaded += chunkData.length;

        // Progress update
        final progress = totalUploaded / length;
      }
    }

    // Upload remaining data in buffer (less than 1MB)
    if (buffer.isNotEmpty) {
      final chunkData = Uint8List.fromList(buffer);
      buffer.clear();


      final result = await uploadChunkToSession(
        uploadUrl: uploadUrl,
        data: chunkData,
        offset: totalUploaded,
        totalSize: length,
      );

      if (result < 0) {
        throw Exception("Failed to upload final chunk at offset $totalUploaded: error code $result");
      }

      totalUploaded += chunkData.length;
    }


    // Get the uploaded file's ID by querying the API
    uploadedFileId = await getFileIdByName(finalName, parentId);
    
    return uploadedFileId ?? finalName;
  }

  // Helper to format bytes
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // ===========================================================================
  // CREATE FOLDER
  // ===========================================================================

  @override
  Future<String> createFolder(String name, String? parentFolderId, {bool checkDuplicates = true}) async {
    // Get cached access token with in-memory caching
    final accessToken = await _getAccessToken();

    String endpoint = (parentFolderId == null || parentFolderId == 'root')
        ? "$_baseUrl/root/children"
        : "$_baseUrl/items/$parentFolderId/children";

    // First, check if a folder with this name already exists
    final listEndpoint = (parentFolderId == null || parentFolderId == 'root')
        ? "$_baseUrl/root/children"
        : "$_baseUrl/items/$parentFolderId/children";

    final listResponse = await http.get(
      Uri.parse(listEndpoint),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    String finalName = name;
    if (listResponse.statusCode == 200) {
      final data = jsonDecode(listResponse.body);
      final List<dynamic> items = data['value'];

      // Check for existing folder with same name
      final existingFolder = items.firstWhere(
        (item) => item['folder'] != null && item['name'].toString().toLowerCase() == name.toLowerCase(),
        orElse: () => null,
      );

      if (existingFolder != null) {
        // Found existing folder, apply Windows-style duplicate resolution
        final String baseName;
        final String? extension;

        if (name.contains('.')) {
          final lastDot = name.lastIndexOf('.');
          baseName = name.substring(0, lastDot);
          extension = name.substring(lastDot); // Include the dot in extension
        } else {
          baseName = name;
          extension = null;
        }

        // Find highest number in existing duplicates
        int highestNumber = 0;
        // Pattern to match (number) before the extension or at the end
        final pattern = RegExp(r'\((\d+)\)(?=\.[^.]+|$)');

        for (final item in items) {
          if (item['folder'] != null) {
            final itemName = item['name'].toString();
            // Check if this item matches our base name pattern
            final basePattern = RegExp('^${RegExp.escape(baseName)}\\s*\\(\\d+\\)', caseSensitive: false);
            if (basePattern.hasMatch(itemName)) {
              final match = pattern.firstMatch(itemName);
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
        finalName = extension != null
          ? '$baseName ($newNumber)$extension'  // Remove the extra dot
          : '$baseName ($newNumber)';

      }
    } else {
    }

    final response = await http.post(
      Uri.parse(endpoint),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json'
      },
      body: jsonEncode({
        "name": finalName,
        "folder": {},
        "@microsoft.graph.conflictBehavior": "replace" // Use replace since we already handled naming
      }),
    );

    if (response.statusCode != 201) throw Exception("Create Folder Failed");
    return jsonDecode(response.body)['id'];
  }

  // ===========================================================================
  // RENAME NODE
  // ===========================================================================

  @override
  Future<void> renameNode(String cloudId, String newName) async {
    // Get cached access token with in-memory caching
    final accessToken = await _getAccessToken();

    // Validate OneDrive naming constraints
    final validationError = _validateOneDriveName(newName);
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
      final listEndpoint = (parentId == 'root')
          ? "$_baseUrl/root/children"
          : "$_baseUrl/items/$parentId/children";

      final listResponse = await http.get(
        Uri.parse(listEndpoint),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (listResponse.statusCode == 200) {
        final data = jsonDecode(listResponse.body);
        final List<dynamic> items = data['value'];

        // Check for existing file/folder with same name (case-insensitive)
        final existingItem = items.firstWhere(
          (item) =>
              item['id'] != cloudId && // Not the same file
              item['name'].toString().toLowerCase() == newName.toLowerCase(),
          orElse: () => null,
        );

        if (existingItem != null) {
          throw Exception("A file or folder with the name '$newName' already exists");
        }
      }
    }

    // Perform the rename using PATCH
    final response = await http.patch(
      Uri.parse("$_baseUrl/items/$cloudId"),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json'
      },
      body: jsonEncode({
        "name": newName,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to rename: ${response.statusCode} - ${response.body}");
    }

  }

  // ===========================================================================
  // MOVE NODE
  // ===========================================================================

  @override
  Future<void> moveNode(String cloudId, String newParentId, {String? newName}) async {
    // Get cached access token with in-memory caching
    final accessToken = await _getAccessToken();

    // Get current node metadata to validate name
    final metadata = await getFileMetadata(cloudId);
    if (metadata == null) {
      throw Exception("File not found: $cloudId");
    }

    // If new name is provided, validate it first
    if (newName != null) {
      final validationError = _validateOneDriveName(newName);
      if (validationError != null) {
        throw Exception(validationError);
      }

      // Check for name conflicts in the new parent
      String listEndpoint = (newParentId == 'root')
          ? "$_baseUrl/root/children"
          : "$_baseUrl/items/$newParentId/children";

      final listResponse = await http.get(
        Uri.parse(listEndpoint),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (listResponse.statusCode == 200) {
        final data = jsonDecode(listResponse.body);
        final List<dynamic> items = data['value'];

        // Check for existing file/folder with same name (case-insensitive)
        final existingItem = items.firstWhere(
          (item) =>
              item['id'] != cloudId && // Not the same file
              item['name'].toString().toLowerCase() == newName.toLowerCase(),
          orElse: () => null,
        );

        if (existingItem != null) {
          throw Exception("A file or folder with name '$newName' already exists in the destination");
        }
      }
    }

    // OneDrive Move API: PATCH /items/{id} with new parent reference
    final patchData = <String, dynamic>{
      "parentReference": {
        "id": newParentId == 'root' ? null : newParentId,
      },
    };

    if (newName != null) {
      patchData["name"] = newName;
    }

    final response = await http.patch(
      Uri.parse("$_baseUrl/items/$cloudId"),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json'
      },
      body: jsonEncode(patchData),
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to move: ${response.statusCode} - ${response.body}");
    }

  }

  /// Validate OneDrive naming constraints
  /// Returns error message if invalid, null if valid
  String? _validateOneDriveName(String name) {
    // Check for empty name
    if (name.trim().isEmpty) {
      return "Name cannot be empty";
    }

    // Check length (max 400 characters)
    if (name.length > 400) {
      return "Name cannot exceed 400 characters";
    }

    // Check for invalid characters: \ / : * ? " < > |
    final invalidChars = RegExp(r'[\\/:*?"<>|]');
    if (invalidChars.hasMatch(name)) {
      return "Name cannot contain any of the following characters: \\ / : * ? \" < > |";
    }

    // Check for reserved names (case-insensitive)
    final reservedNames = [
      'CON', 'PRN', 'AUX', 'NUL',
      'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
      'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    ];

    // Check if name is exactly a reserved name (with or without extension)
    final baseName = name.contains('.') ? name.substring(0, name.indexOf('.')) : name;
    if (reservedNames.contains(baseName.toUpperCase())) {
      return "Name cannot be a reserved system name: $baseName";
    }

    // Check for leading/trailing spaces
    if (name != name.trim()) {
      return "Name cannot start or end with a space";
    }

    // Check for trailing period
    if (name.endsWith('.')) {
      return "Name cannot end with a period";
    }

    return null; // Name is valid
  }

  // ===========================================================================
  // DELETE NODE
  // ===========================================================================

  @override
  Future<void> deleteNode(String cloudId) async {
    // Get cached access token with in-memory caching
    final accessToken = await _getAccessToken();

    // Try to delete with exponential backoff for locked files
    bool deleted = false;
    int attempts = 0;
    const maxAttempts = 5;

    while (!deleted && attempts < maxAttempts) {
      attempts++;
      if (attempts > 1) {
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
        final delay = Duration(seconds: pow(2, attempts - 1).toInt());
        await Future.delayed(delay);
      }

      final response = await http.delete(
        Uri.parse("$_baseUrl/items/$cloudId"),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (response.statusCode == 204) {
        deleted = true;
      } else if (response.statusCode == 423) {
        if (attempts >= maxAttempts) {
          throw Exception("File is locked and cannot be deleted after $maxAttempts attempts: ${response.body}");
        }
      } else {
        if (attempts >= maxAttempts) {
          throw Exception("Failed to delete OneDrive file after $maxAttempts attempts: ${response.statusCode} - ${response.body}");
        }
      }
    }
  }

  @override
  Future<void> downloadFile(String fileId, String savePath) async {
    // Use the existing downloadStream implementation
    final stream = await downloadStream(fileId);
    final file = File(savePath);
    final sink = file.openWrite();
    await stream.pipe(sink);
    await sink.close();
  }

  @override
  Future<void> uploadFile(String localPath, String? parentFolderId) async {
    final file = File(localPath);
    final length = await file.length();
    final stream = file.openRead();
    final fileName = localPath.split(Platform.pathSeparator).last;

    // Use the existing uploadStream implementation
    await uploadStream(fileName, stream, length, parentFolderId);
  }

  // ===========================================================================
  // COPY FOLDER
  // ===========================================================================

  @override
  Future<String> copyFolder(String sourceFolderId, String? destinationParentId, String newName, {bool checkDuplicates = true}) async {
    // OneDrive doesn't have a simple copy folder API like Google Drive.
    // We need to:
    // 1. Create a new folder at the destination with the desired name
    // 2. Recursively copy all contents from source to destination folder


    // Step 1: Determine the destination parent ID
    String? destParentId;
    if (destinationParentId == null || destinationParentId == 'root') {
      destParentId = null; // Will use root
    } else {
      destParentId = destinationParentId;
    }

    // Step 2: Create new folder at destination with duplicate resolution
    final newFolderId = await createFolder(newName, destParentId, checkDuplicates: checkDuplicates);

    // Step 3: Recursively copy all contents from source folder to new folder
    await _copyFolderContentsRecursively(sourceFolderId, newFolderId);

    return newFolderId;
  }

  /// Recursively copy all contents from source folder to destination folder
  Future<void> _copyFolderContentsRecursively(String sourceFolderId, String destFolderId) async {

    // Get cached access token with in-memory caching
    final accessToken = await _getAccessToken();

    // List all items in source folder
    String sourceEndpoint = (sourceFolderId == 'root')
        ? "$_baseUrl/root/children"
        : "$_baseUrl/items/$sourceFolderId/children";

    final response = await http.get(
      Uri.parse(sourceEndpoint),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to list OneDrive folder contents: ${response.body}");
    }

    final data = jsonDecode(response.body);
    final List<dynamic> items = data['value'];


    // Process items in parallel for better performance
    final futures = <Future<void>>[];

    for (final item in items) {
      final isFolder = item['folder'] != null;
      final itemId = item['id'];
      final itemName = item['name'];

      if (isFolder) {
        // It's a subfolder - create it and recurse
        futures.add(_copySubFolder(itemName, itemId, destFolderId));
      } else {
        // It's a file - copy it directly using OneDrive's copy API
        futures.add(_copyFileToFolder(itemId, itemName, destFolderId));
      }
    }

    // Wait for all copy operations to complete
    if (futures.isNotEmpty) {
      await Future.wait(futures, eagerError: false);
    }

  }

  /// Helper to copy a subfolder recursively
  Future<void> _copySubFolder(String folderName, String sourceFolderId, String destParentId) async {
    try {
      // Create subfolder in destination
      final newSubFolderId = await createFolder(folderName, destParentId, checkDuplicates: true);

      // Recursively copy contents
      await _copyFolderContentsRecursively(sourceFolderId, newSubFolderId);
    } catch (e) {
    }
  }

  /// Helper to copy a file to a folder
  Future<void> _copyFileToFolder(String sourceFileId, String fileName, String destFolderId) async {
    // Get cached access token with in-memory caching
    final accessToken = await _getAccessToken();

    try {
      // Use OneDrive's copy API for files
      // POST /items/{item-id}/copy
      final copyEndpoint = "$_baseUrl/items/$sourceFileId/copy";

      final response = await http.post(
        Uri.parse(copyEndpoint),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({
          "parentReference": {
            "id": destFolderId == 'root' ? null : destFolderId,
            "path": destFolderId == 'root' ? "/drive/root" : null
          },
          "name": fileName
        }),
      );

      if (response.statusCode != 202 && response.statusCode != 200) {
        throw Exception("Failed to copy OneDrive file: ${response.statusCode} - ${response.body}");
      }

    } catch (e) {
    }
  }

  // ===========================================================================
  // FILE METADATA
  // ===========================================================================

  @override
  Future<CloudNode?> getFileMetadata(String fileId) async {
    // Get cached access token with in-memory caching
    final accessToken = await _getAccessToken();

    try {
      // Get file metadata from OneDrive API
      final endpoint = "$_baseUrl/items/$fileId";

      final response = await http.get(
        Uri.parse(endpoint),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (response.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(response.body);
      final isFolder = data['folder'] != null;
      final fileSize = isFolder ? 0 : (data['size'] as int? ?? 0);

      return CloudNode(
        id: data['id'],
        parentId: null,
        cloudId: data['id'],
        accountId: _accountId,
        name: data['name'],
        isFolder: isFolder,
        provider: 'onedrive',
        updatedAt: DateTime.parse(data['lastModifiedDateTime']),
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
      // Get cached access token with in-memory caching
      final accessToken = await _getAccessToken();

      // Determine the endpoint based on parent folder
      String endpoint;
      if (parentFolderId == null || parentFolderId == 'root') {
        endpoint = "$_baseUrl/root/children";
      } else {
        endpoint = "$_baseUrl/items/$parentFolderId/children";
      }

      // Search for file by name in the parent folder
      final response = await http.get(
        Uri.parse(endpoint),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (response.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(response.body);
      final List<dynamic> items = data['value'];

      // Find the file with matching name
      final matchingItem = items.firstWhere(
        (item) => item['name'] == fileName && item['folder'] == null,
        orElse: () => null,
      );

      if (matchingItem != null) {
        final fileId = matchingItem['id'] as String;
        return fileId;
      }

      return null;
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

    // Get cached access token with in-memory caching
    final accessToken = await _getAccessToken();


    try {
      // Call the Drive API to get storage quota
      final response = await http.get(
        Uri.parse("$_baseUrl?\$select=quota"),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (response.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(response.body);
      final quota = data['quota'];

      if (quota == null) {
        return null;
      }

      final totalBytes = quota['total'] as int? ?? 0;
      final usedBytes = quota['used'] as int? ?? 0;
      final remainingBytes = quota['remaining'] as int? ?? (totalBytes - usedBytes);

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
  // PATH RESOLUTION (For Rclone)
  // ===========================================================================

  @override
  Future<String?> getPathFromId(String fileId) async {
    try {

      // Get cached access token with in-memory caching
      final accessToken = await _getAccessToken();

      // Build the path by traversing parent hierarchy
      final pathSegments = <String>[];
      String? currentId = fileId;

      // Traverse up to root, collecting path segments
      while (currentId != null && currentId != 'root') {
        // Get the file's metadata including its parent
        final response = await http.get(
          Uri.parse("$_baseUrl/items/$currentId?\$select=id,name,parentReference"),
          headers: {'Authorization': 'Bearer $accessToken'},
        );

        if (response.statusCode != 200) {
          break;
        }

        final data = jsonDecode(response.body);

        if (data['name'] == null) {
          break;
        }

        // Add this segment to the beginning of the path
        pathSegments.insert(0, data['name']);

        // Move to parent
        final parentRef = data['parentReference'];
        if (parentRef != null && parentRef['id'] != null) {
          currentId = parentRef['id'];
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
  // TRANSFER API (Not supported by OneDrive)
  // ===========================================================================

  @override
  Future<String?> transferFileOwnership({
    required String fileId,
    required String targetDriveId,
    String? destinationFolderId,
  }) async {
    // OneDrive doesn't support instant file ownership transfer
    // Falls back to streaming in CloudStreamService
    return null;
  }

  @override
  Future<List<String>> transferMultipleFiles({
    required List<String> fileIds,
    required String targetDriveId,
    String? destinationFolderId,
    Function(int, int)? onProgress,
  }) async {
    // OneDrive doesn't support batch file ownership transfer
    return [];
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
      final sourceFile = await getFileMetadata(sourceFileId);
      final String finalName = newName ?? sourceFile?.name ?? "Untitled";

      // Use OneDrive's native copy API
      // POST /items/{item-id}/copy
      final copyEndpoint = "$_baseUrl/items/$sourceFileId/copy";

      final response = await http.post(
        Uri.parse(copyEndpoint),
        headers: {
          'Authorization': 'Bearer ${await _getAccessToken()}',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({
          "parentReference": {
            "id": destinationParentId == 'root' ? null : destinationParentId,
          },
          "name": finalName
        }),
      );

      if (response.statusCode == 202 || response.statusCode == 200) {
        // OneDrive returns 202 Accepted for async copy
        // The file will be copied in the background
        return sourceFileId;
      } else if (response.statusCode == 201) {
        return null;
      } else {
        return null;
      }
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
      return await _getAccessToken();
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


      final accessToken = await _getAccessToken();
      final response = await http.get(
        Uri.parse("$_baseUrl/items/$fileId/content"),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Range': rangeHeader,
        },
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

  /// Upload a chunk of data to a file using upload session
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


      final accessToken = await _getAccessToken();

      if (isNewFile) {
        // For new files, use the simple upload API (max 4MB)
        final response = await http.put(
          Uri.parse("$_baseUrl/items/$fileId/content"),
          headers: {
            'Authorization': 'Bearer $accessToken',
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
        final response = await http.patch(
          Uri.parse("$_baseUrl/items/$fileId/content"),
          headers: {
            'Authorization': 'Bearer $accessToken',
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

  /// Create a new file upload session and return the item ID
  ///
  /// This is the first step for uploading a new file in chunks.
  /// OneDrive uses createUploadSession for large files.
  ///
  /// [name] - The name of the new file
  /// [parentId] - The parent folder ID (null for root)
  /// [totalSize] - The total size of the file in bytes
  /// [contentType] - The MIME type of the file
  ///
  /// Returns the new item ID, or null on error
  Future<String?> createUploadSession({
    required String name,
    String? parentId,
    required int totalSize,
    String contentType = 'application/octet-stream',
  }) async {
    try {

      final accessToken = await _getAccessToken();

      // Create upload session
      final response = await http.post(
        Uri.parse("$_baseUrl/items/$parentId:/${Uri.encodeComponent(name)}:/createUploadSession"),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          "item": {
            "@microsoft.graph.conflictBehavior": "rename",
            "name": name,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final uploadUrl = data['uploadUrl'] as String?;
        if (uploadUrl != null) {
          // Return the upload URL as the "fileId" for subsequent chunk uploads
          return uploadUrl;
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Upload a chunk using the upload session URL
  ///
  /// This is used for large file uploads via upload session.
  ///
  /// [uploadUrl] - The upload URL from createUploadSession
  /// [data] - The chunk data to upload
  /// [offset] - The byte offset in the file
  /// [totalSize] - The total size of the file
  ///
  /// Returns 0 on success, negative error code on failure
  Future<int> uploadChunkToSession({
    required String uploadUrl,
    required Uint8List data,
    required int offset,
    required int totalSize,
  }) async {
    try {
      if (data.isEmpty) return 0;

      final contentLength = data.length;
      final rangeEnd = offset + contentLength - 1;
      final contentRange = 'bytes $offset-$rangeEnd/$totalSize';


      final response = await http.put(
        Uri.parse(uploadUrl),
        headers: {
          'Content-Length': contentLength.toString(),
          'Content-Range': contentRange,
        },
        body: data,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return 0;
      } else if (response.statusCode == 202 || response.statusCode == 204) {
        // Upload session accepted more data
        return 0;
      } else {
        return -response.statusCode;
      }
    } catch (e) {
      return -1;
    }
  }
}