import 'dart:async';
import 'dart:developer' as developer;

/// Throttled logger to prevent main thread flooding from excessive print statements
class ThrottledLogger {
  final String prefix;
  final Duration throttleDuration;
  final bool enabled;
  
  final Map<String, Timer> _timers = {};
  final Map<String, String> _pendingMessages = {};
  final Map<String, int> _messageCounts = {};
  
  ThrottledLogger({
    this.prefix = '',
    this.throttleDuration = const Duration(milliseconds: 500),
    this.enabled = true,
  });

  /// Log a message with throttling
  void log(String message, {bool force = false}) {
    if (!enabled) return;
    
    if (force) {
      _printMessage(message);
      return;
    }
    
    final key = _generateKey(message);
    
    // Update pending message and count
    _pendingMessages[key] = message;
    _messageCounts[key] = (_messageCounts[key] ?? 0) + 1;
    
    // Cancel existing timer for this key
    _timers[key]?.cancel();
    
    // Set new timer
    _timers[key] = Timer(throttleDuration, () {
      final count = _messageCounts[key] ?? 1;
      final finalMessage = count > 1 
          ? '$message (x$count)' 
          : message;
      
      _printMessage(finalMessage);
      
      // Clean up
      _timers.remove(key);
      _pendingMessages.remove(key);
      _messageCounts.remove(key);
    });
  }

  /// Log an error message (always printed immediately)
  void error(String message) {
    if (!enabled) return;
    _printMessage('ERROR: $message', isError: true);
  }

  /// Log a warning message (always printed immediately)
  void warning(String message) {
    if (!enabled) return;
    _printMessage('WARNING: $message');
  }

  /// Log a success message (always printed immediately)
  void success(String message) {
    if (!enabled) return;
    _printMessage('$message');
  }

  /// Log an info message (throttled)
  void info(String message) {
    log('$message');
  }

  /// Log a debug message (throttled)
  void debug(String message) {
    log('$message');
  }

  void _printMessage(String message, {bool isError = false}) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 23);
    final fullMessage = prefix.isEmpty 
        ? '[$timestamp] $message'
        : '[$timestamp] $prefix: $message';
    
    if (isError) {
      developer.log(fullMessage, level: 1000); // Error level
    } else {
      developer.log(fullMessage);
    }
  }

  String _generateKey(String message) {
    // Generate a simple key based on the first 50 characters
    return message.length > 50 
        ? message.substring(0, 50) 
        : message;
  }

  /// Flush all pending messages
  void flush() {
    for (final key in _pendingMessages.keys) {
      _timers[key]?.cancel();
      final count = _messageCounts[key] ?? 1;
      final message = _pendingMessages[key] ?? '';
      final finalMessage = count > 1 
          ? '$message (x$count)' 
          : message;
      _printMessage(finalMessage);
    }
    _timers.clear();
    _pendingMessages.clear();
    _messageCounts.clear();
  }

  /// Clear all pending messages without printing
  void clear() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _pendingMessages.clear();
    _messageCounts.clear();
  }
}

/// Global logger instance
final logger = ThrottledLogger(
  prefix: 'CloudNexus',
  throttleDuration: const Duration(milliseconds: 500),
);