import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'ytdlp_service.dart';
import 'stream_policy.dart';
import '../../services/stream_policy_service.dart';
import '../../services/proxy_discovery_service.dart';

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
    // 1. If home stream proxy is active and verified on home LAN, resolve via proxy!
    if (await ProxyDiscoveryService.instance.isProxyActiveAndAvailable()) {
      try {
        return await ProxyDiscoveryService.instance.resolveFromProxy(youtubeId);
      } catch (e) {
        // Fallback silently to local yt-dlp
      }
    }

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
  static VideoStreamMetadata parseManifest(Map<String, dynamic> manifest, {StreamPolicy? policy}) {
    final activePolicy = policy ?? StreamPolicyService.instance.activePolicy;
    final formats = (manifest['formats'] as List<dynamic>?) ?? [];

    bool isHlsFormat(Map<String, dynamic> f) {
      final p = (f['protocol'] ?? '').toString().toLowerCase();
      final url = (f['url'] ?? '').toString().toLowerCase();
      final fid = (f['format_id'] ?? '').toString();
      return p.contains('m3u8') ||
          url.contains('m3u8') ||
          url.contains('hls') ||
          url.contains('manifest.googlevideo.com') ||
          activePolicy.preferredHlsLiveItags.contains(fid) ||
          activePolicy.preferredHlsVodItags.contains(fid);
    }

    // 1. Filter out blocked itags from policy (e.g. format 299)
    var playableFormats = formats.where((f) {
      if (f is! Map<String, dynamic>) return false;
      final fid = f['format_id']?.toString() ?? '';
      return !activePolicy.blockedItags.contains(fid);
    }).cast<Map<String, dynamic>>().toList();

    // Fallback if all video formats were filtered out
    if (playableFormats.where((f) => f['vcodec'] != 'none' && f['height'] != null).isEmpty) {
      playableFormats = formats.where((f) => f is Map<String, dynamic>).cast<Map<String, dynamic>>().toList();
    }

    // Include all playable video formats
    final videoFormats = playableFormats.where((f) =>
      f['vcodec'] != 'none' &&
      f['height'] != null &&
      !f['format_id'].toString().startsWith('sb')
    ).toList();

    // Extract audio streams (filtering DRC if policy requests it)
    var audioFormats = playableFormats.where((f) {
      final isAudio = f['acodec'] != 'none' && f['vcodec'] == 'none';
      if (!isAudio) return false;
      if (activePolicy.excludeDrc && f['format_id'].toString().contains('drc')) {
        return false;
      }
      return true;
    }).toList();

    if (audioFormats.isEmpty) {
      audioFormats = playableFormats.where((f) =>
        f['acodec'] != 'none' && f['vcodec'] == 'none'
      ).toList();
    }

    if (videoFormats.isEmpty) {
      return const VideoStreamMetadata(videoStreams: []);
    }

    int codecPriority(String vcodec) {
      final v = vcodec.toLowerCase();
      for (int i = 0; i < activePolicy.codecPriority.length; i++) {
        final pref = activePolicy.codecPriority[i];
        if (v.startsWith(pref)) return i + 1;
      }
      return activePolicy.codecPriority.length + 1;
    }

    // Sort video by:
    // 1. Height descending (1080p, 720p, etc.)
    // 2. Protocol priority from policy (HLS over DASH to bypass IP-pinning and 403 Forbidden)
    // 3. Codec priority from policy (AVC > VP9 > HEVC > AV1)
    videoFormats.sort((a, b) {
      final hA = (a['height'] ?? 0) as int;
      final hB = (b['height'] ?? 0) as int;
      if (hA != hB) return hB.compareTo(hA);

      final isHlsA = isHlsFormat(a);
      final isHlsB = isHlsFormat(b);
      if (isHlsA && !isHlsB) return -1;
      if (!isHlsA && isHlsB) return 1;

      final fidA = a['format_id']?.toString() ?? '';
      final fidB = b['format_id']?.toString() ?? '';
      final isPrefVodA = activePolicy.preferredHlsVodItags.contains(fidA);
      final isPrefVodB = activePolicy.preferredHlsVodItags.contains(fidB);
      if (isPrefVodA && !isPrefVodB) return -1;
      if (!isPrefVodA && isPrefVodB) return 1;

      final vA = (a['vcodec'] ?? '').toString();
      final vB = (b['vcodec'] ?? '').toString();
      final pA = codecPriority(vA);
      final pB = codecPriority(vB);
      if (pA != pB) return pA.compareTo(pB);

      final tbrA = (a['tbr'] ?? a['vbr'] ?? 0) as num;
      final tbrB = (b['tbr'] ?? b['vbr'] ?? 0) as num;
      return tbrB.compareTo(tbrA);
    });

    final topVideo = videoFormats.first;
    final topVideoIsHls = isHlsFormat(topVideo);
    final topVideoHasInternalAudio = topVideo['acodec'] != null &&
        topVideo['acodec'] != 'none' &&
        topVideo['acodec'].toString().isNotEmpty;

    // Sort audio streams according to policy:
    if (audioFormats.isNotEmpty) {
      audioFormats.sort((a, b) {
        if (topVideoIsHls) {
          final isHlsA = isHlsFormat(a) || activePolicy.liveAudioItags.contains(a['format_id']?.toString());
          final isHlsB = isHlsFormat(b) || activePolicy.liveAudioItags.contains(b['format_id']?.toString());
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

    // Determine audio track URL according to policy:
    // If top video is HLS and already has internal audio (e.g. VOD 301/300),
    // skip attaching external audio!
    String? bestAudio;
    if (topVideoIsHls && topVideoHasInternalAudio) {
      bestAudio = null;
    } else {
      final bestAudioFormat = audioFormats.isNotEmpty ? audioFormats.first : null;
      bestAudio = (bestAudioFormat != null && (bestAudioFormat['url'] as String? ?? '').isNotEmpty)
          ? bestAudioFormat['url'] as String
          : null;
    }

    final mediaHeaders = Map<String, String>.from(activePolicy.playbackHeaders);
    final bestAudioFormat = audioFormats.isNotEmpty ? audioFormats.first : null;
    if (bestAudioFormat != null && bestAudioFormat['http_headers'] != null) {
      final h = bestAudioFormat['http_headers'] as Map<String, dynamic>;
      if (h['User-Agent'] != null) {
        mediaHeaders['User-Agent'] = h['User-Agent'].toString();
      }
    }
    if (manifest['http_headers'] != null && manifest['http_headers']['User-Agent'] != null) {
      mediaHeaders['User-Agent'] = manifest['http_headers']['User-Agent']!.toString();
    } else if (videoFormats.first['http_headers'] != null) {
      final h = videoFormats.first['http_headers'] as Map<String, dynamic>;
      if (h['User-Agent'] != null) {
        mediaHeaders['User-Agent'] = h['User-Agent'].toString();
      }
    }

    return VideoStreamMetadata(
      videoStreams: uniqueStreams,
      audioUrl: bestAudio,
      httpHeaders: mediaHeaders,
      rawManifest: manifest,
    );
  }
}
