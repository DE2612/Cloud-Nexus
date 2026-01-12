import 'dart:io';
import 'package:cloud_nexus/services/security_service.dart';
import 'package:flutter/material.dart' hide IconThemeData;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart'; // File picker for uploads
import 'package:flutter_dotenv/flutter_dotenv.dart'; // For loading environment variables
import 'utils/svg_icon_cache.dart'; // For pre-caching icons on startup
import 'providers/file_system_provider.dart';
import 'providers/tabs_provider.dart';
import 'providers/selection_provider.dart';
import 'adapters/cloud_adapter.dart';
import 'themes/ubuntu_theme.dart';
import 'widgets/file_explorer.dart';
import 'widgets/scroll_behavior.dart' as scroll_behavior;
import 'widgets/floating_controls.dart';
import 'widgets/context_menu.dart';
import 'widgets/icons/icon_theme_provider.dart';
import 'services/hive_storage_service.dart';
import 'services/notification_service.dart';
import 'models/cloud_account.dart';
import 'widgets/notification_overlay.dart';
// Note: We don't need to import CloudNode here as Provider handles the list


void main() async {
  
  // Set preferred refresh rate for smoother performance
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load environment variables from .env file
  await dotenv.load(fileName: ".env");
  
  // Initialize Hive storage (cross-platform)
  await HiveStorageService.instance.initialize();
  
  // Pre-cache frequently used icons to reduce initial render lag
  SvgIconCache.preloadCommonIcons();
  
  // Configure for ultra-high refresh rate displays (240Hz)
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    // Set system overlay style for Ubuntu light theme
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: UbuntuColors.veryLightGrey,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
    
    // Enable immersive mode for better performance
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    
    // Configure for ultra-high refresh rate displays
    try {
      // Set frame rate to maximum for ultra-smooth animations
      WidgetsBinding.instance.addTimingsCallback((timings) {
        // Monitor frame timing for performance optimization
      });
    } catch (e) {
    }
  }
  
  runApp(const CloudNexusApp());
}

class CloudNexusApp extends StatelessWidget {
  const CloudNexusApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Initialize notification service
    final notificationService = NotificationService();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => FileSystemProvider()..loadNodes()),
        ChangeNotifierProvider(create: (_) => TabsProvider()),
        ChangeNotifierProvider(create: (_) => SelectionProvider()),
      ],
      child: IconThemeProvider(
        data: IconThemeData.defaultLightTheme,
        child: MaterialApp(
          title: 'Cloud Nexus',
          debugShowCheckedModeBanner: false,
          theme: UbuntuTheme.lightTheme,
          darkTheme: UbuntuTheme.lightTheme, // Use light theme 
          themeMode: ThemeMode.light, // Force light theme 
          builder: (context, child) {
            return ScrollConfiguration(
              behavior: const scroll_behavior.ScrollBehavior(),
              child: NotificationOverlay(
                notificationService: notificationService,
                child: child!,
              ),
            );
          },
          home: const UbuntuCloudNexusApp(),
        ),
      ),
    );
  }
}

class UbuntuCloudNexusApp extends StatefulWidget {
  const UbuntuCloudNexusApp({super.key});

  @override
  State<UbuntuCloudNexusApp> createState() => _UbuntuCloudNexusAppState();
}

class _UbuntuCloudNexusAppState extends State<UbuntuCloudNexusApp> {
  @override
  Widget build(BuildContext context) {
    // Use Ubuntu file explorer for authentic Ubuntu desktop experience
    return const FileExplorer();
  }

