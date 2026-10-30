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

    String? denoPath;
    if (File('/app/bin/deno').existsSync()) {
      denoPath = '/app/bin/deno';
    } else {
      final dataHome = Platform.environment['XDG_DATA_HOME'];
      if (dataHome != null && File('$dataHome/yt-dlp/deno').existsSync()) {
        denoPath = '$dataHome/yt-dlp/deno';
      }
    }

    final ytdlpArgs = buildArgs(youtubeId, denoPath: denoPath);
    var result = await Process.run(ytdlpPath, ytdlpArgs);

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

  /// Pure argument builder: separated for unit testing and regression prevention
  static List<String> buildArgs(String youtubeId, {String? denoPath}) {
    final args = <String>[];
    if (denoPath != null && denoPath.isNotEmpty) {
      args.addAll(['--js-runtimes', 'deno:$denoPath']);
    }
    args.addAll([
      '-j',
      'https://www.youtube.com/watch?v=$youtubeId',
    ]);
    return args;
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

    // Include all playable formats (HLS manifests and DASH streams)
    final videoFormats = formats.where((f) =>
      f is Map<String, dynamic> &&
      f['vcodec'] != 'none' &&
      f['height'] != null
    ).cast<Map<String, dynamic>>().toList();

    // Extract audio streams (including HLS and DASH, avoiding DRC variants)
    var audioFormats = formats.where((f) =>
      f is Map<String, dynamic> &&
      f['acodec'] != 'none' &&
      f['vcodec'] == 'none' &&
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

    int codecPriority(String vcodec) {
      final v = vcodec.toLowerCase();
      if (v.startsWith('avc') || v.startsWith('h264')) return 1; // H.264: 100% universal hardware acceleration
      if (v.startsWith('vp9') || v.startsWith('vp09')) return 2; // VP9: Hardware accelerated on Android TV
      if (v.startsWith('hev') || v.startsWith('h265')) return 3; // HEVC: Hardware accelerated
      if (v.startsWith('av01') || v.startsWith('av1')) return 4; // AV1: Software-only on almost all projectors -> severe glitching
      return 5;
    }

    // Sort video by height descending, then by hardware codec capability (AVC > VP9 > HEVC > AV1)
    // Sort video by:
    // 1. Height descending (1080p, 720p, etc.)
    // 2. Prefer HLS (e.g. format 312) to bypass IP-pinning and 403 Forbidden errors
    // 3. Prefer AVC (H.264) over VP9/HEVC/AV1 for universal HW decoding
    videoFormats.sort((a, b) {
      final hA = (a['height'] ?? 0) as int;
      final hB = (b['height'] ?? 0) as int;
      if (hA != hB) return hB.compareTo(hA);

      final isHlsA = isHlsFormat(a);
      final isHlsB = isHlsFormat(b);
      if (isHlsA && !isHlsB) return -1;
      if (!isHlsA && isHlsB) return 1;

      final vA = (a['vcodec'] ?? '').toString();
      final vB = (b['vcodec'] ?? '').toString();
      final pA = codecPriority(vA);
      final pB = codecPriority(vB);
      if (pA != pB) return pA.compareTo(pB);

      final tbrA = (a['tbr'] ?? a['vbr'] ?? 0) as num;
      final tbrB = (b['tbr'] ?? b['vbr'] ?? 0) as num;
      return tbrB.compareTo(tbrA);
    });

    // Determine if the selected video stream is HLS
    final topVideoIsHls = videoFormats.isNotEmpty && isHlsFormat(videoFormats.first);

    // Sort audio streams:
    // If video is HLS (format 312), prioritize matching HLS audio (format 234)
    // to bypass IP-pinning, cipher throttling, and 403 Forbidden errors!
    if (audioFormats.isNotEmpty) {
      audioFormats.sort((a, b) {
        if (topVideoIsHls) {
          final isHlsA = isHlsFormat(a);
          final isHlsB = isHlsFormat(b);
          if (isHlsA && !isHlsB) return -1;
          if (!isHlsA && isHlsB) return 1;
        }

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
