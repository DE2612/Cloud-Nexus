import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../models/cloud_node.dart';
import '../adapters/cloud_adapter.dart';
import 'package:path_provider/path_provider.dart';

/// Modern, resource-optimized file preview dialog
/// Features:
/// - Lazy loading with progressive enhancement
/// - Memory-efficient streaming
/// - Modern Material 3 design
/// - Smooth animations
/// - Proper resource disposal
class FilePreviewDialog extends StatefulWidget {
  final CloudNode file;
  final ICloudAdapter adapter;

  const FilePreviewDialog({
    required this.file,
    required this.adapter,
  });

  @override
  State<FilePreviewDialog> createState() => _FilePreviewDialogState();
}

class _FilePreviewDialogState extends State<FilePreviewDialog>
    with SingleTickerProviderStateMixin {
  Uint8List? _previewBytes;
  bool _isLoading = true;
  String? _errorMessage;
  PdfViewerController? _pdfViewerController;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  // Optimized preview byte limits
  static const int _imagePreviewBytes = 512 * 1024; // 512KB for images (reduced)
  static const int _textPreviewBytes = 5 * 1024; // 5KB for text (reduced)
  static const int _pdfPreviewBytes = 2 * 1024 * 1024; // 2MB for PDFs (increased for better UX)

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _animationController.forward();
    _loadPreview();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _pdfViewerController?.dispose();
    _previewBytes = null; // Help GC
    super.dispose();
  }

  Future<void> _loadPreview() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final extension = widget.file.name.split('.').last.toLowerCase();
      
      // For PDFs, download the entire file to RAM (necessary for PDF viewer)
      if (extension == 'pdf') {
        await _loadPdfPreview();
      } else {
        // For other files, download partial preview with streaming
        await _loadPartialPreview(extension);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load preview: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadPdfPreview() async {
    final stream = await widget.adapter.downloadStream(widget.file.cloudId!);
    
    // Build bytes list with progress tracking
    final bytesBuilder = BytesBuilder();
    int bytesDownloaded = 0;
    
    await for (final byte in stream) {
      bytesDownloaded += byte.length;
      bytesBuilder.add(byte);
      
      // Update progress periodically
      if (bytesDownloaded % (100 * 1024) == 0 && mounted) {
        setState(() {}); // Trigger rebuild for progress indicator
      }
    }
    
    final previewBytes = bytesBuilder.toBytes();
    
    if (mounted) {
      setState(() {
        _previewBytes = previewBytes;
        _isLoading = false;
      });
    }
  }

  Future<void> _loadPartialPreview(String extension) async {
    final stream = await widget.adapter.downloadStream(widget.file.cloudId!);
    
    final bytesBuilder = BytesBuilder();
    int bytesDownloaded = 0;
    final maxBytes = _getMaxBytesForFile(extension);
    
    await for (final byte in stream) {
      bytesDownloaded += byte.length;
      bytesBuilder.add(byte);
      
      // Stop at max bytes to save memory
      if (bytesDownloaded >= maxBytes) {
        break;
      }
    }
    
    final previewBytes = bytesBuilder.takeBytes();
    
    if (mounted) {
      setState(() {
        _previewBytes = previewBytes;
        _isLoading = false;
      });
    }
  }

  int _getMaxBytesForFile(String extension) {
    // Determine preview size based on file type
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg'].contains(extension)) {
      return _imagePreviewBytes;
    } else if (_isTextFile(extension)) {
      return _textPreviewBytes;
    } else {
      return _textPreviewBytes;
    }
  }

  bool _isTextFile(String extension) {
    const textExtensions = [
      'txt', 'md', 'json', 'xml', 'csv', 'log',
      'c', 'cpp', 'h', 'hpp', 'cs', 'java', 'js', 'ts', 'dart', 'py', 'rb', 'go', 'rs', 'php',
      'html', 'css', 'scss', 'jsx', 'tsx', 'vue',
      'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'sh', 'bat', 'ps1', 'gitignore', 'env',
      'markdown', 'rst', 'plist', 'props', 'gradle',
    ];
    return textExtensions.contains(extension);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          constraints: const BoxConstraints(
            maxWidth: 900,
            maxHeight: 700,
          ),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(colorScheme),
                Flexible(
                  child: _buildContent(colorScheme),
                ),
                _buildFooter(colorScheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme colorScheme) {
    final extension = widget.file.name.split('.').last.toUpperCase();
    final isEncrypted = widget.file.name.endsWith('.enc');
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withOpacity(0.5),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withOpacity(0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _getFileIcon(widget.file.name),
              size: 24,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.file.name,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _buildInfoChip(
                      _formatBytes(widget.file.size),
                      colorScheme,
                    ),
                    const SizedBox(width: 8),
                    _buildInfoChip(
                      extension,
                      colorScheme,
                    ),
                    if (isEncrypted) ...[
                      const SizedBox(width: 8),
                      _buildInfoChip(
                        'Encrypted',
                        colorScheme,
                        isWarning: true,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close_rounded,
              color: colorScheme.onSurfaceVariant,
            ),
            onPressed: () => Navigator.pop(context),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChip(String label, ColorScheme colorScheme, {bool isWarning = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isWarning 
            ? colorScheme.errorContainer.withOpacity(0.3)
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: isWarning 
              ? colorScheme.error
              : colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildContent(ColorScheme colorScheme) {
    if (_isLoading) {
      return _buildLoadingState(colorScheme);
    }

    if (_errorMessage != null) {
      return _buildErrorState(colorScheme);
    }

    return _buildPreviewContent(colorScheme);
  }

  Widget _buildLoadingState(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surface,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: colorScheme.primary,
              strokeWidth: 3,
            ),
            const SizedBox(height: 16),
            Text(
              'Loading preview...',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surface,
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: colorScheme.error,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Preview Unavailable',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? 'An error occurred',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loadPreview,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewContent(ColorScheme colorScheme) {
    if (_previewBytes == null || _previewBytes!.isEmpty) {
      return _buildNoPreviewState(colorScheme);
    }

    final extension = widget.file.name.split('.').last.toLowerCase();

    // Image preview
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(extension)) {
      return _buildImagePreview(colorScheme);
    }

    // SVG preview
    if (extension == 'svg') {
      return _buildSvgPreview(colorScheme);
    }

    // Text preview
    if (_isTextFile(extension)) {
      return _buildTextPreview(colorScheme);
    }

    // PDF preview
    if (extension == 'pdf') {
      return _buildPdfPreview(colorScheme);
    }

    // Unsupported file type
    return _buildUnsupportedPreview(colorScheme, extension);
  }

  Widget _buildImagePreview(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surface,
      child: Center(
        child: InteractiveViewer(
          minScale: 0.1,
          maxScale: 5.0,
          child: Image.memory(
            _previewBytes!,
            errorBuilder: (context, error, stackTrace) {
              return _buildImageErrorState(colorScheme);
            },
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }

  Widget _buildImageErrorState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image_rounded,
            size: 64,
            color: colorScheme.onSurfaceVariant.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Failed to load image',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSvgPreview(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surface,
      child: Center(
        child: InteractiveViewer(
          minScale: 0.1,
          maxScale: 5.0,
          child: SvgPicture.memory(
            _previewBytes!,
            fit: BoxFit.contain,
            placeholderBuilder: (context) => CircularProgressIndicator(
              color: colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextPreview(ColorScheme colorScheme) {
    final text = String.fromCharCodes(_previewBytes!);
    
    return Container(
      color: colorScheme.surface,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: colorScheme.onSurface,
            height: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildPdfPreview(ColorScheme colorScheme) {
    if (_previewBytes == null || _previewBytes!.isEmpty) {
      return _buildNoPreviewState(colorScheme);
    }

    try {
      _pdfViewerController ??= PdfViewerController();
      
      return Container(
        color: colorScheme.surface,
        child: SfPdfViewer.memory(
          _previewBytes!,
          controller: _pdfViewerController,
          canShowScrollHead: true,
          canShowScrollStatus: true,
          pageSpacing: 4,
          onDocumentLoaded: (PdfDocumentLoadedDetails details) {
          },
          onDocumentLoadFailed: (PdfDocumentLoadFailedDetails details) {
            if (mounted) {
              setState(() {
                _errorMessage = details.error.toString();
              });
            }
          },
        ),
      );
    } catch (e) {
      return _buildErrorState(colorScheme);
    }
  }

  Widget _buildUnsupportedPreview(ColorScheme colorScheme, String extension) {
    return Container(
      color: colorScheme.surface,
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                _getFileIcon(widget.file.name),
                size: 64,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Preview Not Available',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This file type ($extension) is not supported for preview',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Size: ${_formatBytes(widget.file.size)}',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoPreviewState(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surface,
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.visibility_off_rounded,
              size: 64,
              color: colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No Preview Available',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withOpacity(0.5),
            width: 1,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: _openWithSystem,
            icon: const Icon(Icons.open_in_new_rounded, size: 20),
            label: const Text('Open with System'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, size: 20),
            label: const Text('Close'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg'].contains(extension)) {
      return Icons.image_rounded;
    }
    
    if (extension == 'pdf') {
      return Icons.picture_as_pdf_rounded;
    }
    
    if (['doc', 'docx'].contains(extension)) {
      return Icons.description_rounded;
    }
    
    if (['xls', 'xlsx'].contains(extension)) {
      return Icons.table_chart_rounded;
    }
    
    if (['mp4', 'avi', 'mov', 'mkv', 'webm'].contains(extension)) {
      return Icons.videocam_rounded;
    }
    
    if (['mp3', 'wav', 'ogg', 'flac', 'm4a'].contains(extension)) {
      return Icons.audiotrack_rounded;
    }
    
    if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2'].contains(extension)) {
      return Icons.folder_zip_rounded;
    }
    
    if (_isTextFile(extension)) {
      return Icons.code_rounded;
    }
    
    if (extension == 'enc') {
      return Icons.lock_rounded;
    }
    
    return Icons.insert_drive_file_rounded;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _openWithSystem() async {
    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/${widget.file.name}');
    
    if (widget.file.name.endsWith('.enc')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Encrypted files must be downloaded through CloudNexus'),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
          ),
        );
      }
      return;
    }
    
    try {
      await widget.adapter.downloadFile(widget.file.cloudId!, tempFile.path);
      
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', tempFile.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [tempFile.path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [tempFile.path]);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open file: $e'),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    }
  }
}