import 'dart:io';
import 'ytdlp_service.dart';

class TestYtDlpService implements YtDlpService {
  final String? localVideoPath;
  final List<int> mockResolutions;
  final String? mockAudioUrl;
  final Map<String, String> mockHttpHeaders;
  final Map<String, VideoStreamMetadata> _customResponses = {};

  TestYtDlpService({
    this.localVideoPath,
    this.mockResolutions = const [1080, 720, 480, 360],
    this.mockAudioUrl,
    this.mockHttpHeaders = const {'User-Agent': 'Test-Agent', 'Referer': 'https://www.youtube.com/'},
  });

  /// Allows registering specific metadata for a specific YouTube ID in tests.
  void registerMockMetadata(String youtubeId, VideoStreamMetadata metadata) {
    _customResponses[youtubeId] = metadata;
  }

  /// Resolves the local video file path, checking common locations if not explicitly provided.
  String resolveLocalVideoPath() {
    if (localVideoPath != null && File(localVideoPath!).existsSync()) {
      return File(localVideoPath!).absolute.path;
    }
    // Check test assets
    const candidatePaths = [
      'test/assets/test_video.mp4',
      '../test_match_video.mp4',
      '/home/geonix/Build/wtt-youtube-organizer/frontend/test/assets/test_video.mp4',
      '/home/geonix/Build/wtt-youtube-organizer/test_match_video.mp4',
      '/app/test_match_video.mp4',
    ];
    for (final path in candidatePaths) {
      final f = File(path);
      if (f.existsSync()) {
        return f.absolute.path;
      }
    }
    return localVideoPath != null ? File(localVideoPath!).absolute.path : File('test/assets/test_video.mp4').absolute.path;
  }

  @override
  Future<VideoStreamMetadata> getVideoStreamMetadata(String youtubeId) async {
    if (_customResponses.containsKey(youtubeId)) {
      return _customResponses[youtubeId]!;
    }

    final videoPath = resolveLocalVideoPath();
    final videoStreams = mockResolutions.map((res) {
      // In local testing, all quality streams can point to the local file,
      // or to file:// URIs, allowing quality switching without network.
      return YtStreamInfo(res, videoPath);
    }).toList();

    return VideoStreamMetadata(
      videoStreams: videoStreams,
      audioUrl: mockAudioUrl,
      httpHeaders: mockHttpHeaders,
    );
  }

  @override
  Future<List<int>> getVideoResolutions(String youtubeId) async {
    final metadata = await getVideoStreamMetadata(youtubeId);
    return metadata.availableResolutions;
  }
}
