import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/cloud_node.dart';
import '../models/cloud_account.dart';
import '../services/encryption_name_service.dart';
import '../themes/ubuntu_theme.dart';
import 'icons/icon_config.dart';
import 'icons/icon_theme_provider.dart';
import 'icons/3d_file_icon_widget.dart';
import 'icons/3d_folder_icon_widget.dart';

/// Ubuntu-style file item with ultra-responsive hover effects optimized for 240Hz
class FileItem extends StatefulWidget {
  final CloudNode node;
  final bool isSelected;
  final VoidCallback? onTap;
  final Function(CloudNode, Offset)? onSecondaryTap;
  final ValueChanged<bool>? onSelectedChanged;
  final bool isGridView;
  final VoidCallback? onCtrlClick;
  final bool isVirtualDrive;
  final CloudAccount? sourceAccount;

  const FileItem({
    Key? key,
    required this.node,
    this.isSelected = false,
    this.onTap,
    this.onSecondaryTap,
    this.onSelectedChanged,
    this.isGridView = false,
    this.onCtrlClick,
    this.isVirtualDrive = false,
    this.sourceAccount,
  }) : super(key: key);

  @override
  State<FileItem> createState() => _FileItemState();
}

class _FileItemState extends State<FileItem> {
  bool _isHovered = false;
  String? _displayName; // Cached display name for encrypted files
  bool _displayNameLoaded = false;
  
  // Cached metadata values to avoid recalculation
  String? _cachedFileType;
  String? _cachedFileSize;
  String? _cachedModifiedDate;
  bool _metadataCached = false;

  @override
  void initState() {
    super.initState();
    
    // Trigger display name lookup for encrypted files
    if (widget.node.isFolder == false &&
        EncryptionNameService.instance.isEncryptedFilename(widget.node.name)) {
      _lookupDisplayName();
    }
    
    // Pre-cache metadata for list view
    if (!widget.isGridView) {
      _cacheMetadata();
    }
  }

  @override
  void didUpdateWidget(FileItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Check if node changed and we need to lookup display name
    if (oldWidget.node.name != widget.node.name || oldWidget.node.id != widget.node.id) {
      _displayNameLoaded = false;
      _displayName = null;
      _metadataCached = false;
      _cachedFileType = null;
      _cachedFileSize = null;
      _cachedModifiedDate = null;
      
      // Re-cache metadata if node changed
      if (!widget.isGridView) {
        _cacheMetadata();
      }
    }
  }
  
  void _cacheMetadata() {
    if (_metadataCached) return;
    
    _cachedFileType = _getFileType();
    _cachedFileSize = _formatFileSize();
    _cachedModifiedDate = _formatModifiedDate();
    _metadataCached = true;
  }

  void _handleHoverChange(bool isHovered) {
    if (_isHovered != isHovered) {
      setState(() {
        _isHovered = isHovered;
      });
    }
  }

