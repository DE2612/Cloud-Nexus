/// Notification types for the top-right notification system
enum NotificationType {
  info,
  success,
  warning,
  error,
}

/// App notification model
class AppNotification {
  final String id;
  final String title;
  final String message;
  final NotificationType type;
  final DateTime createdAt;
  final Duration duration;
  bool dismissed;

  AppNotification({
    String? id,
    required this.title,
    required this.message,
    this.type = NotificationType.info,
    DateTime? createdAt,
    this.duration = const Duration(seconds: 4),
    this.dismissed = false,
  })  : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        createdAt = createdAt ?? DateTime.now();

  /// Create a copy with modified properties
  AppNotification copyWith({
    String? id,
    String? title,
    String? message,
    NotificationType? type,
    DateTime? createdAt,
    Duration? duration,
    bool? dismissed,
  }) {
    return AppNotification(
      id: id ?? this.id,
      title: title ?? this.title,
      message: message ?? this.message,
      type: type ?? this.type,
      createdAt: createdAt ?? this.createdAt,
      duration: duration ?? this.duration,
      dismissed: dismissed ?? this.dismissed,
    );
  }

  /// Convert to map for storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'message': message,
      'type': type.index,
      'createdAt': createdAt.toIso8601String(),
      'duration': duration.inMilliseconds,
      'dismissed': dismissed,
    };
  }

  /// Create from map
  factory AppNotification.fromMap(Map<String, dynamic> map) {
    return AppNotification(
      id: map['id'],
      title: map['title'],
      message: map['message'],
      type: NotificationType.values[map['type']],
      createdAt: DateTime.parse(map['createdAt']),
      duration: Duration(milliseconds: map['duration']),
      dismissed: map['dismissed'] ?? false,
    );
  }
}