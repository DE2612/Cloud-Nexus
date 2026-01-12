import 'package:flutter/material.dart';
import '../models/notification_type.dart';
import '../models/notification_type.dart' as notification_model;
import '../services/notification_service.dart';

/// Top-right notification overlay widget
class NotificationOverlay extends StatefulWidget {
  final Widget child;
  final NotificationService notificationService;

  const NotificationOverlay({
    super.key,
    required this.child,
    required this.notificationService,
  });

  @override
  State<NotificationOverlay> createState() => _NotificationOverlayState();
}

class _NotificationOverlayState extends State<NotificationOverlay> {
  final List<notification_model.AppNotification> _notifications = [];

  @override
  void initState() {
    super.initState();
    widget.notificationService.notifications.listen(_onNotification);
    widget.notificationService.dismissStream.listen(_onDismiss);
  }

  void _onNotification(notification_model.AppNotification notification) {
    if (mounted) {
      setState(() {
        _notifications.add(notification);
      });
    }
  }

  void _onDismiss(String id) {
    if (mounted) {
      setState(() {
        _notifications.removeWhere((n) => n.id == id);
      });
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        // Notification overlay
        Positioned(
          top: 60,
          right: 16,
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: _notifications.map((notification) {
              return _NotificationItem(
                notification: notification,
                onDismiss: () => widget.notificationService.dismiss(notification.id),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _NotificationItem extends StatefulWidget {
  final notification_model.AppNotification notification;
  final VoidCallback onDismiss;

  const _NotificationItem({
    required this.notification,
    required this.onDismiss,
  });

  @override
  State<_NotificationItem> createState() => _NotificationItemState();
}

class _NotificationItemState extends State<_NotificationItem> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _slideAnimation = Tween<double>(begin: -50, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    // Start animation
    _controller.forward();

    // Auto-dismiss after duration
    Future.delayed(widget.notification.duration, () {
      if (mounted) {
        _controller.reverse().then((_) {
          if (mounted) {
            widget.onDismiss();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _getColor(widget.notification.type);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _slideAnimation.value),
          child: Opacity(
            opacity: _fadeAnimation.value,
            child: child,
          ),
        );
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: color.withOpacity(0.3),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left colored bar
              Container(
                width: 4,
                height: 60,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(8),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Icon
              Container(
                margin: const EdgeInsets.only(top: 12),
                child: Icon(
                  _getIcon(widget.notification.type),
                  color: color,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              // Content
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.notification.title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Flexible(
                        child: Text(
                          widget.notification.message,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Close button
              IconButton(
                onPressed: () {
                  _controller.reverse().then((_) {
                    widget.onDismiss();
                  });
                },
                icon: Icon(
                  Icons.close,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                ),
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Color _getColor(notification_model.NotificationType type) {
    switch (type) {
      case notification_model.NotificationType.info:
        return Colors.blue;
      case notification_model.NotificationType.success:
        return Colors.green;
      case notification_model.NotificationType.warning:
        return Colors.orange;
      case notification_model.NotificationType.error:
        return Colors.red;
    }
  }

  IconData _getIcon(notification_model.NotificationType type) {
    switch (type) {
      case notification_model.NotificationType.info:
        return Icons.info_outline;
      case notification_model.NotificationType.success:
        return Icons.check_circle_outline;
      case notification_model.NotificationType.warning:
        return Icons.warning_amber_outlined;
      case notification_model.NotificationType.error:
        return Icons.error_outline;
    }
  }
}