  void _handleTap() {
    HapticFeedback.lightImpact();
    
    // Check if Ctrl key is pressed for Ctrl+Click selection
    final isCtrlPressed = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.controlLeft) ||
                        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.controlRight) ||
                        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.metaLeft) ||
                        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.metaRight);
    
    if (isCtrlPressed && widget.onCtrlClick != null) {
      widget.onCtrlClick?.call();
    } else {
      widget.onTap?.call();
    }
  }

  void _handleSecondaryTap(TapDownDetails details) {
    HapticFeedback.lightImpact();
    widget.onSecondaryTap?.call(widget.node, details.globalPosition);
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: MouseRegion(
        onEnter: (_) => _handleHoverChange(true),
        onExit: (_) => _handleHoverChange(false),
        child: GestureDetector(
          onTap: _handleTap,
          onSecondaryTapDown: _handleSecondaryTap,
          child: Container(
            decoration: BoxDecoration(
              color: _isHovered ? UbuntuColors.veryLightGrey : UbuntuColors.white,
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              border: Border.all(
                color: widget.isSelected
                    ? UbuntuColors.orange
                    : _isHovered
                        ? UbuntuColors.lightGrey
                        : UbuntuColors.lightGrey.withOpacity(0.5),
                width: widget.isSelected ? 2.0 : 1.0,
              ),
              boxShadow: _isHovered || widget.isSelected
                  ? [
                      BoxShadow(
                        color: UbuntuColors.black.withOpacity(0.1),
                        blurRadius: 4.0,
                        offset: Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: widget.isGridView
                ? _buildGridViewItem()
                : _buildListViewItem(),
          ),
        ),
      ),
    );
  }

  Widget _buildGridViewItem() {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Checkbox for selection (top right corner)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: UbuntuColors.white.withOpacity(0.9),
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
                child: Checkbox(
                  value: widget.isSelected,
                  onChanged: (value) {
                    widget.onSelectedChanged?.call(value ?? false);
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Icon centered horizontally
          Center(
            child: _buildIcon(size: 64),
          ),
          const SizedBox(height: 6),
          // Name below icon with proper text wrapping
          _buildName(isCentered: true),
        ],
      ),
    );
  }

  Widget _buildListViewItem() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: SizedBox(
        height: 32, // Fixed height like 24px icons
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Checkbox for selection
            Transform.translate(
              offset: const Offset(0, 0),
              child: Checkbox(
                value: widget.isSelected,
                onChanged: (value) {
                  widget.onSelectedChanged?.call(value ?? false);
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 8),
            // Icon will overflow but display at 64px
            SizedBox(
              width: 64,
              height: 64,
              child: _buildIcon(size: 64),
            ),
            const SizedBox(width: 12),
            Expanded(child: _buildName(isCentered: false)),
            _buildMetadata(),
          ],
        ),
      ),
    );
  }

  Widget _buildIcon({required double size}) {
    // Determine icon size enum
    final iconSize = size <= 48 ? IconSize.medium : (size <= 64 ? IconSize.large : IconSize.extraLarge);

    if (widget.node.isFolder) {
      // Determine folder variant
      FolderVariant variant = FolderVariant.regular;
      if (widget.node.name.toLowerCase().contains('encrypted') ||
          EncryptionNameService.instance.isEncryptedFilename(widget.node.name)) {
        variant = FolderVariant.encrypted;
      } else if (widget.node.name.toLowerCase().contains('shared')) {
        variant = FolderVariant.shared;
      }

      return D3DFolderIconWidget(
        variant: variant,
        size: iconSize,
        isSelected: widget.isSelected,
        isHovered: _isHovered,
      );
    } else {
      return D3DFileIconWidget(
        fileName: widget.node.name,
        size: iconSize,
        isSelected: widget.isSelected,
        isHovered: _isHovered,
      );
    }
  }

  Widget _buildName({required bool isCentered}) {
    // Get display name (original name for encrypted files)
    final displayName = _getDisplayName();
    
    return Text(
      displayName,
      style: TextStyle(
        fontSize: widget.isGridView ? 12 : 14,
        fontWeight: widget.isSelected ? FontWeight.w600 : FontWeight.w400,
        color: widget.isSelected ? UbuntuColors.orange : UbuntuColors.darkGrey,
        fontFamily: 'Ubuntu',
      ),
      textAlign: isCentered ? TextAlign.center : TextAlign.left,
      maxLines: widget.isGridView ? 2 : 1,
      overflow: TextOverflow.ellipsis,
    );
  }
  
  String _getDisplayName() {
    if (widget.node.isFolder) {
      return widget.node.name;
    }
      
    // Return cached display name if available
    if (_displayName != null) {
      return _displayName!;
    }
      
    // Check if this is an encrypted filename
    if (EncryptionNameService.instance.isEncryptedFilename(widget.node.name)) {
      // Trigger lookup if not already done
      if (!_displayNameLoaded) {
        _lookupDisplayName();
      }
      return widget.node.name; // Return encrypted name for now
    }
      
    return widget.node.name;
  }
  
  void _lookupDisplayName() async {
    if (_displayNameLoaded) return;
    
    try {
      final originalName = await EncryptionNameService.instance.getOriginalName(widget.node.name);
      if (originalName != null && mounted) {
        setState(() {
          _displayName = originalName;
          _displayNameLoaded = true;
        });
      }
    } catch (e) {
      _displayNameLoaded = true; // Mark as loaded to prevent retry
    }
  }

  Widget _buildMetadata() {
    if (widget.isGridView) return const SizedBox.shrink();
    
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drive source column (only for virtual drives) - moved before Type column
        if (widget.isVirtualDrive) ...[
          SizedBox(
            width: 120,
            child: _buildDriveSource(),
          ),
          const SizedBox(width: 16),
        ],
        // Type column
        SizedBox(
          width: 60,
          child: Text(
            _getCachedFileType(),
            style: const TextStyle(
              fontSize: 12,
              color: UbuntuColors.textGrey,
              fontFamily: 'Ubuntu',
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 16),
        // Size column
        SizedBox(
          width: 70,
          child: Text(
            _getCachedFileSize(),
            style: const TextStyle(
              fontSize: 12,
              color: UbuntuColors.textGrey,
              fontFamily: 'Ubuntu',
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 16),
        // Modified date column
        SizedBox(
          width: 120,
          child: Text(
            _getCachedModifiedDate(),
            style: const TextStyle(
              fontSize: 12,
              color: UbuntuColors.textGrey,
              fontFamily: 'Ubuntu',
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildDriveSource() {
    if (widget.sourceAccount == null) {
      return const Text(
        'Unknown',
        style: TextStyle(
          fontSize: 12,
          color: Colors.grey,
          fontFamily: 'Ubuntu',
        ),
        overflow: TextOverflow.ellipsis,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _getProviderIcon(widget.sourceAccount!.provider),
          size: 12,
          color: _getProviderColor(widget.sourceAccount!.provider),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            widget.sourceAccount!.name ?? widget.sourceAccount!.email ?? 'Unknown',
            style: TextStyle(
              fontSize: 12,
              color: _getProviderColor(widget.sourceAccount!.provider),
              fontFamily: 'Ubuntu',
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  IconData _getProviderIcon(String provider) {
    switch (provider) {
      case 'gdrive':
        return Icons.add_to_drive;
      case 'onedrive':
        return Icons.cloud;
      case 'dropbox':
        return Icons.folder;
      default:
        return Icons.cloud;
    }
  }

  Color _getProviderColor(String provider) {
    switch (provider) {
      case 'gdrive':
        return Colors.green;
      case 'onedrive':
        return Colors.blue;
      case 'dropbox':
        return Colors.blue.shade800;
      default:
        return Colors.grey;
    }
  }

  String _formatFileSize() {
    // Use cached value if available
    if (_cachedFileSize != null) {
      return _cachedFileSize!;
    }
    
    if (widget.node.isFolder) {
      return '--';
    }
    
    final bytes = widget.node.size;
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
  }

  String _getFileType() {
    if (widget.node.isFolder) {
      return 'Folder';
    }
    
    return IconConfig.getFileTypeLabel(widget.node.name);
  }

  String _formatModifiedDate() {
    // Use cached value if available
    if (_cachedModifiedDate != null) {
      return _cachedModifiedDate!;
    }
    
    final date = widget.node.updatedAt;
    // Format as: MM/DD/YYYY HH:MM AM/PM with local timezone
    return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year} ${_formatTime(date)}';
  }

  String _formatTime(DateTime date) {
    final hour = date.hour;
    final minute = date.minute;
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '${displayHour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $period';
  }
  
  String _getCachedFileType() {
    if (_cachedFileType != null) {
      return _cachedFileType!;
    }
    return _getFileType();
  }
  
  String _getCachedFileSize() {
    if (_cachedFileSize != null) {
      return _cachedFileSize!;
    }
    return _formatFileSize();
  }
  
  String _getCachedModifiedDate() {
    if (_cachedModifiedDate != null) {
      return _cachedModifiedDate!;
    }
    return _formatModifiedDate();
  }
}

/// Ubuntu-style file list with ultra-high performance
class UbuntuFileList extends StatelessWidget {
  final List<CloudNode> files;
  final Set<String> selectedFiles;
  final Function(CloudNode) onFileTap;
  final Function(CloudNode, Offset) onFileSecondaryTap;
  final Function(CloudNode, bool) onSelectionChanged;
  final bool isGridView;
  final ScrollController? scrollController;
  final Function(CloudNode)? onFileCtrlClick;
  final bool isVirtualDrive;
  final Map<String, CloudAccount>? sourceAccounts;
  final bool hasMore;
  final bool isLoadingMore;

  const UbuntuFileList({
    Key? key,
    required this.files,
    required this.selectedFiles,
    required this.onFileTap,
    required this.onFileSecondaryTap,
    required this.onSelectionChanged,
    this.isGridView = false,
    this.scrollController,
    this.onFileCtrlClick,
    this.isVirtualDrive = false,
    this.sourceAccounts,
    this.hasMore = false,
    this.isLoadingMore = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final effectiveItemCount = files.length + (isLoadingMore ? 1 : 0);
    
    if (isGridView) {
      return GridView.builder(
        controller: scrollController,
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 6,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 0.85,
        ),
        itemCount: effectiveItemCount,
        addAutomaticKeepAlives: true,
        addRepaintBoundaries: true,
        cacheExtent: 500.0,
        itemBuilder: (context, index) {
          // Show loading indicator at the end
          if (index == files.length) {
            return _buildLoadingIndicator();
          }
          
          final file = files[index];
          return FileItem(
            key: ValueKey(file.id),
            node: file,
            isSelected: selectedFiles.contains(file.id),
            onTap: () => onFileTap(file),
            onSecondaryTap: onFileSecondaryTap,
            onSelectedChanged: (selected) => onSelectionChanged(file, selected),
            isGridView: true,
            onCtrlClick: onFileCtrlClick != null ? () => onFileCtrlClick!(file) : null,
            isVirtualDrive: isVirtualDrive,
            sourceAccount: (file.sourceAccountId != null && sourceAccounts != null)
                ? sourceAccounts![file.sourceAccountId!]
                : null,
          );
        },
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: effectiveItemCount,
      addAutomaticKeepAlives: true,
      addRepaintBoundaries: true,
      cacheExtent: 500.0,
      itemBuilder: (context, index) {
        // Show loading indicator at the end
        if (index == files.length) {
          return _buildLoadingIndicator();
        }
        
        final file = files[index];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: FileItem(
            key: ValueKey(file.id),
            node: file,
            isSelected: selectedFiles.contains(file.id),
            onTap: () => onFileTap(file),
            onSecondaryTap: onFileSecondaryTap,
            onSelectedChanged: (selected) => onSelectionChanged(file, selected),
            isGridView: false,
            onCtrlClick: onFileCtrlClick != null ? () => onFileCtrlClick!(file) : null,
            isVirtualDrive: isVirtualDrive,
            sourceAccount: (file.sourceAccountId != null && sourceAccounts != null)
                ? sourceAccounts![file.sourceAccountId!]
                : null,
          ),
        );
      },
    );
  }
  
  Widget _buildLoadingIndicator() {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: CircularProgressIndicator(
          strokeWidth: 3,
          valueColor: AlwaysStoppedAnimation<Color>(
            UbuntuColors.orange,
          ),
        ),
      ),
    );
  }
}