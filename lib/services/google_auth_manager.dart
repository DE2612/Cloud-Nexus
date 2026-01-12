import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import '../models/cloud_account.dart';
import 'hive_storage_service.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

class GoogleAuthManager {
  // Singleton instance
  static final GoogleAuthManager instance = GoogleAuthManager._internal();
  factory GoogleAuthManager() => instance;
  GoogleAuthManager._internal();
  
  // ---------------------------------------------------------
  // CONFIGURATION
  // ---------------------------------------------------------
  static String get _windowsClientId => dotenv.env['GOOGLE_CLIENT_ID'] ?? '';
  static String get _windowsClientSecret => dotenv.env['GOOGLE_CLIENT_SECRET'] ?? '';
  
  // Scopes for Google Drive access
  static const _scopes = [
    drive.DriveApi.driveFileScope,
    drive.DriveApi.driveReadonlyScope,
  ];

  Future<Map<String, dynamic>?> signIn() async {
    if (Platform.isAndroid) {
      return _signInAndroid();
    } else if (Platform.isWindows) {
      return _signInWindows();
    }
    return null;
  }

  /// ANDROID: Uses the standard system popup
  Future<Map<String, dynamic>?> _signInAndroid() async {
    // Create a fresh GoogleSignIn instance to force new account selection
    final googleSignIn = GoogleSignIn(
      scopes: _scopes,
      // Force sign out first to allow account selection
      signInOption: SignInOption.standard,
      serverClientId: _windowsClientId, // Required for offline access on Android
    );
    
    await googleSignIn.signOut(); // Clear cached account
    
    final account = await googleSignIn.signIn();
    if (account == null) return null; // User cancelled

    // Get email for display
    final email = account.email;
    
    // Extension method converts it to an AuthClient
    final authClient = await googleSignIn.authenticatedClient();
    if (authClient == null) return null;

    // Serialize credentials for storage
    final credentials = authClient.credentials;
    final credentialsJson = _serializeCredentials(credentials);

    // Return credentials, email, name, AND the original authClient for immediate use
    return {
      'email': email,
      'name': email,
      'credentials': credentialsJson,
      'authClient': authClient, // Include the original authenticated client for immediate use
    };
  }

