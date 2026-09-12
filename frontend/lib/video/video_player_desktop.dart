import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'video_player_service.dart';

VideoPlayerWidget createVideoPlayer({
  Key? key,
  ValueNotifier<bool>? resizingNotifier,
  required String? matchId,
  required String? youtubeId,
  required String imageUrl,
  required int offsetSeconds,
  required void Function() onDoubleTap,
}) {
  return _DesktopVideoPlayerWidget(
    key: key,
    resizingNotifier: resizingNotifier,
    matchId: matchId,
    youtubeId: youtubeId,
    imageUrl: imageUrl,
    offsetSeconds: offsetSeconds,
    onDoubleTap: onDoubleTap,
  );
}

class YtStreamInfo {
  final int height;
  final String url;
  YtStreamInfo(this.height, this.url);
}

class _DesktopVideoPlayerWidget extends VideoPlayerWidget {
  const _DesktopVideoPlayerWidget({
    super.key,
    super.resizingNotifier,
    required super.matchId,
    required super.youtubeId,
    required super.imageUrl,
    required super.offsetSeconds,
    required super.onDoubleTap,
  });

  @override
  State<_DesktopVideoPlayerWidget> createState() => _DesktopVideoPlayerState();
}

class _DesktopVideoPlayerState extends State<_DesktopVideoPlayerWidget> {
  late final Player _player;
  late final VideoController _controller;
  String? _lastMatchId;
  StreamSubscription? _durationSub;

  List<YtStreamInfo> _availableStreams = [];
  YtStreamInfo? _selectedStream;
  String? _audioUrl;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _loadVideo(String youtubeId, int startSeconds, [YtStreamInfo? specificStream]) async {
    try {
      final dataHome = Platform.environment['XDG_DATA_HOME'];
      String ytdlpPath = 'yt-dlp';
      if (dataHome != null && File('$dataHome/yt-dlp/yt-dlp_linux').existsSync()) {
        ytdlpPath = '$dataHome/yt-dlp/yt-dlp_linux';
      } else if (File('/app/bin/yt-dlp_linux').existsSync()) {
        ytdlpPath = '/app/bin/yt-dlp_linux';
      } else if (File('/usr/local/bin/yt-dlp_linux').existsSync()) {
        ytdlpPath = '/usr/local/bin/yt-dlp_linux';
      }

      // Log the yt-dlp version to guarantee we are executing the updated binary and not an obsolete system package
      final versionResult = await Process.run(ytdlpPath, ['--version']);
      debugPrint('DIAGNOSTICS: yt-dlp binary path: $ytdlpPath');
      debugPrint('DIAGNOSTICS: yt-dlp version executing: ${versionResult.stdout.toString().trim()}');

      final result = await Process.run(ytdlpPath, [
        '-j',
        'https://www.youtube.com/watch?v=$youtubeId'
      ]);

      if (result.exitCode != 0) {
        debugPrint('yt-dlp extraction failed: ${result.stderr}');
        return;
      }

      debugPrint('yt-dlp successfully extracted JSON manifest for $youtubeId');
      final manifest = jsonDecode(result.stdout);
      final formats = manifest['formats'] as List<dynamic>;

      // Extract adaptive video streams
      final videoFormats = formats.where((f) => 
        f['vcodec'] != 'none' && 
        f['acodec'] == 'none' && 
        f['height'] != null
      ).toList();

      // Extract adaptive audio streams
      final audioFormats = formats.where((f) => 
        f['acodec'] != 'none' && 
        f['vcodec'] == 'none'
      ).toList();

      if (videoFormats.isEmpty || audioFormats.isEmpty) return;

      videoFormats.sort((a, b) => (b['height'] as int).compareTo(a['height'] as int));
      audioFormats.sort((a, b) => ((b['abr'] ?? 0) as num).compareTo((a['abr'] ?? 0) as num));

      final videoStreams = videoFormats.map((f) => YtStreamInfo(f['height'] as int, f['url'] as String)).toList();
      final bestAudio = audioFormats.first['url'] as String;

      if (mounted) {
        setState(() {
          // Remove duplicate resolutions
          final uniqueHeights = <int>{};
          _availableStreams = videoStreams.where((s) {
            if (uniqueHeights.contains(s.height)) return false;
            uniqueHeights.add(s.height);
            return true;
          }).toList();

          _selectedStream = specificStream ?? _availableStreams.first;
          _audioUrl = bestAudio;
          
          debugPrint('====================================');
          debugPrint('Selected Resolution: ${_selectedStream!.height}p');
          debugPrint('Video Stream URL: ${_selectedStream!.url.substring(0, 50)}... (truncated)');
          debugPrint('Audio Stream URL: ${_audioUrl!.substring(0, 50)}... (truncated)');
          debugPrint('====================================');
        });
      }

      _durationSub?.cancel();
      
      final nativePlayer = _player.platform as dynamic;
      try { nativePlayer.setProperty('ytdl', 'no'); } catch (e) { debugPrint('MPV prop err: $e'); }
      try { nativePlayer.setProperty('tls-verify', 'no'); } catch (e) { debugPrint('MPV prop err: $e'); }
      
      try {
        String userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';
        if (manifest['http_headers'] != null && manifest['http_headers']['User-Agent'] != null) {
          userAgent = manifest['http_headers']['User-Agent'].toString().replaceAll(',', '');
        }
        final headers = 'User-Agent: $userAgent,Referer: https://www.youtube.com/';
        nativePlayer.setProperty('http-header-fields', headers);
      } catch (e) {
        debugPrint('MPV prop err: $e');
      }

      Map<String, String> mediaHeaders = {
        'Referer': 'https://www.youtube.com/'
      };
      if (manifest['http_headers'] != null && manifest['http_headers']['User-Agent'] != null) {
        mediaHeaders['User-Agent'] = manifest['http_headers']['User-Agent'].toString();
        debugPrint('yt-dlp User-Agent extracted: ${mediaHeaders['User-Agent']}');
      }
      
      debugPrint('Initializing libmpv Media with video URL and ${mediaHeaders.length} custom headers...');

      await _player.open(Media(_selectedStream!.url, httpHeaders: mediaHeaders), play: false);
      
      if (_audioUrl != null) {
        await _player.setAudioTrack(AudioTrack.uri(_audioUrl!));
      }
      
      Future<void> playAndSeek() async {
        await _player.seek(Duration(seconds: startSeconds));
        await _player.play();
      }

      if (_player.state.duration.inSeconds > 0) {
        await playAndSeek();
      } else {
        _durationSub = _player.stream.duration.listen((duration) async {
          if (duration.inSeconds > 0) {
            _durationSub?.cancel();
            await playAndSeek();
          }
        });
      }
    } catch (e) {
      debugPrint('Failed to load youtube video: $e');
    }
  }

