import 'package:flutter/material.dart';

/// Caching utility for text measurements to reduce text rendering overhead.
/// 
/// Reduces TextPainter overhead by caching text layout measurements.
/// Cache is keyed by text content, style, and max width combination.
class TextCache {
  static final Map<String, _CachedTextMeasurement> _cache = {};
  static const int _maxCacheSize = 200;
  
  /// Get cached text measurement or create and cache a new one.
  /// 
  /// [text] - The text content
  /// [style] - Text style
  /// [maxWidth] - Maximum width for text wrapping
  /// [textAlign] - Text alignment (default: TextAlign.start)
  static _CachedTextMeasurement _getMeasurement({
    required String text,
    required TextStyle style,
    required double maxWidth,
    TextAlign textAlign = TextAlign.start,
  }) {
    final cacheKey = _generateCacheKey(text, style, maxWidth, textAlign);
    
    // Return cached measurement if available
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }
    
    // Create and cache new measurement
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
      maxLines: null,
    );
    
    painter.layout(maxWidth: maxWidth);
    
    final measurement = _CachedTextMeasurement(
      width: painter.width,
      height: painter.height,
      didExceedMaxWidth: painter.didExceedMaxLines,
      painter: painter,
    );
    
    // Add to cache with size limit check
    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[cacheKey] = measurement;
    
    return measurement;
  }
  
  /// Generate a unique cache key based on text parameters.
  static String _generateCacheKey(
    String text,
    TextStyle style,
    double maxWidth,
    TextAlign textAlign,
  ) {
    return '${text}_${style.hashCode}_${maxWidth.toStringAsFixed(2)}_$textAlign';
  }
  
  /// Measure text width for a given style and max width.
  /// 
  /// Returns the width of the text, up to maxWidth.
  static double measureTextWidth({
    required String text,
    required TextStyle style,
    double maxWidth = double.infinity,
  }) {
    final measurement = _getMeasurement(
      text: text,
      style: style,
      maxWidth: maxWidth,
    );
    return measurement.width;
  }
  
  /// Measure text height for a given style and max width.
  /// 
  /// Returns the height of the text.
  static double measureTextHeight({
    required String text,
    required TextStyle style,
    double maxWidth = double.infinity,
  }) {
    final measurement = _getMeasurement(
      text: text,
      style: style,
      maxWidth: maxWidth,
    );
    return measurement.height;
  }
  
  /// Check if text exceeds max width for a given style.
  /// 
  /// Returns true if the text exceeds the maximum width.
  static bool willTextExceedMaxWidth({
    required String text,
    required TextStyle style,
    required double maxWidth,
  }) {
    final measurement = _getMeasurement(
      text: text,
      style: style,
      maxWidth: maxWidth,
    );
    return measurement.didExceedMaxWidth;
  }
  
  /// Get cached text measurement for use with TextPainter operations.
  /// 
  /// Returns a _CachedTextMeasurement object containing measurements and the painter.
  static _CachedTextMeasurement getTextMeasurement({
    required String text,
    required TextStyle style,
    double maxWidth = double.infinity,
    TextAlign textAlign = TextAlign.start,
  }) {
    return _getMeasurement(
      text: text,
      style: style,
      maxWidth: maxWidth,
      textAlign: textAlign,
    );
  }
  
  /// Clear the entire cache.
  /// 
  /// Useful for memory management when theme or text styles change.
  static void clear() {
    _cache.clear();
  }
  
  /// Get current cache size.
  /// 
  /// Useful for monitoring memory usage during development.
  static int get cacheSize => _cache.length;
}

/// Cached text measurement containing layout metrics.
class _CachedTextMeasurement {
  final double width;
  final double height;
  final bool didExceedMaxWidth;
  final TextPainter painter;
  
  _CachedTextMeasurement({
    required this.width,
    required this.height,
    required this.didExceedMaxWidth,
    required this.painter,
  });
}