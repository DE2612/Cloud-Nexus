import 'package:flutter/material.dart';
import '../services/task_service.dart';
import '../models/queued_task.dart';
import '../themes/ubuntu_theme.dart' as theme;
import '../services/hive_storage_service.dart';

/// Enhanced task progress widget with Ubuntu theme
/// Shows active tasks with pause/stop controls, collapse/expand, and scrolling
class TaskProgressWidget extends StatefulWidget {
  const TaskProgressWidget({Key? key}) : super(key: key);

  @override
  State<TaskProgressWidget> createState() => _TaskProgressWidgetState();
}

class _TaskProgressWidgetState extends State<TaskProgressWidget>
    with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late AnimationController _collapseController;
  late Animation<double> _collapseAnimation;
  bool _isCollapsed = false;
  
  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: theme.UbuntuAnimations.fast,
      vsync: this,
    );
    
    _collapseController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: theme.UbuntuAnimations.smooth),
    );
    
    _collapseAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _collapseController, curve: Curves.easeInOut),
    );
    
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _collapseController.dispose();
    super.dispose();
  }

  void _toggleCollapse() {
    setState(() {
      _isCollapsed = !_isCollapsed;
      if (_isCollapsed) {
        _collapseController.forward();
      } else {
        _collapseController.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: AnimatedBuilder(
        animation: TaskService.instance,
        builder: (context, child) {
          final activeTasks = TaskService.instance.activeTasks;
          final hasActiveTasks = activeTasks.isNotEmpty;
          
          if (!hasActiveTasks) {
            _fadeController.reverse();
            return const SizedBox.shrink();
          }
          
          _fadeController.forward();
          
          return FadeTransition(
            opacity: _fadeAnimation,
            child: _buildWidget(activeTasks),
          );
        },
      ),
    );
  }

  Widget _buildWidget(List<QueuedTask> activeTasks) {
    return Container(
      width: 480,
      constraints: const BoxConstraints(
        minWidth: 480,
        maxWidth: 480,
        maxHeight: 500,
      ),
      decoration: BoxDecoration(
        color: theme.UbuntuColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.UbuntuColors.lightGrey,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: theme.UbuntuColors.black.withOpacity(0.08),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          _buildHeader(activeTasks.length),
          
          // Task list with collapse animation
          SizeTransition(
            sizeFactor: _collapseAnimation,
            axisAlignment: -1.0,
            child: _buildTaskList(activeTasks),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(int totalCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.UbuntuColors.veryLightGrey,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(11),
          topRight: Radius.circular(11),
        ),
        border: const Border(
          bottom: BorderSide(color: theme.UbuntuColors.lightGrey, width: 1),
        ),
      ),
      child: Row(
        children: [
          // Icon
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: theme.UbuntuColors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              Icons.sync,
              size: 14,
              color: theme.UbuntuColors.orange,
            ),
          ),
          const SizedBox(width: 8),
          
          // Title
          Text(
            'Active Tasks',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.UbuntuColors.darkGrey,
              fontFamily: 'Ubuntu',
            ),
          ),
          const Spacer(),
          
          // Task count badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.UbuntuColors.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$totalCount',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: theme.UbuntuColors.orange,
                fontFamily: 'Ubuntu',
              ),
            ),
          ),
          
          const SizedBox(width: 8),
          
          // Collapse/Expand button
          InkWell(
            onTap: _toggleCollapse,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: AnimatedRotation(
                turns: _isCollapsed ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: Icon(
                  Icons.expand_more,
                  size: 18,
                  color: theme.UbuntuColors.textGrey,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskList(List<QueuedTask> activeTasks) {
    return Container(
      constraints: const BoxConstraints(
        maxHeight: 400,
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 8),
            ...activeTasks.asMap().entries.map((entry) {
              final index = entry.key;
              final task = entry.value;
              return _EnhancedTaskItem(
                task: task,
                showDivider: index < activeTasks.length - 1,
              );
            }).toList(),
          ],
        ),
      ),
    );
  }
}

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

/// Enhanced task item widget with pause/cancel controls
class _EnhancedTaskItem extends StatelessWidget {
  final QueuedTask task;
  final bool showDivider;

  const _EnhancedTaskItem({
    required this.task,
    required this.showDivider,
  });

