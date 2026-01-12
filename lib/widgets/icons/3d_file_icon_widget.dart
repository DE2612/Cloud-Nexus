import 'package:flutter/material.dart';
import 'icon_config.dart';
import '../../utils/svg_icon_cache.dart';

/// 3D Material Design file icon widget using pre-created 3D SVG assets.
/// 
/// Renders file icons using 3D-style SVG files that follow Material Design 3
/// principles with elevated effects, layered depth, and dynamic shadows.
/// Icons are loaded from assets/icons/3d directory.
/// 
/// ## Features
/// - Automatic file type detection based on extension
/// - Four icon sizes: small (24px), medium (48px), large (64px), extraLarge (96px)
/// - Selection state with blue border
/// - Hover state with shadow effect
/// - Smooth 150ms animations for state transitions
/// - Fallback placeholder icon for missing 3D SVG assets
/// - Support for 80+ file types via IconConfig
/// - Unique 3D elements for each file type category
/// 
/// ## Design System
/// - **Documents:** Red gradient with document pages (#D32F2F → #C62828)
/// - **Spreadsheets:** Green gradient with grid pattern (#388E3C → #2E7D32)
/// - **Presentations:** Orange gradient with screen (#F57C00 → #EF6C00)
/// - **Images:** Purple gradient with image frame (#7B1FA2 → #6A1B9A)
/// - **Videos:** Blue gradient with play button (#1976D2 → #1565C0)
/// - **Audio:** Teal gradient with musical notes (#00897B → #00796B)
/// - **Archives:** Grey gradient with box (#616161 → #424242)
/// - **Code:** Indigo gradient with angle brackets (#3F51B5 → #303F9F)
/// - **Text/Data:** Cyan gradient with text lines (#00ACC1 → #0097A7)
/// - **Executables:** Amber gradient with gear (#FFA000 → #FF8F00)
/// - **Encrypted:** Purple gradient with lock (#7B1FA2 → #6A1B9A)
/// - **Fonts:** Pink gradient with "Aa" character (#E91E63 → #C2185B)
/// - **3D/CAD:** Orange gradient with 3D cube (#FF6F00 → #E65100)
/// - **E-books:** Brown gradient with book (#795548 → #6D4C41)
/// 
/// ## 3D Effects
/// - **Elevation:** Three-layer elevation system (4px, 2px, 1px)
/// - **Shadows:** Dynamic drop shadows (dy=1-4, stdDeviation=2-16)
/// - **Highlights:** Edge highlights (opacity=0.3, stroke-width=1-2)
/// - **Badges:** Floating badges with category labels
/// - **Lighting:** Top-left to bottom-right gradient
/// - **Depth:** Darker bottom edges for 3D appearance
/// 
/// ## Usage
/// ```dart
/// D3DFileIconWidget(
///   fileName: 'document.pdf',
///   size: IconSize.small,
///   isSelected: true,
///   isHovered: false,
///   onTap: () {
///     // Handle icon tap
///   },
/// )
/// ```
class D3DFileIconWidget extends StatelessWidget {
  /// The file name including extension (e.g., "document.pdf")
  /// Used to determine file type and corresponding 3D SVG icon
  final String fileName;
  
  /// The icon size to display
  /// - small: 24px (for lists, search results)
  /// - medium: 48px (for grid view)
  /// - large: 64px (for detailed views)
  /// - extraLarge: 96px (for detailed previews)
  final IconSize size;
  
  /// Whether icon is currently selected
  /// When true, displays a 2px blue border around icon
  final bool isSelected;
  
  /// Whether icon is currently being hovered
  /// When true, displays a shadow effect below icon
  final bool isHovered;
  
  /// Optional callback when icon is tapped
  /// Can be used to trigger file opening or selection
  final VoidCallback? onTap;
  
  const D3DFileIconWidget({
    super.key,
    required this.fileName,
    this.size = IconSize.medium,
    this.isSelected = false,
    this.isHovered = false,
    this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    // Get 3D SVG asset path for this file type
    // Example: "assets/icons/3d/24px/files/pdf.svg"
    final iconPath = IconConfig.getFileIconPathWithStyle(fileName, size, IconStyle.threeD);
    
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size.size.toDouble(),
        height: size.size.toDouble(),
        decoration: BoxDecoration(
          // Rounded corners for modern look
          borderRadius: BorderRadius.circular(4),
        ),
        child: SvgIconCache.get(
          path: iconPath,
          size: size.size.toDouble(),
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}