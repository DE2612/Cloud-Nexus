import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/file_system_provider.dart';
import '../providers/selection_provider.dart';
import '../services/security_service.dart';
import '../themes/ubuntu_theme.dart' as theme;

/// Optimized unlock vault button - receives vault state from parent
class VaultUnlockButton extends StatelessWidget {
  final bool isUnlocked;
  final VoidCallback? onUnlock;

  const VaultUnlockButton({
    super.key,
    required this.isUnlocked,
    this.onUnlock,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: isUnlocked ? 'Vault Unlocked' : 'Unlock Vault',
      child: Container(
        height: 32,
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isUnlocked
              ? Colors.green.withOpacity(0.15)
              : Colors.red.withOpacity(0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isUnlocked ? Colors.green : Colors.red,
            width: 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: isUnlocked ? null : onUnlock,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 14,
                  color: isUnlocked ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 6),
                Text(
                  'Unlock Vault',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: isUnlocked ? Colors.green : Colors.red,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Header widget that listens only to SelectionProvider's selected count
/// Uses Selector to prevent unnecessary rebuilds when other provider state changes
class FileListHeader extends StatelessWidget {
  final FileSystemProvider fileSystemProvider;
  final SelectionProvider selectionProvider;
  final VoidCallback? onSelectAll;
  final VoidCallback? onDownload;
  final VoidCallback? onCopy;
  final VoidCallback? onCut;
  final VoidCallback onPaste;
  final VoidCallback? onDelete;
  final VoidCallback onUpload;
  final VoidCallback onFolderUpload;
  final VoidCallback onNewFolder;
  final VoidCallback onViewToggle;
  final VoidCallback? onUnlockVault;
  final bool isGridView;

  const FileListHeader({
    Key? key,
    required this.fileSystemProvider,
    required this.selectionProvider,
    this.onSelectAll,
    this.onDownload,
    this.onCopy,
    this.onCut,
    required this.onPaste,
    this.onDelete,
    required this.onUpload,
    required this.onFolderUpload,
    required this.onNewFolder,
    required this.onViewToggle,
    this.onUnlockVault,
    required this.isGridView,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Selector<SelectionProvider, int>(
      selector: (context, provider) => provider.selectedCount,
      builder: (context, selectedCount, _) {
        final fs = fileSystemProvider;
        final selection = selectionProvider;
        
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: const Border(
              bottom: BorderSide(color: theme.UbuntuColors.lightGrey, width: 1),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 100,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: selectedCount > 0
                      ? theme.UbuntuColors.orange.withOpacity(0.1)
                      : theme.UbuntuColors.lightGrey.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  selectedCount == 0
                      ? '${fs.currentNodes.length} items'
                      : '$selectedCount selected',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selectedCount > 0 ? FontWeight.w600 : FontWeight.w400,
                    color: selectedCount > 0 ? theme.UbuntuColors.orange : theme.UbuntuColors.textGrey,
                    fontFamily: 'Ubuntu',
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildFileOperationButton(
                    icon: selectedCount == fs.currentNodes.length ? Icons.deselect : Icons.select_all,
                    tooltip: selectedCount == fs.currentNodes.length ? 'Deselect All' : 'Select All',
                    onPressed: onSelectAll,
                    isEnabled: true,
                  ),
                  _buildFileOperationButton(
                    icon: Icons.download,
                    tooltip: 'Download',
                    onPressed: selectedCount > 0 ? onDownload : null,
                    isEnabled: selectedCount > 0,
                  ),
                  _buildFileOperationButton(
                    icon: Icons.copy,
                    tooltip: 'Copy',
                    onPressed: selectedCount > 0 ? onCopy : null,
                    isEnabled: selectedCount > 0,
                  ),
                  _buildFileOperationButton(
                    icon: Icons.cut,
                    tooltip: 'Cut',
                    onPressed: selectedCount > 0 ? onCut : null,
                    isEnabled: selectedCount > 0,
                  ),
                  _buildFileOperationButton(
                    icon: Icons.paste,
                    tooltip: 'Paste',
                    onPressed: onPaste,
                    isEnabled: true,
                  ),
                  _buildFileOperationButton(
                    icon: Icons.delete,
                    tooltip: 'Delete',
                    onPressed: selectedCount > 0 ? onDelete : null,
                    isEnabled: selectedCount > 0,
                  ),
                  const SizedBox(width: 8),
                  _buildSortButton(),
                ],
              ),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VaultUnlockButton(
                    isUnlocked: SecurityService.instance.isUnlocked,
                    onUnlock: onUnlockVault,
                  ),
                  const SizedBox(width: 8),
                  _buildFileOperationButton(
                    icon: Icons.upload_file,
                    tooltip: 'Upload',
                    onPressed: onUpload,
                    isEnabled: true,
                  ),
                  _buildFileOperationButton(
                    icon: Icons.cloud_upload,
                    tooltip: 'Upload Folder',
                    onPressed: onFolderUpload,
                    isEnabled: true,
                  ),
                  _buildFileOperationButton(
                    icon: Icons.create_new_folder,
                    tooltip: 'New Folder',
                    onPressed: onNewFolder,
                    isEnabled: true,
                  ),
                  const SizedBox(width: 8),
                  _buildViewToggle(Icons.list, false),
                  const SizedBox(width: 4),
                  _buildViewToggle(Icons.grid_view, true),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFileOperationButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    required bool isEnabled,
  }) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 32,
        height: 32,
        margin: const EdgeInsets.only(right: 4),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: Icon(
              icon,
              size: 16,
              color: isEnabled ? theme.UbuntuColors.darkGrey : theme.UbuntuColors.lightGrey,
            ),
          ),
        ),
      ),
    );
  }


  Widget _buildViewToggle(IconData icon, bool isGrid) {
    return GestureDetector(
      onTap: () {
        if (isGridView != isGrid) {
          onViewToggle();
        }
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isGridView == isGrid ? theme.UbuntuColors.orange.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(
          icon,
          size: 16,
          color: isGridView == isGrid ? theme.UbuntuColors.orange : theme.UbuntuColors.mediumGrey,
        ),
      ),
    );
  }

  Widget _buildSortButton() {
    return Selector<FileSystemProvider, SortOption>(
      selector: (context, provider) => provider.currentSortOption,
      builder: (context, sortOption, _) {
        final sortAscending = fileSystemProvider.sortAscending;
        
        return PopupMenuButton<SortOption>(
          initialValue: sortOption,
          tooltip: 'Sort by',
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          position: PopupMenuPosition.under,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(
                color: theme.UbuntuColors.lightGrey.withOpacity(0.5),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Sort by',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: theme.UbuntuColors.darkGrey,
                    fontFamily: 'Ubuntu',
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_drop_down,
                  size: 14,
                  color: theme.UbuntuColors.darkGrey,
                ),
              ],
            ),
          ),
          itemBuilder: (BuildContext context) => [
            PopupMenuItem<SortOption>(
              value: SortOption.name,
              child: SizedBox(
                width: 180,
                child: Row(
                children: [
                  Icon(
                    Icons.sort_by_alpha,
                    size: 18,
                    color: sortOption == SortOption.name && sortAscending
                        ? theme.UbuntuColors.orange
                        : theme.UbuntuColors.darkGrey,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Name',
                    style: TextStyle(
                      fontSize: 14,
                      color: sortOption == SortOption.name && sortAscending
                          ? theme.UbuntuColors.orange
                          : theme.UbuntuColors.darkGrey,
                      fontFamily: 'Ubuntu',
                      fontWeight: sortOption == SortOption.name ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (sortOption == SortOption.name) ...[
                    const Spacer(),
                    Icon(
                      sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 16,
                      color: theme.UbuntuColors.orange,
                    ),
                  ],
                ],
              ),
            ),
            ),
            PopupMenuItem<SortOption>(
              value: SortOption.size,
              child: SizedBox(
                width: 180,
                child: Row(
                children: [
                  Icon(
                    Icons.straighten,
                    size: 18,
                    color: sortOption == SortOption.size && sortAscending
                        ? theme.UbuntuColors.orange
                        : theme.UbuntuColors.darkGrey,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Size',
                    style: TextStyle(
                      fontSize: 14,
                      color: sortOption == SortOption.size && sortAscending
                          ? theme.UbuntuColors.orange
                          : theme.UbuntuColors.darkGrey,
                      fontFamily: 'Ubuntu',
                      fontWeight: sortOption == SortOption.size ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (sortOption == SortOption.size) ...[
                    const Spacer(),
                    Icon(
                      sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 16,
                      color: theme.UbuntuColors.orange,
                    ),
                  ],
                ],
              ),
            ),
            ),
            PopupMenuItem<SortOption>(
              value: SortOption.dateModified,
              child: SizedBox(
                width: 180,
                child: Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 18,
                    color: sortOption == SortOption.dateModified && sortAscending
                        ? theme.UbuntuColors.orange
                        : theme.UbuntuColors.darkGrey,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Date Modified',
                    style: TextStyle(
                      fontSize: 14,
                      color: sortOption == SortOption.dateModified && sortAscending
                          ? theme.UbuntuColors.orange
                          : theme.UbuntuColors.darkGrey,
                      fontFamily: 'Ubuntu',
                      fontWeight: sortOption == SortOption.dateModified ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (sortOption == SortOption.dateModified) ...[
                    const Spacer(),
                    Icon(
                      sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 16,
                      color: theme.UbuntuColors.orange,
                    ),
                  ],
                ],
              ),
            ),
            ),
            PopupMenuItem<SortOption>(
              value: SortOption.type,
              child: SizedBox(
                width: 180,
                child: Row(
                children: [
                  Icon(
                    Icons.category,
                    size: 18,
                    color: sortOption == SortOption.type && sortAscending
                        ? theme.UbuntuColors.orange
                        : theme.UbuntuColors.darkGrey,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Type',
                    style: TextStyle(
                      fontSize: 14,
                      color: sortOption == SortOption.type && sortAscending
                          ? theme.UbuntuColors.orange
                          : theme.UbuntuColors.darkGrey,
                      fontFamily: 'Ubuntu',
                      fontWeight: sortOption == SortOption.type ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (sortOption == SortOption.type) ...[
                    const Spacer(),
                    Icon(
                      sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 16,
                      color: theme.UbuntuColors.orange,
                    ),
                  ],
                ],
              ),
            ),
            ),
          ],
          onSelected: (SortOption? selectedOption) {
            if (selectedOption != null) {
              fileSystemProvider.setSortOption(selectedOption);
            }
          },
        );
      },
    );
  }
}
