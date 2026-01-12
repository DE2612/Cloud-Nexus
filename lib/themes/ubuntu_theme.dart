import 'package:flutter/material.dart';
import '../models/cloud_node.dart';

class UbuntuTheme {
  // Ubuntu Light Theme Colors
  static const Color _ubuntuOrange = Color(0xFFE95420);
  static const Color _ubuntuDarkOrange = Color(0xFFC34113);
  static const Color _ubuntuLightOrange = Color(0xFFF4A261);
  
  static const Color _ubuntuWarmGrey = Color(0xFFAEA79F);
  static const Color _ubuntuMediumGrey = Color(0xFF868686);
  static const Color _ubuntuLightGrey = Color(0xFFE8E8E8);
  static const Color _ubuntuVeryLightGrey = Color(0xFFF7F7F7);
  static const Color _ubuntuWhite = Color(0xFFFFFFFF);
  
  static const Color _ubuntuBlack = Color(0xFF000000);
  static const Color _ubuntuDarkGrey = Color(0xFF3D3846);
  static const Color _ubuntuTextGrey = Color(0xFF666666);
  
  // Ubuntu-specific colors
  static const Color _ubuntuPurple = Color(0xFF77216F);
  static const Color _ubuntuBlue = Color(0xFF2C001E);
  static const Color _ubuntuTeal = Color(0xFF062C36);

  // High refresh rate animation constants
  static const Duration _ultraFastDuration = Duration(milliseconds: 16); // ~1 frame at 240Hz
  static const Duration _fastDuration = Duration(milliseconds: 33); // ~2 frames at 240Hz
  static const Duration _mediumDuration = Duration(milliseconds: 66); // ~4 frames at 240Hz
  static const Duration _slowDuration = Duration(milliseconds: 125); // ~8 frames at 240Hz

  // Ubuntu-style animation curves
  static const Curve _ubuntuEaseOut = Cubic(0.215, 0.610, 0.355, 1.000);
  static const Curve _ubuntuEaseInOut = Cubic(0.645, 0.045, 0.355, 1.000);
  static const Curve _ubuntuSharp = Cubic(0.4, 0.0, 0.6, 1.0);
  static const Curve _ubuntuSmooth = Cubic(0.25, 0.1, 0.25, 1.0);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.light,
      
      // Color scheme
      colorScheme: const ColorScheme.light(
        primary: _ubuntuOrange,
        secondary: _ubuntuLightOrange,
        surface: _ubuntuWhite,
        background: _ubuntuVeryLightGrey,
        error: _ubuntuDarkOrange,
        onPrimary: _ubuntuWhite,
        onSecondary: _ubuntuWhite,
        onSurface: _ubuntuDarkGrey,
        onBackground: _ubuntuDarkGrey,
        onError: _ubuntuWhite,
      ),
      
