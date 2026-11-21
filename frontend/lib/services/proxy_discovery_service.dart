import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../video/ytdlp/ytdlp_models.dart';
import 'log_service.dart';
import 'settings_service.dart';

class ProxyDiscoveryService extends ChangeNotifier {
  static final ProxyDiscoveryService instance = ProxyDiscoveryService._();
  ProxyDiscoveryService._();

  bool _isAutoDiscoveryEnabled = true;
  String? _serverHost;
  int _serverHttpPort = 8080;
  String? _serverInstanceId;
  String? _serverHostname;
  bool _isVerifiedOnLAN = false;
  bool _isInitializing = false;

  bool get isAutoDiscoveryEnabled => _isAutoDiscoveryEnabled;
  String? get serverHost => _serverHost;
  int get serverHttpPort => _serverHttpPort;
  String? get serverHostname => _serverHostname;
  bool get isVerifiedOnLAN => _isVerifiedOnLAN;

  /// Initializes the service by reading saved config and probing the LAN.
  Future<void> initialize() async {
    if (kIsWeb || _isInitializing) return;
    _isInitializing = true;

    try {
      _isAutoDiscoveryEnabled = await SettingsService.instance.loadStreamProxyEnabled();
      _serverHost = await SettingsService.instance.loadStreamProxyHost();
      _serverHttpPort = await SettingsService.instance.loadStreamProxyPort();
      _serverInstanceId = await SettingsService.instance.loadStreamProxyInstanceId();

      LogService.instance.log(
        '[PROXY] Initialized: enabled=$_isAutoDiscoveryEnabled, cachedHost=$_serverHost:$_serverHttpPort, instance=$_serverInstanceId',
      );

      if (_isAutoDiscoveryEnabled) {
        // Fast probe cached host first
        if (_serverHost != null && _serverHost!.isNotEmpty) {
          final isReachable = await verifyOnHomeNetwork(timeout: const Duration(milliseconds: 400));
          if (isReachable) {
            LogService.instance.log('[PROXY] Verified cached server $_serverHost:$_serverHttpPort on home LAN!');
            return;
          }
        }

        // If cached host failed or wasn't present, run discovery
        LogService.instance.log('[PROXY] Cached host unavailable; starting UDP broadcast discovery...');
        await discoverServer();
      }
    } catch (e) {
      LogService.instance.log('[PROXY] Initialization error: $e');
    } finally {
      _isInitializing = false;
    }
  }

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

                LogService.instance.log(
                  '[PROXY] Discovered proxy at $_serverHost:$_serverHttpPort ($_serverHostname, $_serverInstanceId)',
                );

                // Persist config for instant reconnection
                SettingsService.instance.saveStreamProxyConfig(
                  host: _serverHost!,
                  port: _serverHttpPort,
                  instanceId: _serverInstanceId,
                );

                notifyListeners();
                if (!completer.isCompleted) {
                  completer.complete(true);
                }
              }
            } catch (e) {
              LogService.instance.log('[PROXY] Malformed discovery response: $e');
            }
          }
        }
      });

      // 1. Send to global broadcast 255.255.255.255
      socket.send(pingBytes, InternetAddress('255.255.255.255'), 8081);

      // 2. Send to specific subnet broadcast addresses (fixes Flatpak / multi-interface routing)
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              final subnetBrd = '${parts[0]}.${parts[1]}.${parts[2]}.255';
              socket.send(pingBytes, InternetAddress(subnetBrd), 8081);
            }
          }
        }
      } catch (e) {
        LogService.instance.log('[PROXY] Subnet enumeration warning: $e');
      }

      Timer(timeout, () {
        if (!completer.isCompleted) {
          LogService.instance.log('[PROXY] UDP discovery timed out without response');
          completer.complete(false);
        }
        socket.close();
      });

      final success = await completer.future;
      return success;
    } catch (e) {
      LogService.instance.log('[PROXY] UDP discovery socket error: $e');
      return false;
    }
  }

  /// Ultra-fast LAN health probe (400ms timeout).
  /// Returns true only if we are currently on the home LAN with the server.
  Future<bool> verifyOnHomeNetwork({Duration timeout = const Duration(milliseconds: 400)}) async {
    if (kIsWeb) return false;
    if (_serverHost == null || _serverHost!.isEmpty) {
      final discovered = await discoverServer(timeout: const Duration(milliseconds: 1000));
      if (!discovered || _serverHost == null) {
        _isVerifiedOnLAN = false;
        notifyListeners();
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
            LogService.instance.log('[PROXY] Server instance ID mismatch: expected $_serverInstanceId, got ${data['instance_id']}');
            _isVerifiedOnLAN = false;
            notifyListeners();
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
    } catch (e) {
      // Unreachable, timeout, or wrong network
    }

    if (_isVerifiedOnLAN) {
      _isVerifiedOnLAN = false;
      notifyListeners();
    }
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
    LogService.instance.log('[PROXY] Resolving stream via home proxy: $url');

    final response = await http.get(url).timeout(const Duration(seconds: 5));
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

    LogService.instance.log('[PROXY] Successfully resolved ${videoStreams.length} streams via home proxy for $youtubeId');

    return VideoStreamMetadata(
      videoStreams: videoStreams,
      audioUrl: audioUrl,
      httpHeaders: httpHeaders,
    );
  }

  void setAutoDiscoveryEnabled(bool enabled) {
    _isAutoDiscoveryEnabled = enabled;
    SettingsService.instance.saveStreamProxyEnabled(enabled);
    if (enabled) {
      verifyOnHomeNetwork();
    } else {
      _isVerifiedOnLAN = false;
      notifyListeners();
    }
  }
}