  /// WINDOWS: Spins up a local loopback server to catch browser redirect
  Future<Map<String, dynamic>?> _signInWindows() async {
    // FIX: Use custom OAuth flow with access_type=offline and prompt=consent
    // This ensures we get a refresh token for long-term authentication
    final id = ClientId(_windowsClientId, _windowsClientSecret);
    
    // Create a loopback server to capture the callback
    final server = await HttpServer.bind('localhost', 0);
    final port = server.port;
    final redirectUri = 'http://localhost:$port';
    
    
    // Build authorization URL with offline access and consent prompt
    final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': _windowsClientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': _scopes.join(' '),
      'access_type': 'offline',  
      'prompt': 'consent',      
    });
    
    
    // Open browser for user consent
    if (await canLaunchUrl(authUrl)) {
      await launchUrl(authUrl);
    } else {
      server.close();
      return null;
    }
    
    // Wait for callback
    final request = await server.first;
    final code = request.uri.queryParameters['code'];
    
    if (code == null) {
      request.response.close();
      server.close();
      return null;
    }
    
    // Send success response
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.text
      ..write('Authentication successful! You can close this window.');
    await request.response.close();
    server.close();
    
    // Exchange authorization code for tokens
    final response = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'code': code,
        'client_id': _windowsClientId,
        'client_secret': _windowsClientSecret,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
      },
    );
    
    if (response.statusCode != 200) {
      return null;
    }
    
    final tokenData = jsonDecode(response.body);
    final accessToken = tokenData['access_token'];
    final refreshToken = tokenData['refresh_token'];
    final expiresIn = tokenData['expires_in'] ?? 3600;
    
    
    if (refreshToken == null) {
    }
    
    // Create credentials with UTC DateTime (required by AccessToken)
    final credentials = AccessCredentials(
      AccessToken('Bearer', accessToken, DateTime.now().toUtc().add(Duration(seconds: expiresIn))),
      refreshToken, // This should be populated now with access_type=offline&prompt=consent
      _scopes,
    );
    
    // Create an authenticated client using our custom _SimpleAuthClient
    final authClient = _SimpleAuthClient(credentials);
    
    // Get user info to determine email and display name
    String email;
    String displayName;
    try {
      final driveApi = drive.DriveApi(authClient);
      final about = await driveApi.about.get($fields: "user(emailAddress,displayName)");
      email = about.user?.emailAddress ?? "Google Account";
      displayName = about.user?.displayName ?? email; // Fallback to email if displayName is not available
    } catch (e) {
      if (e.toString().contains('403') && e.toString().contains('not been used')) {
        throw Exception(
          'Google Drive API is not enabled for this project. '
          'Please enable it at: https://console.developers.google.com/apis/api/drive.googleapis.com/overview'
        );
      }
      rethrow;
    }

    // Serialize credentials for storage
    final credentialsJson = _serializeCredentials(credentials);

    // Return credentials, email, name (displayName), AND the original authClient for immediate use
    return {
      'email': email,
      'name': displayName,
      'credentials': credentialsJson,
      'authClient': authClient, // Include the original authenticated client for immediate use
    };
  }
  
  /// Get an authenticated client for a specific account
  /// This uses stored credentials and does NOT trigger a login flow
  Future<AuthClient?> getAuthClient(String accountId) async {
    
    final account = await HiveStorageService.instance.getAccount(accountId);
    if (account == null) {
      return null;
    }
    
    if (account.credentials == null) {
      return null;
    }
    
    
    final credentials = _deserializeCredentials(account.credentials!);
    if (credentials == null) {
      return null;
    }
    

    // Create an authenticated client from stored credentials
    // We use clientViaUserConsent but with a no-op prompt since we have credentials
    final clientId = ClientId(_windowsClientId, _windowsClientSecret);
    
    // Create a simple authenticated client using the stored credentials
    return _SimpleAuthClient(credentials, accountId);
  }
  
  /// Get a DriveApi instance for a specific account
  Future<drive.DriveApi?> getDriveApi(String accountId) async {
    final authClient = await getAuthClient(accountId);
    if (authClient == null) return null;
    return drive.DriveApi(authClient);
  }
  
  /// Refresh credentials for a specific account using refresh token
  Future<bool> refreshCredentialsForAccount(String accountId) async {
    final account = await HiveStorageService.instance.getAccount(accountId);
    if (account == null || account.credentials == null) {
      return false;
    }
    
    final credentials = _deserializeCredentials(account.credentials!);
    if (credentials == null || credentials.refreshToken == null) {
      return false;
    }
    
    try {
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': _windowsClientId,
          'client_secret': _windowsClientSecret,
          'refresh_token': credentials.refreshToken,
          'grant_type': 'refresh_token',
        },
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final accessToken = data['access_token'];
        final expiresIn = data['expires_in'] ?? 3600;
        final newTokenExpiry = DateTime.now().toUtc().add(Duration(seconds: expiresIn));
        
        // Create updated credentials with new access token
        final updatedCredentials = AccessCredentials(
          AccessToken('Bearer', accessToken, newTokenExpiry),
          credentials.refreshToken, // Keep the same refresh token
          <String>[],
        );
        
        // Update account in Hive
        final newCredentialsJson = _serializeCredentials(updatedCredentials);
        final updatedAccount = CloudAccount(
          id: account.id,
          provider: account.provider,
          name: account.name,
          email: account.email,
          credentials: newCredentialsJson,
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
  
  /// Serialize AccessCredentials to JSON string
  String _serializeCredentials(AccessCredentials credentials) {
    return jsonEncode({
      'accessToken': credentials.accessToken.data,
      'accessTokenExpiry': credentials.accessToken.expiry.toIso8601String(),
      'refreshToken': credentials.refreshToken,
    });
  }
  
  /// Deserialize JSON string to AccessCredentials
  static AccessCredentials? _deserializeCredentials(String credentialsJson) {
    try {
      final json = jsonDecode(credentialsJson);
      final expiry = DateTime.parse(json['accessTokenExpiry']).toUtc();
      final accessToken = AccessToken(
        'Bearer',
        json['accessToken'],
        expiry,
      );
      
      return AccessCredentials(
        accessToken,
        json['refreshToken'],
        <String>[], // idToken is not needed for our use case
      );
    } catch (e) {
      return null;
    }
  }
  
  /// Sign out a specific account (remove stored credentials)
  Future<void> signOutAccount(String accountId) async {
    final account = await HiveStorageService.instance.getAccount(accountId);
    if (account == null) return;
    
    // For Android, we need to sign out from GoogleSignIn too
    if (Platform.isAndroid) {
      final googleSignIn = GoogleSignIn(scopes: _scopes);
      await googleSignIn.signOut();
    }
    
    // Note: We don't delete the account from Hive here as the file system
    // nodes may still reference it. The app should handle account removal separately.
  }
  
  /// Sign out all Google Drive accounts
  Future<void> signOutAll() async {
    final accounts = await HiveStorageService.instance.getAccounts();
    for (final account in accounts) {
      if (account.provider == 'gdrive') {
        await signOutAccount(account.id);
      }
    }
    
    // Clear GoogleSignIn on Android
    if (Platform.isAndroid) {
      final googleSignIn = GoogleSignIn(scopes: _scopes);
      await googleSignIn.signOut();
    }
  }
}

/// Simple AuthClient wrapper that uses stored credentials
/// This avoids triggering a new login flow
class _SimpleAuthClient extends AuthClient {
  AccessCredentials _credentials; // Made mutable so we can update it
  final http.Client _baseClient;
  final String? _accountId; // Account ID for refreshing tokens
  final String? _quotaUser; // quotaUser parameter for better quota tracking
  
  _SimpleAuthClient(this._credentials, [this._accountId]) :
    _baseClient = http.Client(),
    _quotaUser = _accountId; // Use account ID as quotaUser for better tracking
  
  @override
  AccessCredentials get credentials => _credentials;
  
  /// Check if token needs refresh (expires within 5 minutes)
  bool _needsRefresh() {
    return _credentials.accessToken.expiry.isBefore(DateTime.now().add(Duration(minutes: 5)));
  }
  
  /// Ensure token is fresh, refresh if needed
  Future<void> _ensureFreshToken() async {
    if (_needsRefresh() && _accountId != null && _credentials.refreshToken != null) {
      
      final refreshSuccess = await GoogleAuthManager.instance.refreshCredentialsForAccount(_accountId!);
      
      if (refreshSuccess) {
        // Get the updated credentials from storage
        final account = await HiveStorageService.instance.getAccount(_accountId!);
        if (account?.credentials != null) {
          final updatedCredentials = GoogleAuthManager._deserializeCredentials(account!.credentials!);
          if (updatedCredentials != null) {
            _credentials = updatedCredentials;
          }
        }
      } else {
      }
    }
  }
  
  @override
  Future<AccessCredentials> obtainAccessCredentials(
    ClientId clientId,
    List<String> scopes,
    String user,
  ) async {
    return _credentials;
  }
  
  @override
  Future<AccessCredentials> obtainAccessCredentialsViaUserConsent(
    ClientId clientId,
    List<String> scopes,
    PromptUserForConsent userPrompt,
  ) async {
    return _credentials;
  }
  
  @override
  Future<AccessCredentials> refreshCredentials(
    ClientId clientId,
    AccessCredentials credentials,
  ) async {
    await _ensureFreshToken();
    return _credentials;
  }
  
  @override
  void close() {
    _baseClient.close();
  }
  
  /// Helper method to add Authorization header and quotaUser to requests
  Map<String, String> _addAuthHeader(Map<String, String>? headers) {
    final authHeaders = <String, String>{};
    if (headers != null) {
      authHeaders.addAll(headers);
    }
    authHeaders['Authorization'] = 'Bearer ${_credentials.accessToken.data}';
    
    // Add quotaUser parameter for better quota tracking per account
    // This helps Google distinguish between different users even from same IP
    if (_quotaUser != null) {
      authHeaders['X-Goog-Api-Client'] = 'quotaUser=$_quotaUser';
    }
    
    return authHeaders;
  }
  
  // Implement Client interface methods with automatic token refresh
  @override
  Future<http.Response> head(Uri url, {Map<String, String>? headers}) async {
    await _ensureFreshToken();
    return _baseClient.head(url, headers: _addAuthHeader(headers));
  }
  
  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    await _ensureFreshToken();
    return _baseClient.get(url, headers: _addAuthHeader(headers));
  }
  
  @override
  Future<http.Response> post(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    await _ensureFreshToken();
    return _baseClient.post(url, headers: _addAuthHeader(headers), body: body, encoding: encoding);
  }
  
  @override
  Future<http.Response> put(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    await _ensureFreshToken();
    return _baseClient.put(url, headers: _addAuthHeader(headers), body: body, encoding: encoding);
  }
  
  @override
  Future<http.Response> patch(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    await _ensureFreshToken();
    return _baseClient.patch(url, headers: _addAuthHeader(headers), body: body, encoding: encoding);
  }
  
  @override
  Future<http.Response> delete(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    await _ensureFreshToken();
    return _baseClient.delete(url, headers: _addAuthHeader(headers), body: body, encoding: encoding);
  }
  
  @override
  Future<String> read(Uri url, {Map<String, String>? headers}) async {
    await _ensureFreshToken();
    return _baseClient.read(url, headers: _addAuthHeader(headers));
  }
  
  @override
  Future<Uint8List> readBytes(Uri url, {Map<String, String>? headers}) async {
    await _ensureFreshToken();
    return _baseClient.readBytes(url, headers: _addAuthHeader(headers));
  }
  
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await _ensureFreshToken();
    // Add Authorization header to the request
    request.headers['Authorization'] = 'Bearer ${_credentials.accessToken.data}';
    return _baseClient.send(request);
  }
}