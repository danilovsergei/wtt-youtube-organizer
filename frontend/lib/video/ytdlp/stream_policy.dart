
/// Represents a data-driven YouTube stream resolution policy loaded from Supabase.
class StreamPolicy {
  final int version;
  final String description;
  final List<String> protocolPriority;
  final List<String> codecPriority;
  final Set<String> blockedItags;
  final List<String> preferredHlsVodItags;
  final List<String> preferredHlsLiveItags;
  final bool excludeDrc;
  final List<String> liveAudioItags;
  final List<String> dashAudioItags;
  final Map<String, String> playbackHeaders;

  const StreamPolicy({
    this.version = 2,
    this.description = 'Default Stream Selection Policy',
    this.protocolPriority = const ['hls', 'dash', 'http'],
    this.codecPriority = const ['avc1', 'h264', 'vp9', 'vp09', 'av01'],
    this.blockedItags = const {'299'},
    this.preferredHlsVodItags = const ['301', '300', '94', '93'],
    this.preferredHlsLiveItags = const ['312', '617'],
    this.excludeDrc = true,
    this.liveAudioItags = const ['234', '233'],
    this.dashAudioItags = const ['140', '251'],
    this.playbackHeaders = const {
      'Referer': 'https://www.youtube.com/',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    },
  });

  factory StreamPolicy.fromJson(Map<String, dynamic> json) {
    final video = (json['video_selection'] as Map<String, dynamic>?) ?? {};
    final audio = (json['audio_selection'] as Map<String, dynamic>?) ?? {};
    final headers = (json['playback_headers'] as Map<String, dynamic>?) ?? {};

    final whenHls = (audio['when_video_is_hls'] as Map<String, dynamic>?) ?? {};
    final ifNone = (whenHls['if_internal_audio_none'] as Map<String, dynamic>?) ?? {};
    final whenDash = (audio['when_video_is_dash'] as Map<String, dynamic>?) ?? {};

    return StreamPolicy(
      version: json['policy_version'] as int? ?? 2,
      description: json['description'] as String? ?? 'Custom Stream Policy',
      protocolPriority: (json['protocol_priority'] as List<dynamic>?)
              ?.map((e) => e.toString().toLowerCase())
              .toList() ??
          const ['hls', 'dash', 'http'],
      codecPriority: (video['codec_priority'] as List<dynamic>?)
              ?.map((e) => e.toString().toLowerCase())
              .toList() ??
          const ['avc1', 'h264', 'vp9', 'vp09', 'av01'],
      blockedItags: (video['blocked_itags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toSet() ??
          const {'299'},
      preferredHlsVodItags: (video['preferred_hls_vod_itags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['301', '300', '94', '93'],
      preferredHlsLiveItags: (video['preferred_hls_live_itags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['312', '617'],
      excludeDrc: audio['exclude_drc'] as bool? ?? true,
      liveAudioItags: (ifNone['preferred_itags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['234', '233'],
      dashAudioItags: (whenDash['preferred_itags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['140', '251'],
      playbackHeaders: headers.map((k, v) => MapEntry(k, v.toString())),
    );
  }

  Map<String, dynamic> toJson() => {
        'policy_version': version,
        'description': description,
        'protocol_priority': protocolPriority,
        'video_selection': {
          'codec_priority': codecPriority,
          'blocked_itags': blockedItags.toList(),
          'preferred_hls_vod_itags': preferredHlsVodItags,
          'preferred_hls_live_itags': preferredHlsLiveItags,
        },
        'audio_selection': {
          'exclude_drc': excludeDrc,
          'when_video_is_hls': {
            'if_internal_audio_present': 'use_embedded',
            'if_internal_audio_none': {
              'attach_external': true,
              'prefer_protocol': 'hls',
              'preferred_itags': liveAudioItags,
            },
          },
          'when_video_is_dash': {
            'attach_external': true,
            'prefer_protocol': 'dash',
            'preferred_itags': dashAudioItags,
            'sort_by': 'abr_descending',
          },
        },
        'playback_headers': playbackHeaders,
      };
}
