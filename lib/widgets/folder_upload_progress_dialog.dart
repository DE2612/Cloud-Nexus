import 'dart:async';
import 'package:flutter/material.dart';
import '../services/folder_upload_service.dart';

/// Throttled setState helper to prevent main thread flooding
class ThrottledSetState {
  final VoidCallback setStateCallback;
  final Duration throttleDuration;
  Timer? _throttleTimer;
  bool _hasPendingUpdate = false;

  ThrottledSetState({
    required this.setStateCallback,
    this.throttleDuration = const Duration(milliseconds: 100),
  });

  void call() {
    _hasPendingUpdate = true;

    if (_throttleTimer == null || !_throttleTimer!.isActive) {
      _throttleTimer = Timer(throttleDuration, _executePending);
    }
  }

  void _executePending() {
    if (_hasPendingUpdate) {
      setStateCallback();
      _hasPendingUpdate = false;
    }
  }

  void dispose() {
    _throttleTimer?.cancel();
    // Execute any pending update before disposing
    if (_hasPendingUpdate) {
      setStateCallback();
    }
  }
}

/// Dialog to show folder upload progress
class FolderUploadProgressDialog extends StatefulWidget {
  final String uploadId;
  final FolderUploadService uploadService;
  final VoidCallback? onComplete;
  final Function(String)? onError;

  const FolderUploadProgressDialog({
    super.key,
    required this.uploadId,
    required this.uploadService,
    this.onComplete,
    this.onError,
  });

  @override
  State<FolderUploadProgressDialog> createState() => _FolderUploadProgressDialogState();
}

class _FolderUploadProgressDialogState extends State<FolderUploadProgressDialog> {
  FolderUploadProgress? _currentProgress;
  StreamSubscription<FolderUploadProgress>? _progressSubscription;
  bool _isCompleted = false;
  ThrottledSetState? _throttledSetState;

  @override
  void initState() {
    super.initState();
    _throttledSetState = ThrottledSetState(
      setStateCallback: () {
        if (mounted) {
          setState(() {});
        }
      },
      throttleDuration: const Duration(milliseconds: 100),
    );
    _listenToProgress();
  }

  void _listenToProgress() {
    final progressStream = widget.uploadService.getProgressStream(widget.uploadId);
    if (progressStream != null) {
      _progressSubscription = progressStream.listen((progress) {
        if (mounted) {
          // Update state variables directly
          _currentProgress = progress;
          if (progress.isCompleted) {
            _isCompleted = true;
          }
          
          // Use throttled setState to prevent main thread flooding
          _throttledSetState?.call();

          if (progress.isCompleted) {
            widget.onComplete?.call();
            // Auto-close after 2 seconds
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted) {
                Navigator.of(context).pop();
              }
            });
          }

          if (progress.error != null) {
            widget.onError?.call(progress.error!);
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _throttledSetState?.dispose();
    _progressSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.folder,
            color: Colors.blue,
            size: 24,
          ),
          const SizedBox(width: 8),
          const Text('Uploading Folder'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: _buildContent(),
      ),
      actions: [
        if (!_isCompleted)
          TextButton(
            onPressed: () async {
              await widget.uploadService.cancelUpload(widget.uploadId);
              if (mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Cancel'),
          ),
        if (_isCompleted)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
      ],
    );
  }

  Widget _buildContent() {
    if (_currentProgress == null) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Initializing upload...'),
        ],
      );
    }

    final progress = _currentProgress!;
    
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Folder name
        Text(
          progress.folderName,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 16),
        
        // Progress bar
        LinearProgressIndicator(
          value: progress.progressPercentage,
          backgroundColor: Colors.grey.shade300,
          valueColor: AlwaysStoppedAnimation<Color>(
            _isCompleted ? Colors.green : Colors.blue,
          ),
        ),
        const SizedBox(height: 8),
        
        // Progress text
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${progress.completedItems}/${progress.totalItems} items',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
              ),
            ),
            Text(
              '${(progress.progressPercentage * 100).toStringAsFixed(1)}%',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        
        // Current item
        if (progress.currentItem.isNotEmpty && !_isCompleted)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Current:',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 12,
                ),
              ),
              Text(
                progress.currentItem,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
            ],
          ),
        
        // Data transfer info
        Row(
          children: [
            Icon(
              Icons.data_usage,
              size: 16,
              color: Colors.grey.shade600,
            ),
            const SizedBox(width: 4),
            Text(
              '${_formatBytes(progress.uploadedBytes)} / ${_formatBytes(progress.totalBytes)}',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
              ),
            ),
          ],
        ),
        
        // Status
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              _isCompleted ? Icons.check_circle : Icons.cloud_upload,
              size: 16,
              color: _isCompleted ? Colors.green : Colors.blue,
            ),
            const SizedBox(width: 4),
            Text(
              _isCompleted ? 'Upload completed!' : 'Uploading...',
              style: TextStyle(
                color: _isCompleted ? Colors.green : Colors.blue,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        
        // Error message
        if (progress.error != null)
          Container(
            margin: const EdgeInsets.only(top: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.error,
                  size: 16,
                  color: Colors.red.shade600,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    progress.error!,
                    style: TextStyle(
                      color: Colors.red.shade600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Utility method to show folder upload progress dialog
Future<void> showFolderUploadProgressDialog({
  required BuildContext context,
  required String uploadId,
  required FolderUploadService uploadService,
  VoidCallback? onComplete,
  Function(String)? onError,
}) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => FolderUploadProgressDialog(
      uploadId: uploadId,
      uploadService: uploadService,
      onComplete: onComplete,
      onError: onError,
    ),
  );
}