      // App bar theme
      appBarTheme: const AppBarTheme(
        elevation: 0,
        backgroundColor: _ubuntuWhite,
        foregroundColor: _ubuntuDarkGrey,
        titleTextStyle: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          fontFamily: 'Ubuntu',
        ),
        iconTheme: IconThemeData(
          color: _ubuntuDarkGrey,
          size: 20,
        ),
      ),
      
      // Card theme
      cardTheme: CardThemeData(
        elevation: 0,
        color: _ubuntuWhite,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: _ubuntuLightGrey, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      
      // Elevated button theme
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _ubuntuOrange,
          foregroundColor: _ubuntuWhite,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            fontFamily: 'Ubuntu',
          ),
        ).copyWith(
          overlayColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.hovered)) {
              return _ubuntuDarkOrange.withOpacity(0.1);
            }
            if (states.contains(MaterialState.pressed)) {
              return _ubuntuDarkOrange.withOpacity(0.2);
            }
            return null;
          }),
        ),
      ),
      
      // Text button theme
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: _ubuntuOrange,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            fontFamily: 'Ubuntu',
          ),
        ).copyWith(
          overlayColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.hovered)) {
              return _ubuntuOrange.withOpacity(0.1);
            }
            if (states.contains(MaterialState.pressed)) {
              return _ubuntuOrange.withOpacity(0.2);
            }
            return null;
          }),
        ),
      ),
      
      // Outlined button theme
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _ubuntuOrange,
          side: const BorderSide(color: _ubuntuOrange, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            fontFamily: 'Ubuntu',
          ),
        ).copyWith(
          overlayColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.hovered)) {
              return _ubuntuOrange.withOpacity(0.1);
            }
            if (states.contains(MaterialState.pressed)) {
              return _ubuntuOrange.withOpacity(0.2);
            }
            return null;
          }),
        ),
      ),
      
      // Icon theme
      iconTheme: const IconThemeData(
        color: _ubuntuDarkGrey,
        size: 20,
      ),
      
      // Text theme
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 32,
          fontWeight: FontWeight.w300,
          fontFamily: 'Ubuntu',
        ),
        displayMedium: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 28,
          fontWeight: FontWeight.w300,
          fontFamily: 'Ubuntu',
        ),
        displaySmall: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 24,
          fontWeight: FontWeight.w400,
          fontFamily: 'Ubuntu',
        ),
        headlineLarge: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 20,
          fontWeight: FontWeight.w500,
          fontFamily: 'Ubuntu',
        ),
        headlineMedium: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 18,
          fontWeight: FontWeight.w500,
          fontFamily: 'Ubuntu',
        ),
        headlineSmall: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          fontFamily: 'Ubuntu',
        ),
        titleLarge: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          fontFamily: 'Ubuntu',
        ),
        titleMedium: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          fontFamily: 'Ubuntu',
        ),
        titleSmall: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          fontFamily: 'Ubuntu',
        ),
        bodyLarge: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 16,
          fontWeight: FontWeight.w400,
          fontFamily: 'Ubuntu',
        ),
        bodyMedium: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 14,
          fontWeight: FontWeight.w400,
          fontFamily: 'Ubuntu',
        ),
        bodySmall: TextStyle(
          color: _ubuntuTextGrey,
          fontSize: 12,
          fontWeight: FontWeight.w400,
          fontFamily: 'Ubuntu',
        ),
        labelLarge: TextStyle(
          color: _ubuntuDarkGrey,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          fontFamily: 'Ubuntu',
        ),
        labelMedium: TextStyle(
          color: _ubuntuTextGrey,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          fontFamily: 'Ubuntu',
        ),
        labelSmall: TextStyle(
          color: _ubuntuTextGrey,
          fontSize: 10,
          fontWeight: FontWeight.w500,
          fontFamily: 'Ubuntu',
        ),
      ),
      
      // Input decoration theme
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _ubuntuWhite,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _ubuntuLightGrey, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _ubuntuLightGrey, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _ubuntuOrange, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _ubuntuDarkOrange, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _ubuntuDarkOrange, width: 2),
        ),
        labelStyle: const TextStyle(
          color: _ubuntuTextGrey,
          fontFamily: 'Ubuntu',
        ),
        hintStyle: const TextStyle(
          color: _ubuntuMediumGrey,
          fontFamily: 'Ubuntu',
        ),
      ),
      
      // List tile theme
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        dense: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
      
      // Divider theme
      dividerTheme: const DividerThemeData(
        color: _ubuntuLightGrey,
        thickness: 1,
        space: 1,
      ),
      
      // Tooltip theme
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: _ubuntuDarkGrey,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(
          color: _ubuntuWhite,
          fontSize: 12,
          fontFamily: 'Ubuntu',
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        margin: const EdgeInsets.all(8),
      ),
      
      // Disable ripple effects for desktop feel
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      
      // Scroll behavior
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(8.0),
        radius: const Radius.circular(4),
        crossAxisMargin: 4,
        mainAxisMargin: 4,
        thumbColor: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.hovered)) {
            return _ubuntuMediumGrey;
          }
          return _ubuntuWarmGrey;
        }),
        trackColor: MaterialStateProperty.resolveWith((states) {
          return _ubuntuLightGrey.withOpacity(0.3);
        }),
        trackBorderColor: MaterialStateProperty.resolveWith((states) {
          return Colors.transparent;
        }),
        interactive: true,
      ),
    );
  }

}

// Ubuntu animation presets
class UbuntuAnimations {
  static const Duration ultraFast = Duration(milliseconds: 16); // ~1 frame at 240Hz
  static const Duration fast = Duration(milliseconds: 33); // ~2 frames at 240Hz
  static const Duration medium = Duration(milliseconds: 66); // ~4 frames at 240Hz
  static const Duration slow = Duration(milliseconds: 125); // ~8 frames at 240Hz
  
  static const Curve easeOut = Cubic(0.215, 0.610, 0.355, 1.000);
  static const Curve easeInOut = Cubic(0.645, 0.045, 0.355, 1.000);
  static const Curve sharp = Cubic(0.4, 0.0, 0.6, 1.0);
  static const Curve smooth = Cubic(0.25, 0.1, 0.25, 1.0);
}

// Ubuntu colors
class UbuntuColors {
  static const Color orange = Color(0xFFE95420);
  static const Color darkOrange = Color(0xFFC34113);
  static const Color lightOrange = Color(0xFFF4A261);
  static const Color warmGrey = Color(0xFFAEA79F);
  static const Color mediumGrey = Color(0xFF868686);
  static const Color lightGrey = Color(0xFFE8E8E8);
  static const Color veryLightGrey = Color(0xFFF7F7F7);
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color darkGrey = Color(0xFF3D3846);
  static const Color textGrey = Color(0xFF666666);
  static const Color purple = Color(0xFF77216F);
  static const Color blue = Color(0xFF2C001E);
  static const Color teal = Color(0xFF062C36);
}

// Ubuntu toolbar components
class UbuntuToolbar extends StatelessWidget {
  final Widget leading;
  final List<Widget> actions;

