import 'ytdlp_models.dart';
import 'ytdlp_service.dart';
import '../../services/proxy_discovery_service.dart';

/// [ProxyAwareYtDlpService] delegates stream resolution to the local network proxy
/// when available and verified on the home LAN, seamlessly falling back to the bundled
/// local [YtDlpService] (Chaquopy on Android or native binary on Linux) when away.
class ProxyAwareYtDlpService implements YtDlpService {
  final YtDlpService localService;
  final ProxyDiscoveryService discoveryService;

  ProxyAwareYtDlpService({
    required this.localService,
    ProxyDiscoveryService? discoveryService,
  }) : discoveryService = discoveryService ?? ProxyDiscoveryService.instance;

  @override
  Future<VideoStreamMetadata> getVideoStreamMetadata(String youtubeId) async {
    // 1. If home proxy is available and verified on current LAN, resolve via proxy
    if (await discoveryService.isProxyActiveAndAvailable()) {
      try {
        final metadata = await discoveryService.resolveFromProxy(youtubeId);
        return metadata;
      } catch (e) {
        // Fallback gracefully to local yt-dlp on any proxy failure
      }
    }

    // 2. Default & away fallback: use local bundled yt-dlp
    return await localService.getVideoStreamMetadata(youtubeId);
  }

  @override
  Future<List<int>> getVideoResolutions(String youtubeId) async {
    final metadata = await getVideoStreamMetadata(youtubeId);
    return metadata.availableResolutions;
  }
}
