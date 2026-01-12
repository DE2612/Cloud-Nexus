import 'dart:async';
import 'package:flutter/material.dart';
import '../models/notification_type.dart';
import '../models/notification_type.dart' as notification_model;

class NotificationService {
  // Singleton pattern
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Notification stream
  final StreamController<notification_model.AppNotification> _notificationsController =
      StreamController<notification_model.AppNotification>.broadcast();
  Stream<notification_model.AppNotification> get notifications => _notificationsController.stream;

  // Active notifications list
  final List<notification_model.AppNotification> _activeNotifications = [];
  List<notification_model.AppNotification> get activeNotifications => List.unmodifiable(_activeNotifications);

  // Dismiss stream
  final StreamController<String> _dismissController = StreamController<String>.broadcast();
  Stream<String> get dismissStream => _dismissController.stream;

  /// Show a notification
  void show({
    required String title,
    required String message,
    notification_model.NotificationType type = notification_model.NotificationType.info,
    Duration duration = const Duration(seconds: 4),
  }) {
    final notification = notification_model.AppNotification(
      title: title,
      message: message,
      type: type,
      duration: duration,
    );

    _activeNotifications.add(notification);
    _notificationsController.add(notification);

    // Auto-dismiss after duration
    Timer(duration, () {
      dismiss(notification.id);
    });
  }

  /// Show info notification
  void info(String message, {String? title, Duration duration = const Duration(seconds: 4)}) {
    show(title: title ?? 'Info', message: message, type: notification_model.NotificationType.info, duration: duration);
  }

  /// Show success notification
  void success(String message, {String? title, Duration duration = const Duration(seconds: 4)}) {
    show(title: title ?? 'Success', message: message, type: notification_model.NotificationType.success, duration: duration);
  }

  /// Show warning notification
  void warning(String message, {String? title, Duration duration = const Duration(seconds: 4)}) {
    show(title: title ?? 'Warning', message: message, type: notification_model.NotificationType.warning, duration: duration);
  }

  /// Show error notification
  void error(String message, {String? title, Duration duration = const Duration(seconds: 6)}) {
    show(title: title ?? 'Error', message: message, type: notification_model.NotificationType.error, duration: duration);
  }

  /// Dismiss a notification by ID
  void dismiss(String id) {
    final index = _activeNotifications.indexWhere((n) => n.id == id);
    if (index != -1) {
      _activeNotifications[index] = _activeNotifications[index].copyWith(dismissed: true);
      _dismissController.add(id);
      _activeNotifications.removeAt(index);
    }
  }

  /// Dismiss all notifications
  void dismissAll() {
    for (final notification in _activeNotifications) {
      _dismissController.add(notification.id);
    }
    _activeNotifications.clear();
  }

  /// Clear all notifications (remove from list immediately)
  void clear() {
    _activeNotifications.clear();
  }

  /// Helper method to show SnackBar-like messages (for migration from SnackBar)
  void showNotification(String message, {bool isError = false}) {
    if (isError) {
      error(message);
    } else {
      success(message);
    }
  }
}