import 'dart:convert';
import 'dart:io';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../models/cloud_account.dart';
import 'hive_storage_service.dart';
import 'package:uuid/uuid.dart';

class OneDriveAuthManager {
  // Singleton instance
  static final OneDriveAuthManager instance = OneDriveAuthManager._internal();
  factory OneDriveAuthManager() => instance;
  OneDriveAuthManager._internal();
  
  // Loaded from .env file - DO NOT hardcode these values!
  final String clientId = dotenv.env['ONEDRIVE_CLIENT_ID'] ?? '';
  final String clientSecret = dotenv.env['ONEDRIVE_CLIENT_SECRET'] ?? '';
  
  // The redirect URI is dynamically generated per auth request
  // Only keep the env var for reference - actual URI is created in signIn()
  final String _envRedirectUri = dotenv.env['ONEDRIVE_REDIRECT_URI'] ?? 'http://localhost:43823/callback';
  
  final String _authUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
  final String _tokenUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
  
  // Scopes: "Files.ReadWrite.All" (Access files), "offline_access" (Get Refresh Token)
  final String _scopes = "Files.ReadWrite.All offline_access User.Read";

  /// Sign in and return auth information
  /// This forces a fresh sign-in flow to allow multiple accounts
  /// IMPORTANT: This does NOT create or store CloudAccount - caller must do that
  Future<Map<String, dynamic>?> signIn() async {
    try {
      // Create a loopback server to capture the callback (like Google Auth Manager)
      final server = await HttpServer.bind('localhost', 0);
      final port = server.port;
      final dynamicRedirectUri = 'http://localhost:$port/callback';
      

      // 1. Construct Login URL with prompt=select_account to force account selection
      final url = Uri.parse(
        "$_authUrl?client_id=$clientId&response_type=code&redirect_uri=$dynamicRedirectUri&response_mode=query&scope=$_scopes&prompt=select_account"
      );


      // 2. Open Browser & Wait for Code
      if (await canLaunchUrl(url)) {
        await launchUrl(url);
      } else {
        server.close();
        return null;
      }

      // 3. Wait for callback on our local server
      final request = await server.first;
      final code = request.uri.queryParameters['code'];
      
      // Send success response
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.text
        ..write('Authentication successful! You can close this window.');
      await request.response.close();
      server.close();

      if (code == null) {
        return null;
      }

      // 4. Exchange Code for Token
      final response = await http.post(
        Uri.parse(_tokenUrl),
        body: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'scope': _scopes,
          'code': code,
          'redirect_uri': dynamicRedirectUri,
          'grant_type': 'authorization_code',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final accessToken = data['access_token'];
        final refreshToken = data['refresh_token'] ?? '';
        
        // Set token expiry (OneDrive tokens typically last 1 hour)
        final tokenExpiry = DateTime.now().add(Duration(hours: 1));
        
        // Get user email and display name for profile
        final email = await _getUserEmail(accessToken);
        final displayName = await _getUserDisplayName(accessToken);
        
        // Serialize credentials for storage
        final credentialsJson = jsonEncode({
          'accessToken': accessToken,
          'refreshToken': refreshToken,
          'tokenExpiry': tokenExpiry.toIso8601String(),
        });

        // Return credentials and email/name (displayName) - do NOT create CloudAccount here
        return {
          'email': email,
          'name': displayName,
          'credentials': credentialsJson,
        };
      } else {
        return null;
      }
    } catch (e) {
      return null;
    }
  }
  
  /// Get user email for display
  Future<String> _getUserEmail(String accessToken) async {
    try {
      final response = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me?\$select=mail,userPrincipalName'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['mail'] ?? data['userPrincipalName'] ?? "OneDrive Account";
      }
    } catch (e) {
    }
    return "OneDrive Account";
  }
  
  /// Get user display name from Microsoft Graph API
  Future<String> _getUserDisplayName(String accessToken) async {
    try {
      final response = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me?\$select=displayName'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['displayName'] ?? "OneDrive Account";
      }
    } catch (e) {
    }
    return "OneDrive Account";
  }
  
  /// Get current access token for a specific account
  Future<String?> getAccessTokenForAccount(String accountId) async {
    
    final account = await HiveStorageService.instance.getAccount(accountId);
    if (account == null) {
      return null;
    }
    
    if (account.credentials == null) {
      return null;
    }
    
    
    // Deserialize credentials
    final credentials = _deserializeCredentials(account.credentials!);
    if (credentials == null) {
      return null;
    }
    
    
    // Check if token needs refresh
    if (credentials['tokenExpiry'].isBefore(DateTime.now().add(Duration(minutes: 5)))) {
      final refreshSuccess = await refreshTokenForAccount(accountId);
      if (!refreshSuccess) {
        return null;
      }
      final updatedAccount = await HiveStorageService.instance.getAccount(accountId);
      if (updatedAccount?.credentials == null) {
        return null;
      }
      final refreshed = _deserializeCredentials(updatedAccount!.credentials!);
      if (refreshed == null) {
        return null;
      }
      return refreshed?['accessToken'];
    }
    
    return credentials['accessToken'];
  }
  
  /// Refresh access token using refresh token for a specific account
  Future<bool> refreshTokenForAccount(String accountId) async {
    final account = await HiveStorageService.instance.getAccount(accountId);
    if (account == null || account.credentials == null) {
      return false;
    }
    
    final credentials = _deserializeCredentials(account.credentials!);
    if (credentials == null || credentials['refreshToken'] == null) {
      return false;
    }
    
    try {
      final response = await http.post(
        Uri.parse(_tokenUrl),
        body: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'refresh_token': credentials['refreshToken'],
          'grant_type': 'refresh_token',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final newAccessToken = data['access_token'];
        final newRefreshToken = data['refresh_token'] ?? credentials['refreshToken'];
        final newTokenExpiry = DateTime.now().add(Duration(hours: 1));
        
        // Serialize new credentials
        final newCredentials = jsonEncode({
          'accessToken': newAccessToken,
          'refreshToken': newRefreshToken,
          'tokenExpiry': newTokenExpiry.toIso8601String(),
        });
        
        // Update account in Hive
        final updatedAccount = CloudAccount(
          id: account.id,
          provider: account.provider,
          name: account.name,
          email: account.email,
          credentials: newCredentials,
        );
        
        await HiveStorageService.instance.createAccount(updatedAccount);
        
        return true;
      } else {
        return false;
      }
    } catch (e) {
      return false;
    }
  }
  
  /// Deserialize credentials JSON string to Map
  Map<String, dynamic>? _deserializeCredentials(String credentialsJson) {
    try {
      final json = jsonDecode(credentialsJson);
      return {
        'accessToken': json['accessToken'],
        'refreshToken': json['refreshToken'],
        'tokenExpiry': DateTime.parse(json['tokenExpiry']),
      };
    } catch (e) {
      return null;
    }
  }
  
  /// Sign out a specific account
  Future<void> signOutAccount(String accountId) async {
    final account = await HiveStorageService.instance.getAccount(accountId);
    if (account == null) return;
    
    // Note: We don't delete the account from Hive here as the file system
    // nodes may still reference it. The app should handle account removal separately.
  }
  
  /// Sign out all OneDrive accounts
  Future<void> signOutAll() async {
    final accounts = await HiveStorageService.instance.getAccounts();
    for (final account in accounts) {
      if (account.provider == 'onedrive') {
        await signOutAccount(account.id);
      }
    }
  }
}