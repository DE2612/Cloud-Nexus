import 'package:flutter/material.dart';
import '../models/cloud_node.dart';
import '../providers/file_system_provider.dart';
import '../services/notification_service.dart';

class ContextMenu extends StatelessWidget {
  final CloudNode node;
  final FileSystemProvider fs;
  final VoidCallback onClose;

  const ContextMenu({
    super.key,
    required this.node,
    required this.fs,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: Theme.of(context).dividerColor,
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (node.isFolder) ...[
            _buildMenuItem(
              context,
              icon: Icons.open_in_browser,
              title: 'Open',
              onTap: () {
                onClose();
                fs.enterFolder(node);
              },
            ),
            const Divider(height: 1),
          ],
          
          _buildMenuItem(
            context,
            icon: Icons.copy,
            title: 'Copy',
            onTap: () {
              onClose();
              fs.copyNode(node);
              NotificationService().success(
                '${node.name} copied',
                title: 'Copied',
              );
            },
          ),
          
          if (fs.clipboardNode != null)
            _buildMenuItem(
              context,
              icon: Icons.paste,
              title: 'Paste',
              onTap: () {
                onClose();
                _pasteFile(context, fs);
              },
            ),
          
          const Divider(height: 1),
          
          if (!node.isFolder && node.provider != 'local')
            _buildMenuItem(
              context,
              icon: Icons.download,
              title: 'Download',
              onTap: () {
                onClose();
                _downloadFile(context, node, fs);
              },
            ),
          
          _buildMenuItem(
            context,
            icon: Icons.info_outline,
            title: 'Properties',
            onTap: () {
              onClose();
              _showProperties(context, node);
            },
          ),
          
          const Divider(height: 1),
          
          _buildMenuItem(
            context,
            icon: Icons.delete,
            title: 'Delete',
            iconColor: Colors.red,
            textColor: Colors.red,
            onTap: () {
              onClose();
              _deleteFile(context, node, fs);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMenuItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    Color? iconColor,
    Color? textColor,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: iconColor ?? Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
            ),
            const SizedBox(width: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: textColor ?? Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _downloadFile(BuildContext context, CloudNode node, FileSystemProvider fs) async {
    try {
      await fs.downloadNode(node);
      if (context.mounted) {
        NotificationService().success(
          '${node.name} downloaded',
          title: 'Download Complete',
        );
      }
    } catch (e) {
      if (context.mounted) {
        NotificationService().error(
          'Failed to download ${node.name}: $e',
          title: 'Download Error',
        );
      }
    }
  }

  void _pasteFile(BuildContext context, FileSystemProvider fs) async {
    try {
      await fs.pasteNode();
      if (context.mounted) {
        NotificationService().success(
          'Paste completed successfully',
          title: 'Paste Complete',
        );
      }
    } catch (e) {
      if (context.mounted) {
        NotificationService().error(
          'Paste failed: $e',
          title: 'Paste Error',
        );
      }
    }
  }

  void _deleteFile(BuildContext context, CloudNode node, FileSystemProvider fs) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Are you sure you want to delete "${node.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await fs.deleteNode(node);
        if (context.mounted) {
          NotificationService().success(
            '${node.name} deleted',
            title: 'Deleted',
          );
        }
      } catch (e) {
        if (context.mounted) {
          NotificationService().error(
            'Failed to delete ${node.name}: $e',
            title: 'Delete Error',
          );
        }
      }
    }
  }

  void _showProperties(BuildContext context, CloudNode node) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Properties'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPropertyRow('Name', node.name),
            _buildPropertyRow('Type', node.isFolder ? 'Folder' : 'File'),
            _buildPropertyRow('Provider', _getProviderDisplayName(node.provider)),
            // CloudNode doesn't have size property
            _buildPropertyRow('Modified', node.updatedAt.toString()),
            _buildPropertyRow('ID', node.id),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildPropertyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }

  String _getProviderDisplayName(String provider) {
    switch (provider) {
      case 'gdrive':
        return 'Google Drive';
      case 'onedrive':
        return 'OneDrive';
      case 'dropbox':
        return 'Dropbox';
      case 'local':
        return 'Local Storage';
      case 'virtual':
        return 'Virtual Drive';
      default:
        return provider;
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
}

class ContextMenuOverlay extends StatelessWidget {
  final Widget child;
  final List<Widget> menuItems;
  final VoidCallback onMenuOpen;
  final VoidCallback onMenuClose;

  const ContextMenuOverlay({
    super.key,
    required this.child,
    required this.menuItems,
    required this.onMenuOpen,
    required this.onMenuClose,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapDown: (details) {
        onMenuOpen();
        _showContextMenu(context, details.globalPosition);
      },
      child: child,
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final overlay = Overlay.of(context);
    late final OverlayEntry overlayEntry;
    
    overlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                overlayEntry.remove();
                onMenuClose();
              },
              child: Container(color: Colors.transparent),
            ),
          ),
          Positioned(
            left: position.dx,
            top: position.dy,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).dividerColor,
                    width: 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: menuItems,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    overlay.insert(overlayEntry);
  }
}