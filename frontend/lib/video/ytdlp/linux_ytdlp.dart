import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'ytdlp_service.dart';

class LinuxYtDlpService implements YtDlpService {
  final String? customBinaryPath;

  const LinuxYtDlpService({this.customBinaryPath});

  /// Resolves the yt-dlp binary path on the system.
  String resolveBinaryPath() {
    if (customBinaryPath != null && File(customBinaryPath!).existsSync()) {
      return customBinaryPath!;
    }
    final dataHome = Platform.environment['XDG_DATA_HOME'];
    if (dataHome != null && File('$dataHome/yt-dlp/yt-dlp_linux').existsSync()) {
      return '$dataHome/yt-dlp/yt-dlp_linux';
    } else if (File('/app/bin/yt-dlp_linux').existsSync()) {
      return '/app/bin/yt-dlp_linux';
    } else if (File('/usr/local/bin/yt-dlp_linux').existsSync()) {
      return '/usr/local/bin/yt-dlp_linux';
    }
    return 'yt-dlp';
  }

  @override
  Future<VideoStreamMetadata> getVideoStreamMetadata(String youtubeId) async {
    final ytdlpPath = resolveBinaryPath();

    try {
      final versionResult = await Process.run(ytdlpPath, ['--version']);
      debugPrint('DIAGNOSTICS: yt-dlp binary path: $ytdlpPath');
      debugPrint('DIAGNOSTICS: yt-dlp version: ${versionResult.stdout.toString().trim()}');
    } catch (e) {
      debugPrint('Warning: Failed to query yt-dlp version: $e');
    }

    final result = await Process.run(ytdlpPath, [
      '-j',
      'https://www.youtube.com/watch?v=$youtubeId',
    ]);

    if (result.exitCode != 0) {
      throw ProcessException(
        ytdlpPath,
        ['-j', 'https://www.youtube.com/watch?v=$youtubeId'],
        'yt-dlp extraction failed: ${result.stderr}',
        result.exitCode,
      );
    }

    final manifest = jsonDecode(result.stdout) as Map<String, dynamic>;
    return parseManifest(manifest);
  }

  @override
  Future<List<int>> getVideoResolutions(String youtubeId) async {
    final metadata = await getVideoStreamMetadata(youtubeId);
    return metadata.availableResolutions;
  }

  /// Pure parsing logic: separated from Process.run for unit testability!
  static VideoStreamMetadata parseManifest(Map<String, dynamic> manifest) {
    final formats = (manifest['formats'] as List<dynamic>?) ?? [];

    // Extract adaptive video streams
    final videoFormats = formats.where((f) =>
      f is Map<String, dynamic> &&
      f['vcodec'] != 'none' &&
      f['acodec'] == 'none' &&
      f['height'] != null
    ).cast<Map<String, dynamic>>().toList();

    // Extract adaptive audio streams
    final audioFormats = formats.where((f) =>
      f is Map<String, dynamic> &&
      f['acodec'] != 'none' &&
      f['vcodec'] == 'none'
    ).cast<Map<String, dynamic>>().toList();

    if (videoFormats.isEmpty) {
      return const VideoStreamMetadata(videoStreams: []);
    }

    // Sort video by height descending (e.g. 1080p, 720p, 480p)
    videoFormats.sort((a, b) => ((b['height'] ?? 0) as int).compareTo((a['height'] ?? 0) as int));

    // Sort audio by ABR descending
    if (audioFormats.isNotEmpty) {
      audioFormats.sort((a, b) => ((b['abr'] ?? 0) as num).compareTo((a['abr'] ?? 0) as num));
    }

    final uniqueHeights = <int>{};
    final List<YtStreamInfo> uniqueStreams = [];

    for (final f in videoFormats) {
      final height = f['height'] as int;
      final url = f['url'] as String? ?? '';
      if (url.isNotEmpty && !uniqueHeights.contains(height)) {
        uniqueHeights.add(height);
        uniqueStreams.add(YtStreamInfo(height, url));
      }
    }

    final bestAudio = audioFormats.isNotEmpty ? audioFormats.first['url'] as String? : null;

    final mediaHeaders = <String, String>{
      'Referer': 'https://www.youtube.com/',
    };
    if (manifest['http_headers'] != null && manifest['http_headers']['User-Agent'] != null) {
      mediaHeaders['User-Agent'] = manifest['http_headers']['User-Agent']!.toString();
    }

    return VideoStreamMetadata(
      videoStreams: uniqueStreams,
      audioUrl: bestAudio,
      httpHeaders: mediaHeaders,
      rawManifest: manifest,
    );
  }
}
