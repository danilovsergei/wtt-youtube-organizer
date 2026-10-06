import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'screen_inhibitor.dart';
import 'video_player_service.dart';
import 'ytdlp/ytdlp_service.dart';

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
  StreamSubscription? _playingSub;
  Timer? _singleClickTimer;

  List<YtStreamInfo> _availableStreams = [];
  YtStreamInfo? _selectedStream;
  String? _audioUrl;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _playingSub = _player.stream.playing.listen((isPlaying) {
      if (Platform.isLinux) {
        if (isPlaying) {
          LinuxScreenInhibitor.enable();
        } else {
          if (Platform.isLinux) LinuxScreenInhibitor.disable();
        }
      }
    });
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _playingSub?.cancel();
    _singleClickTimer?.cancel();
    LinuxScreenInhibitor.disable();
    _player.dispose();
    super.dispose();
  }

  void _loadVideo(String youtubeId, int startSeconds, [YtStreamInfo? specificStream]) async {
    try {
      final metadata = await YtDlpService.instance.getVideoStreamMetadata(youtubeId);
      if (metadata.videoStreams.isEmpty) {
        debugPrint('No video streams extracted for $youtubeId');
        return;
      }

      if (mounted) {
        setState(() {
          _availableStreams = metadata.videoStreams;
          _selectedStream = specificStream ?? _availableStreams.first;
          _audioUrl = metadata.audioUrl;

          debugPrint('====================================');
          debugPrint('Selected Resolution: ${_selectedStream!.height}p');
          debugPrint('Video Stream URL: ${_selectedStream!.url.length > 50 ? _selectedStream!.url.substring(0, 50) : _selectedStream!.url}... (truncated)');
          debugPrint('Audio Stream URL: ${_audioUrl != null && _audioUrl!.length > 50 ? _audioUrl!.substring(0, 50) : _audioUrl}... (truncated)');
          debugPrint('====================================');
        });
      }

      _durationSub?.cancel();
      _singleClickTimer?.cancel();

      final nativePlayer = _player.platform as dynamic;
      try { nativePlayer.setProperty('ytdl', 'no'); } catch (e) { debugPrint('MPV prop err: $e'); }
      try { nativePlayer.setProperty('tls-verify', 'no'); } catch (e) { debugPrint('MPV prop err: $e'); }

      try {
        String userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';
        if (metadata.httpHeaders['User-Agent'] != null) {
          userAgent = metadata.httpHeaders['User-Agent']!.replaceAll(',', '');
        }
        final headers = 'User-Agent: $userAgent,Referer: https://www.youtube.com/';
        nativePlayer.setProperty('http-header-fields', headers);
      } catch (e) {
        debugPrint('MPV prop err: $e');
      }

      Map<String, String> mediaHeaders = Map<String, String>.from(metadata.httpHeaders);
      if (!mediaHeaders.containsKey('Referer')) {
        mediaHeaders['Referer'] = 'https://www.youtube.com/';
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
    _singleClickTimer?.cancel();
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


  Widget _buildQualitySelector() {
    return PopupMenuButton<YtStreamInfo>(
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
    );
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
          LayoutBuilder(
            builder: (context, constraints) {
              return Listener(
                behavior: HitTestBehavior.translucent,
                onPointerUp: (event) {
                  if (event.localPosition.dy < constraints.maxHeight - 80) {
                    if (_singleClickTimer != null && _singleClickTimer!.isActive) {
                      // Double click detected! Cancel the pending single click action
                      _singleClickTimer!.cancel();
                    } else {
                      // Start a timer for single click action (300ms is standard double-click window)
                      _singleClickTimer = Timer(const Duration(milliseconds: 300), () {
                        debugPrint('Raw pointer event detected in video area! Toggling play/pause...');
                        _player.playOrPause();
                      });
                    }
                  }
                },
                child: GestureDetector(
                  // media_kit does not consume double taps by default, so this safely wins the arena
                  onDoubleTap: widget.onDoubleTap,
                  child: MaterialDesktopVideoControlsTheme(
                    normal: MaterialDesktopVideoControlsThemeData(
                      hideMouseOnControlsRemoval: true,
                      topButtonBar: [
                        const Spacer(),
                        if (_availableStreams.isNotEmpty) _buildQualitySelector(),
                      ],
                    ),
                    fullscreen: MaterialDesktopVideoControlsThemeData(
                      hideMouseOnControlsRemoval: true,
                      topButtonBar: [
                        const Spacer(),
                        if (_availableStreams.isNotEmpty) _buildQualitySelector(),
                      ],
                    ),
                    child: Video(controller: _controller),
                  ),
                ),
              );
            },
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
