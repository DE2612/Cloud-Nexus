import 'package:flutter/material.dart';

/// Status of a streaming transfer
enum StreamStatus {
  queued,
  transferring,
  completed,
  failed,
  cancelled,
}

/// Represents a streaming session
class StreamSession {
  final String id;
  final String fileName;
  final int totalBytes;
  int transferredBytes;
  StreamStatus status;
  String? errorMessage;

  StreamSession({
    required this.id,
    required this.fileName,
    required this.totalBytes,
    this.transferredBytes = 0,
    this.status = StreamStatus.queued,
    this.errorMessage,
  });

  double get progress => totalBytes > 0 ? transferredBytes / totalBytes : 0.0;

  void updateProgress(int bytes) {
    transferredBytes = bytes;
    if (status == StreamStatus.queued) {
      status = StreamStatus.transferring;
    }
  }

  void complete() {
    status = StreamStatus.completed;
  }

  void fail(String error) {
    status = StreamStatus.failed;
    errorMessage = error;
  }

  void cancel() {
    status = StreamStatus.cancelled;
  }
}

/// Dialog to show streaming progress
class StreamingProgressDialog extends StatefulWidget {
  final List<StreamSession> sessions;
  final VoidCallback onCancelAll;

  const StreamingProgressDialog({
    Key? key,
    required this.sessions,
    required this.onCancelAll,
  }) : super(key: key);

  @override
  State<StreamingProgressDialog> createState() => _StreamingProgressDialogState();
}

class _StreamingProgressDialogState extends State<StreamingProgressDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Streaming Transfers'),
      content: SizedBox(
        width: 400,
        height: 300,
        child: ListView.builder(
          itemCount: widget.sessions.length,
          itemBuilder: (context, index) {
            final session = widget.sessions[index];
            return _buildSessionTile(session);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.onCancelAll,
          child: const Text('Cancel All'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildSessionTile(StreamSession session) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(_getStatusIcon(session.status)),
        title: Text(session.fileName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: session.progress,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(_getStatusColor(session.status)),
            ),
            const SizedBox(height: 4),
            Text(
              _getStatusText(session),
              style: TextStyle(
                color: _getStatusColor(session.status),
                fontSize: 12,
              ),
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.cancel),
          onPressed: session.status == StreamStatus.transferring
              ? () {
                  session.cancel();
                  setState(() {});
                }
              : null,
        ),
      ),
    );
  }

  IconData _getStatusIcon(StreamStatus status) {
    switch (status) {
      case StreamStatus.queued:
        return Icons.hourglass_empty;
      case StreamStatus.transferring:
        return Icons.sync;
      case StreamStatus.completed:
        return Icons.check_circle;
      case StreamStatus.failed:
        return Icons.error;
      case StreamStatus.cancelled:
        return Icons.cancel;
    }
  }

  Color _getStatusColor(StreamStatus status) {
    switch (status) {
      case StreamStatus.queued:
        return Colors.grey;
      case StreamStatus.transferring:
        return Colors.blue;
      case StreamStatus.completed:
        return Colors.green;
      case StreamStatus.failed:
        return Colors.red;
      case StreamStatus.cancelled:
        return Colors.orange;
    }
  }

  String _getStatusText(StreamSession session) {
    switch (session.status) {
      case StreamStatus.queued:
        return 'Queued';
      case StreamStatus.transferring:
        final percent = (session.progress * 100).toStringAsFixed(1);
        return '$percent% (${_formatBytes(session.transferredBytes)}/${_formatBytes(session.totalBytes)})';
      case StreamStatus.completed:
        return 'Completed';
      case StreamStatus.failed:
        return 'Failed: ${session.errorMessage}';
      case StreamStatus.cancelled:
        return 'Cancelled';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}