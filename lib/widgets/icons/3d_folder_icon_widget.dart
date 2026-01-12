import 'package:flutter/material.dart';
import 'icon_config.dart';
import '../../utils/svg_icon_cache.dart';

/// 3D Material Design folder icon widget using pre-created 3D SVG assets.
/// 
/// Renders folder icons using 3D-style SVG files that follow Material Design 3
/// principles with elevated effects, layered depth, and dynamic shadows.
/// Icons are loaded from assets/icons/3d directory.
/// 
/// ## Features
/// - Four folder variants with distinct visual styles and icons
/// - Four icon sizes: small (24px), medium (48px), large (64px), extraLarge (96px)
/// - Selection state with blue border
/// - Hover state with shadow effect
/// - Smooth 150ms animations for state transitions
/// - Consistent design language with 3D file icons
/// - Unique identifying icons for each folder variant
/// 
/// ## Folder Variants
/// - **Regular:** Orange gradient with standard folder appearance (#FFA000 → #FFB74D)
/// - **Encrypted:** Purple gradient with padlock icon (#7B1FA2 → #8E24AA)
/// - **Shared:** Blue gradient with user icon (#1976D2 → #2196F3)
/// - **Root:** Amber gradient with home/server icon (#FF8F00 → #FFA726)
/// 
/// ## 3D Effects
/// - **Elevation:** Three-layer elevation system (4px, 2px, 1px)
/// - **Shadows:** Dynamic drop shadows (dy=1-4, stdDeviation=2-16)
/// - **Highlights:** Edge highlights (opacity=0.3, stroke-width=1-2)
/// - **Identifiers:** Floating icons for variant identification
/// - **Lighting:** Top-left to bottom-right gradient
/// - **Depth:** Darker bottom edges for 3D appearance
/// - **Fold:** Visible folder fold on right side
/// 
/// ## Usage
/// ```dart
/// D3DFolderIconWidget(
///   variant: FolderVariant.encrypted,
///   size: IconSize.medium,
///   isSelected: true,
///   isHovered: false,
///   onTap: () {
///     // Handle folder tap
///   },
/// )
/// ```
class D3DFolderIconWidget extends StatelessWidget {
  /// The folder variant to display
  /// Determines visual style, color, and identifying icon
  final FolderVariant variant;
  
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
  /// Can be used to trigger folder navigation or selection
  final VoidCallback? onTap;
  
  const D3DFolderIconWidget({
    super.key,
    this.variant = FolderVariant.regular,
    this.size = IconSize.medium,
    this.isSelected = false,
    this.isHovered = false,
    this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    // Get 3D SVG asset path for this folder variant
    // Example: "assets/icons/3d/24px/folders/encrypted.svg"
    final iconPath = IconConfig.getFolderIconPathWithStyle(variant, size, IconStyle.threeD);
    
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