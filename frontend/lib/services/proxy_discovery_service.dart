import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../video/ytdlp/ytdlp_models.dart';

class ProxyDiscoveryService extends ChangeNotifier {
  static final ProxyDiscoveryService instance = ProxyDiscoveryService._();
  ProxyDiscoveryService._();

  bool _isAutoDiscoveryEnabled = true;
  String? _serverHost;
  int _serverHttpPort = 8080;
  String? _serverInstanceId;
  String? _serverHostname;
  bool _isVerifiedOnLAN = false;

  bool get isAutoDiscoveryEnabled => _isAutoDiscoveryEnabled;
  String? get serverHost => _serverHost;
  int get serverHttpPort => _serverHttpPort;
  String? get serverHostname => _serverHostname;
  bool get isVerifiedOnLAN => _isVerifiedOnLAN;

  @visibleForTesting
  void setServerForTest({
    required String host,
    required int port,
    String? instanceId,
    String? hostname,
    bool verified = true,
  }) {
    _serverHost = host;
    _serverHttpPort = port;
    _serverInstanceId = instanceId;
    _serverHostname = hostname;
    _isVerifiedOnLAN = verified;
  }

  /// Performs a UDP broadcast to discover the WTT stream proxy on port 8081.
  Future<bool> discoverServer({Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (kIsWeb) return false;
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      final completer = Completer<bool>();
      final pingBytes = utf8.encode('WTT_PROXY_DISCOVERY_PING');

      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) {
            try {
              final jsonStr = utf8.decode(datagram.data);
              final data = jsonDecode(jsonStr) as Map<String, dynamic>;
              if (data['service'] == 'wtt-stream-proxy') {
                _serverHost = datagram.address.address;
                _serverHttpPort = data['http_port'] as int? ?? 8080;
                _serverInstanceId = data['instance_id'] as String?;
                _serverHostname = data['hostname'] as String?;
                _isVerifiedOnLAN = true;
                notifyListeners();
                if (!completer.isCompleted) {
                  completer.complete(true);
                }
              }
            } catch (_) {}
          }
        }
      });

      socket.send(pingBytes, InternetAddress('255.255.255.255'), 8081);

      Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.complete(false);
        }
        socket.close();
      });

      return await completer.future;
    } catch (e) {
      debugPrint('UDP discovery error: $e');
      return false;
    }
  }

  /// Ultra-fast LAN health probe (300ms timeout).
  /// Returns true only if we are currently on the home LAN with the server.
  Future<bool> verifyOnHomeNetwork({Duration timeout = const Duration(milliseconds: 300)}) async {
    if (kIsWeb) return false;
    if (_serverHost == null || _serverHost!.isEmpty) {
      final discovered = await discoverServer(timeout: const Duration(milliseconds: 800));
      if (!discovered || _serverHost == null) {
        _isVerifiedOnLAN = false;
        return false;
      }
    }

    try {
      final url = Uri.parse('http://$_serverHost:$_serverHttpPort/health');
      final client = http.Client();
      final response = await client.get(url).timeout(timeout);
      client.close();

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['service'] == 'wtt-stream-proxy') {
          if (_serverInstanceId != null && data['instance_id'] != _serverInstanceId) {
            _isVerifiedOnLAN = false;
            return false;
          }
          _serverInstanceId ??= data['instance_id'] as String?;
          _serverHostname ??= data['hostname'] as String?;
          if (!_isVerifiedOnLAN) {
            _isVerifiedOnLAN = true;
            notifyListeners();
          }
          return true;
        }
      }
    } catch (_) {
      // Unreachable, timeout, or wrong network
    }

    _isVerifiedOnLAN = false;
    return false;
  }

  /// Checks if proxy should be used for playback.
  Future<bool> isProxyActiveAndAvailable() async {
    if (!_isAutoDiscoveryEnabled) return false;
    return await verifyOnHomeNetwork();
  }

  /// Fetches resolved stream metadata from the proxy.
  Future<VideoStreamMetadata> resolveFromProxy(String youtubeId) async {
    final url = Uri.parse('http://$_serverHost:$_serverHttpPort/api/resolve/$youtubeId');
    final response = await http.get(url).timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) {
      throw Exception('Proxy returned status ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final streamsJson = (data['videoStreams'] as List<dynamic>?) ?? [];
    final videoStreams = streamsJson.map((item) {
      final m = item as Map<String, dynamic>;
      return YtStreamInfo(m['height'] as int, m['url'] as String);
    }).toList();

    final audioUrl = data['audioUrl'] as String?;
    final headersMap = (data['httpHeaders'] as Map<String, dynamic>?) ?? {};
    final httpHeaders = headersMap.map((k, v) => MapEntry(k, v.toString()));

    return VideoStreamMetadata(
      videoStreams: videoStreams,
      audioUrl: audioUrl,
      httpHeaders: httpHeaders,
    );
  }

  void setAutoDiscoveryEnabled(bool enabled) {
    _isAutoDiscoveryEnabled = enabled;
    notifyListeners();
  }
}
