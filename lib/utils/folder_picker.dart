import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

/// Utility class for picking folders
class FolderPicker {
  /// Pick a directory using platform-specific method
  static Future<String?> pickDirectory(BuildContext context) async {
    try {
      // Try using file_picker's directory picker first
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Select folder to upload',
          lockParentWindow: true,
        );
        
        if (selectedDirectory != null && selectedDirectory.isNotEmpty) {
          return selectedDirectory;
        }
      }
      
      // Fallback for mobile or if directory picker fails
      return await _showFolderPickerDialog(context);
      
    } catch (e) {
      // Show fallback dialog
      return await _showFolderPickerDialog(context);
    }
  }

  /// Show a custom folder picker dialog as fallback
  static Future<String?> _showFolderPickerDialog(BuildContext context) async {
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return const FolderPickerDialog();
      },
    );
  }

  /// Get folder information (name, size, file count)
  static Future<FolderInfo> getFolderInfo(String folderPath) async {
    final folder = Directory(folderPath);
    if (!await folder.exists()) {
      throw Exception('Folder does not exist: $folderPath');
    }

    int fileCount = 0;
    int folderCount = 0;
    int totalSize = 0;
    String largestFile = '';
    int largestFileSize = 0;

    await for (final entity in folder.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        fileCount++;
        final fileSize = await entity.length();
        totalSize += fileSize;
        
        if (fileSize > largestFileSize) {
          largestFileSize = fileSize;
          largestFile = entity.path;
        }
      } else if (entity is Directory) {
        folderCount++;
      }
    }

    return FolderInfo(
      path: folderPath,
      name: folder.path.split(Platform.pathSeparator).last,
      fileCount: fileCount,
      folderCount: folderCount,
      totalSize: totalSize,
      largestFile: largestFile,
      largestFileSize: largestFileSize,
    );
  }
}

/// Information about a folder
class FolderInfo {
  final String path;
  final String name;
  final int fileCount;
  final int folderCount;
  final int totalSize;
  final String largestFile;
  final int largestFileSize;

  FolderInfo({
    required this.path,
    required this.name,
    required this.fileCount,
    required this.folderCount,
    required this.totalSize,
    required this.largestFile,
    required this.largestFileSize,
  });

  int get totalItems => fileCount + folderCount;
  
  String get formattedSize => _formatBytes(totalSize);
  String get formattedLargestFileSize => _formatBytes(largestFileSize);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Custom folder picker dialog for mobile platforms
class FolderPickerDialog extends StatefulWidget {
  const FolderPickerDialog({super.key});

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  String? _selectedPath;
  List<String> _breadcrumbs = [];
  List<Directory> _directories = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDirectory(Directory.current);
  }

  Future<void> _loadDirectory(Directory directory) async {
    setState(() {
      _isLoading = true;
    });

    try {
      final directories = <Directory>[];
      await for (final entity in directory.list()) {
        if (entity is Directory) {
          directories.add(entity);
        }
      }

      setState(() {
        _selectedPath = directory.path;
        _directories = directories..sort((a, b) => a.path.compareTo(b.path));
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _navigateToDirectory(Directory directory) {
    setState(() {
      _breadcrumbs.add(_selectedPath!);
    });
    _loadDirectory(directory);
  }

  void _navigateToParent() {
    if (_breadcrumbs.isNotEmpty) {
      final parentPath = _breadcrumbs.removeLast();
      _loadDirectory(Directory(parentPath));
    }
  }

  void _navigateToBreadcrumb(int index) {
    final targetPath = _breadcrumbs[index];
    _breadcrumbs.removeRange(index, _breadcrumbs.length);
    _loadDirectory(Directory(targetPath));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Folder'),
      content: SizedBox(
        width: 400,
        height: 500,
        child: Column(
          children: [
            // Breadcrumbs
            _buildBreadcrumbs(),
            const SizedBox(height: 16),
            
            // Directory list
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _buildDirectoryList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _selectedPath != null
              ? () => Navigator.pop(context, _selectedPath)
              : null,
          child: const Text('Select'),
        ),
      ],
    );
  }

  Widget _buildBreadcrumbs() {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _breadcrumbs.isNotEmpty ? _navigateToParent : null,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  TextButton(
                    onPressed: () {
                      _breadcrumbs.clear();
                      _loadDirectory(Directory.current);
                    },
                    child: const Text('Root'),
                  ),
                  if (_breadcrumbs.isNotEmpty) ...[
                    const Text(' > '),
                    ..._breadcrumbs.asMap().entries.map((entry) {
                      final index = entry.key;
                      final path = entry.value;
                      final isLast = index == _breadcrumbs.length - 1;
                      final name = path.split(Platform.pathSeparator).last;
                      
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (index > 0) const Text(' > '),
                          if (!isLast)
                            TextButton(
                              onPressed: () => _navigateToBreadcrumb(index),
                              child: Text(name),
                            )
                          else
                            Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      );
                    }),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDirectoryList() {
    if (_directories.isEmpty) {
      return const Center(
        child: Text('No subdirectories found'),
      );
    }

    return ListView.builder(
      itemCount: _directories.length,
      itemBuilder: (context, index) {
        final directory = _directories[index];
        final name = directory.path.split(Platform.pathSeparator).last;
        
        return ListTile(
          leading: const Icon(Icons.folder),
          title: Text(name),
          subtitle: Text(directory.path),
          onTap: () => _navigateToDirectory(directory),
        );
      },
    );
  }
}