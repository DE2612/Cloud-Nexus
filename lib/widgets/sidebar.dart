import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../models/cloud_node.dart';
import '../models/cloud_account.dart';
import '../models/storage_quota.dart';
import '../providers/file_system_provider.dart';
import '../services/hive_storage_service.dart';
import '../services/security_service.dart';
import '../services/notification_service.dart';
import '../themes/ubuntu_theme.dart';
import '../widgets/storage_bar.dart';
import '../utils/svg_icon_cache.dart';

class Sidebar extends StatefulWidget {
  final List<CloudNode> breadcrumbs;
  final List<CloudAccount> accounts;
  final List<CloudNode> virtualDrives;
  final CloudNode? currentFolder;
  final Function(CloudNode) onNavigate;
  final Function(CloudAccount) onAccountSelected;
  final VoidCallback onHomeClicked;
  final VoidCallback? onAddCloudDrive;
  final VoidCallback? onRefresh;
  final VoidCallback? onEncryptionChanged;
  final VoidCallback? onCreateVirtualDrive;
  final Future<void> Function()? onRefreshSearchIndex;
  final Future<void> Function(String accountId)? onRefreshStorageQuota;

  const Sidebar({
    Key? key,
    required this.breadcrumbs,
    required this.accounts,
    required this.virtualDrives,
    this.currentFolder,
    required this.onNavigate,
    required this.onAccountSelected,
    required this.onHomeClicked,
    this.onAddCloudDrive,
    this.onRefresh,
    this.onEncryptionChanged,
    this.onCreateVirtualDrive,
    this.onRefreshSearchIndex,
    this.onRefreshStorageQuota,
  }) : super(key: key);

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar>
    with TickerProviderStateMixin {
  late AnimationController _slideController;
  late AnimationController _fadeController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  late AnimationController _refreshController;
  late Animation<double> _refreshAnimation;
  
  bool _isRefreshing = false;
  bool _initialQuotaFetchDone = false; // Track if initial quota fetch has been done
  Timer? _quotaFetchTimer; // Debounce timer for quota fetches
  Set<String> _pendingQuotaFetches = {}; // Track pending quota fetch account IDs

  @override
  void initState() {
    super.initState();
    
    _slideController = AnimationController(
      duration: UbuntuAnimations.medium,
      vsync: this,
    );
    
    _fadeController = AnimationController(
      duration: UbuntuAnimations.fast,
      vsync: this,
    );

    _refreshController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(-0.1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: UbuntuAnimations.easeOut,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: UbuntuAnimations.smooth,
    ));

    _refreshAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _refreshController,
      curve: Curves.linear,
    ));

    // Start animations
    _slideController.forward();
    _fadeController.forward();
    
    // Schedule initial quota fetch once after widget is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final fs = context.read<FileSystemProvider>();
        _fetchStorageQuotasAtStartup(fs);
      }
    });
  }

  @override
  void dispose() {
    _quotaFetchTimer?.cancel();
    _slideController.dispose();
    _fadeController.dispose();
    _refreshController.dispose();
    super.dispose();
  }

  Future<void> _handleRefresh(FileSystemProvider fs) async {
    if (_isRefreshing) return;
    
    setState(() {
      _isRefreshing = true;
    });
    
    // Start rotation animation
    _refreshController.repeat();
    
    try {
      // Refresh search index if provided
      if (widget.onRefreshSearchIndex != null) {
        await widget.onRefreshSearchIndex!();
      }
      
      // Refresh storage quotas for all cloud accounts with rate limiting
      for (final account in widget.accounts) {
        if (account.provider != 'virtual' && !_pendingQuotaFetches.contains(account.id)) {
          try {
            _pendingQuotaFetches.add(account.id);
            final quota = await fs.refreshStorageQuota(account.id); // Force refresh
            if (quota != null) {
            }
          } catch (e) {
          } finally {
            _pendingQuotaFetches.remove(account.id);
          }
          // Add delay between requests to avoid rate limiting
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    } finally {
      // Stop animation and reset state
      _refreshController.stop();
      _refreshController.reset();
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  /// Debounced storage quota fetch - only fetches after a delay and only once
  void _scheduleQuotaFetchDebounced(FileSystemProvider fs) {
    _quotaFetchTimer?.cancel();
    _quotaFetchTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        _fetchStorageQuotasAtStartup(fs);
      }
    });
  }

  Future<void> _fetchStorageQuotasAtStartup(FileSystemProvider fs) async {
    // Only trigger initial fetch once per widget lifecycle
    if (_initialQuotaFetchDone) return;
    
    _initialQuotaFetchDone = true;
    
    // Check cache first - only fetch if needed
    for (final account in widget.accounts) {
      if (account.provider != 'virtual') {
        // Check if we already have cached data
        final cachedQuota = fs.getStorageQuotaForAccountSync(account.id);
        if (cachedQuota != null && !cachedQuota.isStale(30)) {
          // Use cached data, no need to fetch
          continue;
        }
        
        // Only fetch if not already pending
        if (!_pendingQuotaFetches.contains(account.id)) {
          try {
            _pendingQuotaFetches.add(account.id);
            final quota = await fs.getStorageQuotaForAccount(account.id);
            if (quota != null) {
            }
          } catch (e) {
          } finally {
            _pendingQuotaFetches.remove(account.id);
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<FileSystemProvider>(
      builder: (context, fs, child) {
        // Build storage quotas map for cloud accounts (uses cached data)
        final storageQuotas = <String, StorageQuota>{};
        for (final account in widget.accounts) {
          if (account.provider != 'virtual') {
            final quota = fs.getStorageQuotaForAccountSync(account.id);
            if (quota != null) {
              storageQuotas[account.id] = quota;
            }
          }
        }
        
        return _SidebarContent(
          storageQuotas: storageQuotas,
          widget: widget,
          slideAnimation: _slideAnimation,
          fadeAnimation: _fadeAnimation,
          refreshController: _refreshController,
          refreshAnimation: _refreshAnimation,
          isRefreshing: _isRefreshing,
          onRefresh: _isRefreshing ? null : () => _handleRefresh(fs),
          context: context,
        );
      },
    );
  }
}

class _SidebarContent extends StatelessWidget {
  final Map<String, StorageQuota> storageQuotas;
  final Sidebar widget;
  final Animation<Offset> slideAnimation;
  final Animation<double> fadeAnimation;
  final AnimationController refreshController;
  final Animation<double> refreshAnimation;
  final bool isRefreshing;
  final VoidCallback? onRefresh;
  final BuildContext context;

  const _SidebarContent({
    Key? key,
    required this.storageQuotas,
    required this.widget,
    required this.slideAnimation,
    required this.fadeAnimation,
    required this.refreshController,
    required this.refreshAnimation,
    required this.isRefreshing,
    required this.onRefresh,
    required this.context,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: UbuntuColors.veryLightGrey,
        border: const Border(
          right: BorderSide(color: UbuntuColors.lightGrey, width: 1),
        ),
      ),
      child: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildContent()),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: UbuntuColors.lightGrey, width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_open,
            color: UbuntuColors.orange,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Cloud Nexus',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: UbuntuColors.darkGrey,
                fontFamily: 'Ubuntu',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('Places'),
          _buildPlacesSection(),
          const SizedBox(height: 16),
          _buildSectionTitleWithRefresh('Cloud Accounts'),
          _buildAccountsSection(),
          if (widget.virtualDrives.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildSectionTitle('Virtual Drives'),
            _buildVirtualDrivesSection(),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: UbuntuColors.textGrey,
          fontFamily: 'Ubuntu',
        ),
      ),
    );
  }

  Widget _buildSectionTitleWithRefresh(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: UbuntuColors.textGrey,
                fontFamily: 'Ubuntu',
              ),
            ),
          ),
          if (widget.onRefreshSearchIndex != null)
            _buildRefreshButton(),
        ],
      ),
    );
  }

  Widget _buildRefreshButton() {
    return AnimatedBuilder(
      animation: refreshController,
      builder: (context, child) {
        return MouseRegion(
          cursor: onRefresh == null ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onRefresh,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isRefreshing ? UbuntuColors.orange.withOpacity(0.1) : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.rotate(
                    angle: refreshAnimation.value * 6.28, // Full rotation (2π)
                    child: Icon(
                      Icons.refresh,
                      size: 14,
                      color: isRefreshing ? UbuntuColors.orange : UbuntuColors.textGrey,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Refresh Search Index',
                    style: TextStyle(
                      fontSize: 11,
                      color: isRefreshing ? UbuntuColors.orange : UbuntuColors.textGrey,
                      fontFamily: 'Ubuntu',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlacesSection() {
    return _buildSidebarItem(
      id: 'home',
      icon: Icons.home,
      title: 'Home',
      isSelected: widget.currentFolder == null,
      onTap: widget.onHomeClicked,
    );
  }

  Widget _buildAccountsSection() {
    return Column(
      children: widget.accounts.asMap().entries.map((entry) {
        final index = entry.key;
        final account = entry.value;
        final quota = storageQuotas[account.id];
        // Don't show loading state - just show the bar with no data until manual refresh
        final hasData = quota != null && quota.totalBytes > 0;
        
        return _DraggableAccountItem(
          account: account,
          quota: quota,
          hasData: hasData,
          isSelected: widget.currentFolder?.accountId == account.id,
          currentFolder: widget.currentFolder,
          onAccountSelected: widget.onAccountSelected,
          onEncryptionChanged: widget.onEncryptionChanged,
          onRefreshStorageQuota: widget.onRefreshStorageQuota,
          context: context,
        );
      }).toList(),
    );
  }

  Widget _buildVirtualDrivesSection() {
    return Column(
      children: widget.virtualDrives.map((drive) {
        return _buildSidebarItem(
          id: drive.id,
          icon: Icons.storage,
          title: drive.name,
          isSelected: widget.currentFolder?.id == drive.id,
          onTap: () => widget.onNavigate(drive),
        );
      }).toList(),
    );
  }

  Widget _buildSidebarItem({
    required String id,
    required IconData icon,
    required String title,
    String? subtitle,
    required bool isSelected,
    required VoidCallback onTap,
    bool showLockIcon = false,
    bool isEncrypted = false,
    Function(bool)? onEncryptionToggle,
  }) {
    return _SidebarItem(
      id: id,
      icon: icon,
      title: title,
      subtitle: subtitle,
      isSelected: isSelected,
      onTap: onTap,
      showLockIcon: showLockIcon,
      isEncrypted: isEncrypted,
      onEncryptionToggle: onEncryptionToggle,
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: UbuntuColors.lightGrey, width: 1),
        ),
      ),
      child: _buildActionButtons(),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            icon: Icons.add,
            label: 'New',
            onTap: () {
              HapticFeedback.lightImpact();
              if (widget.onAddCloudDrive != null) {
                widget.onAddCloudDrive!();
              }
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildActionButton(
            icon: Icons.refresh,
            label: 'Refresh',
            onTap: () {
              HapticFeedback.lightImpact();
              if (widget.onRefresh != null) {
                widget.onRefresh!();
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: UbuntuColors.white,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        splashColor: UbuntuColors.orange.withOpacity(0.1),
        hoverColor: UbuntuColors.lightGrey,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: UbuntuColors.lightGrey),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 16,
                color: UbuntuColors.mediumGrey,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10,
                  color: UbuntuColors.textGrey,
                  fontFamily: 'Ubuntu',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getAccountIconPath(String provider) {
    switch (provider) {
      case 'gdrive':
        return 'assets/icons/gdrive.svg';
      case 'onedrive':
        return 'assets/icons/onedrive.svg';
      case 'dropbox':
        return 'assets/icons/gdrive.svg'; // Fallback to gdrive for now
      default:
        return 'assets/icons/gdrive.svg';
    }
  }
}

/// Combined account item with storage bar that shares hover state
class _AccountItemWithStorageBar extends StatefulWidget {
  final CloudAccount account;
  final StorageQuota? quota;
  final bool hasData;
  final bool isSelected;
  final CloudNode? currentFolder;
  final Function(CloudAccount) onAccountSelected;
  final VoidCallback? onEncryptionChanged;
  final Future<void> Function(String accountId)? onRefreshStorageQuota;
  final BuildContext context;

  const _AccountItemWithStorageBar({
    Key? key,
    required this.account,
    required this.quota,
    required this.hasData,
    required this.isSelected,
    required this.currentFolder,
    required this.onAccountSelected,
    required this.onEncryptionChanged,
    required this.onRefreshStorageQuota,
    required this.context,
  }) : super(key: key);

  @override
  State<_AccountItemWithStorageBar> createState() => _AccountItemWithStorageBarState();
}

class _AccountItemWithStorageBarState extends State<_AccountItemWithStorageBar> {
  bool _isHovered = false;

  void _handleHoverChange(bool isHovered) {
    setState(() {
      _isHovered = isHovered;
    });
  }

  String _getAccountIconPath(String provider) {
    switch (provider) {
      case 'gdrive':
        return 'assets/icons/gdrive.svg';
      case 'onedrive':
        return 'assets/icons/onedrive.svg';
      case 'dropbox':
        return 'assets/icons/gdrive.svg'; // Fallback to gdrive for now
      default:
        return 'assets/icons/gdrive.svg';
    }
  }

  Future<void> _handleEncryptionToggle(bool currentValue) async {
    HapticFeedback.lightImpact();
    
    // Toggle encryption for this account
    final fs = context.read<FileSystemProvider>();
    
    try {
      await fs.setAccountEncryption(widget.account.id, !currentValue);
      
      // Show notification
      if (mounted) {
        if (!currentValue) {
          NotificationService().success(
            'Encryption enabled for ${widget.account.name}',
            title: 'Encryption',
          );
        } else {
          NotificationService().warning(
            'Encryption disabled for ${widget.account.name}',
            title: 'Encryption',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        NotificationService().error(
          'Failed to update encryption: $e',
          title: 'Encryption Error',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Use Selector to only rebuild when THIS account's encryption state changes
    return Selector<FileSystemProvider, bool>(
      selector: (context, fs) {
        // Use the encryption value from the widget's account
        // This ensures we only rebuild when THIS account's encryption changes
        return widget.account.encryptUploads ?? false;
      },
      builder: (context, encryptUploads, child) {
        return _AccountItemContent(
          account: widget.account,
          quota: widget.quota,
          hasData: widget.hasData,
          isSelected: widget.isSelected,
          currentFolder: widget.currentFolder,
          onAccountSelected: widget.onAccountSelected,
          onEncryptionChanged: widget.onEncryptionChanged,
          onRefreshStorageQuota: widget.onRefreshStorageQuota,
          isHovered: _isHovered,
          onHoverChange: _handleHoverChange,
          encryptUploads: encryptUploads,
          onEncryptionToggle: _handleEncryptionToggle,
        );
      },
    );
  }
}

/// Content widget that rebuilds when encryption state changes
class _AccountItemContent extends StatelessWidget {
  final CloudAccount account;
  final StorageQuota? quota;
  final bool hasData;
  final bool isSelected;
  final CloudNode? currentFolder;
  final Function(CloudAccount) onAccountSelected;
  final VoidCallback? onEncryptionChanged;
  final Future<void> Function(String accountId)? onRefreshStorageQuota;
  final bool isHovered;
  final Function(bool) onHoverChange;
  final bool encryptUploads;
  final Future<void> Function(bool currentValue) onEncryptionToggle;

  const _AccountItemContent({
    Key? key,
    required this.account,
    required this.quota,
    required this.hasData,
    required this.isSelected,
    required this.currentFolder,
    required this.onAccountSelected,
    required this.onEncryptionChanged,
    required this.onRefreshStorageQuota,
    required this.isHovered,
    required this.onHoverChange,
    required this.encryptUploads,
    required this.onEncryptionToggle,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // No Consumer or FutureBuilder - just render the passed data
    return _buildAccountItem(context, encryptUploads);
  }

  String _getAccountIconPath(String provider) {
    switch (provider) {
      case 'gdrive':
        return 'assets/icons/gdrive.svg';
      case 'onedrive':
        return 'assets/icons/onedrive.svg';
      case 'dropbox':
        return 'assets/icons/gdrive.svg'; // Fallback to gdrive for now
      default:
        return 'assets/icons/gdrive.svg';
    }
  }

  Widget _buildAccountItem(BuildContext context, bool encryptUploads) {
    return RepaintBoundary(
      child: MouseRegion(
        onEnter: (_) => onHoverChange(true),
        onExit: (_) => onHoverChange(false),
        child: GestureDetector(
          onTap: () => onAccountSelected(account),
          behavior: HitTestBehavior.translucent,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? UbuntuColors.orange.withOpacity(0.1)
                  : isHovered
                      ? UbuntuColors.orange.withOpacity(0.1)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected
                    ? UbuntuColors.orange
                    : isHovered
                        ? UbuntuColors.orange.withOpacity(0.3)
                        : Colors.transparent,
                width: isSelected ? 2 : isHovered ? 1 : 0,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Account name row
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // SVG icon - fixed width
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: SvgIconCache.get(
                        path: _getAccountIconPath(account.provider),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Account name and email
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            account.name ?? 'Unknown Account',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: isSelected
                                  ? UbuntuColors.orange
                                  : UbuntuColors.darkGrey,
                              fontFamily: 'Ubuntu',
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (account.email != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              account.email!,
                              style: const TextStyle(
                                fontSize: 11,
                                color: UbuntuColors.textGrey,
                                fontFamily: 'Ubuntu',
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Encryption toggle (always visible, shows lock when enabled)
                    GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: (onEncryptionChanged != null)
                          ? () => onEncryptionToggle(encryptUploads)
                          : null,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: encryptUploads
                              ? UbuntuColors.orange.withOpacity(0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 36,
                              height: 20,
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  color: encryptUploads
                                      ? UbuntuColors.orange
                                      : UbuntuColors.lightGrey,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Align(
                                    alignment: encryptUploads
                                        ? Alignment.centerRight
                                        : Alignment.centerLeft,
                                    child: Container(
                                      width: 16,
                                      height: 16,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.1),
                                            blurRadius: 2,
                                            offset: const Offset(0, 1),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              encryptUploads
                                  ? Icons.lock
                                  : Icons.lock_open,
                              size: 14,
                              color: encryptUploads
                                  ? UbuntuColors.orange
                                  : UbuntuColors.mediumGrey,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                // Drag handle and storage bar row
                if (account.provider == 'gdrive' || account.provider == 'onedrive') ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // Drag handle - positioned to the left of storage bar
                      SizedBox(
                        width: 20,
                        child: Align(
                          alignment: Alignment.center,
                          child: Transform.translate(
                            offset: const Offset(0, -9),
                            child: SizedBox(
                              height: 24,
                              child: LongPressDraggable<CloudAccount>(
                                data: account,
                                delay: const Duration(milliseconds: 100),
                                hapticFeedbackOnStart: true,
                                feedback: _DragFeedback(account: account),
                                child: Opacity(
                                  opacity: isHovered ? 1.0 : 0.0,
                                  child: const Icon(
                                    Icons.drag_indicator,
                                    color: UbuntuColors.mediumGrey,
                                    size: 22,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Storage bar - takes remaining space
                      Expanded(
                        child: StorageBar(
                          quota: quota,
                          isLoading: false,
                          onRefresh: onRefreshStorageQuota != null
                              ? () => onRefreshStorageQuota!(account.id)
                              : null,
                          showRefresh: true,
                          height: 6,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Individual sidebar item with hover scale animation
class _SidebarItem extends StatefulWidget {
  final String id;
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool isSelected;
  final VoidCallback onTap;
  final bool showLockIcon;
  final bool isEncrypted;
  final Function(bool)? onEncryptionToggle;

  const _SidebarItem({
    Key? key,
    required this.id,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.isSelected,
    required this.onTap,
    this.showLockIcon = false,
    this.isEncrypted = false,
    this.onEncryptionToggle,
  }) : super(key: key);

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _isHovered = false;

  void _handleHoverChange(bool isHovered) {
    if (_isHovered != isHovered) {
      setState(() {
        _isHovered = isHovered;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _handleHoverChange(true),
      onExit: (_) => _handleHoverChange(false),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onTap();
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? UbuntuColors.orange.withOpacity(0.1)
                : _isHovered
                    ? UbuntuColors.orange.withOpacity(0.1)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.isSelected
                  ? UbuntuColors.orange
                  : Colors.transparent,
              width: widget.isSelected ? 2 : 0,
            ),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 20,
                color: widget.isSelected
                    ? UbuntuColors.orange
                    : UbuntuColors.mediumGrey,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: widget.isSelected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: widget.isSelected
                            ? UbuntuColors.orange
                            : UbuntuColors.darkGrey,
                        fontFamily: 'Ubuntu',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: UbuntuColors.textGrey,
                          fontFamily: 'Ubuntu',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.onEncryptionToggle != null) ...[
                const SizedBox(width: 8),
                _EncryptionToggle(
                  value: widget.isEncrypted,
                  onChanged: widget.onEncryptionToggle!,
                ),
              ] else if (widget.showLockIcon) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.lock,
                  size: 14,
                  color: widget.isSelected
                      ? UbuntuColors.orange
                      : UbuntuColors.mediumGrey,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact toggle switch for encryption
class _EncryptionToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _EncryptionToggle({
    Key? key,
    required this.value,
    required this.onChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 20,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onChanged(!value);
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: value ? UbuntuColors.orange : UbuntuColors.lightGrey,
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Align(
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ubuntu-style breadcrumb navigation
class UbuntuBreadcrumb extends StatelessWidget {
  final List<CloudNode> breadcrumbs;
  final CloudNode? currentFolder;
  final Function(CloudNode) onNavigate;
  final Function(CloudNode)? onNavigateToFolder;
  final VoidCallback? onHomeClicked;

  const UbuntuBreadcrumb({
    Key? key,
    required this.breadcrumbs,
    this.currentFolder,
    required this.onNavigate,
    this.onNavigateToFolder,
    this.onHomeClicked,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: UbuntuColors.lightGrey, width: 1),
        ),
      ),
      child: Row(
        children: [
          _buildBreadcrumbItem(
            title: 'Home',
            icon: Icons.home,
            isLast: breadcrumbs.isEmpty,
            onTap: onHomeClicked ?? () {},
          ),
          ...breadcrumbs.asMap().entries.map((entry) {
            final index = entry.key;
            final breadcrumb = entry.value;
            final isLast = index == breadcrumbs.length - 1;
            
            return [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: UbuntuColors.mediumGrey,
                ),
              ),
              _buildBreadcrumbItem(
                title: breadcrumb.name,
                icon: breadcrumb.isFolder ? Icons.folder : Icons.insert_drive_file,
                isLast: isLast,
                onTap: () {
                  // Use proper navigation method for breadcrumb clicks
                  if (onNavigateToFolder != null) {
                    onNavigateToFolder!(breadcrumb);
                  } else {
                    // Fallback to old behavior
                    if (!isLast) {
                      onNavigate(breadcrumb);
                    }
                  }
                },
              ),
            ];
          }).expand((element) => element),
        ],
      ),
    );
  }

  Widget _buildBreadcrumbItem({
    required String title,
    required IconData icon,
    bool isLast = false,
    required VoidCallback onTap,
  }) {
    return MouseRegion(
      child: GestureDetector(
        onTap: isLast ? null : onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isLast 
                  ? UbuntuColors.darkGrey 
                  : UbuntuColors.orange,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isLast ? FontWeight.w600 : FontWeight.w500,
                color: isLast 
                    ? UbuntuColors.darkGrey 
                    : UbuntuColors.orange,
                fontFamily: 'Ubuntu',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vault create dialog for first-time setup
class _VaultCreateDialog extends StatefulWidget {
  const _VaultCreateDialog();

  @override
  State<_VaultCreateDialog> createState() => _VaultCreateDialogState();
}

class _VaultCreateDialogState extends State<_VaultCreateDialog> {
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (_passwordController.text.length < 8) {
        setState(() {
          _errorMessage = 'Password must be at least 8 characters';
          _isLoading = false;
        });
        return;
      }
      if (_passwordController.text != _confirmPasswordController.text) {
        setState(() {
          _errorMessage = 'Passwords do not match';
          _isLoading = false;
        });
        return;
      }
      
      await SecurityService.instance.createVault(_passwordController.text);
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock, color: UbuntuColors.orange),
          SizedBox(width: 12),
          Text('Create Vault'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Create a vault password to enable encryption for your uploads.',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              enabled: !_isLoading,
              decoration: InputDecoration(
                labelText: 'New Password',
                border: const OutlineInputBorder(),
                errorText: _errorMessage,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmPasswordController,
              obscureText: true,
              enabled: !_isLoading,
              decoration: const InputDecoration(
                labelText: 'Confirm Password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}

/// Change password dialog
class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Verify current password
      final isCorrect = await SecurityService.instance.unlockVault(_currentPasswordController.text);
      if (!isCorrect) {
        setState(() {
          _errorMessage = 'Current password is incorrect';
          _isLoading = false;
        });
        return;
      }

      // Validate new password
      if (_newPasswordController.text.length < 8) {
        setState(() {
          _errorMessage = 'New password must be at least 8 characters';
          _isLoading = false;
        });
        return;
      }

      if (_newPasswordController.text != _confirmPasswordController.text) {
        setState(() {
          _errorMessage = 'New passwords do not match';
          _isLoading = false;
        });
        return;
      }

      // Change password
      await SecurityService.instance.changePassword(_newPasswordController.text);
      
      if (mounted) {
        Navigator.pop(context);
        NotificationService().success(
          'Your vault password has been changed successfully',
          title: 'Password Changed',
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.vpn_key, color: UbuntuColors.orange),
          SizedBox(width: 12),
          Text('Change Vault Password'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your current password and a new password.',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _currentPasswordController,
              obscureText: true,
              enabled: !_isLoading,
              decoration: InputDecoration(
                labelText: 'Current Password',
                border: const OutlineInputBorder(),
                errorText: _errorMessage,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _newPasswordController,
              obscureText: true,
              enabled: !_isLoading,
              decoration: const InputDecoration(
                labelText: 'New Password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmPasswordController,
              obscureText: true,
              enabled: !_isLoading,
              decoration: const InputDecoration(
                labelText: 'Confirm New Password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Change Password'),
        ),
      ],
    );
  }
}

/// Vault unlock dialog for existing vaults
class _VaultUnlockDialog extends StatefulWidget {
  const _VaultUnlockDialog();

  @override
  State<_VaultUnlockDialog> createState() => _VaultUnlockDialogState();
}

class _VaultUnlockDialogState extends State<_VaultUnlockDialog> {
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final success = await SecurityService.instance.unlockVault(_passwordController.text);
      if (success) {
        if (mounted) {
          Navigator.pop(context, true);
        }
      } else {
        setState(() {
          _errorMessage = 'Incorrect password';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock_open, color: UbuntuColors.orange),
          SizedBox(width: 12),
          Text('Unlock Vault'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your vault password to enable encryption.',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              enabled: !_isLoading,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                errorText: _errorMessage,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Unlock'),
        ),
      ],
    );
  }
}

/// Reset vault confirmation dialog
class _ResetVaultDialog extends StatefulWidget {
  const _ResetVaultDialog();

  @override
  State<_ResetVaultDialog> createState() => _ResetVaultDialogState();
}

class _ResetVaultDialogState extends State<_ResetVaultDialog> {
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _resetVault() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Clear all vault data
      await SecurityService.instance.clearVault();
      
      if (mounted) {
        Navigator.pop(context);
        NotificationService().info(
          'Vault has been reset. You can create a new vault by enabling encryption on an account.',
          title: 'Vault Reset',
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning, color: Colors.red),
          SizedBox(width: 12),
          Text('Reset Vault'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '⚠️ WARNING: This will permanently delete your vault and all encrypted data.',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.red),
            ),
            const SizedBox(height: 16),
            const Text(
              'This action cannot be undone. All encrypted files will become inaccessible.',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            const Text(
              'Are you sure you want to reset the vault?',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                style: const TextStyle(fontSize: 12, color: Colors.red),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _resetVault,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Reset Vault'),
        ),
      ],
    );
  }
}

/// Draggable account item with drag handle for reordering
class _DraggableAccountItem extends StatefulWidget {
  final CloudAccount account;
  final StorageQuota? quota;
  final bool hasData;
  final bool isSelected;
  final CloudNode? currentFolder;
  final Function(CloudAccount) onAccountSelected;
  final VoidCallback? onEncryptionChanged;
  final Future<void> Function(String accountId)? onRefreshStorageQuota;
  final BuildContext context;

  const _DraggableAccountItem({
    Key? key,
    required this.account,
    required this.quota,
    required this.hasData,
    required this.isSelected,
    required this.currentFolder,
    required this.onAccountSelected,
    required this.onEncryptionChanged,
    required this.onRefreshStorageQuota,
    required this.context,
  }) : super(key: key);

  @override
  State<_DraggableAccountItem> createState() => _DraggableAccountItemState();
}

class _DraggableAccountItemState extends State<_DraggableAccountItem> {
  bool _isDragging = false;
  bool _isHoveringForDrop = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<CloudAccount>(
      onWillAccept: (data) => data != null && data.id != widget.account.id,
      onAccept: (data) async {
        final fs = widget.context.read<FileSystemProvider>();
        final accounts = await fs.getAccountsInOrder();
        final accountIds = accounts.map((a) => a.id).toList();
        
        final oldIndex = accountIds.indexOf(data.id);
        final newIndex = accountIds.indexOf(widget.account.id);
        
        if (oldIndex != -1 && newIndex != -1 && oldIndex != newIndex) {
          accountIds.removeAt(oldIndex);
          accountIds.insert(newIndex, data.id);
          await fs.reorderAccounts(accountIds);
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        _isHoveringForDrop = isHovering;
        
        return Container(
          decoration: BoxDecoration(
            border: isHovering
                ? Border.all(color: UbuntuColors.orange, width: 2)
                : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: _AccountItemWithStorageBar(
            account: widget.account,
            quota: widget.quota,
            hasData: widget.hasData,
            isSelected: widget.isSelected,
            currentFolder: widget.currentFolder,
            onAccountSelected: widget.onAccountSelected,
            onEncryptionChanged: widget.onEncryptionChanged,
            onRefreshStorageQuota: widget.onRefreshStorageQuota,
            context: widget.context,
          ),
        );
      },
    );
  }
}

/// Optimized drag feedback widget - lightweight and constant where possible
class _DragFeedback extends StatelessWidget {
  final CloudAccount account;
  
  const _DragFeedback({Key? key, required this.account}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        color: Colors.transparent,
        child: Container(
          width: 280,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: UbuntuColors.orange.withOpacity(0.2),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: UbuntuColors.orange, width: 2),
          ),
          child: Row(
            children: [
              const Icon(Icons.drag_indicator, color: UbuntuColors.orange, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  account.email ?? account.name ?? 'Unknown Account',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: UbuntuColors.darkGrey,
                    fontFamily: 'Ubuntu',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}