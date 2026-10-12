import 'package:flutter/material.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'video_player_service.dart';

VideoPlayerWidget createVideoPlayer({
  Key? key,
  ValueNotifier<bool>? resizingNotifier,
  required String? matchId,
  required String? youtubeId,
  required String imageUrl,
  required int offsetSeconds,
  int? matchDurationSeconds,
  required void Function() onDoubleTap,
  bool autoPlay = true,
}) {
  return _WebVideoPlayerWidget(
    key: key,
    resizingNotifier: resizingNotifier,
    matchId: matchId,
    youtubeId: youtubeId,
    imageUrl: imageUrl,
    offsetSeconds: offsetSeconds,
    matchDurationSeconds: matchDurationSeconds,
    onDoubleTap: onDoubleTap,
    autoPlay: autoPlay,
  );
}

class _WebVideoPlayerWidget extends VideoPlayerWidget {
  const _WebVideoPlayerWidget({
    super.key,
    super.resizingNotifier,
    required super.matchId,
    required super.youtubeId,
    required super.imageUrl,
    required super.offsetSeconds,
    super.matchDurationSeconds,
    required super.onDoubleTap,
    super.autoPlay = true,
  });

  @override
  State<_WebVideoPlayerWidget> createState() => _WebVideoPlayerState();
}

class _WebVideoPlayerState extends State<_WebVideoPlayerWidget> {
  YoutubePlayerController? _controller;
  String? _lastMatchId;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController(
      params: const YoutubePlayerParams(
        showControls: true,
        showFullscreenButton: true,
        mute: false,
      ),
    );
  }

  @override
  void dispose() {
    _controller?.close();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    final isDifferentMatch = _lastMatchId != widget.matchId;
    
    if (isDifferentMatch && widget.youtubeId != null) {
      _lastMatchId = widget.matchId;
      _controller?.loadVideoById(
        videoId: widget.youtubeId!,
        startSeconds: widget.offsetSeconds.toDouble(),
      );
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
            color: Colors.black.withOpacity(0.6),
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

    if (widget.youtubeId == null || _controller == null) {
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
          YoutubePlayer(controller: _controller!),
          Positioned(
            top: 24,
            right: 32,
            child: Container(
              key: const Key('player_diagnostics_badge'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF00E676).withValues(alpha: 0.5),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.6),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF00E676),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '1080p • HTML5 Web Player',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
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

