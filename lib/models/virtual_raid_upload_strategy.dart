import 'package:flutter/material.dart';

/// Represents the upload strategy for Virtual RAID drives.
enum VirtualRaidUploadStrategy {
  /// User manually selects which drives to upload to
  manual,
  
  /// Automatically upload to drive with most available space
  mostFreeStorage,
  
  /// Automatically upload to drive with lowest usage percentage
  lowestFullPercentage,
}

/// Extension on VirtualRaidUploadStrategy to get display name and description
extension VirtualRaidUploadStrategyInfo on VirtualRaidUploadStrategy {
  String get displayName {
    switch (this) {
      case VirtualRaidUploadStrategy.manual:
        return 'Manual';
      case VirtualRaidUploadStrategy.mostFreeStorage:
        return 'Most Free Storage';
      case VirtualRaidUploadStrategy.lowestFullPercentage:
        return 'Lowest Full Percentage';
    }
  }

  String get description {
    switch (this) {
      case VirtualRaidUploadStrategy.manual:
        return 'Select which drives to upload to. Upload fails if any selected drive lacks storage.';
      case VirtualRaidUploadStrategy.mostFreeStorage:
        return 'Automatically upload to the drive with the most available space. Upload fails if no drive has enough space.';
      case VirtualRaidUploadStrategy.lowestFullPercentage:
        return 'Automatically upload to the least full drive. Tries other drives if the first one is full.';
    }
  }

  IconData get icon {
    switch (this) {
      case VirtualRaidUploadStrategy.manual:
        return Icons.checklist;
      case VirtualRaidUploadStrategy.mostFreeStorage:
        return Icons.storage;
      case VirtualRaidUploadStrategy.lowestFullPercentage:
        return Icons.pie_chart;
    }
  }
}

/// Represents a drive with its storage information for upload decisions
class DriveUploadInfo {
  final String accountId;
  final String accountName;
  final String provider;
  final int usedBytes;
  final int totalBytes;
  final int remainingBytes;

  DriveUploadInfo({
    required this.accountId,
    required this.accountName,
    required this.provider,
    required this.usedBytes,
    required this.totalBytes,
    required this.remainingBytes,
  });

  /// Calculate usage percentage (0.0 to 1.0)
  double get usagePercentage {
    if (totalBytes <= 0) return 0.0;
    return (usedBytes / totalBytes).clamp(0.0, 1.0);
  }

  /// Check if a file of given size can fit with 1MB buffer
  bool canFit(int fileSizeBytes, {int bufferBytes = 1024 * 1024}) {
    return remainingBytes >= (fileSizeBytes + bufferBytes);
  }
}

/// Result of finding drives for upload
class DriveSelectionResult {
  /// List of selected account IDs
  final List<String> selectedAccountIds;

  /// List of drives that couldn't fit the file
  final List<String> insufficientStorageIds;

  /// List of drive names that couldn't fit
  final List<String> insufficientStorageNames;

  /// Error message if selection failed
  final String? errorMessage;

  DriveSelectionResult({
    required this.selectedAccountIds,
    this.insufficientStorageIds = const [],
    this.insufficientStorageNames = const [],
    this.errorMessage,
  });

  bool get hasError => errorMessage != null;
  bool get hasInsufficientStorage => insufficientStorageIds.isNotEmpty;
}