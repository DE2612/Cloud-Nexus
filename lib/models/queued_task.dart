import 'cancellation_token.dart';

enum TaskType { upload, uploadFolder, download, downloadFolder, delete, move, createFolder, copyFolder, copyFile }
enum TaskStatus { pending, running, paused, completed, failed }

class QueuedTask {
  final String id;
  final TaskType type;
  final String name; // e.g. "report.pdf"
  final String? accountId; // Which drive is this for?
   
  // Progress tracking
  TaskStatus status;
  double progress; // 0.0 to 1.0
  String? errorMessage;
  DateTime? completedAt; // When the task was completed
   
  // Cancellation token for pause/cancel support
  final CancellationToken cancellationToken;
   
  // Payload (Data needed to run the task)
  final Map<String, dynamic> payload;
 
  QueuedTask({
    required this.id,
    required this.type,
    required this.name,
    this.accountId,
    required this.payload,
    this.status = TaskStatus.pending,
    this.progress = 0.0,
    this.completedAt,
  }) : cancellationToken = CancellationToken();
}