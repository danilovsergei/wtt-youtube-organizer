import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
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
  return _WebVideoPlayerWidget(
    key: key,
    resizingNotifier: resizingNotifier,
    matchId: matchId,
    youtubeId: youtubeId,
    imageUrl: imageUrl,
    offsetSeconds: offsetSeconds,
    onDoubleTap: onDoubleTap,
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
    required super.onDoubleTap,
  });

  @override
  State<_WebVideoPlayerWidget> createState() => _WebVideoPlayerState();
}

class _WebVideoPlayerState extends State<_WebVideoPlayerWidget> {
  YoutubePlayerController? _controller;
  String? _lastMatchId;
  int _lastTapTime = 0;

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