  const UbuntuToolbar({
    Key? key,
    required this.leading,
    required this.actions,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: UbuntuColors.white,
        border: Border(
          bottom: BorderSide(color: UbuntuColors.lightGrey, width: 1),
        ),
      ),
      child: Row(
        children: [
          leading,
          const Spacer(),
          ...actions,
        ],
      ),
    );
  }
}

class UbuntuToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const UbuntuToolbarButton({
    Key? key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 36,
        height: 36,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: Icon(
              icon,
              size: 18,
              color: onPressed != null ? UbuntuColors.darkGrey : UbuntuColors.lightGrey,
            ),
          ),
        ),
      ),
    );
  }
}

class UbuntuToolbarAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isActive;

  const UbuntuToolbarAction({
    Key? key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.isActive = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 36,
        height: 36,
        margin: const EdgeInsets.only(left: 4),
        child: Material(
          color: isActive ? UbuntuColors.orange.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: Icon(
              icon,
              size: 18,
              color: onPressed != null
                  ? (isActive ? UbuntuColors.orange : UbuntuColors.darkGrey)
                  : UbuntuColors.lightGrey,
            ),
          ),
        ),
      ),
    );
  }
}

// Ubuntu breadcrumb component
class UbuntuBreadcrumbNav extends StatelessWidget {
  final List<CloudNode> breadcrumbs;
  final CloudNode? currentFolder;
  final Function(CloudNode) onNavigate;
  final Function(CloudNode) onNavigateToFolder;
  final VoidCallback onHomeClicked;

  const UbuntuBreadcrumbNav({
    Key? key,
    required this.breadcrumbs,
    this.currentFolder,
    required this.onNavigate,
    required this.onNavigateToFolder,
    required this.onHomeClicked,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: UbuntuColors.white,
        border: Border(
          bottom: BorderSide(color: UbuntuColors.lightGrey, width: 1),
        ),
      ),
      child: Row(
        children: [
          // Home button
          _buildBreadcrumbItem(
            icon: Icons.home,
            label: 'Home',
            onTap: onHomeClicked,
            isFirst: true,
          ),
          
          // Breadcrumb items
          if (breadcrumbs.isNotEmpty) ...[
            const SizedBox(width: 8),
            ...breadcrumbs.asMap().entries.map((entry) {
              final index = entry.key;
              final folder = entry.value;
              final isLast = index == breadcrumbs.length - 1;
              
              return [
                if (index > 0) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: UbuntuColors.mediumGrey,
                  ),
                  const SizedBox(width: 4),
                ],
                _buildBreadcrumbItem(
                  label: folder.name,
                  onTap: isLast ? null : () => onNavigateToFolder(folder),
                  isLast: isLast,
                ),
              ];
            }).expand((item) => item),
          ],
          
          // Current folder
          if (currentFolder != null && !breadcrumbs.contains(currentFolder)) ...[
            if (breadcrumbs.isNotEmpty) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 16,
                color: UbuntuColors.mediumGrey,
              ),
              const SizedBox(width: 4),
            ],
            _buildBreadcrumbItem(
              label: currentFolder!.name,
              onTap: null,
              isLast: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBreadcrumbItem({
    IconData? icon,
    required String label,
    VoidCallback? onTap,
    bool isFirst = false,
    bool isLast = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 16,
                color: onTap != null ? UbuntuColors.orange : UbuntuColors.mediumGrey,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
                color: onTap != null ? UbuntuColors.orange : UbuntuColors.mediumGrey,
                fontFamily: 'Ubuntu',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Ubuntu status bar component
class UbuntuStatusBarWidget extends StatelessWidget {
  final List<UbuntuStatusItem> leftItems;
  final List<UbuntuStatusItem> rightItems;

  const UbuntuStatusBarWidget({
    Key? key,
    required this.leftItems,
    required this.rightItems,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: UbuntuColors.white,
        border: Border(
          top: BorderSide(color: UbuntuColors.lightGrey, width: 1),
        ),
      ),
      child: Row(
        children: [
          Row(
            children: leftItems.map((item) => _buildStatusItem(item)).toList(),
          ),
          const Spacer(),
          Row(
            children: rightItems.map((item) => _buildStatusItem(item)).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusItem(UbuntuStatusItem item) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item.icon != null) ...[
            Icon(
              item.icon,
              size: 12,
              color: item.color ?? UbuntuColors.textGrey,
            ),
            const SizedBox(width: 4),
          ],
          Text(
            item.text,
            style: TextStyle(
              fontSize: 11,
              color: item.color ?? UbuntuColors.textGrey,
              fontFamily: 'Ubuntu',
            ),
          ),
        ],
      ),
    );
  }
}

class UbuntuStatusItem {
  final String text;
  final IconData? icon;
  final Color? color;

  const UbuntuStatusItem({
    required this.text,
    this.icon,
    this.color,
  });
}