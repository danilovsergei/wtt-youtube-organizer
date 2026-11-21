import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';
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
        '[PROXY] Initialized: enabled=$_isAutoDiscoveryEnabled, cachedHost=$_serverHost:$_serverHttpPort',
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

        // If cached host failed or wasn't present, run Chromecast-standard mDNS discovery
        LogService.instance.log('[PROXY] Starting Chromecast-standard mDNS discovery...');
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

  /// Discovers the WTT stream proxy using standard Chromecast mDNS (Multicast DNS on 224.0.0.251:5353).
  Future<bool> discoverServer({Duration timeout = const Duration(seconds: 3)}) async {
    if (kIsWeb) return false;

    // 1. Primary: Chromecast-standard mDNS
    final mdnsFound = await discoverViaMDNS(timeout: timeout);
    if (mdnsFound) return true;

    // 2. Secondary: UDP Broadcast
    LogService.instance.log('[PROXY] mDNS yielded no response, checking UDP broadcast...');
    return await _discoverViaUDP(const Duration(milliseconds: 1000));
  }

  /// Performs mDNS lookup for _wtt-proxy._tcp.local
  Future<bool> discoverViaMDNS({Duration timeout = const Duration(seconds: 3)}) async {
    final MDnsClient client = MDnsClient();
    try {
      await client.start();

      await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer('_wtt-proxy._tcp.local'),
      ).timeout(timeout, onTimeout: (sink) => sink.close())) {
        
        LogService.instance.log('[PROXY] mDNS found PTR: ${ptr.domainName}');

        await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
        ).timeout(const Duration(seconds: 1), onTimeout: (sink) => sink.close())) {
          
          LogService.instance.log('[PROXY] mDNS found SRV: target=${srv.target}, port=${srv.port}');

          await for (final IPAddressResourceRecord a in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
          ).timeout(const Duration(seconds: 1), onTimeout: (sink) => sink.close())) {
            
            final resolvedIp = a.address.address;
            if (!resolvedIp.startsWith('127.') && !resolvedIp.startsWith('172.17.')) {
              _serverHost = resolvedIp;
              _serverHttpPort = srv.port;
              _serverHostname = srv.target;
              _isVerifiedOnLAN = true;

              LogService.instance.log(
                '[PROXY] ✅ Discovered via Chromecast mDNS: $_serverHost:$_serverHttpPort ($_serverHostname)',
              );

              SettingsService.instance.saveStreamProxyConfig(
                host: _serverHost!,
                port: _serverHttpPort,
              );

              notifyListeners();
              return true;
            }
          }
        }
      }
    } catch (e) {
      LogService.instance.log('[PROXY] mDNS discovery warning: $e');
    } finally {
      client.stop();
    }

    return false;
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
                  '[PROXY] Discovered proxy via UDP at $_serverHost:$_serverHttpPort',
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
      return false;
    }
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
