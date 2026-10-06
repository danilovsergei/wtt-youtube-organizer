import 'ytdlp_models.dart';
import 'linux_ytdlp.dart';

export 'ytdlp_models.dart';

abstract class YtDlpService {
  /// Extracts available video/audio stream metadata for a given YouTube ID or URL.
  Future<VideoStreamMetadata> getVideoStreamMetadata(String youtubeId);

  /// Resolves available video resolutions (e.g. [1080, 720, 480]).
  Future<List<int>> getVideoResolutions(String youtubeId) async {
    final metadata = await getVideoStreamMetadata(youtubeId);
    return metadata.availableResolutions;
  }

  /// Active singleton/service instance.
  /// Defaults to [LinuxYtDlpService], but can be swapped with [TestYtDlpService]
  /// or platform-specific implementations (e.g. Android).
  static YtDlpService instance = LinuxYtDlpService();
}
