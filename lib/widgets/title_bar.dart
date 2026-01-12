import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../themes/ubuntu_theme.dart';

/// Ubuntu-style title bar with window controls
class TitleBar extends StatefulWidget {
  final String title;
  final List<Widget>? actions;
  final VoidCallback? onClose;
  final VoidCallback? onMinimize;
  final VoidCallback? onMaximize;
  final bool isMaximized;

  const TitleBar({
    Key? key,
    required this.title,
    this.actions,
    this.onClose,
    this.onMinimize,
    this.onMaximize,
    this.isMaximized = false,
  }) : super(key: key);

  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar>
    with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  
  String? _hoveredButton;

  @override
  void initState() {
    super.initState();
    
    _fadeController = AnimationController(
      duration: UbuntuAnimations.medium,
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: UbuntuAnimations.smooth,
    ));

    // Start fade-in animation
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  void _handleButtonHoverChange(String? buttonId) {
    setState(() {
      _hoveredButton = buttonId;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) {
        return Opacity(
          opacity: _fadeAnimation.value,
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: UbuntuColors.white,
              border: const Border(
                bottom: BorderSide(color: UbuntuColors.lightGrey, width: 1),
              ),
            ),
            child: Row(
              children: [
                _buildWindowControls(),
                Expanded(child: _buildTitle()),
                if (widget.actions != null) ...widget.actions!,
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildWindowControls() {
    return Row(
      children: [
        _buildWindowButton(
          id: 'close',
          icon: Icons.close,
          color: UbuntuColors.darkGrey,
          hoverColor: UbuntuColors.darkOrange,
          onTap: widget.onClose,
        ),
        _buildWindowButton(
          id: 'minimize',
          icon: Icons.remove,
          color: UbuntuColors.darkGrey,
          hoverColor: UbuntuColors.warmGrey,
          onTap: widget.onMinimize,
        ),
        _buildWindowButton(
          id: 'maximize',
          icon: widget.isMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
          color: UbuntuColors.darkGrey,
          hoverColor: UbuntuColors.warmGrey,
          onTap: widget.onMaximize,
        ),
        const SizedBox(width: 16),
      ],
    );
  }

  Widget _buildWindowButton({
    required String id,
    required IconData icon,
    required Color color,
    required Color hoverColor,
    VoidCallback? onTap,
  }) {
    return MouseRegion(
      onEnter: (_) => _handleButtonHoverChange(id),
      onExit: (_) => _handleButtonHoverChange(null),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap?.call();
        },
        child: AnimatedContainer(
          duration: UbuntuAnimations.ultraFast,
          width: 24,
          height: 24,
          margin: const EdgeInsets.only(left: 8, top: 8, bottom: 8),
          decoration: BoxDecoration(
            color: _hoveredButton == id ? hoverColor.withOpacity(0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            size: 14,
            color: _hoveredButton == id ? hoverColor : color,
          ),
        ),
      ),
    );
  }

  Widget _buildTitle() {
    return GestureDetector(
      onDoubleTap: () {
        HapticFeedback.lightImpact();
        widget.onMaximize?.call();
      },
      child: Container(
        height: 40,
        alignment: Alignment.center,
        child: Text(
          widget.title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: UbuntuColors.darkGrey,
            fontFamily: 'Ubuntu',
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// Ubuntu-style toolbar with action buttons
class UbuntuToolbar extends StatelessWidget {
  final List<UbuntuToolbarAction> actions;
  final Widget? leading;
  final Widget? title;

  const UbuntuToolbar({
    Key? key,
    required this.actions,
    this.leading,
    this.title,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: UbuntuColors.lightGrey, width: 1),
        ),
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: leading,
            ),
            Container(
              width: 1,
              height: 32,
              color: UbuntuColors.lightGrey,
            ),
          ],
          Expanded(child: title ?? const SizedBox.shrink()),
          _buildActions(),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: actions.map((action) => _buildActionButton(action)).toList(),
    );
  }

  Widget _buildActionButton(UbuntuToolbarAction action) {
    return UbuntuToolbarButton(
      icon: action.icon,
      tooltip: action.tooltip,
      onPressed: action.onPressed,
      isActive: action.isActive,
    );
  }
}

/// Ubuntu-style toolbar button
class UbuntuToolbarButton extends StatefulWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool isActive;

  const UbuntuToolbarButton({
    Key? key,
    required this.icon,
    this.tooltip,
    this.onPressed,
    this.isActive = false,
  }) : super(key: key);

  @override
  State<UbuntuToolbarButton> createState() => _UbuntuToolbarButtonState();
}

class _UbuntuToolbarButtonState extends State<UbuntuToolbarButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<Color?> _colorAnimation;
  
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    
    _animationController = AnimationController(
      duration: UbuntuAnimations.ultraFast,
      vsync: this,
    );

    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.1,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: UbuntuAnimations.smooth,
    ));

    _colorAnimation = ColorTween(
      begin: UbuntuColors.mediumGrey,
      end: UbuntuColors.orange,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: UbuntuAnimations.smooth,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _handleHoverChange(bool isHovered) {
    if (_isHovered != isHovered) {
      setState(() {
        _isHovered = isHovered;
      });
      
      if (isHovered) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget button = MouseRegion(
      onEnter: (_) => _handleHoverChange(true),
      onExit: (_) => _handleHoverChange(false),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onPressed?.call();
        },
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: Container(
                width: 36,
                height: 36,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: widget.isActive 
                      ? UbuntuColors.orange.withOpacity(0.1)
                      : _isHovered 
                          ? UbuntuColors.lightGrey 
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  widget.icon,
                  size: 18,
                  color: widget.isActive 
                      ? UbuntuColors.orange
                      : _colorAnimation.value,
                ),
              ),
            );
          },
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(
        message: widget.tooltip!,
        child: button,
      );
    }

    return button;
  }
}

/// Ubuntu toolbar action definition
class UbuntuToolbarAction {
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool isActive;

  const UbuntuToolbarAction({
    required this.icon,
    this.tooltip,
    this.onPressed,
    this.isActive = false,
  });
}

/// Ubuntu-style status bar
class UbuntuStatusBar extends StatelessWidget {
  final List<Widget> leftItems;
  final List<Widget> rightItems;

  const UbuntuStatusBar({
    Key? key,
    required this.leftItems,
    required this.rightItems,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      decoration: const BoxDecoration(
        color: UbuntuColors.veryLightGrey,
        border: Border(
          top: BorderSide(color: UbuntuColors.lightGrey, width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: leftItems.map((item) => _buildStatusItem(item)).toList(),
            ),
          ),
          Row(
            children: rightItems.map((item) => _buildStatusItem(item)).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusItem(Widget item) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: DefaultTextStyle(
        style: const TextStyle(
          fontSize: 11,
          color: UbuntuColors.textGrey,
          fontFamily: 'Ubuntu',
        ),
        child: item,
      ),
    );
  }
}

/// Ubuntu-style status item
class UbuntuStatusItem extends StatelessWidget {
  final IconData? icon;
  final String? text;
  final Color? color;

  const UbuntuStatusItem({
    Key? key,
    this.icon,
    this.text,
    this.color,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            size: 12,
            color: color ?? UbuntuColors.textGrey,
          ),
          const SizedBox(width: 4),
        ],
        if (text != null)
          Text(
            text!,
            style: TextStyle(
              color: color ?? UbuntuColors.textGrey,
            ),
          ),
      ],
    );
  }
}