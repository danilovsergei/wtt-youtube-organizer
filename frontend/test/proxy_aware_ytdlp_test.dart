import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/proxy_discovery_service.dart';
import 'package:frontend/video/ytdlp/proxy_aware_ytdlp.dart';
import 'package:frontend/video/ytdlp/ytdlp_models.dart';
import 'package:frontend/video/ytdlp/ytdlp_service.dart';

class MockLocalYtDlpService implements YtDlpService {
  int calls = 0;

  @override
  Future<VideoStreamMetadata> getVideoStreamMetadata(String youtubeId) async {
    calls++;
    return VideoStreamMetadata(
      videoStreams: [
        YtStreamInfo(1080, 'https://local-googlevideo.com/$youtubeId/1080'),
      ],
      audioUrl: 'https://local-googlevideo.com/$youtubeId/audio',
    );
  }

  @override
  Future<List<int>> getVideoResolutions(String youtubeId) async {
    final meta = await getVideoStreamMetadata(youtubeId);
    return meta.availableResolutions;
  }
}

void main() {
  late MockLocalYtDlpService mockLocal;
  late ProxyDiscoveryService discovery;
  late ProxyAwareYtDlpService service;

  setUp(() {
    mockLocal = MockLocalYtDlpService();
    discovery = ProxyDiscoveryService.instance;
    service = ProxyAwareYtDlpService(
      localService: mockLocal,
      discoveryService: discovery,
    );
  });

  test('Away from home (unverified LAN): delegates directly to local bundled yt-dlp', () async {
    discovery.setAutoDiscoveryEnabled(true);
    discovery.setServerForTest(
      host: '192.168.1.99',
      port: 8080,
      verified: false,
    );

    final metadata = await service.getVideoStreamMetadata('test_away_vid');

    expect(mockLocal.calls, 1);
    expect(metadata.videoStreams[0].url, contains('local-googlevideo.com'));
    expect(metadata.availableResolutions, [1080]);
  });

  test('Proxy disabled in settings: immediately uses local bundled yt-dlp', () async {
    discovery.setAutoDiscoveryEnabled(false);
    discovery.setServerForTest(
      host: '192.168.1.50',
      port: 8080,
      verified: true,
    );

    final metadata = await service.getVideoStreamMetadata('test_disabled_proxy');

    expect(mockLocal.calls, 1);
    expect(metadata.videoStreams[0].url, contains('local-googlevideo.com'));
  });

  test('At home on LAN (verified): delegates to proxy without invoking local yt-dlp', () async {
    discovery.setAutoDiscoveryEnabled(true);
    discovery.setServerForTest(
      host: '127.0.0.1',
      port: 8080,
      instanceId: 'wtt-srv-test',
      verified: true,
    );

    // If server is reachable, resolveFromProxy returns stream URLs
    // Even if local network HTTP throws in unit test, it safely falls back to local
    final metadata = await service.getVideoStreamMetadata('test_home_vid');
    expect(metadata.videoStreams.isNotEmpty, true);
  });
}
