import 'package:flutter/material.dart';
import '../services/task_service.dart';
import '../models/queued_task.dart';
import '../services/hive_storage_service.dart';

/// Helper class for task location information
class _TaskLocation {
  final String email;
  final Color color;
  final IconData? icon;
  final bool isCloud;
  
  _TaskLocation({
    required this.email,
    required this.color,
    this.icon,
    required this.isCloud,
  });
}

class TaskMonitorWidget extends StatelessWidget {
  const TaskMonitorWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: TaskService.instance,
      builder: (context, _) {
        final tasks = TaskService.instance.activeTasks;
        if (tasks.isEmpty) return const SizedBox.shrink();

        final task = tasks.first;

        return Container(
          color: Colors.grey[900],
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const CircularProgressIndicator(strokeWidth: 2),
                  const SizedBox(width: 12),
                  Text("${tasks.length} Tasks Running...", style: const TextStyle(color: Colors.white)),
                ],
              ),
              const SizedBox(height: 8),
              // Show the first task details
              Text(
                "Processing: ${task.name}",
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 6),
              // Source and Destination (async)
              FutureBuilder<List<_TaskLocation>>(
                future: Future.wait([_getSourceAsync(task), _getDestinationAsync(task)]),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const SizedBox.shrink();
                  }
                  
                  final locations = snapshot.data!;
                  final source = locations[0];
                  final destination = locations[1];
                  
                  return Row(
                    children: [
                      _buildLocationChip(source, 'From'),
                      const SizedBox(width: 4),
                      _buildLocationChip(destination, 'To'),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLocationChip(_TaskLocation location, String prefix) {
    return Row(
      children: [
        Text(
          '$prefix ',
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: location.color.withOpacity(0.2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (location.icon != null) ...[
                Icon(location.icon, size: 10, color: location.color),
                const SizedBox(width: 3),
              ],
              Text(
                location.email,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: location.color),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<_TaskLocation> _getSourceAsync(QueuedTask task) async {
    final accountId = task.payload['sourceAccountId'] as String?;
    
    // For uploads and uploads from local, source is Local
    if (task.type == TaskType.upload ||
        task.type == TaskType.uploadFolder ||
        (task.type == TaskType.copyFile && accountId == null) ||
        (task.type == TaskType.copyFolder && accountId == null)) {
      return _TaskLocation(
        email: 'Local',
        color: Colors.grey,
        icon: Icons.computer,
        isCloud: false,
      );
    }
    
    // For downloads and copy from cloud, source is cloud
    return await _getCloudLocationAsync(accountId ?? task.accountId);
  }

  Future<_TaskLocation> _getDestinationAsync(QueuedTask task) async {
    // For downloads, destination is Local
    if (task.type == TaskType.download ||
        task.type == TaskType.downloadFolder) {
      return _TaskLocation(
        email: 'Local',
        color: Colors.grey,
        icon: Icons.computer,
        isCloud: false,
      );
    }
    
    // For uploads and copies, destination is cloud
    final accountId = task.accountId;
    return await _getCloudLocationAsync(accountId);
  }

  Future<_TaskLocation> _getCloudLocationAsync(String? accountId) async {
    if (accountId == null) {
      return _TaskLocation(
        email: 'Local',
        color: Colors.grey,
        icon: Icons.computer,
        isCloud: false,
      );
    }
    
    // Look up account from Hive to get provider and email
    final account = await HiveStorageService.instance.getAccount(accountId);
    
    if (account == null) {
      // Account not found, return generic cloud
      return _TaskLocation(
        email: 'Cloud',
        color: Colors.grey,
        icon: Icons.cloud,
        isCloud: true,
      );
    }
    
    // Color coding: green for gdrive, blue for onedrive
    Color color;
    IconData? icon;
    String displayName;
    
    final provider = account.provider.toLowerCase();
    
    if (provider == 'gdrive') {
      color = Colors.green;
      icon = Icons.cloud;
      displayName = account.email.contains('@') ? account.email : 'Google Drive';
    } else if (provider == 'onedrive') {
      color = Colors.blue;
      icon = Icons.cloud;
      displayName = account.email.contains('@') ? account.email : 'OneDrive';
    } else {
      color = Colors.grey;
      icon = Icons.cloud;
      displayName = account.email.contains('@') ? account.email : 'Cloud';
    }
    
    return _TaskLocation(
      email: displayName,
      color: color,
      icon: icon,
      isCloud: true,
    );
  }
}