  void _showNewFolderDialog(BuildContext context, FileSystemProvider fs) {
    // Determine appropriate title based on current provider
    String dialogTitle = "New Folder";
    if (fs.currentFolderNode != null) {
      switch (fs.currentFolderNode!.provider) {
        case 'local':
          dialogTitle = "New Local Folder";
          break;
        case 'gdrive':
          dialogTitle = "New Google Drive Folder";
          break;
        case 'virtual':
          dialogTitle = "New Virtual RAID Folder";
          break;
      }
    }

    showDialog(context: context, builder: (ctx) {
      final controller = TextEditingController();
      return AlertDialog(
        title: Text(dialogTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: "Enter folder name",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel")
          ),
          TextButton(
            onPressed: () async {
              try {
                // Special handling for Virtual RAID - show drive selection dialog
                if (fs.currentFolderNode?.provider == 'virtual') {
                  Navigator.pop(ctx); // Close the name dialog first
                  // Use the helper method to handle Virtual RAID creation safely
                  _handleVirtualRaidFolderCreation(context, fs, controller.text);
                } else {
                  // Normal folder creation for local and cloud drives
                  await fs.createFolder(controller.text);
                  Navigator.pop(ctx);
                  NotificationService().success("Folder '${controller.text}' created successfully");
                }
              } catch (e) {
                Navigator.pop(ctx);
                NotificationService().error("Failed to create folder: $e");
              }
            },
            child: const Text("Create")
          )
        ],
      );
    });
  }

  void _handleUpload(BuildContext context, FileSystemProvider fs) async {
    NotificationService().info("Selecting file...");
    
    try {
      // Special handling for Virtual RAID - show drive selection dialog
      if (fs.currentFolderNode?.provider == 'virtual') {
        // Use the helper method to handle Virtual RAID upload with drive selection
        _handleVirtualRaidFileUpload(context, fs);
      } else {
        // Normal upload for regular cloud drives
        // For regular drives, we'll handle single and multiple files
        await _handleRegularDriveUpload(context, fs);
      }
    } catch (e) {
      NotificationService().error("Upload Error: $e");
    }
  }

  void _handlePaste(BuildContext context, FileSystemProvider fs) async {
    NotificationService().info("Pasting... please wait");
    try {
      await fs.pasteNode();
      if (context.mounted) {
        NotificationService().success("Paste Complete!");
      }
    } catch (e) {
      if (context.mounted) {
        NotificationService().error("Error: $e");
      }
    }
  }

  void _showSettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const AccountSettingsDialog(),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About CloudNexus'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CloudNexus - Secure Multi-Cloud Storage'),
            SizedBox(height: 8),
            Text('Version 1.0.0'),
            SizedBox(height: 8),
            Text('A secure file explorer for multiple cloud drives'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // Helper method to handle regular drive uploads (single or multiple files)
  Future<void> _handleRegularDriveUpload(BuildContext context, FileSystemProvider fs) async {
    try {
      // Let user pick files (multiple selection enabled)
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true, // Enable multiple file selection
      );
      
      if (result == null) {
        NotificationService().info("File selection cancelled");
        return;
      }

      final filePaths = result.files.map((file) => file.path!).toList();
      final fileNames = result.files.map((file) => file.name).toList();
      

      if (filePaths.isEmpty) {
        NotificationService().info("No files selected");
        return;
      }

      if (filePaths.length == 1) {
        // Single file - use existing upload logic
        await fs.uploadFile(filePaths: [filePaths.first], fileNames: [fileNames.first]);
        NotificationService().success("Upload Complete!");
      } else {
        // Multiple files - use the new multiple file upload method
        await fs.uploadMultipleFilesToRegularDrive(filePaths, fileNames);
        NotificationService().success("Uploaded ${fileNames.length} file(s) to ${fs.currentFolderNode?.name ?? 'drive'}");
      }
    } catch (e) {
      NotificationService().error("Upload Error: $e");
    }
  }

  // Helper method to handle Virtual RAID folder creation safely
  void _handleVirtualRaidFolderCreation(BuildContext context, FileSystemProvider fs, String folderName) {
    // Close any open dialogs first
    Navigator.of(context).popUntil((route) => route.isFirst);
    
    // Then show the drive selection dialog
    _showVirtualDriveSelectionDialog(context, fs, folderName);
  }

  // Helper method to handle Virtual RAID file upload with drive selection
  Future<void> _handleVirtualRaidFileUpload(BuildContext context, FileSystemProvider fs) async {
    try {
      
      // First, let user pick files (multiple selection enabled)
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true, // Enable multiple file selection
      );
      
      if (result == null) {
        NotificationService().info("File selection cancelled");
        return;
      }

      final filePaths = result.files.map((file) => file.path!).toList();
      final fileNames = result.files.map((file) => file.name).toList();
      

      // Validate file selection
      if (filePaths.isEmpty) {
        NotificationService().info("No files selected");
        return;
      }

      // Get account details for the current virtual drive
      final accountDetails = await fs.getVirtualDriveAccountDetails();
      
      if (accountDetails.isEmpty) {
        NotificationService().warning("No accounts available in this virtual drive");
        return;
      }

      // Prepare dialog title based on number of files
      final dialogTitle = filePaths.length == 1 
          ? "Upload '${fileNames.first}' to drives"
          : "Upload ${filePaths.length} files to drives";

      // Show drive selection dialog
      final selectedAccountIds = await showDialog<List<String>>(
        context: context,
        barrierDismissible: false,
        builder: (context) => VirtualDriveSelectionDialog(
          accountDetails: accountDetails,
          folderName: fileNames.first, // Use first filename for consistency
          customTitle: dialogTitle,
        ),
      );

      if (selectedAccountIds != null && selectedAccountIds.isNotEmpty) {
        
        // Show progress indicator
        NotificationService().info("Uploading ${filePaths.length} file(s) to ${selectedAccountIds.length} drive(s)...");

        // Handle single file vs multiple files
        Map<String, dynamic> uploadResults;
        if (filePaths.length == 1) {
          // Single file upload (existing logic)
          await fs.uploadFileToVirtualRaidWithSelection(filePaths.first, fileNames.first, selectedAccountIds);
          uploadResults = {
            'successful_uploads': {fileNames.first: selectedAccountIds},
            'total_files': 1,
            'successful_files': 1,
          };
        } else {
          // Multiple file upload (new functionality)
          uploadResults = await fs.uploadMultipleFilesToVirtualRaidWithSelection(filePaths, fileNames, selectedAccountIds);
        }
        
        // Show success results
        if (context.mounted) {
          final successfulFiles = uploadResults['successful_files'] as int;
          final totalFiles = uploadResults['total_files'] as int;
          
          if (successfulFiles == totalFiles) {
            NotificationService().success("All $successfulFiles file(s) uploaded to ${selectedAccountIds.length} drive(s)");
          } else {
            NotificationService().warning("$successfulFiles of $totalFiles file(s) uploaded to ${selectedAccountIds.length} drive(s)");
          }
        }
      } else {
        if (context.mounted) {
          NotificationService().info("File upload cancelled");
        }
      }
    } catch (e, stackTrace) {
      
      if (context.mounted) {
        NotificationService().error("Failed to upload file: $e");
      }
    }
  }

  // Show drive selection dialog for Virtual RAID folder creation
  Future<void> _showVirtualDriveSelectionDialog(BuildContext context, FileSystemProvider fs, String folderName) async {
    try {
      
      // Get account details for the current virtual drive
      final accountDetails = await fs.getVirtualDriveAccountDetails();
      
      if (accountDetails.isEmpty) {
        NotificationService().warning("No accounts available in this virtual drive");
        return;
      }

      // Show selection dialog with error handling
      final selectedAccountIds = await showDialog<List<String>>(
        context: context,
        barrierDismissible: false, // Prevent accidental dismissal
        builder: (BuildContext dialogContext) => VirtualDriveSelectionDialog(
          accountDetails: accountDetails,
          folderName: folderName,
        ),
      );


      if (selectedAccountIds != null && selectedAccountIds.isNotEmpty) {
        
        // Create folders in selected drives
        await fs.createFolderInVirtualRaidWithSelection(folderName, selectedAccountIds);
        
        if (context.mounted) {
          NotificationService().success("Folder '$folderName' created in ${selectedAccountIds.length} drive(s)");
        }
      } else {
        if (context.mounted) {
          NotificationService().info("Folder creation cancelled");
        }
      }
    } catch (e, stackTrace) {
      
      if (context.mounted) {
        NotificationService().error("Failed to show drive selection: $e");
      }
    }
  }
}

