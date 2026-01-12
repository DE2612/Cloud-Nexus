import 'dart:math';

/// Represents storage quota information for a cloud account.
///
/// Contains total storage, used storage, and calculates usage percentage.
class StorageQuota {
  /// Total storage available in bytes
  final int totalBytes;

  /// Currently used storage in bytes
  final int usedBytes;

  /// Remaining storage in bytes (calculated if not provided)
  final int? remainingBytes;

  /// Timestamp when this data was last fetched from the API
  final DateTime? lastUpdated;

  const StorageQuota({
    required this.totalBytes,
    required this.usedBytes,
    this.remainingBytes,
    this.lastUpdated,
  });

  /// Get the remaining bytes (calculated from total and used if not provided)
  int get effectiveRemainingBytes =>
      remainingBytes ?? (totalBytes - usedBytes);

  /// Calculate usage percentage (0.0 to 1.0)
  ///
  /// Returns 0.0 if totalBytes is 0 to avoid division by zero
  double get usagePercentage {
    if (totalBytes <= 0) return 0.0;
    return (usedBytes / totalBytes).clamp(0.0, 1.0);
  }

  /// Calculate usage percentage as a string (e.g., "15.3%")
  String get usagePercentageString {
    return '${(usagePercentage * 100).toStringAsFixed(1)}%';
  }

  /// Get formatted used storage (e.g., "2.3 GB")
  String get usedFormatted => _formatBytes(usedBytes);

  /// Get formatted total storage (e.g., "15 GB")
  String get totalFormatted => _formatBytes(totalBytes);

  /// Get formatted remaining storage (e.g., "12.7 GB")
  String get remainingFormatted => _formatBytes(effectiveRemainingBytes);

  /// Get formatted usage text (e.g., "2.3 GB of 15 GB")
  String get usageText => '$usedFormatted of $totalFormatted';

  /// Check if storage is nearly full (> 90% used)
  bool get isNearlyFull => usagePercentage > 0.9;

  /// Check if storage is full (> 95% used)
  bool get isFull => usagePercentage > 0.95;

  /// Check if this quota data is stale (older than [maxAgeMinutes] minutes)
  ///
  /// Returns true if the data is older than the specified age, indicating it should be refreshed.
  /// [maxAgeMinutes] The maximum age in minutes before considering the data stale (default: 30)
  bool isStale([int maxAgeMinutes = 30]) {
    if (lastUpdated == null) return true;
    final age = DateTime.now().difference(lastUpdated!);
    return age.inMinutes > maxAgeMinutes;
  }

  /// Check if a file of the given size can fit in the remaining storage.
  ///
  /// Returns true if the file can fit, false otherwise.
  ///
  /// [fileSizeBytes] The size of the file in bytes to check.
  /// [bufferBytes] Optional buffer to reserve (default 1MB for metadata/overhead).
  bool canFit(int fileSizeBytes, {int bufferBytes = 1024 * 1024}) {
    final requiredSpace = fileSizeBytes + bufferBytes;
    return effectiveRemainingBytes >= requiredSpace;
  }

  /// Get the maximum file size that can be uploaded with a buffer.
  ///
  /// [bufferBytes] Optional buffer to reserve (default 1MB for metadata/overhead).
  int getMaxUploadSize({int bufferBytes = 1024 * 1024}) {
    return effectiveRemainingBytes - bufferBytes;
  }

  /// Create a copy with updated values
  StorageQuota copyWith({
    int? totalBytes,
    int? usedBytes,
    int? remainingBytes,
    DateTime? lastUpdated,
  }) {
    return StorageQuota(
      totalBytes: totalBytes ?? this.totalBytes,
      usedBytes: usedBytes ?? this.usedBytes,
      remainingBytes: remainingBytes ?? this.remainingBytes,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'totalBytes': totalBytes,
      'usedBytes': usedBytes,
      'remainingBytes': remainingBytes,
      'lastUpdated': lastUpdated?.toIso8601String(),
    };
  }

  /// Create from JSON
  factory StorageQuota.fromJson(Map<String, dynamic> json) {
    return StorageQuota(
      totalBytes: json['totalBytes'] as int? ?? 0,
      usedBytes: json['usedBytes'] as int? ?? 0,
      remainingBytes: json['remainingBytes'] as int?,
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.parse(json['lastUpdated'] as String)
          : null,
    );
  }

  @override
  String toString() {
    return 'StorageQuota(used=$usedFormatted, total=$totalFormatted, percentage=$usagePercentageString)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StorageQuota &&
        other.totalBytes == totalBytes &&
        other.usedBytes == usedBytes &&
        other.remainingBytes == remainingBytes;
  }

  @override
  int get hashCode =>
      totalBytes.hashCode ^ usedBytes.hashCode ^ remainingBytes.hashCode;

  /// Format bytes to human-readable string
  ///
  /// Handles bytes up to petabytes
  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';

    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    final suffixIndex = (log(bytes) / log(1024)).floor();
    final normalizedValue = bytes / pow(1024, suffixIndex);
    final formattedValue = normalizedValue < 10
        ? normalizedValue.toStringAsFixed(1)
        : normalizedValue.toStringAsFixed(0);

    return '$formattedValue ${suffixes[suffixIndex.clamp(0, suffixes.length - 1)]}';
  }
}