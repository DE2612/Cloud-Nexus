import 'package:hive/hive.dart';

part 'cloud_account.g.dart';

@HiveType(typeId: 1)
class CloudAccount extends HiveObject {
  @HiveField(0)
  final String id;        // Internal UUID
  
  @HiveField(1)
  final String provider;  // 'gdrive' or 'onedrive'
  
  @HiveField(2)
  final String name;      // e.g. "john@gmail.com"
  
  @HiveField(3)
  final String email;     // For UI display

  @HiveField(4, defaultValue: null)
  final String? accessToken;  // For OneDrive: access token
  
  @HiveField(5, defaultValue: null)
  final String? refreshToken; // For OneDrive: refresh token
  
  @HiveField(6, defaultValue: null)
  final DateTime? tokenExpiry; // For OneDrive: when token expires
  
  @HiveField(7, defaultValue: null)
  final String? credentials;   // For Google Drive: serialized credentials
  
  @HiveField(8, defaultValue: false)
  final bool encryptUploads;   // Whether to encrypt files uploaded to this drive
  
  @HiveField(9, defaultValue: 0)
  final int orderIndex;         // Order index for UI sorting (drag-and-drop)

  CloudAccount({
    required this.id,
    required this.provider,
    required this.name,
    required this.email,
    this.accessToken,
    this.refreshToken,
    this.tokenExpiry,
    this.credentials,
    this.encryptUploads = false,
    this.orderIndex = 0,
  });

  // Keep existing methods for compatibility during migration
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'provider': provider,
      'name': name,
      'email': email,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'tokenExpiry': tokenExpiry?.toIso8601String(),
      'credentials': credentials,
      'encryptUploads': encryptUploads,
      'orderIndex': orderIndex,
    };
  }

  factory CloudAccount.fromMap(Map<String, dynamic> map) {
    return CloudAccount(
      id: map['id'],
      provider: map['provider'],
      name: map['name'],
      email: map['email'],
      accessToken: map['accessToken'],
      refreshToken: map['refreshToken'],
      tokenExpiry: map['tokenExpiry'] != null 
          ? DateTime.parse(map['tokenExpiry'])
          : null,
      credentials: map['credentials'],
      encryptUploads: map['encryptUploads'] ?? false,
      orderIndex: map['orderIndex'] ?? 0,
    );
  }

  // Check if the account has valid credentials
  bool get hasValidCredentials {
    if (provider == 'onedrive') {
      return accessToken != null && 
             (tokenExpiry == null || DateTime.now().isBefore(tokenExpiry!));
    } else if (provider == 'gdrive') {
      return credentials != null;
    }
    return false;
  }

  // Helper to check if token needs refresh (for OneDrive)
  bool get needsTokenRefresh {
    if (tokenExpiry == null) return false;
    // Refresh if token expires within 5 minutes
    return DateTime.now().add(Duration(minutes: 5)).isAfter(tokenExpiry!);
  }
}