/// Dialog for selecting which drives to create a folder in for Virtual RAID
class VirtualDriveSelectionDialog extends StatefulWidget {
  final List<dynamic> accountDetails; // Using dynamic to avoid import issues
  final String folderName;
  final String? customTitle; // Optional custom title for different operations

  const VirtualDriveSelectionDialog({
    Key? key,
    required this.accountDetails,
    required this.folderName,
    this.customTitle,
  }) : super(key: key);

  @override
  State<VirtualDriveSelectionDialog> createState() => _VirtualDriveSelectionDialogState();
}

class _VirtualDriveSelectionDialogState extends State<VirtualDriveSelectionDialog> {
  final Set<String> _selectedAccountIds = {};

  @override
  void initState() {
    super.initState();
    // Pre-select all available accounts by default
    _selectedAccountIds.addAll(
      widget.accountDetails.where((acc) => acc.isAvailable ?? true).map((acc) => acc.accountId)
    );
  }

  @override
  Widget build(BuildContext context) {
    
    final dialogTitle = widget.customTitle ?? "Create '${widget.folderName}' in drives";
    
    return AlertDialog(
      title: Text(dialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Select which drives to create the folder in:",
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          Flexible(
            child: Container(
              width: double.maxFinite,
              constraints: const BoxConstraints(maxHeight: 300),
              child: Scrollbar(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.accountDetails.length,
                  itemBuilder: (context, index) {
                    final accountInfo = widget.accountDetails[index];
                    return _buildAccountTile(accountInfo);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "Selected: ${_selectedAccountIds.length} of ${widget.accountDetails.length} drives",
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
          },
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          onPressed: _selectedAccountIds.isEmpty
              ? null
              : () {
                  Navigator.pop(context, _selectedAccountIds.toList());
                }
          ,
          child: const Text("Create"),
        ),
      ],
    );
  }

  Widget _buildAccountTile(dynamic accountInfo) {
    try {
      
      final isSelected = _selectedAccountIds.contains(accountInfo.accountId);
      final isAvailable = accountInfo.isAvailable ?? true;
      
      return Card(
        elevation: isSelected ? 4 : 1,
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: InkWell(
          onTap: isAvailable
              ? () {
                  setState(() {
                    if (isSelected) {
                      _selectedAccountIds.remove(accountInfo.accountId);
                    } else {
                      _selectedAccountIds.add(accountInfo.accountId);
                    }
                  });
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Selection checkbox
                Checkbox(
                  value: isSelected,
                  onChanged: isAvailable
                      ? (value) {
                          setState(() {
                            if (value == true) {
                              _selectedAccountIds.add(accountInfo.accountId);
                            } else {
                              _selectedAccountIds.remove(accountInfo.accountId);
                            }
                          });
                        }
                      : null,
                ),
                const SizedBox(width: 12),
                 
                // Provider icon
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (accountInfo.providerColor ?? Colors.grey).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    accountInfo.providerIcon ?? Icons.storage,
                    color: accountInfo.providerColor ?? Colors.grey,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                 
                // Account information
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        accountInfo.displayName ?? 'Unknown Account',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        accountInfo.providerDisplayName ?? 'Unknown Provider',
                        style: TextStyle(
                          fontSize: 12,
                          color: accountInfo.providerColor ?? Colors.grey,
                        ),
                      ),
                      if (accountInfo.account?.email != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          accountInfo.account.email,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                 
                // Availability indicator
                if (!isAvailable)
                  const Tooltip(
                    message: "Drive not available",
                    child: Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 20,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    } catch (e, stackTrace) {
      
      // Return a fallback widget if there's an error
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          leading: const Icon(Icons.error, color: Colors.red),
          title: const Text('Error loading account'),
          subtitle: Text('Details: $e'),
        ),
      );
    }
  }
}

/// Account Settings Dialog with encryption toggles
class AccountSettingsDialog extends StatefulWidget {
  const AccountSettingsDialog({super.key});

  @override
  State<AccountSettingsDialog> createState() => _AccountSettingsDialogState();
}

class _AccountSettingsDialogState extends State<AccountSettingsDialog> {
  late Future<List<CloudAccount>> _accountsFuture;

  @override
  void initState() {
    super.initState();
    _accountsFuture = HiveStorageService.instance.getAccounts();
  }

  Future<void> _refreshAccounts() async {
    setState(() {
      _accountsFuture = HiveStorageService.instance.getAccounts();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Account Settings'),
      content: SizedBox(
        width: 500,
        height: 400,
        child: FutureBuilder<List<CloudAccount>>(
          future: _accountsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Error: ${snapshot.error}'));
            }
            final accounts = snapshot.data ?? [];
            if (accounts.isEmpty) {
              return const Center(child: Text('No accounts connected'));
            }
            return ListView.builder(
              itemCount: accounts.length,
              itemBuilder: (context, index) {
                final account = accounts[index];
                return _buildAccountTile(account);
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildAccountTile(CloudAccount account) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _getAccountIcon(account.provider),
                  color: _getProviderColor(account.provider),
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.name ?? 'Unknown Account',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        account.email ?? 'No email',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.lock, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                const Text(
                  'Encrypt uploads',
                  style: TextStyle(fontSize: 12),
                ),
                const Spacer(),
                Switch(
                  value: account.encryptUploads,
                  onChanged: (value) async {
                    await HiveStorageService.instance.updateAccountEncryption(
                      account.id,
                      value,
                    );
                    await _refreshAccounts();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getAccountIcon(String provider) {
    switch (provider) {
      case 'gdrive':
        return Icons.cloud;
      case 'onedrive':
        return Icons.cloud_queue;
      case 'dropbox':
        return Icons.cloud_circle;
      default:
        return Icons.cloud;
    }
  }

  Color _getProviderColor(String provider) {
    switch (provider) {
      case 'gdrive':
        return Colors.green;
      case 'onedrive':
        return Colors.blue;
      case 'dropbox':
        return Colors.blue.shade800;
      default:
        return Colors.grey;
    }
  }
}