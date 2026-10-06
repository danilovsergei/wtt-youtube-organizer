import 'dart:convert';
import 'package:flutter/services.dart';
import 'linux_ytdlp.dart';
import 'ytdlp_service.dart';

class AndroidYtDlpService implements YtDlpService {
  static const MethodChannel _channel = MethodChannel('wtt/ytdlp');

  @override
  Future<VideoStreamMetadata> getVideoStreamMetadata(String youtubeId) async {
    final String? jsonString = await _channel.invokeMethod<String>(
      'getVideoStreamMetadata',
      {'youtubeId': youtubeId},
    );

    if (jsonString == null || jsonString.isEmpty) {
      throw PlatformException(
        code: 'EMPTY_MANIFEST',
        message: 'No metadata returned by Chaquopy yt-dlp for $youtubeId',
      );
    }

    final manifest = jsonDecode(jsonString) as Map<String, dynamic>;
    return LinuxYtDlpService.parseManifest(manifest);
  }

  @override
  Future<List<int>> getVideoResolutions(String youtubeId) async {
    final metadata = await getVideoStreamMetadata(youtubeId);
    return metadata.availableResolutions;
  }

  /// Triggers background pip upgrade of yt-dlp inside Chaquopy.
  Future<String> updateYtDlp() async {
    try {
      final status = await _channel.invokeMethod<String>('updateYtDlp');
      return status ?? 'UNKNOWN';
    } catch (e) {
      return 'FAILED: $e';
    }
  }

  /// Queries the current bundled yt-dlp version.
  Future<String> getYtDlpVersion() async {
    try {
      final version = await _channel.invokeMethod<String>('getYtDlpVersion');
      return version ?? 'UNKNOWN';
    } catch (e) {
      return 'UNKNOWN';
    }
  }
}
