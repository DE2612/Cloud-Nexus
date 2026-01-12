import 'dart:async';
import 'package:flutter/foundation.dart';

/// Provider for managing file selection state independently.
/// This separates selection logic from the main file explorer,
/// reducing unnecessary rebuilds when selection changes.
///
/// Benefits:
/// - Only widgets that depend on selection state will rebuild
/// - Sidebar, tab bar, and address bar won't rebuild on checkbox clicks
/// - Cleaner separation of concerns
/// - Debounced selection updates to prevent rapid rebuilds
class SelectionProvider extends ChangeNotifier {
  final Set<String> _selectedFiles = <String>{};
  
  // OPTIMIZATION: Debounce timer for selection updates
  Timer? _debounceTimer;
  static const Duration _debounceDuration = Duration(milliseconds: 50);
  
  // Pending selection changes to apply after debounce
  final Map<String, bool> _pendingChanges = {};
  bool _pendingClear = false;

  /// Get the current set of selected file IDs
  Set<String> get selectedFiles => _selectedFiles;

  /// Get the count of selected files
  int get selectedCount => _selectedFiles.length;

  /// Check if a specific file is selected
  bool isSelected(String fileId) => _selectedFiles.contains(fileId);

  /// Check if all files in a list are selected
  bool areAllSelected(List<String> fileIds) {
    if (fileIds.isEmpty) return false;
    return fileIds.every((id) => _selectedFiles.contains(id));
  }

  /// Check if any files in a list are selected
  bool areAnySelected(List<String> fileIds) {
    return fileIds.any((id) => _selectedFiles.contains(id));
  }

  /// Toggle selection for a single file
  /// Uses debouncing to batch rapid changes
  void toggleSelection(String fileId) {
    _queueChange(fileId, !_selectedFiles.contains(fileId));
  }

  /// Select a specific file
  void selectFile(String fileId) {
    _queueChange(fileId, true);
  }

  /// Deselect a specific file
  void deselectFile(String fileId) {
    _queueChange(fileId, false);
  }

  /// Add multiple files to selection
  void selectFiles(Iterable<String> fileIds) {
    for (final id in fileIds) {
      _queueChange(id, true);
    }
  }

  /// Remove multiple files from selection
  void deselectFiles(Iterable<String> fileIds) {
    for (final id in fileIds) {
      _queueChange(id, false);
    }
  }

  /// Select all files in a list
  void selectAll(Iterable<String> fileIds) {
    _clearPending();
    for (final id in fileIds) {
      _selectedFiles.add(id);
    }
    notifyListeners();
  }

  /// Clear all selections
  void clearSelection() {
    if (_selectedFiles.isEmpty) return;
    
    _clearPending();
    _pendingClear = true;
    _scheduleDebounce();
  }

  /// Queue a selection change (debounced)
  void _queueChange(String fileId, bool selected) {
    _pendingChanges[fileId] = selected;
    _scheduleDebounce();
  }

  /// Schedule debounced notification
  void _scheduleDebounce() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, _applyChanges);
  }

  /// Apply pending changes and notify listeners
  void _applyChanges() {
    if (_pendingClear) {
      _selectedFiles.clear();
      _pendingClear = false;
    } else {
      for (final entry in _pendingChanges.entries) {
        if (entry.value) {
          _selectedFiles.add(entry.key);
        } else {
          _selectedFiles.remove(entry.key);
        }
      }
    }
    
    _clearPending();
    
    if (hasListeners) {
      notifyListeners();
    }
  }

  /// Clear pending changes
  void _clearPending() {
    _pendingChanges.clear();
  }

  /// Force apply any pending changes immediately
  /// Useful when you need to ensure state is up-to-date
  void flushPending() {
    if (_pendingChanges.isNotEmpty || _pendingClear) {
      _applyChanges();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }
}