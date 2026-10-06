import 'dart:io';
import 'ytdlp_models.dart';
import 'linux_ytdlp.dart';
import 'android_ytdlp.dart';

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
  /// Automatically selects [AndroidYtDlpService] on Android (using Chaquopy)
  /// and [LinuxYtDlpService] on Linux/Desktop, but can be swapped with [TestYtDlpService] in tests.
  static YtDlpService instance = Platform.isAndroid
      ? AndroidYtDlpService()
      : LinuxYtDlpService();
}
