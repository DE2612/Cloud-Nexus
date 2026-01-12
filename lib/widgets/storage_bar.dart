import 'package:flutter/material.dart';
import '../models/storage_quota.dart';
import '../themes/ubuntu_theme.dart';

/// A compact storage usage bar widget that displays storage quota information.
///
/// Features:
/// - Horizontal progress bar with color-coded usage
/// - Displays used/total storage in human-readable format
/// - Color coding: Green (<50%), Yellow (50-80%), Red (>80%)
/// - Optional refresh button for manual updates
/// - Loading state indicator
class StorageBar extends StatelessWidget {
  /// The storage quota data to display
  final StorageQuota? quota;

  /// Whether the widget is in a loading state
  final bool isLoading;

  /// Callback when refresh is requested
  final VoidCallback? onRefresh;

  /// Whether to show the refresh button
  final bool showRefresh;

  /// Width of the progress bar (default: full width)
  final double width;

  /// Height of the progress bar (default: 6)
  final double height;

  const StorageBar({
    Key? key,
    this.quota,
    this.isLoading = false,
    this.onRefresh,
    this.showRefresh = true,
    this.width = double.infinity,
    this.height = 6,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Loading state
    if (isLoading) {
      return _buildLoadingState();
    }

    // No quota available
    if (quota == null || quota!.totalBytes <= 0) {
      return _buildNoDataState();
    }

    return _buildContent();
  }

  Widget _buildLoadingState() {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Skeleton progress bar
          Container(
            height: height,
            decoration: BoxDecoration(
              color: UbuntuColors.lightGrey,
              borderRadius: BorderRadius.circular(height / 2),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Loading storage info...',
                  style: const TextStyle(
                    fontSize: 10,
                    color: UbuntuColors.textGrey,
                    fontFamily: 'Ubuntu',
                  ),
                ),
              ),
              if (showRefresh && onRefresh != null)
                _buildRefreshButton(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNoDataState() {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Empty progress bar
          Container(
            height: height,
            decoration: BoxDecoration(
              color: UbuntuColors.lightGrey,
              borderRadius: BorderRadius.circular(height / 2),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Tap refresh to load storage info',
                  style: TextStyle(
                    fontSize: 10,
                    color: UbuntuColors.textGrey,
                    fontFamily: 'Ubuntu',
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              if (showRefresh && onRefresh != null)
                _buildRefreshButton(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final usagePercentage = quota!.usagePercentage;
    final progressColor = _getProgressColor(usagePercentage);

    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: width, // Ensure minimum width
        maxWidth: width, // Match parent width
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress bar with usage percentage
          LayoutBuilder(
            builder: (context, constraints) {
              final availableWidth = constraints.maxWidth;
              final fillWidth = availableWidth * usagePercentage;
              
              return Stack(
                children: [
                  // Background
                  Container(
                    height: height,
                    decoration: BoxDecoration(
                      color: UbuntuColors.lightGrey,
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                  ),
                  // Fill - colored portion representing percentage used
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    height: height,
                    width: fillWidth > 0 ? fillWidth : 0,
                    decoration: BoxDecoration(
                      color: progressColor,
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 4),
          // Usage text
          Row(
            children: [
              Expanded(
                child: Text(
                  '${quota!.usedFormatted} of ${quota!.totalFormatted} used (${quota!.usagePercentageString})',
                  style: TextStyle(
                    fontSize: 10,
                    color: quota!.isFull ? Colors.red : UbuntuColors.textGrey,
                    fontFamily: 'Ubuntu',
                    fontWeight: quota!.isNearlyFull ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              if (showRefresh && onRefresh != null)
                _buildRefreshButton(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRefreshButton() {
    return GestureDetector(
      onTap: onRefresh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(
          Icons.refresh,
          size: 14,
          color: UbuntuColors.textGrey,
        ),
      ),
    );
  }

  /// Get the appropriate color based on usage percentage
  Color _getProgressColor(double percentage) {
    if (percentage >= 0.9) {
      return Colors.red.shade700; // > 90% - Critical
    } else if (percentage >= 0.8) {
      return Colors.orange.shade600; // 80-90% - Warning
    } else if (percentage >= 0.5) {
      return Colors.amber.shade500; // 50-80% - Caution
    } else {
      return UbuntuColors.orange; // < 50% - Normal (Ubuntu orange)
    }
  }
}

/// A compact version of the storage bar for tighter spaces
class CompactStorageBar extends StatelessWidget {
  final StorageQuota? quota;
  final VoidCallback? onRefresh;
  final bool isLoading;

  const CompactStorageBar({
    Key? key,
    this.quota,
    this.onRefresh,
    this.isLoading = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 4,
            child: LinearProgressIndicator(
              backgroundColor: UbuntuColors.lightGrey,
              minHeight: 4,
            ),
          ),
          SizedBox(width: 4),
          Text(
            '...',
            style: TextStyle(fontSize: 10, color: UbuntuColors.textGrey),
          ),
        ],
      );
    }

    if (quota == null || quota!.totalBytes <= 0) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 4,
            child: LinearProgressIndicator(
              backgroundColor: UbuntuColors.lightGrey,
              minHeight: 4,
              value: 0,
            ),
          ),
          SizedBox(width: 4),
          Text(
            'N/A',
            style: TextStyle(fontSize: 10, color: UbuntuColors.textGrey),
          ),
        ],
      );
    }

    final color = _getColor(quota!.usagePercentage);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 4,
          child: LinearProgressIndicator(
            value: quota!.usagePercentage,
            backgroundColor: UbuntuColors.lightGrey,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 4,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          quota!.usagePercentageString,
          style: TextStyle(
            fontSize: 10,
            color: quota!.isNearlyFull ? Colors.red : UbuntuColors.textGrey,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (onRefresh != null) ...[
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onRefresh,
            child: Icon(
              Icons.refresh,
              size: 10,
              color: UbuntuColors.textGrey,
            ),
          ),
        ],
      ],
    );
  }

  Color _getColor(double percentage) {
    if (percentage >= 0.9) return Colors.red.shade700;
    if (percentage >= 0.8) return Colors.orange.shade600;
    if (percentage >= 0.5) return Colors.amber.shade500;
    return UbuntuColors.orange;
  }
}