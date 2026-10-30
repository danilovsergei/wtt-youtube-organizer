import 'package:flutter/widgets.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../data/prod_database.dart';
import 'log_service.dart';

class PairingSession {
  final String sessionId;
  final String code;
  final String secretToken;
  final String deviceName;
  final DateTime expiresAt;

  PairingSession({
    required this.sessionId,
    required this.code,
    required this.secretToken,
    required this.deviceName,
    required this.expiresAt,
  });
}

class PairingInfo {
  final bool isValid;
  final String? deviceName;
  final String? error;

  PairingInfo({
    required this.isValid,
    this.deviceName,
    this.error,
  });
}

class DevicePairingService {
  static final DevicePairingService instance = DevicePairingService._();
  DevicePairingService._();

  @visibleForTesting
  String? customRpcBaseUrl;

  String get _rpcBaseUrl =>
      customRpcBaseUrl ?? '${ProdDatabaseService.supabaseUrl}/rest/v1/rpc';

  Map<String, String> get _headers => {
        'apikey': ProdDatabaseService.supabasePublishableKey,
        'Authorization': 'Bearer ${ProdDatabaseService.supabasePublishableKey}',
        'Content-Type': 'application/json',
      };

  String _generateSecretToken() {
    final rand = Random.secure();
    final bytes = List<int>.generate(32, (_) => rand.nextInt(256));
    return base64UrlEncode(bytes);
  }

  static bool isTvMode(BuildContext context) {
    const isTvDefined = bool.fromEnvironment('IS_TV', defaultValue: false);
    if (isTvDefined) return true;
    if (!kIsWeb && Platform.isAndroid) {
      final size = MediaQuery.of(context).size;
      if (size.width >= 960 && size.height >= 500) {
        return true;
      }
    }
    return false;
  }

  String get defaultDeviceName {
    const isTvDefined = bool.fromEnvironment('IS_TV', defaultValue: false);
    if (isTvDefined) return 'Android TV';
    if (kIsWeb) return 'Web Browser';
    if (Platform.isAndroid) return 'Android Phone';
    if (Platform.isLinux) return 'Linux Desktop';
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isIOS) return 'iPhone/iPad';
    return 'WTT Client';
  }

  /// Creates a new pairing session for this device (e.g. Android TV).
  Future<PairingSession?> createPairingSession({String? deviceName}) async {
    final name = deviceName ?? defaultDeviceName;
    final secretToken = _generateSecretToken();

    try {
      final res = await http.post(
        Uri.parse('$_rpcBaseUrl/create_device_pairing'),
        headers: _headers,
        body: jsonEncode({
          'p_device_name': name,
          'p_secret_token': secretToken,
        }),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return PairingSession(
          sessionId: data['session_id'],
          code: data['code'],
          secretToken: secretToken,
          deviceName: name,
          expiresAt: DateTime.parse(data['expires_at']),
        );
      } else {
        LogService.instance.log('[PAIRING] Failed to create pairing session: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      LogService.instance.log('[PAIRING] Error creating pairing session: $e');
    }
    return null;
  }

  /// Polls the pairing session until claimed or expired.
  Future<Map<String, dynamic>?> pollForClaim(
    PairingSession session, {
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final startTime = DateTime.now();

    while (DateTime.now().difference(startTime) < timeout) {
      try {
        final res = await http.post(
          Uri.parse('$_rpcBaseUrl/claim_device_pairing'),
          headers: _headers,
          body: jsonEncode({
            'p_session_id': session.sessionId,
            'p_secret_token': session.secretToken,
          }),
        );

        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final status = data['status'];
          if (status == 'claimed' && data['payload'] != null) {
            LogService.instance.log('[PAIRING] Received pairing payload successfully!');
            return Map<String, dynamic>.from(data['payload']);
          } else if (status == 'expired') {
            LogService.instance.log('[PAIRING] Pairing session expired.');
            return null;
          }
        }
      } catch (e) {
        LogService.instance.log('[PAIRING] Poll error: $e');
      }

      await Future.delayed(interval);
    }
    return null;
  }

  /// Facilitating device checks code validity and target device name.
  Future<PairingInfo> getPairingInfo(String code) async {
    final cleanCode = code.replaceAll(RegExp(r'\D'), '');
    if (cleanCode.length != 6) {
      return PairingInfo(isValid: false, error: 'Code must be 6 digits');
    }

    try {
      final res = await http.post(
        Uri.parse('$_rpcBaseUrl/get_device_pairing_info'),
        headers: _headers,
        body: jsonEncode({'p_code': cleanCode}),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['valid'] == true) {
          return PairingInfo(
            isValid: true,
            deviceName: data['device_name'],
          );
        } else {
          return PairingInfo(isValid: false, error: data['error'] ?? 'Invalid code');
        }
      }
    } catch (e) {
      return PairingInfo(isValid: false, error: 'Network error: $e');
    }
    return PairingInfo(isValid: false, error: 'Could not verify code');
  }

  /// Facilitating device pushes pairing payload (e.g. Cloud Sync credentials).
  Future<bool> fulfillPairing(String code, Map<String, dynamic> payload) async {
    final cleanCode = code.replaceAll(RegExp(r'\D'), '');
    try {
      final res = await http.post(
        Uri.parse('$_rpcBaseUrl/fulfill_device_pairing'),
        headers: _headers,
        body: jsonEncode({
          'p_code': cleanCode,
          'p_payload': payload,
        }),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data['success'] == true;
      }
    } catch (e) {
      LogService.instance.log('[PAIRING] Error fulfilling pairing: $e');
    }
    return false;
  }
}
