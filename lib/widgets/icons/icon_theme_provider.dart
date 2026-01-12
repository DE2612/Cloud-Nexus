import 'package:flutter/material.dart';
import 'icon_config.dart';

/// Color scheme for file categories
class FileCategoryColors {
  final List<Color> lightMode;
  final List<Color> darkMode;

  const FileCategoryColors({
    required this.lightMode,
    required this.darkMode,
  });

  List<Color> getColors(bool isDarkMode) {
    return isDarkMode ? darkMode : lightMode;
  }
}

/// Theme data for file icons
class IconThemeData {
  final Map<FileCategory, FileCategoryColors> categoryColors;
  final double borderRadius;
  final double shadowBlur;
  final double shadowOffset;
  final double shadowOpacity;
  final TextStyle labelStyle;
  final bool showIconOverlay;

  const IconThemeData({
    required this.categoryColors,
    this.borderRadius = 8.0,
    this.shadowBlur = 4.0,
    this.shadowOffset = 2.0,
    this.shadowOpacity = 0.2,
    this.labelStyle = const TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.bold,
      color: Colors.white,
    ),
    this.showIconOverlay = true,
  });

  /// Get colors for a category
  List<Color> getColors(FileCategory category, bool isDarkMode) {
    return categoryColors[category]?.getColors(isDarkMode) ?? 
           categoryColors[FileCategory.unknown]!.getColors(isDarkMode);
  }

  /// Create a copy with modified properties
  IconThemeData copyWith({
    Map<FileCategory, FileCategoryColors>? categoryColors,
    double? borderRadius,
    double? shadowBlur,
    double? shadowOffset,
    double? shadowOpacity,
    TextStyle? labelStyle,
    bool? showIconOverlay,
  }) {
    return IconThemeData(
      categoryColors: categoryColors ?? this.categoryColors,
      borderRadius: borderRadius ?? this.borderRadius,
      shadowBlur: shadowBlur ?? this.shadowBlur,
      shadowOffset: shadowOffset ?? this.shadowOffset,
      shadowOpacity: shadowOpacity ?? this.shadowOpacity,
      labelStyle: labelStyle ?? this.labelStyle,
      showIconOverlay: showIconOverlay ?? this.showIconOverlay,
    );
  }

  /// Default light theme
  static IconThemeData get defaultLightTheme {
    return IconThemeData(
      categoryColors: {
        FileCategory.documents: const FileCategoryColors(
          lightMode: [
            Color(0xFFE53935), // Red
            Color(0xFFC62828),
          ],
          darkMode: [
            Color(0xFFEF5350),
            Color(0xFFE57373),
          ],
        ),
        FileCategory.spreadsheets: const FileCategoryColors(
          lightMode: [
            Color(0xFF43A047), // Green
            Color(0xFF2E7D32),
          ],
          darkMode: [
            Color(0xFF66BB6A),
            Color(0xFF4CAF50),
          ],
        ),
        FileCategory.presentations: const FileCategoryColors(
          lightMode: [
            Color(0xFFFF9800), // Orange
            Color(0xFFF57C00),
          ],
          darkMode: [
            Color(0xFFFFB74D),
            Color(0xFFFF9800),
          ],
        ),
        FileCategory.images: const FileCategoryColors(
          lightMode: [
            Color(0xFF9C27B0), // Purple
            Color(0xFF7B1FA2),
          ],
          darkMode: [
            Color(0xFFBA68C8),
            Color(0xFF9C27B0),
          ],
        ),
        FileCategory.videos: const FileCategoryColors(
          lightMode: [
            Color(0xFF1E88E5), // Blue
            Color(0xFF1565C0),
          ],
          darkMode: [
            Color(0xFF42A5F5),
            Color(0xFF2196F3),
          ],
        ),
        FileCategory.audio: const FileCategoryColors(
          lightMode: [
            Color(0xFF00ACC1), // Teal
            Color(0xFF00838F),
          ],
          darkMode: [
            Color(0xFF26C6DA),
            Color(0xFF00BCD4),
          ],
        ),
        FileCategory.archives: const FileCategoryColors(
          lightMode: [
            Color(0xFF607D8B), // Blue Grey
            Color(0xFF455A64),
          ],
          darkMode: [
            Color(0xFF78909C),
            Color(0xFF607D8B),
          ],
        ),
        FileCategory.code: const FileCategoryColors(
          lightMode: [
            Color(0xFF283593), // Dark Blue
            Color(0xFF1A237E),
          ],
          darkMode: [
            Color(0xFF3949AB),
            Color(0xFF283593),
          ],
        ),
        FileCategory.text: const FileCategoryColors(
          lightMode: [
            Color(0xFF4FC3F7), // Light Blue
            Color(0xFF29B6F6),
          ],
          darkMode: [
            Color(0xFF81D4FA),
            Color(0xFF4FC3F7),
          ],
        ),
        FileCategory.data: const FileCategoryColors(
          lightMode: [
            Color(0xFFFFB300), // Amber
            Color(0xFFFFA000),
          ],
          darkMode: [
            Color(0xFFFFCA28),
            Color(0xFFFFB300),
          ],
        ),
        FileCategory.executable: const FileCategoryColors(
          lightMode: [
            Color(0xFFD32F2F), // Red
            Color(0xFFC62828),
          ],
          darkMode: [
            Color(0xFFEF5350),
            Color(0xFFE57373),
          ],
        ),
        FileCategory.folder: const FileCategoryColors(
          lightMode: [
            Color(0xFFFFA726), // Orange
            Color(0xFFFF9800),
          ],
          darkMode: [
            Color(0xFFFFB74D),
            Color(0xFFFFA726),
          ],
        ),
        FileCategory.unknown: const FileCategoryColors(
          lightMode: [
            Color(0xFF9E9E9E), // Grey
            Color(0xFF757575),
          ],
          darkMode: [
            Color(0xFFBDBDBD),
            Color(0xFF9E9E9E),
          ],
        ),
      },
      borderRadius: 8.0,
      shadowBlur: 4.0,
      shadowOffset: 2.0,
      shadowOpacity: 0.2,
      labelStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
      showIconOverlay: true,
    );
  }
}

/// Inherited widget for icon theme
class IconThemeProvider extends InheritedWidget {
  final IconThemeData data;

  const IconThemeProvider({
    super.key,
    required this.data,
    required Widget child,
  }) : super(child: child);

  static IconThemeProvider of(BuildContext context) {
    final IconThemeProvider? result =
        context.dependOnInheritedWidgetOfExactType<IconThemeProvider>();
    assert(result != null, 'No IconThemeProvider found in context');
    return result!;
  }

  @override
  bool updateShouldNotify(IconThemeProvider oldWidget) {
    return data != oldWidget.data;
  }
}