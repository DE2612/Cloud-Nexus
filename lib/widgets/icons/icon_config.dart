import 'package:flutter/material.dart';

/// Icon size presets
enum IconSize {
  small(24),
  medium(48),
  large(64),
  extraLarge(96);

  final double size;
  const IconSize(this.size);
}

/// Folder icon variants
enum FolderVariant {
  regular,
  encrypted,
  shared,
  root,
}

/// Icon style enum for choosing between 2D SVG and 3D icons
enum IconStyle {
  svg,
  threeD,
}

/// File category enum for organizing file types
enum FileCategory {
  documents,
  spreadsheets,
  presentations,
  images,
  videos,
  audio,
  archives,
  code,
  text,
  data,
  executable,
  folder,
  unknown,
}

/// Information about a file type
class FileTypeInfo {
  final FileCategory category;
  final String label;
  final IconData? icon;
  final List<Color>? customColors;

  const FileTypeInfo({
    required this.category,
    required this.label,
    this.icon,
    this.customColors,
  });
}

/// Configuration for file type icons
class IconConfig {
  /// Get file type information from file name
  static FileTypeInfo getFileTypeInfo(String fileName) {
    final extension = fileName.toLowerCase().split('.').last;
    return _fileTypeMap[extension] ?? _fileTypeMap['*']!;
  }

  /// Get file category from file name
  static FileCategory getFileCategory(String fileName) {
    return getFileTypeInfo(fileName).category;
  }

  /// Get file type label from file name
  static String getFileTypeLabel(String fileName) {
    return getFileTypeInfo(fileName).label;
  }

  /// Get icon for file type
  static IconData? getFileTypeIcon(String fileName) {
    return getFileTypeInfo(fileName).icon;
  }

  /// Check if file name is a folder
  static bool isFolder(String fileName) {
    return !fileName.contains('.');
  }

  /// Get SVG asset path for a file type
  /// Returns the default "file" icon for unknown file types
  static String getFileIconPath(String fileName, IconSize size) {
    return getFileIconPathWithStyle(fileName, size, IconStyle.svg);
  }

  /// Get SVG asset path for a folder variant
  static String getFolderIconPath(FolderVariant variant, IconSize size) {
    return getFolderIconPathWithStyle(variant, size, IconStyle.svg);
  }

  /// Get asset path for a file type with specified style (SVG or 3D)
  /// Returns the default "file" icon for unknown file types
  static String getFileIconPathWithStyle(String fileName, IconSize size, IconStyle style) {
    final extension = fileName.toLowerCase().split('.').last;
    final sizeDir = _getSizeDirectory(size);
    final styleDir = _getStyleDirectory(style);
    
    // Check if the extension is in our file type map
    // If not, use the default "file" icon
    if (!_fileTypeMap.containsKey(extension)) {
      return 'assets/icons/$styleDir/$sizeDir/files/file.svg';
    }
    
    return 'assets/icons/$styleDir/$sizeDir/files/$extension.svg';
  }

  /// Get asset path for a folder variant with specified style (SVG or 3D)
  static String getFolderIconPathWithStyle(FolderVariant variant, IconSize size, IconStyle style) {
    final sizeDir = _getSizeDirectory(size);
    final styleDir = _getStyleDirectory(style);
    return 'assets/icons/$styleDir/$sizeDir/folders/${variant.name}.svg';
  }

  static String _getStyleDirectory(IconStyle style) {
    switch (style) {
      case IconStyle.svg: return 'svg';
      case IconStyle.threeD: return '3d';
    }
  }

  static String _getSizeDirectory(IconSize size) {
    switch (size) {
      case IconSize.small: return '24px';
      case IconSize.medium: return '48px';
      case IconSize.large: return '64px';
      case IconSize.extraLarge: return '96px';
    }
  }

