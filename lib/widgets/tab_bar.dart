import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/tab_data.dart';
import '../themes/ubuntu_theme.dart';

/// Browser-style tab bar for CloudNexus file explorer.
/// Ubuntu-styled with hover effects and close buttons.
class TabBar extends StatefulWidget {
  final List<TabData> tabs;
  final int activeTabIndex;
  final Function(int) onTabTap;
  final Function(int) onTabClose;

  const TabBar({
    super.key,
    required this.tabs,
    required this.activeTabIndex,
    required this.onTabTap,
    required this.onTabClose,
  });

  @override
  State<TabBar> createState() => _TabBarState();
}

class _TabBarState extends State<TabBar> {
  final ScrollController _scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: UbuntuColors.white,
        border: Border(
          bottom: BorderSide(color: UbuntuColors.lightGrey.withValues(alpha: 0.5), width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Scrollbar(
              controller: _scrollController,
              thumbVisibility: false,
              child: ListView.builder(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 8, right: 4),
                itemCount: widget.tabs.length,
                itemBuilder: (context, index) {
                  return _buildTab(context, index);
                },
              ),
            ),
          ),
          _buildNewTabButton(context),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildTab(BuildContext context, int index) {
    final tab = widget.tabs[index];
    final isActive = index == widget.activeTabIndex;
    final String title = tab.title;
    final bool isRoot = tab.currentFolder == null && tab.breadcrumbs.isEmpty;
    final bool isSearching = tab.searchQuery.isNotEmpty && tab.isSearchActive;

    IconData icon;
    Color iconColor;

    if (isRoot) {
      icon = Icons.cloud;
      iconColor = UbuntuColors.darkGrey;
    } else if (isSearching) {
      icon = Icons.search;
      iconColor = UbuntuColors.darkGrey;
    } else {
      icon = Icons.folder;
      iconColor = UbuntuColors.orange;
    }

    return _TabWidget(
      isActive: isActive,
      icon: icon,
      iconColor: iconColor,
      title: title,
      onTap: () {
        widget.onTabTap(index);
        HapticFeedback.lightImpact();
      },
      onClose: () {
        widget.onTabClose(index);
        HapticFeedback.lightImpact();
      },
    );
  }

  Widget _buildNewTabButton(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: () {
            widget.onTabTap(-1); // -1 means create new tab
            HapticFeedback.lightImpact();
          },
          borderRadius: BorderRadius.circular(6),
          child: const Icon(
            Icons.add,
            size: 18,
            color: UbuntuColors.darkGrey,
          ),
        ),
      ),
    );
  }
}

/// Individual tab widget with hover support and modern minimal design
class _TabWidget extends StatefulWidget {
  final bool isActive;
  final IconData icon;
  final Color iconColor;
  final String title;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _TabWidget({
    required this.isActive,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<_TabWidget> createState() => _TabWidgetState();
}

class _TabWidgetState extends State<_TabWidget> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: widget.isActive ? UbuntuColors.orange : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          constraints: const BoxConstraints(maxWidth: 200, minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 14, color: widget.iconColor),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: UbuntuColors.darkGrey,
                    fontFamily: 'Ubuntu',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              _buildCloseButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCloseButton() {
    // Show close button on hover or if active
    final shouldShow = _isHovered || widget.isActive;

    return AnimatedOpacity(
      opacity: shouldShow ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 150),
      child: GestureDetector(
        onTap: widget.onClose,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Icon(
            Icons.close,
            size: 12,
            color: UbuntuColors.textGrey,
          ),
        ),
      ),
    );
  }
}