  void _changeQuality(YtStreamInfo stream) {
    if (widget.youtubeId != null) {
      final currentPosition = _player.state.position.inSeconds;
      _loadVideo(widget.youtubeId!, currentPosition, stream);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDifferentMatch = _lastMatchId != widget.matchId;
    
    if (isDifferentMatch && widget.youtubeId != null) {
      _lastMatchId = widget.matchId;
      _loadVideo(widget.youtubeId!, widget.offsetSeconds);
    }

    final thumbnailWidget = Container(
      decoration: BoxDecoration(
        color: Colors.black,
        image: DecorationImage(
          image: NetworkImage(widget.imageUrl),
          fit: BoxFit.cover,
        ),
      ),
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.play_arrow,
            size: 48,
            color: Colors.white,
          ),
        ),
      ),
    );

    if (widget.youtubeId == null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: thumbnailWidget,
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Stack(
            fit: StackFit.expand,
            children: [
              Video(controller: _controller),
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  debugPrint('Single tap gesture detected! Toggling play/pause...');
                  _player.playOrPause();
                },
                onDoubleTap: widget.onDoubleTap,
                child: const SizedBox.expand(),
              ),
            ],
          ),
          
          if (_availableStreams.isNotEmpty)
            Positioned(
              top: 16,
              right: 16,
              child: PopupMenuButton<YtStreamInfo>(
                key: const Key('quality_selector_btn'),
                icon: const Icon(Icons.settings, color: Colors.white, size: 28),
                color: Colors.black.withValues(alpha: 0.8),
                tooltip: 'Video Quality',
                onSelected: _changeQuality,
                itemBuilder: (BuildContext context) {
                  return _availableStreams.map((stream) {
                    final isSelected = stream.height == _selectedStream?.height;
                    return PopupMenuItem<YtStreamInfo>(
                      key: Key('quality_${stream.height}p'),
                      value: stream,
                      child: Row(
                        children: [
                          Icon(
                            isSelected ? Icons.check : Icons.circle,
                            color: isSelected ? Colors.red : Colors.transparent,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${stream.height}p',
                            style: TextStyle(
                              color: isSelected ? Colors.red : Colors.white,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList();
                },
              ),
            ),

          if (widget.resizingNotifier != null)
            ValueListenableBuilder<bool>(
              valueListenable: widget.resizingNotifier!,
              builder: (context, isResizing, _) {
                if (isResizing) {
                  return thumbnailWidget;
                }
                return const SizedBox.shrink();
              },
            ),
        ],
      ),
    );
  }
}
