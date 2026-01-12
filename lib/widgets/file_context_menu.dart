import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/cloud_node.dart';
import '../providers/file_system_provider.dart';
import '../themes/ubuntu_theme.dart' as theme;

/// Context menu for file/folder operations
/// Shows different options based on selection type:
/// - Single file: Preview (if supported), Copy, Download, Rename, Delete
/// - Multiple files/folders: Copy, Download, Delete
class FileContextMenu extends StatelessWidget {
  final List<CloudNode> selectedNodes;
  final FileSystemProvider fileSystemProvider;
  final VoidCallback? onPreview;
  final VoidCallback? onCopy;
  final VoidCallback? onDownload;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  const FileContextMenu({
    Key? key,
    required this.selectedNodes,
    required this.fileSystemProvider,
    this.onPreview,
    this.onCopy,
    this.onDownload,
    this.onRename,
    this.onDelete,
  }) : super(key: key);

  /// Show context menu at the specified position with intelligent positioning
  static Future<void> show({
    required BuildContext context,
    required Offset position,
    required List<CloudNode> selectedNodes,
    required FileSystemProvider fileSystemProvider,
    VoidCallback? onPreview,
    VoidCallback? onCopy,
    VoidCallback? onDownload,
    VoidCallback? onRename,
    VoidCallback? onDelete,
  }) async {
    HapticFeedback.lightImpact();
    
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final screenSize = overlay.size;
    
    // Build menu items first to count them
    final items = _buildMenuItems(
      selectedNodes: selectedNodes,
      fileSystemProvider: fileSystemProvider,
      onPreview: onPreview,
      onCopy: onCopy,
      onDownload: onDownload,
      onRename: onRename,
      onDelete: onDelete,
    );
    
    // Estimate menu dimensions
    const double menuItemHeight = 48.0; // Standard menu item height
    const double menuWidth = 200.0;
    const double dividerHeight = 1.0;
    
    // Calculate total height
    double menuHeight = 0;
    for (final item in items) {
      if (item is PopupMenuItem) {
        menuHeight += menuItemHeight;
      } else if (item is PopupMenuDivider) {
        menuHeight += dividerHeight;
      }
    }
    
    // Calculate optimal position
    double left = position.dx;
    double top = position.dy;
    
    // Check if menu would go off the right edge
    if (left + menuWidth > screenSize.width) {
      left = screenSize.width - menuWidth - 8; // 8px padding
    }
    
    // Check if menu would go off the left edge
    if (left < 8) {
      left = 8;
    }
    
    // Check if menu would go off the bottom edge
    if (top + menuHeight > screenSize.height) {
      // Show menu above cursor instead
      top = position.dy - menuHeight;
    }
    
    // Check if menu would go off the top edge
    if (top < 8) {
      top = 8;
    }
    
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(left, top, 0, 0),
        Offset.zero & screenSize,
      ),
      items: items,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      color: theme.UbuntuColors.white,
    );
  }

  /// Build menu items based on selection type
  static List<PopupMenuEntry<void>> _buildMenuItems({
    required List<CloudNode> selectedNodes,
    required FileSystemProvider fileSystemProvider,
    VoidCallback? onPreview,
    VoidCallback? onCopy,
    VoidCallback? onDownload,
    VoidCallback? onRename,
    VoidCallback? onDelete,
  }) {
    final items = <PopupMenuEntry<void>>[];
    
    final isSingleFile = selectedNodes.length == 1 && !selectedNodes.first.isFolder;
    final isSingleFolder = selectedNodes.length == 1 && selectedNodes.first.isFolder;
    
    // Single file options
    if (isSingleFile) {
      final file = selectedNodes.first;
      final canPreview = _canPreviewFile(file, fileSystemProvider);
      
      // Preview option (greyed out if not supported)
      items.add(
        PopupMenuItem<void>(
          enabled: canPreview,
          value: 'preview',
          child: Row(
            children: [
              Icon(
                Icons.visibility,
                size: 18,
                color: canPreview ? theme.UbuntuColors.darkGrey : theme.UbuntuColors.lightGrey,
              ),
              const SizedBox(width: 12),
              Text(
                'Preview',
                style: TextStyle(
                  color: canPreview ? theme.UbuntuColors.darkGrey : theme.UbuntuColors.lightGrey,
                ),
              ),
            ],
          ),
          onTap: canPreview ? onPreview : null,
        ),
      );
      
      items.add(const PopupMenuDivider(height: 1));
    }
    
    // Common options for all selections
    items.add(
      PopupMenuItem<void>(
        value: 'copy',
        child: Row(
          children: [
            const Icon(Icons.copy, size: 18, color: theme.UbuntuColors.darkGrey),
            const SizedBox(width: 12),
            const Text('Copy', style: TextStyle(color: theme.UbuntuColors.darkGrey)),
          ],
        ),
        onTap: onCopy,
      ),
    );
    
    items.add(
      PopupMenuItem<void>(
        value: 'download',
        child: Row(
          children: [
            const Icon(Icons.download, size: 18, color: theme.UbuntuColors.darkGrey),
            const SizedBox(width: 12),
            const Text('Download', style: TextStyle(color: theme.UbuntuColors.darkGrey)),
          ],
        ),
        onTap: onDownload,
      ),
    );
    
    // Rename option only for single file/folder
    if (isSingleFile || isSingleFolder) {
      items.add(
        PopupMenuItem<void>(
          value: 'rename',
          child: Row(
            children: [
              const Icon(Icons.edit, size: 18, color: theme.UbuntuColors.darkGrey),
              const SizedBox(width: 12),
              const Text('Rename', style: TextStyle(color: theme.UbuntuColors.darkGrey)),
            ],
          ),
          onTap: onRename,
        ),
      );
    }
    
    items.add(const PopupMenuDivider(height: 1));
    
    // Delete option for all selections
    items.add(
      PopupMenuItem<void>(
        value: 'delete',
        child: Row(
          children: [
            const Icon(Icons.delete, size: 18, color: Colors.red),
            const SizedBox(width: 12),
            const Text('Delete', style: TextStyle(color: Colors.red)),
          ],
        ),
        onTap: onDelete,
      ),
    );
    
    return items;
  }

  /// Check if a file can be previewed
  static bool _canPreviewFile(CloudNode file, FileSystemProvider fileSystemProvider) {
    // Folders cannot be previewed
    if (file.isFolder) {
      return false;
    }
    
    // Encrypted files cannot be previewed directly
    if (file.name.endsWith('.enc')) {
      return false;
    }
    
    // Check if we have an adapter for this file
    final adapter = fileSystemProvider.getAdapterForAccount(
      file.accountId ?? file.sourceAccountId ?? ''
    );
    
    if (adapter == null) {
      return false;
    }
    
    // Check if file type is supported for preview
    final extension = file.name.split('.').last.toLowerCase();
    final supportedExtensions = [
      // Images
      'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg',
      // Text files
      'txt', 'md', 'json', 'xml', 'csv', 'log',
      // Programming languages
      'c', 'cpp', 'h', 'hpp', 'cs', 'java', 'js', 'ts', 'dart', 'py', 'rb', 'go', 'rs', 'php',
      // Web technologies
      'html', 'css', 'scss', 'jsx', 'tsx', 'vue',
      // Config files
      'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'sh', 'bat', 'ps1', 'gitignore', 'env',
      // Other text formats
      'markdown', 'rst', 'plist', 'props', 'gradle',
      // PDF (basic support)
      'pdf',
    ];
    
    return supportedExtensions.contains(extension);
  }

  @override
  Widget build(BuildContext context) {
    // This widget is mainly used for static methods
    return const SizedBox.shrink();
  }
}

