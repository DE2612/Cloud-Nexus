import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../models/cloud_account.dart';
import '../themes/ubuntu_theme.dart';

/// Dialog for creating a new virtual drive by combining multiple cloud accounts
class VirtualDriveCreationDialog extends StatefulWidget {
  final List<CloudAccount> availableAccounts;
  final Function(String name, List<String> selectedAccountIds) onCreate;

  const VirtualDriveCreationDialog({
    Key? key,
    required this.availableAccounts,
    required this.onCreate,
  }) : super(key: key);

  @override
  State<VirtualDriveCreationDialog> createState() => _VirtualDriveCreationDialogState();
}

class _VirtualDriveCreationDialogState extends State<VirtualDriveCreationDialog> {
  final _nameController = TextEditingController();
  final Set<String> _selectedAccountIds = {};
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // Pre-select all available accounts by default
    _selectedAccountIds.addAll(widget.availableAccounts.map((acc) => acc.id));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    setState(() {
      _errorMessage = null;
    });

    // Validate name
    if (_nameController.text.trim().isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a name for the virtual drive';
      });
      return;
    }

    // Validate at least one account is selected
    if (_selectedAccountIds.isEmpty) {
      setState(() {
        _errorMessage = 'Please select at least one cloud account';
      });
      return;
    }

    // Create the virtual drive
    widget.onCreate(_nameController.text.trim(), _selectedAccountIds.toList());
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.merge_type, color: UbuntuColors.orange),
          const SizedBox(width: 12),
          const Text('Create Virtual Drive'),
        ],
      ),
      content: SizedBox(
        width: 500,
        height: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Combine multiple cloud drives into a single virtual drive. Files and folders will be stored across all selected drives.',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 24),
            
            // Virtual drive name input
            TextField(
              controller: _nameController,
              enabled: !_isLoading,
              decoration: InputDecoration(
                labelText: 'Virtual Drive Name',
                hintText: 'e.g., My Combined Drive',
                border: const OutlineInputBorder(),
                errorText: _errorMessage,
                prefixIcon: const Icon(Icons.storage),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 24),
            
            // Account selection
            const Text(
              'Select Cloud Accounts to Combine:',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: UbuntuColors.darkGrey,
              ),
            ),
            const SizedBox(height: 12),
            
            // Select All / Deselect All buttons
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    setState(() {
                      _selectedAccountIds.addAll(
                        widget.availableAccounts.map((acc) => acc.id)
                      );
                    });
                  },
                  icon: const Icon(Icons.select_all, size: 16),
                  label: const Text('Select All'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    setState(() {
                      _selectedAccountIds.clear();
                    });
                  },
                  icon: const Icon(Icons.deselect, size: 16),
                  label: const Text('Deselect All'),
                ),
                const Spacer(),
                Text(
                  '${_selectedAccountIds.length} of ${widget.availableAccounts.length} selected',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            
            // Account list
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: UbuntuColors.lightGrey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: widget.availableAccounts.length,
                  itemBuilder: (context, index) {
                    final account = widget.availableAccounts[index];
                    final isSelected = _selectedAccountIds.contains(account.id);
                    
                    return _buildAccountTile(account, isSelected);
                  },
                ),
              ),
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
          style: ElevatedButton.styleFrom(
            backgroundColor: UbuntuColors.orange,
            foregroundColor: Colors.white,
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Text('Create Virtual Drive'),
        ),
      ],
    );
  }

  Widget _buildAccountTile(CloudAccount account, bool isSelected) {
    return Card(
      elevation: isSelected ? 4 : 1,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          setState(() {
            if (isSelected) {
              _selectedAccountIds.remove(account.id);
            } else {
              _selectedAccountIds.add(account.id);
            }
          });
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Checkbox
              Checkbox(
                value: isSelected,
                onChanged: (value) {
                  HapticFeedback.lightImpact();
                  setState(() {
                    if (value == true) {
                      _selectedAccountIds.add(account.id);
                    } else {
                      _selectedAccountIds.remove(account.id);
                    }
                  });
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 12),
              
              // Provider icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _getProviderColor(account.provider).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _buildProviderIcon(account.provider),
              ),
              const SizedBox(width: 12),
              
              // Account information
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
                    const SizedBox(height: 2),
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
              
              // Provider name
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _getProviderColor(account.provider).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _getProviderDisplayName(account.provider),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _getProviderColor(account.provider),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProviderIcon(String provider) {
    switch (provider) {
      case 'gdrive':
        return SvgPicture.asset(
          'assets/icons/gdrive.svg',
          width: 24,
          height: 24,
        );
      case 'onedrive':
        return SvgPicture.asset(
          'assets/icons/onedrive.svg',
          width: 24,
          height: 24,
        );
      case 'dropbox':
        return Icon(
          Icons.folder,
          color: _getProviderColor(provider),
          size: 24,
        );
      default:
        return Icon(
          Icons.cloud,
          color: _getProviderColor(provider),
          size: 24,
        );
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

  String _getProviderDisplayName(String provider) {
    switch (provider) {
      case 'gdrive':
        return 'Google Drive';
      case 'onedrive':
        return 'OneDrive';
      case 'dropbox':
        return 'Dropbox';
      default:
        return provider;
    }
  }
}