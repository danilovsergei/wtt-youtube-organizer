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

    bool isHlsFormat(Map<String, dynamic> f) {
      final p = (f['protocol'] ?? '').toString().toLowerCase();
      final url = (f['url'] ?? '').toString().toLowerCase();
      final fid = (f['format_id'] ?? '').toString();
      return p.contains('m3u8') || url.contains('m3u8') || url.contains('hls') || fid == '312' || fid == '617';
    }

    // 1. Strictly prefer direct HTTPS DASH video streams (avc1/mp4)
    final dashVideoFormats = formats.where((f) =>
      f is Map<String, dynamic> &&
      f['vcodec'] != 'none' &&
      f['acodec'] == 'none' &&
      f['height'] != null &&
      !isHlsFormat(f)
    ).cast<Map<String, dynamic>>().toList();

    // 2. Fall back to muxed or HLS streams only if no DASH formats are present
    final otherVideoFormats = formats.where((f) =>
      f is Map<String, dynamic> &&
      f['vcodec'] != 'none' &&
      f['height'] != null
    ).cast<Map<String, dynamic>>().toList();

    var videoFormats = dashVideoFormats.isNotEmpty ? dashVideoFormats : otherVideoFormats;

    // Extract adaptive audio streams (matching direct HTTPS DASH streams, avoiding DRC variants)
    var audioFormats = formats.where((f) =>
      f is Map<String, dynamic> &&
      f['acodec'] != 'none' &&
      f['vcodec'] == 'none' &&
      !isHlsFormat(f) &&
      !f['format_id'].toString().contains('drc')
    ).cast<Map<String, dynamic>>().toList();

    if (audioFormats.isEmpty) {
      audioFormats = formats.where((f) =>
        f is Map<String, dynamic> &&
        f['acodec'] != 'none' &&
        f['vcodec'] == 'none'
      ).cast<Map<String, dynamic>>().toList();
    }

    if (videoFormats.isEmpty) {
      return const VideoStreamMetadata(videoStreams: []);
    }

    // Sort video by height descending, preferring avc1 (H.264) over av01 (AV1)
    videoFormats.sort((a, b) {
      final hA = (a['height'] ?? 0) as int;
      final hB = (b['height'] ?? 0) as int;
      if (hA != hB) return hB.compareTo(hA);

      final vA = (a['vcodec'] ?? '').toString();
      final vB = (b['vcodec'] ?? '').toString();
      final isAvcA = vA.startsWith('avc');
      final isAvcB = vB.startsWith('avc');
      if (isAvcA && !isAvcB) return -1;
      if (!isAvcA && isAvcB) return 1;
      return 0;
    });

    // Sort audio by ABR descending, preferring m4a/aac
    if (audioFormats.isNotEmpty) {
      audioFormats.sort((a, b) {
        final abrA = (a['abr'] ?? 0) as num;
        final abrB = (b['abr'] ?? 0) as num;
        if (abrA != abrB) return abrB.compareTo(abrA);

        final extA = (a['ext'] ?? '').toString();
        final extB = (b['ext'] ?? '').toString();
        if (extA == 'm4a' && extB != 'm4a') return -1;
        if (extA != 'm4a' && extB == 'm4a') return 1;
        return 0;
      });
    }

    final uniqueHeights = <int>{};
    final List<YtStreamInfo> uniqueStreams = [];

    for (final f in videoFormats) {
      final height = f['height'] as int;
      final rawUrl = f['url'] as String? ?? '';
      if (rawUrl.isNotEmpty && !uniqueHeights.contains(height)) {
        uniqueHeights.add(height);
        uniqueStreams.add(YtStreamInfo(height, rawUrl));
      }
    }

    final bestAudioFormat = audioFormats.isNotEmpty ? audioFormats.first : null;
    final bestAudio = (bestAudioFormat != null && (bestAudioFormat['url'] as String? ?? '').isNotEmpty)
        ? bestAudioFormat['url'] as String
        : null;

    final mediaHeaders = <String, String>{
      'Referer': 'https://www.youtube.com/',
    };
    if (bestAudioFormat != null && bestAudioFormat['http_headers'] != null) {
      final h = bestAudioFormat['http_headers'] as Map<String, dynamic>;
      if (h['User-Agent'] != null) {
        mediaHeaders['User-Agent'] = h['User-Agent'].toString();
      }
    }
    if (!mediaHeaders.containsKey('User-Agent') &&
        manifest['http_headers'] != null &&
        manifest['http_headers']['User-Agent'] != null) {
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
