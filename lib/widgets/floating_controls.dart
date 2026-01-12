import 'package:flutter/material.dart';
import '../providers/file_system_provider.dart';

class FloatingControls extends StatelessWidget {
  final FileSystemProvider fs;
  final VoidCallback onNewFolder;
  final VoidCallback onUpload;
  final VoidCallback onPaste;

  const FloatingControls({
    super.key,
    required this.fs,
    required this.onNewFolder,
    required this.onUpload,
    required this.onPaste,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Paste button (only show if there's something in clipboard)
        if (fs.clipboardNode != null) ...[
          FloatingActionButton.small(
            heroTag: 'paste',
            backgroundColor: Colors.orange,
            onPressed: onPaste,
            child: const Icon(Icons.paste),
          ),
          const SizedBox(height: 8),
        ],
        
        // Upload button (only show in cloud drives)
        if (fs.currentFolderNode?.provider == 'gdrive' || 
            fs.currentFolderNode?.provider == 'onedrive' || 
            fs.currentFolderNode?.provider == 'virtual') ...[
          FloatingActionButton.small(
            heroTag: 'upload',
            backgroundColor: Colors.green,
            onPressed: onUpload,
            child: const Icon(Icons.upload),
          ),
          const SizedBox(height: 8),
        ],
        
        // New folder button
        FloatingActionButton(
          heroTag: 'newFolder',
          backgroundColor: Colors.blue,
          onPressed: onNewFolder,
          child: const Icon(Icons.create_new_folder),
        ),
      ],
    );
  }
}

class ExpandableFab extends StatefulWidget {
  final List<Widget> children;
  final IconData initialIcon;
  final IconData expandedIcon;

  const ExpandableFab({
    super.key,
    required this.children,
    this.initialIcon = Icons.add,
    this.expandedIcon = Icons.close,
  });

  @override
  State<ExpandableFab> createState() => _ExpandableFabState();
}

class _ExpandableFabState extends State<ExpandableFab>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _expandAnimation;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _expandAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.fastOutSlowIn,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        alignment: Alignment.bottomRight,
        clipBehavior: Clip.none,
        children: [
          _buildTapToCloseFab(),
          ..._buildExpandingActionButtons(),
          _buildTapToOpenFab(),
        ],
      ),
    );
  }

  Widget _buildTapToCloseFab() {
    return SizedBox(
      width: 56.0,
      height: 56.0,
      child: Center(
        child: Material(
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          elevation: 4.0,
          child: InkWell(
            onTap: _toggleExpanded,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Icon(
                widget.expandedIcon,
                color: Theme.of(context).primaryColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildExpandingActionButtons() {
    final children = <Widget>[];
    final count = widget.children.length;
    
    for (int i = 0; i < count; i++) {
      children.add(
        _ExpandingActionButton(
          directionInDegrees: 90,
          maxDistance: 70.0 + (i * 60.0),
          progress: _expandAnimation,
          child: widget.children[i],
        ),
      );
    }
    
    return children;
  }

  Widget _buildTapToOpenFab() {
    return IgnorePointer(
      ignoring: _isExpanded,
      child: AnimatedContainer(
        transformAlignment: Alignment.center,
        transform: Matrix4.diagonal3Values(
          _isExpanded ? 0.7 : 1.0,
          _isExpanded ? 0.7 : 1.0,
          1.0,
        ),
        duration: const Duration(milliseconds: 250),
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
        child: AnimatedOpacity(
          opacity: _isExpanded ? 0.0 : 1.0,
          curve: const Interval(0.25, 1.0, curve: Curves.easeInOut),
          duration: const Duration(milliseconds: 250),
          child: FloatingActionButton(
            onPressed: _toggleExpanded,
            child: Icon(widget.initialIcon),
          ),
        ),
      ),
    );
  }
}

class _ExpandingActionButton extends StatelessWidget {
  final double directionInDegrees;
  final double maxDistance;
  final Animation<double> progress;
  final Widget child;

  const _ExpandingActionButton({
    required this.directionInDegrees,
    required this.maxDistance,
    required this.progress,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, child) {
        final offset = Offset.fromDirection(
          directionInDegrees * (3.14159 / 180.0),
          progress.value * maxDistance,
        );
        return Positioned(
          right: 4.0 + offset.dx,
          bottom: 4.0 + offset.dy,
          child: Transform.rotate(
            angle: (1.0 - progress.value) * 3.14159 / 2,
            child: child,
          ),
        );
      },
      child: FadeTransition(
        opacity: progress,
        child: child,
      ),
    );
  }
}

class QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;
  final String tooltip;

  const QuickActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: (color ?? Theme.of(context).colorScheme.primary).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: (color ?? Theme.of(context).colorScheme.primary).withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: color ?? Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: color ?? Theme.of(context).colorScheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}