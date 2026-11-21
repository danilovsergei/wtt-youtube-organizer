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
        LogService.instance.log('[PROXY] Cached host unavailable; starting discovery...');
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

  /// Manually configure or override the server address.
  Future<bool> setCustomServer(String host, int port) async {
    final cleanHost = host.trim();
    if (cleanHost.isEmpty) return false;

    LogService.instance.log('[PROXY] Testing custom server: http://$cleanHost:$port/health');
    try {
      final url = Uri.parse('http://$cleanHost:$port/health');
      final client = http.Client();
      final response = await client.get(url).timeout(const Duration(milliseconds: 1500));
      client.close();

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['service'] == 'wtt-stream-proxy') {
          _serverHost = cleanHost;
          _serverHttpPort = port;
          _serverInstanceId = data['instance_id'] as String?;
          _serverHostname = data['hostname'] as String?;
          _isVerifiedOnLAN = true;

          await SettingsService.instance.saveStreamProxyConfig(
            host: _serverHost!,
            port: _serverHttpPort,
            instanceId: _serverInstanceId,
          );

          LogService.instance.log('[PROXY] Successfully verified and saved custom server: $_serverHost:$_serverHttpPort');
          notifyListeners();
          return true;
        }
      }
    } catch (e) {
      LogService.instance.log('[PROXY] Failed to connect to custom server: $e');
    }

    return false;
  }

  /// Discovers the WTT stream proxy using UDP broadcast followed by fast subnet probing.
  Future<bool> discoverServer({Duration timeout = const Duration(milliseconds: 1200)}) async {
    if (kIsWeb) return false;

    // 1. Try UDP broadcast discovery
    final udpFound = await _discoverViaUDP(timeout);
    if (udpFound) return true;

    // 2. If UDP was dropped by Wi-Fi router AP isolation, fallback to fast subnet HTTP probing
    LogService.instance.log('[PROXY] UDP broadcast yielded no response, falling back to subnet HTTP scan...');
    return await _probeSubnetFast();
  }

  Future<bool> _discoverViaUDP(Duration timeout) async {
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

      // Send to 255.255.255.255
      socket.send(pingBytes, InternetAddress('255.255.255.255'), 8081);

      // Send to subnet broadcasts
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
      } catch (_) {}

      Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.complete(false);
        }
        socket.close();
      });

      return await completer.future;
    } catch (e) {
      LogService.instance.log('[PROXY] UDP socket error: $e');
      return false;
    }
  }

  /// Fast parallel HTTP probing across candidate IPs (handles Wi-Fi AP isolation).
  Future<bool> _probeSubnetFast() async {
    final candidateHosts = <String>{
      '192.168.31.49', // Geonix desktop
      '192.168.31.2',  // OMV server
      '127.0.0.1',
    };

    // Add local interface subnet IPs
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4 && parts[0] == '192' && parts[1] == '168') {
            final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
            for (int i = 1; i <= 60; i++) {
              candidateHosts.add('$prefix.$i');
            }
          }
        }
      }
    } catch (_) {}

    final client = http.Client();
    final completer = Completer<bool>();

    // Test ports 8080 and 8085
    for (final host in candidateHosts) {
      for (final port in [8080, 8085]) {
        final url = Uri.parse('http://$host:$port/health');
        client.get(url).timeout(const Duration(milliseconds: 350)).then((response) {
          if (response.statusCode == 200 && !completer.isCompleted) {
            try {
              final data = jsonDecode(response.body) as Map<String, dynamic>;
              if (data['service'] == 'wtt-stream-proxy') {
                _serverHost = host;
                _serverHttpPort = port;
                _serverInstanceId = data['instance_id'] as String?;
                _serverHostname = data['hostname'] as String?;
                _isVerifiedOnLAN = true;

                LogService.instance.log('[PROXY] Found server via HTTP subnet scan: $_serverHost:$_serverHttpPort ($_serverHostname)');

                SettingsService.instance.saveStreamProxyConfig(
                  host: _serverHost!,
                  port: _serverHttpPort,
                  instanceId: _serverInstanceId,
                );

                notifyListeners();
                completer.complete(true);
              }
            } catch (_) {}
          }
        }).catchError((_) {});
      }
    }

    Timer(const Duration(milliseconds: 800), () {
      if (!completer.isCompleted) {
        client.close();
        completer.complete(false);
      }
    });

    final success = await completer.future;
    return success;
  }

  /// Ultra-fast LAN health probe (400ms timeout).
  Future<bool> verifyOnHomeNetwork({Duration timeout = const Duration(milliseconds: 400)}) async {
    if (kIsWeb) return false;
    if (_serverHost == null || _serverHost!.isEmpty) {
      final discovered = await discoverServer();
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
            LogService.instance.log('[PROXY] Server instance ID mismatch');
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
    } catch (_) {}

    if (_isVerifiedOnLAN) {
      _isVerifiedOnLAN = false;
      notifyListeners();
    }
    return false;
  }

  Future<bool> isProxyActiveAndAvailable() async {
    if (!_isAutoDiscoveryEnabled) return false;
    return await verifyOnHomeNetwork();
  }

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
