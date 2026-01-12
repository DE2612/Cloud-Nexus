import 'package:flutter/material.dart';
import '../themes/ubuntu_theme.dart' as theme;

/// Loading indicator widget that displays during API calls
class LoadingIndicator extends StatelessWidget {
  final String? message;
  final double size;
  final Color? color;
  final bool showBackground;

  const LoadingIndicator({
    Key? key,
    this.message,
    this.size = 32.0,
    this.color,
    this.showBackground = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final backgroundColor = showBackground
        ? theme.UbuntuColors.white.withOpacity(0.9)
        : Colors.transparent;

    return Container(
      color: backgroundColor,
      padding: message != null
          ? const EdgeInsets.symmetric(horizontal: 24, vertical: 16)
          : EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(
                color ?? theme.UbuntuColors.orange,
              ),
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 12),
            Text(
              message!,
              style: const TextStyle(
                fontSize: 13,
                color: theme.UbuntuColors.textGrey,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Inline loading row for list items
class LoadingRow extends StatelessWidget {
  final String? message;
  final double height;

  const LoadingRow({
    Key? key,
    this.message,
    this.height = 60,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.UbuntuColors.orange.withOpacity(0.7),
              ),
            ),
          ),
          if (message != null) ...[
            const SizedBox(width: 12),
            Text(
              message!,
              style: const TextStyle(
                fontSize: 13,
                color: theme.UbuntuColors.textGrey,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shimmer loading effect for list items
class ShimmerLoadingItem extends StatelessWidget {
  final double height;
  final double borderRadius;

  const ShimmerLoadingItem({
    Key? key,
    this.height = 56,
    this.borderRadius = 8,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Icon placeholder
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.UbuntuColors.lightGrey.withOpacity(0.3),
              borderRadius: BorderRadius.circular(borderRadius),
            ),
          ),
          const SizedBox(width: 12),
          // Text lines
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  height: 14,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: theme.UbuntuColors.lightGrey.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 10,
                  width: 100,
                  decoration: BoxDecoration(
                    color: theme.UbuntuColors.lightGrey.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full screen loading overlay
class LoadingOverlay extends StatelessWidget {
  final bool isLoading;
  final String? message;
  final Widget child;

  const LoadingOverlay({
    Key? key,
    required this.isLoading,
    this.message,
    required this.child,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (isLoading)
          Positioned.fill(
            child: Container(
              color: Colors.black26,
              child: Center(
                child: LoadingIndicator(
                  message: message ?? 'Loading...',
                  showBackground: true,
                ),
              ),
            ),
          ),
      ],
    );
  }
}