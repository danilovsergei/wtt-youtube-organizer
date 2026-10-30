import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/device_pairing_service.dart';

void main() {
  group('DevicePairingService Unit Tests', () {
    late HttpServer server;
    late int port;
    late String mockBaseUrl;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      mockBaseUrl = 'http://127.0.0.1:$port';
      DevicePairingService.instance.customRpcBaseUrl = mockBaseUrl;
    });

    tearDown(() async {
      await server.close(force: true);
      DevicePairingService.instance.customRpcBaseUrl = null;
    });

    test('createPairingSession issues RPC and returns PairingSession model', () async {
      server.listen((HttpRequest request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/create_device_pairing')) {
          final body = await utf8.decodeStream(request);
          final map = jsonDecode(body);
          expect(map['p_device_name'], 'Living Room TV');
          expect(map['p_secret_token'], isNotEmpty);

          request.response.write(jsonEncode({
            'session_id': 'uuid-1234',
            'code': '842910',
            'device_name': 'Living Room TV',
            'expires_at': DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
          }));
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });

      final session = await DevicePairingService.instance.createPairingSession(
        deviceName: 'Living Room TV',
      );

      expect(session, isNotNull);
      expect(session!.sessionId, 'uuid-1234');
      expect(session.code, '842910');
      expect(session.deviceName, 'Living Room TV');
      expect(session.expiresAt.isAfter(DateTime.now()), isTrue);
    });

    test('getPairingInfo validates code formatting and handles RPC responses', () async {
      // 1. Invalid short code
      final invalid = await DevicePairingService.instance.getPairingInfo('123');
      expect(invalid.isValid, isFalse);
      expect(invalid.error, contains('6 digits'));

      // 2. Valid code lookup
      server.listen((HttpRequest request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/get_device_pairing_info')) {
          final body = await utf8.decodeStream(request);
          final map = jsonDecode(body);
          if (map['p_code'] == '123456') {
            request.response.write(jsonEncode({
              'valid': true,
              'device_name': 'Android TV (Living Room)',
            }));
          } else {
            request.response.write(jsonEncode({
              'valid': false,
              'error': 'Code not found',
            }));
          }
        }
        await request.response.close();
      });

      final valid = await DevicePairingService.instance.getPairingInfo('123456');
      expect(valid.isValid, isTrue);
      expect(valid.deviceName, 'Android TV (Living Room)');

      final notFound = await DevicePairingService.instance.getPairingInfo('999999');
      expect(notFound.isValid, isFalse);
      expect(notFound.error, 'Code not found');
    });

    test('fulfillPairing and pollForClaim transfer credentials end-to-end', () async {
      bool fulfilled = false;
      server.listen((HttpRequest request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/fulfill_device_pairing')) {
          final body = await utf8.decodeStream(request);
          final map = jsonDecode(body);
          expect(map['p_code'], '654321');
          expect(map['p_payload']['project_url'], 'https://user.supabase.co');
          fulfilled = true;
          request.response.write(jsonEncode({'success': true}));
        } else if (request.uri.path.endsWith('/claim_device_pairing')) {
          if (fulfilled) {
            request.response.write(jsonEncode({
              'status': 'claimed',
              'payload': {
                'action': 'cloud_sync',
                'project_url': 'https://user.supabase.co',
                'anon_key': 'key_abc',
                'project_ref': 'ref_xyz',
              },
            }));
          } else {
            request.response.write(jsonEncode({'status': 'pending'}));
          }
        }
        await request.response.close();
      });

      final session = PairingSession(
        sessionId: 'session_1',
        code: '654321',
        secretToken: 'secret_tok',
        deviceName: 'TV',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );

      // Start fulfilling from facilitating device
      final ok = await DevicePairingService.instance.fulfillPairing('654-321', {
        'action': 'cloud_sync',
        'project_url': 'https://user.supabase.co',
        'anon_key': 'key_abc',
        'project_ref': 'ref_xyz',
      });
      expect(ok, isTrue);

      // Poll from TV
      final payload = await DevicePairingService.instance.pollForClaim(
        session,
        interval: const Duration(milliseconds: 50),
        timeout: const Duration(seconds: 1),
      );

      expect(payload, isNotNull);
      expect(payload!['project_url'], 'https://user.supabase.co');
      expect(payload['anon_key'], 'key_abc');
      expect(payload['project_ref'], 'ref_xyz');
    });
  });
}