  @override
  Widget build(BuildContext context) {
    // Enable pause/resume for pending, running, and paused tasks
    final canPauseOrResume = task.status == TaskStatus.pending ||
                              task.status == TaskStatus.running ||
                              task.status == TaskStatus.paused;
    // Enable cancel for pending, running, and paused tasks
    final canCancel = task.status == TaskStatus.pending ||
                      task.status == TaskStatus.running ||
                      task.status == TaskStatus.paused;
    
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Task icon
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _getTaskTypeColor().withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  _getTaskTypeIcon(),
                  size: 16,
                  color: _getTaskTypeColor(),
                ),
              ),
              
              const SizedBox(width: 12),
              
              // Task info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Task name row
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            task.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: theme.UbuntuColors.darkGrey,
                              fontFamily: 'Ubuntu',
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildStatusChip(),
                      ],
                    ),
                     
                    const SizedBox(height: 6),
                     
                    // Progress bar or status text
                    if (task.status == TaskStatus.running) ...[
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: task.progress,
                                backgroundColor: theme.UbuntuColors.lightGrey,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  _getTaskTypeColor(),
                                ),
                                minHeight: 4,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${(task.progress * 100).round()}%',
                            style: const TextStyle(
                              fontSize: 11,
                              color: theme.UbuntuColors.textGrey,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      Text(
                        _getStatusText(),
                        style: TextStyle(
                          fontSize: 11,
                          color: _getStatusColor(),
                        ),
                      ),
                    ],
                     
                    const SizedBox(height: 4),
                     
                    // Source and Destination row
                    Row(
                      children: [
                        _buildSourceDestinationInfo(),
                      ],
                    ),
                  ],
                ),
              ),
              
              const SizedBox(width: 12),
              
              // Control buttons with new colors
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Pause/Resume button
                  // - Blue for pause (pending tasks)
                  // - Green for resume (paused tasks)
                  // - Greyed out for running tasks
                  Tooltip(
                    message: _getPauseTooltip(),
                    child: IconButton(
                      icon: Icon(
                        _getPauseIcon(),
                        size: 18,
                      ),
                      onPressed: _canPause()
                          ? () {
                              if (task.status == TaskStatus.paused) {
                                TaskService.instance.resumeTask(task.id);
                              } else {
                                TaskService.instance.pauseTask(task.id);
                              }
                            }
                          : null,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      color: _getPauseButtonColor(),
                    ),
                  ),
                   
                  const SizedBox(width: 4),
                   
                  // Cancel button - Red
                  Tooltip(
                    message: _getCancelTooltip(),
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: canCancel
                          ? () => TaskService.instance.cancelTask(task.id)
                          : null,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      color: canCancel ? Colors.red.shade600 : theme.UbuntuColors.lightGrey,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            color: theme.UbuntuColors.lightGrey,
            indent: 56,
            endIndent: 12,
          ),
      ],
    );
  }

  /// Get the appropriate icon for pause/resume state
  /// Square = pause, Triangle (play_arrow) = resume
  IconData _getPauseIcon() {
    switch (task.status) {
      case TaskStatus.pending:
        return Icons.stop; // Square icon for pause (when can pause)
      case TaskStatus.running:
        return Icons.stop; // Square icon for pause (when can pause)
      case TaskStatus.paused:
        return Icons.play_arrow; // Triangle icon for resume
      case TaskStatus.completed:
        return Icons.check; // Check mark for completed
      case TaskStatus.failed:
        return Icons.error; // Error icon for failed
    }
  }

  String _getPauseTooltip() {
    switch (task.status) {
      case TaskStatus.pending:
        return 'Pause this task';
      case TaskStatus.running:
        return 'Pause this running task';
      case TaskStatus.paused:
        return 'Resume this task';
      case TaskStatus.completed:
        return 'Task completed';
      case TaskStatus.failed:
        return 'Task failed';
    }
  }

  String _getCancelTooltip() {
    switch (task.status) {
      case TaskStatus.pending:
        return 'Cancel this pending task';
      case TaskStatus.running:
        return 'Cancel this running task';
      case TaskStatus.paused:
        return 'Cancel this paused task';
      case TaskStatus.completed:
        return 'Task completed';
      case TaskStatus.failed:
        return 'Task failed';
    }
  }

  /// Build source and destination info with color coding
  Widget _buildSourceDestinationInfo() {
    return FutureBuilder<List<_TaskLocation>>(
      future: Future.wait([_getSourceAsync(), _getDestinationAsync()]),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }
        
        final locations = snapshot.data!;
        final source = locations[0];
        final destination = locations[1];
        
        return Row(
          children: [
            // Source
            _buildLocationChip(source, 'From'),
            const SizedBox(width: 4),
            // Destination
            _buildLocationChip(destination, 'To'),
          ],
        );
      },
    );
  }
  
  /// Build a single location chip with color coding
  Widget _buildLocationChip(_TaskLocation location, String prefix) {
    return Row(
      children: [
        Text(
          '$prefix ',
          style: const TextStyle(
            fontSize: 10,
            color: theme.UbuntuColors.textGrey,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: location.color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (location.icon != null) ...[
                Icon(
                  location.icon,
                  size: 10,
                  color: location.color,
                ),
                const SizedBox(width: 3),
              ],
              Text(
                location.email,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: location.color,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
  
  /// Get source location info (async)
  Future<_TaskLocation> _getSourceAsync() async {
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
  
  /// Get destination location info (async)
  Future<_TaskLocation> _getDestinationAsync() async {
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
  
  /// Get cloud location info by looking up account from Hive
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

  Widget _buildStatusChip() {
    Color backgroundColor;
    Color textColor;
    String text;
    
    switch (task.status) {
      case TaskStatus.running:
        backgroundColor = Colors.blue.withOpacity(0.1);
        textColor = Colors.blue.shade700;
        text = 'Active';
        break;
      case TaskStatus.pending:
        backgroundColor = theme.UbuntuColors.lightOrange.withOpacity(0.15);
        textColor = theme.UbuntuColors.darkOrange;
        text = 'Pending';
        break;
      case TaskStatus.paused:
        backgroundColor = Colors.amber.withOpacity(0.1);
        textColor = Colors.amber.shade700;
        text = 'Paused';
        break;
      case TaskStatus.completed:
        backgroundColor = Colors.green.withOpacity(0.1);
        textColor = Colors.green.shade700;
        text = 'Done';
        break;
      case TaskStatus.failed:
        backgroundColor = Colors.red.withOpacity(0.1);
        textColor = Colors.red.shade700;
        text = 'Failed';
        break;
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }

  Color _getTaskTypeColor() {
    switch (task.type) {
      case TaskType.upload:
        return Colors.blue;
      case TaskType.uploadFolder:
        return Colors.indigo;
      case TaskType.download:
        return Colors.green;
      case TaskType.downloadFolder:
        return Colors.lightGreen;
      case TaskType.delete:
        return Colors.red;
      case TaskType.move:
        return Colors.purple;
      case TaskType.createFolder:
        return theme.UbuntuColors.orange;
      case TaskType.copyFile:
      case TaskType.copyFolder:
        return Colors.teal;
    }
  }

  IconData _getTaskTypeIcon() {
    switch (task.type) {
      case TaskType.upload:
        return Icons.cloud_upload;
      case TaskType.uploadFolder:
        return Icons.folder_open;
      case TaskType.download:
        return Icons.cloud_download;
      case TaskType.downloadFolder:
        return Icons.folder;
      case TaskType.delete:
        return Icons.delete;
      case TaskType.move:
        return Icons.drive_file_move;
      case TaskType.createFolder:
        return Icons.create_new_folder;
      case TaskType.copyFile:
      case TaskType.copyFolder:
        return Icons.file_copy;
    }
  }

  String _getStatusText() {
    switch (task.status) {
      case TaskStatus.running:
        return '${_getTaskTypeLabel()}...';
      case TaskStatus.pending:
        return 'Waiting to start...';
      case TaskStatus.paused:
        return 'Paused';
      case TaskStatus.completed:
        return 'Completed';
      case TaskStatus.failed:
        return task.errorMessage ?? 'Failed';
    }
  }

  Color _getStatusColor() {
    switch (task.status) {
      case TaskStatus.running:
        return theme.UbuntuColors.textGrey;
      case TaskStatus.pending:
        return theme.UbuntuColors.textGrey;
      case TaskStatus.paused:
        return Colors.amber.shade600;
      case TaskStatus.completed:
        return Colors.green.shade600;
      case TaskStatus.failed:
        return Colors.red.shade600;
    }
  }

  String _getTaskTypeLabel() {
    switch (task.type) {
      case TaskType.upload:
        return 'Uploading';
      case TaskType.uploadFolder:
        return 'Uploading folder';
      case TaskType.download:
        return 'Downloading';
      case TaskType.downloadFolder:
        return 'Downloading folder';
      case TaskType.delete:
        return 'Deleting';
      case TaskType.move:
        return 'Moving';
      case TaskType.createFolder:
        return 'Creating folder';
      case TaskType.copyFile:
        return 'Copying file';
      case TaskType.copyFolder:
        return 'Copying folder';
    }
  }

  /// Check if pause/resume button should be enabled
  /// - Can pause pending tasks (pause button shown)
  /// - Can resume paused tasks (resume button shown)
  /// - Running tasks cannot be paused (greyed out, cancel still available)
  bool _canPause() {
    return task.status == TaskStatus.pending || task.status == TaskStatus.paused;
  }

  /// Get the color for pause/resume button
  /// - Blue for pause (pending tasks)
  /// - Green for resume (paused tasks)
  /// - Grey for disabled (running tasks)
  Color _getPauseButtonColor() {
    switch (task.status) {
      case TaskStatus.pending:
        return Colors.blue.shade600;
      case TaskStatus.paused:
        return Colors.green.shade600;
      case TaskStatus.running:
        return theme.UbuntuColors.lightGrey;
      default:
        return theme.UbuntuColors.lightGrey;
    }
  }
}