import 'package:flutter/material.dart';
import '../themes/ubuntu_theme.dart';
import '../services/search_service.dart';
import 'icons/icon_config.dart';
import 'icons/icon_theme_provider.dart';
import 'icons/3d_file_icon_widget.dart';
import 'icons/3d_folder_icon_widget.dart';

class SearchResultsDropdown extends StatelessWidget {
  final List<SearchResult> results;
  final Function(SearchResult) onResultSelected;
  final bool isLoading;
  final String query;
  final int maxVisibleItems;
  final BoxConstraints? constraints;

  const SearchResultsDropdown({
    Key? key,
    required this.results,
    required this.onResultSelected,
    required this.isLoading,
    required this.query,
    this.maxVisibleItems = 6,
    this.constraints,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    
    // Calculate if scrolling is needed and if "View all" button should be shown
    const itemHeight = 36.0;
    const headerHeight = 32.0;
    const maxDisplayHeight = 220.0;
    final estimatedVisibleHeight = results.length * itemHeight;
    final needsScroll = estimatedVisibleHeight > maxDisplayHeight;
    final showViewAll = needsScroll && results.length > maxVisibleItems;
    
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: this.constraints?.copyWith(maxHeight: 280) ?? const BoxConstraints(
          minWidth: 280,
          maxWidth: 400,
          maxHeight: 280,
        ),
        decoration: BoxDecoration(
          color: UbuntuColors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header with count
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: UbuntuColors.veryLightGrey.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Text(
                      maxVisibleItems < 0 || results.length <= maxVisibleItems
                          ? '${results.length} result${results.length == 1 ? '' : 's'}'
                          : '${results.length} of ${results.length}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: UbuntuColors.darkGrey,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (showViewAll)
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          minimumSize: const Size(24, 20),
                          textStyle: const TextStyle(
                            fontSize: 10,
                            color: UbuntuColors.orange,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        onPressed: () {},
                        child: const Text('View all'),
                      ),
                  ],
                ),
              ),
              
              // Results list with scrolling
              Expanded(
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: maxDisplayHeight - headerHeight,
                  ),
                  child: results.isEmpty
                      ? _buildEmptyState()
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: results.length,
                          padding: EdgeInsets.zero,
                          itemBuilder: (context, index) => _buildResultItem(results[index], index),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultItem(SearchResult result, int index) {
    final isLast = index == results.length - 1;
    
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onResultSelected(result),
        splashColor: UbuntuColors.orange.withOpacity(0.08),
        hoverColor: UbuntuColors.orange.withOpacity(0.05),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          decoration: BoxDecoration(
            color: isLast ? Colors.transparent : UbuntuColors.white.withOpacity(0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isLast ? Colors.transparent : UbuntuColors.veryLightGrey.withOpacity(0.2),
              width: 0.5,
            ),
          ),
          child: SizedBox(
            height: 32, // Fixed height like 24px icons
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Icon will overflow but display at 64px
                SizedBox(
                  width: 64,
                  height: 64,
                  child: result.entry.isFolder
                      ? D3DFolderIconWidget(
                          variant: FolderVariant.regular,
                          size: IconSize.large,
                        )
                      : D3DFileIconWidget(
                          fileName: result.entry.nodeName,
                          size: IconSize.large,
                        ),
                ),
                const SizedBox(width: 12),
                
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        result.entry.nodeName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 12,
                          color: UbuntuColors.darkGrey,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        result.displayPath,
                        style: const TextStyle(
                          fontSize: 10,
                          color: UbuntuColors.textGrey,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isLoading ? Icons.search : Icons.search_off,
              size: 36,
              color: isLoading ? UbuntuColors.orange : UbuntuColors.lightGrey.withOpacity(0.6),
            ),
            const SizedBox(height: 12),
            Text(
              isLoading ? 'Searching...' : 'No results found',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: UbuntuColors.textGrey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}