  /// File type mappings
  static const Map<String, FileTypeInfo> _fileTypeMap = {
    // Documents
    'pdf': FileTypeInfo(
      category: FileCategory.documents,
      label: 'PDF',
      icon: Icons.picture_as_pdf,
    ),
    'doc': FileTypeInfo(
      category: FileCategory.documents,
      label: 'DOC',
      icon: Icons.description,
    ),
    'docx': FileTypeInfo(
      category: FileCategory.documents,
      label: 'DOC',
      icon: Icons.description,
    ),
    'odt': FileTypeInfo(
      category: FileCategory.documents,
      label: 'ODT',
      icon: Icons.description,
    ),
    'rtf': FileTypeInfo(
      category: FileCategory.documents,
      label: 'RTF',
      icon: Icons.description,
    ),
    'tex': FileTypeInfo(
      category: FileCategory.documents,
      label: 'TEX',
      icon: Icons.description,
    ),

    // Spreadsheets
    'xls': FileTypeInfo(
      category: FileCategory.spreadsheets,
      label: 'XLS',
      icon: Icons.table_chart,
    ),
    'xlsx': FileTypeInfo(
      category: FileCategory.spreadsheets,
      label: 'XLS',
      icon: Icons.table_chart,
    ),
    'ods': FileTypeInfo(
      category: FileCategory.spreadsheets,
      label: 'ODS',
      icon: Icons.table_chart,
    ),
    'csv': FileTypeInfo(
      category: FileCategory.spreadsheets,
      label: 'CSV',
      icon: Icons.table_chart,
    ),
    'tsv': FileTypeInfo(
      category: FileCategory.spreadsheets,
      label: 'TSV',
      icon: Icons.table_chart,
    ),

    // Presentations
    'ppt': FileTypeInfo(
      category: FileCategory.presentations,
      label: 'PPT',
      icon: Icons.slideshow,
    ),
    'pptx': FileTypeInfo(
      category: FileCategory.presentations,
      label: 'PPT',
      icon: Icons.slideshow,
    ),
    'odp': FileTypeInfo(
      category: FileCategory.presentations,
      label: 'ODP',
      icon: Icons.slideshow,
    ),
    'key': FileTypeInfo(
      category: FileCategory.presentations,
      label: 'KEY',
      icon: Icons.slideshow,
    ),

    // Images
    'jpg': FileTypeInfo(
      category: FileCategory.images,
      label: 'JPG',
      icon: Icons.image,
    ),
    'jpeg': FileTypeInfo(
      category: FileCategory.images,
      label: 'JPG',
      icon: Icons.image,
    ),
    'png': FileTypeInfo(
      category: FileCategory.images,
      label: 'PNG',
      icon: Icons.image,
    ),
    'gif': FileTypeInfo(
      category: FileCategory.images,
      label: 'GIF',
      icon: Icons.image,
    ),
    'bmp': FileTypeInfo(
      category: FileCategory.images,
      label: 'BMP',
      icon: Icons.image,
    ),
    'svg': FileTypeInfo(
      category: FileCategory.images,
      label: 'SVG',
      icon: Icons.image,
    ),
    'webp': FileTypeInfo(
      category: FileCategory.images,
      label: 'WEBP',
      icon: Icons.image,
    ),
    'ico': FileTypeInfo(
      category: FileCategory.images,
      label: 'ICO',
      icon: Icons.image,
    ),
    'tiff': FileTypeInfo(
      category: FileCategory.images,
      label: 'TIFF',
      icon: Icons.image,
    ),
    'psd': FileTypeInfo(
      category: FileCategory.images,
      label: 'PSD',
      icon: Icons.image,
    ),
    'ai': FileTypeInfo(
      category: FileCategory.images,
      label: 'AI',
      icon: Icons.image,
    ),

    // Videos
    'mp4': FileTypeInfo(
      category: FileCategory.videos,
      label: 'MP4',
      icon: Icons.videocam,
    ),
    'avi': FileTypeInfo(
      category: FileCategory.videos,
      label: 'AVI',
      icon: Icons.videocam,
    ),
    'mkv': FileTypeInfo(
      category: FileCategory.videos,
      label: 'MKV',
      icon: Icons.videocam,
    ),
    'mov': FileTypeInfo(
      category: FileCategory.videos,
      label: 'MOV',
      icon: Icons.videocam,
    ),
    'wmv': FileTypeInfo(
      category: FileCategory.videos,
      label: 'WMV',
      icon: Icons.videocam,
    ),
    'flv': FileTypeInfo(
      category: FileCategory.videos,
      label: 'FLV',
      icon: Icons.videocam,
    ),
    'webm': FileTypeInfo(
      category: FileCategory.videos,
      label: 'WEBM',
      icon: Icons.videocam,
    ),
    'm4v': FileTypeInfo(
      category: FileCategory.videos,
      label: 'M4V',
      icon: Icons.videocam,
    ),
    '3gp': FileTypeInfo(
      category: FileCategory.videos,
      label: '3GP',
      icon: Icons.videocam,
    ),

    // Audio
    'mp3': FileTypeInfo(
      category: FileCategory.audio,
      label: 'MP3',
      icon: Icons.audiotrack,
    ),
    'wav': FileTypeInfo(
      category: FileCategory.audio,
      label: 'WAV',
      icon: Icons.audiotrack,
    ),
    'flac': FileTypeInfo(
      category: FileCategory.audio,
      label: 'FLAC',
      icon: Icons.audiotrack,
    ),
    'aac': FileTypeInfo(
      category: FileCategory.audio,
      label: 'AAC',
      icon: Icons.audiotrack,
    ),
    'ogg': FileTypeInfo(
      category: FileCategory.audio,
      label: 'OGG',
      icon: Icons.audiotrack,
    ),
    'wma': FileTypeInfo(
      category: FileCategory.audio,
      label: 'WMA',
      icon: Icons.audiotrack,
    ),
    'm4a': FileTypeInfo(
      category: FileCategory.audio,
      label: 'M4A',
      icon: Icons.audiotrack,
    ),
    'opus': FileTypeInfo(
      category: FileCategory.audio,
      label: 'OPUS',
      icon: Icons.audiotrack,
    ),

    // Archives
    'zip': FileTypeInfo(
      category: FileCategory.archives,
      label: 'ZIP',
      icon: Icons.folder_zip,
    ),
    'rar': FileTypeInfo(
      category: FileCategory.archives,
      label: 'RAR',
      icon: Icons.folder_zip,
    ),
    '7z': FileTypeInfo(
      category: FileCategory.archives,
      label: '7Z',
      icon: Icons.folder_zip,
    ),
    'tar': FileTypeInfo(
      category: FileCategory.archives,
      label: 'TAR',
      icon: Icons.folder_zip,
    ),
    'gz': FileTypeInfo(
      category: FileCategory.archives,
      label: 'GZ',
      icon: Icons.folder_zip,
    ),
    'bz2': FileTypeInfo(
      category: FileCategory.archives,
      label: 'BZ2',
      icon: Icons.folder_zip,
    ),
    'xz': FileTypeInfo(
      category: FileCategory.archives,
      label: 'XZ',
      icon: Icons.folder_zip,
    ),
    'iso': FileTypeInfo(
      category: FileCategory.archives,
      label: 'ISO',
      icon: Icons.folder_zip,
    ),
    'dmg': FileTypeInfo(
      category: FileCategory.archives,
      label: 'DMG',
      icon: Icons.folder_zip,
    ),

    // Code
    'dart': FileTypeInfo(
      category: FileCategory.code,
      label: 'DART',
      icon: Icons.code,
    ),
    'js': FileTypeInfo(
      category: FileCategory.code,
      label: 'JS',
      icon: Icons.code,
    ),
    'ts': FileTypeInfo(
      category: FileCategory.code,
      label: 'TS',
      icon: Icons.code,
    ),
    'html': FileTypeInfo(
      category: FileCategory.code,
      label: 'HTML',
      icon: Icons.code,
    ),
    'css': FileTypeInfo(
      category: FileCategory.code,
      label: 'CSS',
      icon: Icons.code,
    ),
    'py': FileTypeInfo(
      category: FileCategory.code,
      label: 'PY',
      icon: Icons.code,
    ),
    'java': FileTypeInfo(
      category: FileCategory.code,
      label: 'JAVA',
      icon: Icons.code,
    ),
    'cpp': FileTypeInfo(
      category: FileCategory.code,
      label: 'CPP',
      icon: Icons.code,
    ),
    'c': FileTypeInfo(
      category: FileCategory.code,
      label: 'C',
      icon: Icons.code,
    ),
    'h': FileTypeInfo(
      category: FileCategory.code,
      label: 'H',
      icon: Icons.code,
    ),
    'cs': FileTypeInfo(
      category: FileCategory.code,
      label: 'CS',
      icon: Icons.code,
    ),
    'php': FileTypeInfo(
      category: FileCategory.code,
      label: 'PHP',
      icon: Icons.code,
    ),
    'rb': FileTypeInfo(
      category: FileCategory.code,
      label: 'RB',
      icon: Icons.code,
    ),
    'go': FileTypeInfo(
      category: FileCategory.code,
      label: 'GO',
      icon: Icons.code,
    ),
    'rs': FileTypeInfo(
      category: FileCategory.code,
      label: 'RS',
      icon: Icons.code,
    ),
    'swift': FileTypeInfo(
      category: FileCategory.code,
      label: 'SWIFT',
      icon: Icons.code,
    ),
    'kt': FileTypeInfo(
      category: FileCategory.code,
      label: 'KT',
      icon: Icons.code,
    ),
    'sql': FileTypeInfo(
      category: FileCategory.code,
      label: 'SQL',
      icon: Icons.code,
    ),
    'sh': FileTypeInfo(
      category: FileCategory.code,
      label: 'SH',
      icon: Icons.code,
    ),
    'bat': FileTypeInfo(
      category: FileCategory.code,
      label: 'BAT',
      icon: Icons.code,
    ),
    'ps1': FileTypeInfo(
      category: FileCategory.code,
      label: 'PS1',
      icon: Icons.code,
    ),
    'xml': FileTypeInfo(
      category: FileCategory.code,
      label: 'XML',
      icon: Icons.code,
    ),
    'json': FileTypeInfo(
      category: FileCategory.data,
      label: 'JSON',
      icon: Icons.code,
    ),
    'yaml': FileTypeInfo(
      category: FileCategory.data,
      label: 'YAML',
      icon: Icons.code,
    ),
    'yml': FileTypeInfo(
      category: FileCategory.data,
      label: 'YAML',
      icon: Icons.code,
    ),

    // Text
    'txt': FileTypeInfo(
      category: FileCategory.text,
      label: 'TXT',
      icon: Icons.text_snippet,
    ),
    'md': FileTypeInfo(
      category: FileCategory.text,
      label: 'MD',
      icon: Icons.text_snippet,
    ),
    'log': FileTypeInfo(
      category: FileCategory.text,
      label: 'LOG',
      icon: Icons.text_snippet,
    ),
    'readme': FileTypeInfo(
      category: FileCategory.text,
      label: 'README',
      icon: Icons.text_snippet,
    ),

    // Data
    'toml': FileTypeInfo(
      category: FileCategory.data,
      label: 'TOML',
      icon: Icons.data_object,
    ),
    'ini': FileTypeInfo(
      category: FileCategory.data,
      label: 'INI',
      icon: Icons.data_object,
    ),
    'cfg': FileTypeInfo(
      category: FileCategory.data,
      label: 'CFG',
      icon: Icons.data_object,
    ),
    'conf': FileTypeInfo(
      category: FileCategory.data,
      label: 'CONF',
      icon: Icons.data_object,
    ),

    // Executables
    'exe': FileTypeInfo(
      category: FileCategory.executable,
      label: 'EXE',
      icon: Icons.settings_applications,
    ),
    'msi': FileTypeInfo(
      category: FileCategory.executable,
      label: 'MSI',
      icon: Icons.settings_applications,
    ),
    'app': FileTypeInfo(
      category: FileCategory.executable,
      label: 'APP',
      icon: Icons.settings_applications,
    ),
    'deb': FileTypeInfo(
      category: FileCategory.executable,
      label: 'DEB',
      icon: Icons.settings_applications,
    ),
    'rpm': FileTypeInfo(
      category: FileCategory.executable,
      label: 'RPM',
      icon: Icons.settings_applications,
    ),
    'apk': FileTypeInfo(
      category: FileCategory.executable,
      label: 'APK',
      icon: Icons.settings_applications,
    ),

    // E-books
    'epub': FileTypeInfo(
      category: FileCategory.documents,
      label: 'EPUB',
      icon: Icons.menu_book,
    ),
    'mobi': FileTypeInfo(
      category: FileCategory.documents,
      label: 'MOBI',
      icon: Icons.menu_book,
    ),
    'azw': FileTypeInfo(
      category: FileCategory.documents,
      label: 'AZW',
      icon: Icons.menu_book,
    ),
    'azw3': FileTypeInfo(
      category: FileCategory.documents,
      label: 'AZW3',
      icon: Icons.menu_book,
    ),

    // 3D/CAD
    'obj': FileTypeInfo(
      category: FileCategory.data,
      label: 'OBJ',
      icon: Icons.view_in_ar,
    ),
    'stl': FileTypeInfo(
      category: FileCategory.data,
      label: 'STL',
      icon: Icons.view_in_ar,
    ),
    'dwg': FileTypeInfo(
      category: FileCategory.data,
      label: 'DWG',
      icon: Icons.view_in_ar,
    ),
    'dxf': FileTypeInfo(
      category: FileCategory.data,
      label: 'DXF',
      icon: Icons.view_in_ar,
    ),

    // Fonts
    'ttf': FileTypeInfo(
      category: FileCategory.data,
      label: 'TTF',
      icon: Icons.font_download,
    ),
    'otf': FileTypeInfo(
      category: FileCategory.data,
      label: 'OTF',
      icon: Icons.font_download,
    ),
    'woff': FileTypeInfo(
      category: FileCategory.data,
      label: 'WOFF',
      icon: Icons.font_download,
    ),
    'woff2': FileTypeInfo(
      category: FileCategory.data,
      label: 'WOFF2',
      icon: Icons.font_download,
    ),

    // Encrypted files
    'enc': FileTypeInfo(
      category: FileCategory.unknown,
      label: 'ENC',
      icon: Icons.lock,
    ),

    // Default/Unknown
    '*': FileTypeInfo(
      category: FileCategory.unknown,
      label: 'FILE',
      icon: Icons.insert_drive_file,
    ),
  };
}