/// Dialog for renaming a file or folder
class RenameDialog extends StatefulWidget {
  final CloudNode node;
  final Function(String) onRename;

  const RenameDialog({
    Key? key,
    required this.node,
    required this.onRename,
  }) : super(key: key);

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.node.name);
    _focusNode = FocusNode();
    
    // Auto-select the filename without extension
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      final lastDot = widget.node.name.lastIndexOf('.');
      if (lastDot > 0) {
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: lastDot,
        );
      } else {
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: widget.node.name.length),
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Validate name based on provider constraints
  String? _validateName(String name) {
    // Check for empty name
    if (name.trim().isEmpty) {
      return "Name cannot be empty";
    }
    
    // Provider-specific validation
    final provider = widget.node.provider.toLowerCase();
    
    if (provider == 'onedrive') {
      // OneDrive naming constraints
      // Check length (max 400 characters)
      if (name.length > 400) {
        return "Name cannot exceed 400 characters";
      }
      
      // Check for invalid characters: \ / : * ? " < > |
      final invalidChars = RegExp(r'[\\/:*?"<>|]');
      if (invalidChars.hasMatch(name)) {
        return "Name cannot contain: \\ / : * ? \" < > |";
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
    } else if (provider == 'gdrive') {
      // Google Drive naming constraints
      // Check length (max 1000 characters)
      if (name.length > 1000) {
        return "Name cannot exceed 1000 characters";
      }
      
      // Check for leading/trailing spaces
      if (name != name.trim()) {
        return "Name cannot start or end with a space";
      }
    }
    
    return null; // Name is valid
  }

  void _handleRename() {
    final newName = _controller.text.trim();
    
    // Validate the name
    final validationError = _validateName(newName);
    if (validationError != null) {
      setState(() {
        _errorMessage = validationError;
      });
      return;
    }
    
    // Check if name hasn't changed
    if (newName == widget.node.name) {
      Navigator.pop(context);
      return;
    }
    
    // Call the rename callback
    widget.onRename(newName);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            widget.node.isFolder ? Icons.folder : Icons.insert_drive_file,
            color: theme.UbuntuColors.orange,
          ),
          const SizedBox(width: 12),
          const Text('Rename'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'New name',
              border: const OutlineInputBorder(),
              errorText: _errorMessage,
            ),
            onChanged: (value) {
              // Clear error when user types
              if (_errorMessage != null) {
                setState(() {
                  _errorMessage = null;
                });
              }
            },
            onSubmitted: (_) => _handleRename(),
          ),
          if (widget.node.provider.toLowerCase() == 'onedrive') ...[
            const SizedBox(height: 8),
            Text(
              'OneDrive naming rules:',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
            Text(
              '• Max 400 characters',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
            Text(
              '• No: \\ / : * ? " < > |',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
            Text(
              '• No reserved names (CON, PRN, etc.)',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _handleRename,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}