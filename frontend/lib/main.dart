import 'services/settings_service.dart';
import 'widgets/diagnostics_screen.dart';
import 'widgets/tv_focusable.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'fullscreen/fullscreen_service.dart';
import 'data/database_service.dart';
import 'data/local_database.dart';
import 'video/ytdlp/ytdlp_service.dart';
import 'video/ytdlp/android_ytdlp.dart';
import 'video/ytdlp/test_ytdlp.dart';
import 'video/video_player_service.dart';

import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main([List<String>? args]) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Cap image cache to 15MB to prevent Android TV LowMemoryKiller (LMK) eviction
  PaintingBinding.instance.imageCache.maximumSizeBytes = 15 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 30;
  if (!kIsWeb) {
    MediaKit.ensureInitialized();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      await windowManager.ensureInitialized();
      WindowOptions windowOptions = const WindowOptions(
        size: Size(1280, 720),
        center: true,
      );
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    }
  }

  final cliArgs = args ?? const <String>[];
  const isHermeticEnv = bool.fromEnvironment('HERMETIC', defaultValue: false);
  final useLocalDb = isHermeticEnv || cliArgs.contains('--local-db') || cliArgs.contains('--hermetic');

  if (useLocalDb) {
    DatabaseService.instance = LocalDatabaseService();
    YtDlpService.instance = TestYtDlpService();
  }

  await DatabaseService.instance.initialize();
  await filterController.loadSettings();
  if (!kIsWeb && Platform.isAndroid && YtDlpService.instance is AndroidYtDlpService) {
    (YtDlpService.instance as AndroidYtDlpService).updateYtDlp().then((status) {
      debugPrint('Chaquopy yt-dlp auto-update: $status');
    }).catchError((e) {
      debugPrint('Chaquopy yt-dlp auto-update error: $e');
    });
  }
  runApp(const WttApp());
  filterController.fetchData();
}

class WttApp extends StatefulWidget {
  const WttApp({super.key});

  @override
  State<WttApp> createState() => _WttAppState();
}

class _WttAppState extends State<WttApp> {
  @override
  void reassemble() {
    super.reassemble();
    // Refresh data on hot reload to handle potential code/model changes
    filterController.fetchData();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WTT Organizer',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark, // Default to dark as per mock
      home: const MainScreen(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final baseTheme = brightness == Brightness.dark
        ? ThemeData.dark()
        : ThemeData.light();
    return baseTheme.copyWith(
      scaffoldBackgroundColor: const Color(0xFF101922),
      colorScheme: baseTheme.colorScheme.copyWith(
        primary: const Color(0xFF0D7FF2),
        secondary: const Color(0xFF0D7FF2),
        surface: const Color(0xFF182634),
        onSurface: Colors.white,
      ),
      textTheme: GoogleFonts.splineSansTextTheme(
        baseTheme.textTheme,
      ).apply(bodyColor: Colors.white, displayColor: Colors.white),
      iconTheme: const IconThemeData(color: Colors.white),
    );
  }
}

// --- Data Models & Mock Data ---

enum TournamentType {
  champions('Champions'),
  contender('Contender'),
  feeder('Feeder'),
  smash('Smash'),
  youthContender('Youth');

  final String label;
  const TournamentType(this.label);
}

class Tournament {
  final String id;
  final String name;
  final int year;
  final TournamentType type;
  final String location;

  const Tournament({
    required this.id,
    required this.name,
    required this.year,
    required this.type,
    required this.location,
  });
}

class Match {
  final String id;
  final String title;
  final String tournamentId;
  final String date;
  final String time;
  final String imageUrl;
  final String tag;
  final String views;
  final String day;
  final DateTime? uploadDate;
  final String? youtubeId;
  final int? offsetSeconds;
  final int? durationSeconds;
  final int? session;
  final DateTime? effectiveTimestamp;

  const Match({
    required this.id,
    required this.title,
    required this.tournamentId,
    required this.date,
    required this.time,
    required this.imageUrl,
    required this.tag,
    required this.day,
    this.views = '',
    this.uploadDate,
    this.youtubeId,
    this.offsetSeconds,
    this.durationSeconds,
    this.session,
    this.effectiveTimestamp,
  });

  String get durationFormatted {
    if (durationSeconds == null || durationSeconds! <= 0) return '';
    final totalMinutes = (durationSeconds! / 60).round();
    if (totalMinutes < 60) {
      return '${totalMinutes}m';
    }
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  }
}

class FilterController extends ChangeNotifier {
  List<Tournament> _allTournaments = [];
  List<Match> _allMatches = [];
  bool _isLoading = true;

  Set<int> _selectedYears = {2025, 2026}; // Default years
  Set<TournamentType> _selectedTypes = {};
  String _selectedTournamentId = '';
  Set<String>? _expandedDayKeys; // Tracks expanded days: "tournamentId_day"
  String _searchQuery = '';
  bool _showSingles = true;
  bool _showDoubles = false;
  Match? _selectedMatch;
  bool _hasUserSelectedMatch = false;
  bool get hasUserSelectedMatch => _hasUserSelectedMatch;
  void markMatchSelected() {
    _hasUserSelectedMatch = true;
    notifyListeners();
  }

  Set<String> get _safeExpandedDayKeys => _expandedDayKeys ??= {};

  List<Tournament> get allTournaments => _allTournaments;
  List<Match> get allMatches => _allMatches;
  bool get isLoading => _isLoading;

  Set<int> get selectedYears => _selectedYears;
  Set<TournamentType> get selectedTypes => _selectedTypes;
  String get selectedTournamentId => _selectedTournamentId;
  String get searchQuery => _searchQuery;
  bool get showSingles => _showSingles;
  bool get showDoubles => _showDoubles;

  Match get selectedMatch {
    if (_selectedMatch != null) return _selectedMatch!;
    final filtered = filteredMatches;
    return filtered.isNotEmpty ? filtered.first : _allMatches.firstOrNull ?? const Match(
      id: 'placeholder',
      title: 'Loading...',
      tournamentId: '',
      date: '',
      time: '',
      imageUrl: '',
      tag: '',
      day: '',
    );
  }

  void setDebugData(List<Tournament> tournaments, List<Match> matches) {
    _allTournaments = tournaments;
    _allMatches = matches;
    _isLoading = false;
    notifyListeners();
  }

  bool isDayExpanded(String tournamentId, String day) {
    return _safeExpandedDayKeys.contains('${tournamentId}_$day');
  }

  void toggleDay(String tournamentId, String day) {
    final key = '${tournamentId}_$day';
    if (_safeExpandedDayKeys.contains(key)) {
      _safeExpandedDayKeys.remove(key);
    } else {
      _safeExpandedDayKeys.add(key);
    }
    notifyListeners();
  }

  void toggleShowSingles() {
    _showSingles = !_showSingles;
    notifyListeners();
  }

  void toggleShowDoubles() {
    _showDoubles = !_showDoubles;
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> Function()? customDataFetcher;

  Future<void> fetchData() async {
    _isLoading = true;
    notifyListeners();
    try {
      final List<dynamic> response = customDataFetcher != null
          ? await customDataFetcher!()
          : await DatabaseService.instance.fetchTournamentSchedule();

      final Map<String, Tournament> tournamentsMap = {};
      final List<Match> matches = [];

      int matchCounter = 0;

      for (final row in response) {
        final tName = row['tournament'] as String? ?? 'Unknown Tournament';
        final tYear = row['year'] as int? ?? DateTime.now().year;
        final tKey = '${tName}_$tYear';

        if (!tournamentsMap.containsKey(tKey)) {
          tournamentsMap[tKey] = Tournament(
            id: tKey,
            name: tName,
            year: tYear,
            type: _inferType(tName),
            location: 'Unknown Location',
          );
        }

        DateTime matchTime;
        try {
          matchTime = row['upload_date'] != null
              ? DateTime.parse(row['upload_date'] as String)
              : DateTime.now();
        } catch (e) {
          matchTime = DateTime.now();
        }

        final youtubeId = row['youtube_id'] as String?;
        final imageUrl = (youtubeId != null && youtubeId.isNotEmpty)
            ? 'https://img.youtube.com/vi/$youtubeId/hqdefault.jpg'
            : 'https://via.placeholder.com/320x180';

        String day = 'Unknown Day';
        // final videoTitle = row['video_title'] as String?;
        if (row['day'] != null && (row['day'] as String).isNotEmpty) {
          day = row['day'] as String;
        }
        final uploadDate = row['upload_date'] != null
            ? DateTime.tryParse(row['upload_date'] as String)
            : null;
        final effectiveTimestamp = row['effective_timestamp'] != null
            ? DateTime.tryParse(row['effective_timestamp'] as String)
            : uploadDate;
        final offsetSeconds = row['video_offset_seconds'] as int?;
        final durationSeconds = row['duration_seconds'] as int?;
        final session = row['session'] as int?;

        matches.add(Match(
          id: 'm_${matchCounter++}',
          title: _formatMatchTitle(row),
          tournamentId: tKey,
          date:
              '${matchTime.year}-${matchTime.month.toString().padLeft(2, '0')}-${matchTime.day.toString().padLeft(2, '0')}',
          time: row['match_time'] as String? ?? '00:00',
          imageUrl: imageUrl,
          tag: row['is_doubles'] == true ? 'Doubles' : 'Singles',
          day: day,
          views: '0',
          uploadDate: uploadDate,
          youtubeId: youtubeId,
          offsetSeconds: offsetSeconds,
          durationSeconds: durationSeconds,
          session: session,
          effectiveTimestamp: effectiveTimestamp,
        ));
      }

      _allTournaments = tournamentsMap.values.toList();
      _allMatches = matches;

      // Update selected match if none selected, or re-link existing
      if (_allMatches.isNotEmpty) {
        if (_selectedMatch == null) {
          _selectedMatch = _allMatches.first;
        } else {
          final updated = _allMatches.cast<Match?>().firstWhere(
            (m) {
              if (m == null) return false;
              if (m.youtubeId != null && _selectedMatch!.youtubeId != null) {
                return m.youtubeId == _selectedMatch!.youtubeId;
              }
              return m.id == _selectedMatch!.id;
            },
            orElse: () => null,
          );
          if (updated != null) {
            _selectedMatch = updated;
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching data: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  TournamentType _inferType(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('youth')) return TournamentType.youthContender;
    if (lower.contains('champion')) return TournamentType.champions;
    if (lower.contains('feeder')) return TournamentType.feeder;
    if (name.contains('Smash')) return TournamentType.smash;
    if (name.contains('Contender')) return TournamentType.contender;
    return TournamentType.contender;
  }

  String _formatMatchTitle(Map<String, dynamic> row) {
    final teamA = row['team_a'] as String?;
    final teamB = row['team_b'] as String?;
    if (teamA != null && teamB != null) {
      return '$teamA vs $teamB';
    }
    return row['video_title'] as String? ?? 'Unknown Match';
  }

  int _selectionNonce = 0;
  int get selectionNonce => _selectionNonce;
  final FocusNode currentMatchFocusNode = FocusNode();
  final FocusNode playButtonFocusNode = FocusNode();
  final FocusNode progressBarFocusNode = FocusNode();

  final ValueNotifier<int> showControlsTrigger = ValueNotifier<int>(0);

  void showControls({int seconds = 5}) {
    showControlsTrigger.value++;
    notifyListeners();
  }

  void focusCurrentMatch() {
    currentMatchFocusNode.requestFocus();
  }

  void focusPlayButton() {
    showControls(seconds: 5);
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        playButtonFocusNode.requestFocus();
      });
    } catch (_) {
      playButtonFocusNode.requestFocus();
    }
  }

  void focusProgressBar() {
    showControls(seconds: 5);
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        progressBarFocusNode.requestFocus();
      });
    } catch (_) {
      progressBarFocusNode.requestFocus();
    }
  }

  void selectMatch(Match match) {
    _hasUserSelectedMatch = true;
    _selectedMatch = match;
    _selectionNonce++;
    if (_selectedTournamentId != match.tournamentId) {
      selectTournament(match.tournamentId);
    }
    final groupKey = match.session != null ? '${match.day} - Round ${match.session}' : match.day;
    _safeExpandedDayKeys.add('${match.tournamentId}_$groupKey');
    _safeExpandedDayKeys.add('${match.tournamentId}_${match.day}');
    isFullscreenNotifier.value = true;
    notifyListeners();
  }

  void selectTournament(String tournamentId) {
    if (_selectedTournamentId == tournamentId) {
      _selectedTournamentId = '';
      _expandedDayKeys?.clear();
    } else {
      _selectedTournamentId = tournamentId;
      _expandedDayKeys?.clear();
    }
    notifyListeners();
  }

  void toggleYear(int year) {
    if (_selectedYears.contains(year)) {
      _selectedYears.remove(year);
    } else {
      _selectedYears.add(year);
    }
    notifyListeners();
  }

  Future<void> loadSettings() async {
    final names = await SettingsService.instance.loadSelectedTournamentTypeNames();
    if (names.isNotEmpty) {
      final types = <TournamentType>{};
      for (final type in TournamentType.values) {
        if (names.contains(type.name)) {
          types.add(type);
        }
      }
      _selectedTypes = types;
      notifyListeners();
    }
  }

  void _persistSelectedTypes() {
    final names = _selectedTypes.map((t) => t.name).toSet();
    SettingsService.instance.saveSelectedTournamentTypeNames(names);
  }

  void toggleType(TournamentType type) {
    if (_selectedTypes.contains(type)) {
      _selectedTypes.remove(type);
    } else {
      _selectedTypes.add(type);
    }
    _persistSelectedTypes();
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void reset() {
    _selectedYears = {2025, 2026};
    _selectedTypes = {};
    _selectedTournamentId = '';
    _expandedDayKeys?.clear();
    _showSingles = true;
    _showDoubles = false;
    _searchQuery = '';
    _selectedMatch = null;
    _hasUserSelectedMatch = false;
    _persistSelectedTypes();
    notifyListeners();
  }

  List<Match> get filteredMatches {
    return _allMatches.where((match) {
      final tournament = _allTournaments.firstWhere(
        (t) => t.id == match.tournamentId,
        orElse: () => const Tournament(id: '', name: '', year: 0, type: TournamentType.contender, location: ''),
      );

      final yearMatch =
          _selectedYears.isEmpty || _selectedYears.contains(tournament.year);
      final bool typeMatch;
      if (tournament.type == TournamentType.youthContender) {
        typeMatch = _selectedTypes.contains(TournamentType.youthContender);
      } else {
        typeMatch =
            _selectedTypes.isEmpty || _selectedTypes.contains(tournament.type);
      }
      final tournamentMatch =
          _selectedTournamentId.isEmpty ||
          _selectedTournamentId == match.tournamentId;
      final searchMatch =
          _searchQuery.isEmpty ||
          match.title.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          tournament.name.toLowerCase().contains(_searchQuery.toLowerCase());
      
      final matchTypeFilter = (match.tag == 'Singles' && _showSingles) ||
                              (match.tag == 'Doubles' && _showDoubles);

      return yearMatch && typeMatch && tournamentMatch && searchMatch && matchTypeFilter;
    }).toList();
  }

  List<Tournament> get availableTournaments {
    return _allTournaments.where((tournament) {
      final yearMatch =
          _selectedYears.isEmpty || _selectedYears.contains(tournament.year);
      final bool typeMatch;
      if (tournament.type == TournamentType.youthContender) {
        typeMatch = _selectedTypes.contains(TournamentType.youthContender);
      } else {
        typeMatch =
            _selectedTypes.isEmpty || _selectedTypes.contains(tournament.type);
      }
      return yearMatch && typeMatch;
    }).toList();
  }
}

final filterController = FilterController();
final ValueNotifier<bool> isFullscreenNotifier = ValueNotifier(false);

// --- Main Layout ---

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  double _sidebarWidth = 320;
  final ValueNotifier<bool> _resizingNotifier = ValueNotifier(false);
  final GlobalKey _videoHeroKey = GlobalKey();

  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    isFullscreenNotifier.addListener(_onFullscreenChanged);
  }

  @override
  void dispose() {
    isFullscreenNotifier.removeListener(_onFullscreenChanged);
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _resizingNotifier.dispose();
    super.dispose();
  }

  void _onFullscreenChanged() {
    if (!isFullscreenNotifier.value) {
      filterController.showControls(seconds: 5);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        filterController.focusCurrentMatch();
      });
    }
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      final isF5 = event.logicalKey == LogicalKeyboardKey.f5;
      final isCtrlR = event.logicalKey == LogicalKeyboardKey.keyR &&
          (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed);
      if (isF5 || isCtrlR) {
        _triggerRefresh();
        return true;
      }
    }
    return false;
  }

  Future<void> _triggerRefresh() async {
    if (_isRefreshing || !mounted) return;
    _isRefreshing = true;

    bool dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return PopScope(
          canPop: false,
          child: Dialog(
            backgroundColor: const Color(0xFF182634),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFF223547)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0D7FF2)),
                    ),
                  ),
                  SizedBox(width: 16),
                  Text(
                    "Refreshing...",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ).then((_) {
      dialogOpen = false;
    });

    try {
      await Future.wait([
        filterController.fetchData(),
        Future.delayed(const Duration(milliseconds: 350)),
      ]);
    } catch (e) {
      debugPrint("Error during F5 refresh: ");
    } finally {
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _isRefreshing = false;
    }
  }



  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (isFullscreenNotifier.value) {
          isFullscreenNotifier.value = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            filterController.focusCurrentMatch();
          });
          return;
        }
        if (filterController.selectedTournamentId.isNotEmpty) {
          filterController.selectTournament('');
          return;
        }
        SystemNavigator.pop();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.f5): _triggerRefresh,
          const SingleActivator(LogicalKeyboardKey.keyR, control: true): _triggerRefresh,
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (isFullscreenNotifier.value) {
              isFullscreenNotifier.value = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                filterController.focusCurrentMatch();
              });
              return;
            }
            if (filterController.selectedTournamentId.isNotEmpty) {
              filterController.selectTournament('');
            }
          },
        },
        child: ListenableBuilder(
      listenable: filterController,
      builder: (context, _) {
        if (filterController.isLoading && filterController.allTournaments.isEmpty) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        return ValueListenableBuilder<bool>(
          valueListenable: isFullscreenNotifier,
          builder: (context, isFullscreen, _) {
            return Scaffold(
              backgroundColor: isFullscreen ? Colors.black : Theme.of(context).scaffoldBackgroundColor,
              drawer: !isDesktop && !isFullscreen
                  ? PointerInterceptor(child: const Drawer(backgroundColor: Colors.transparent, child: Sidebar()))
                  : null,
              body: SafeArea(
                top: !isFullscreen,
                bottom: false,
                left: !isFullscreen,
                right: !isFullscreen,
                child: Stack(
                  children: [
                    Row(
                    children: [
                      if (isDesktop && !isFullscreen) ...[
                        SizedBox(width: _sidebarWidth, child: const Sidebar()),
                        MouseRegion(
                          cursor: SystemMouseCursors.resizeColumn,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragStart: (_) => _resizingNotifier.value = true,
                            onHorizontalDragUpdate: (details) {
                              setState(() {
                                _sidebarWidth += details.delta.dx;
                                if (_sidebarWidth < 250) _sidebarWidth = 250;
                                if (_sidebarWidth > 600) _sidebarWidth = 600;
                              });
                            },
                            onHorizontalDragEnd: (_) => _resizingNotifier.value = false,
                            onHorizontalDragCancel: () => _resizingNotifier.value = false,
                            child: Container(width: 12, color: Colors.transparent),
                          ),
                        ),
                      ],
                      Expanded(
                        child: Column(
                          children: [
                            if (!isDesktop && !isFullscreen)
                              MobileHeader(onRefresh: _triggerRefresh),
                            Expanded(
                              child: RefreshIndicator(
                                color: const Color(0xFF0D7FF2),
                                backgroundColor: const Color(0xFF182634),
                                onRefresh: () async {
                                  await filterController.fetchData();
                                },
                                notificationPredicate: (notification) => !isFullscreen,
                                child: SingleChildScrollView(
                                  physics: isFullscreen
                                      ? const NeverScrollableScrollPhysics()
                                      : const AlwaysScrollableScrollPhysics(),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (isFullscreen)
                                        Container(
                                          height: MediaQuery.of(context).size.height,
                                          width: MediaQuery.of(context).size.width,
                                          color: Colors.black,
                                          child: Center(
                                            child: AspectRatio(
                                              aspectRatio: 16 / 9,
                                              child: VideoHero(key: _videoHeroKey, resizingNotifier: _resizingNotifier),
                                            ),
                                          ),
                                        )
                                      else
                                        VideoHero(key: _videoHeroKey, resizingNotifier: _resizingNotifier),
                                      if (!isFullscreen) const MatchDetails(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (!isDesktop && !isFullscreen) const MobileBottomNav(),
                          ],
                        ),
                      ),
                    ],
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: _resizingNotifier,
                    builder: (context, isResizing, child) {
                      if (!isResizing) return const SizedBox.shrink();
                      return Positioned.fill(
                        child: PointerInterceptor(child: Container(color: Colors.transparent)),
                      );
                    },
                  ),
                ],
              ),
            ),
            );
          },
        );
      },
    ),
  ),
    );
  }
}

// --- Components ---

class MobileHeader extends StatelessWidget {
  final VoidCallback? onRefresh;

  const MobileHeader({super.key, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF101922),
        border: Border(bottom: BorderSide(color: Color(0xFF223649))),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    SvgPicture.asset(
                      'assets/app_icon.svg',
                      width: 24,
                      height: 24,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'WTT Organizer',
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.splineSans(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Refresh',
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh, color: Colors.white),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Scaffold.of(context).openDrawer(),
                    icon: const Icon(Icons.menu, color: Colors.white),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Sidebar extends StatelessWidget {
  const Sidebar({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: filterController,
      builder: (context, _) {
        final selectedTournamentId = filterController.selectedTournamentId;
        final isDetailView = selectedTournamentId.isNotEmpty;

        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF101922).withValues(alpha: 0.95),
            border: const Border(right: BorderSide(color: Color(0xFF223649))),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
              // Logo Area
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0xFF223649))),
                ),
                child: Row(
                  children: [
                    SvgPicture.asset(
                      'assets/app_icon.svg',
                      width: 30,
                      height: 30,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        'WTT Organizer',
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.splineSans(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Search
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          onChanged:
                              (value) => filterController.setSearchQuery(value),
                          decoration: InputDecoration(
                            hintText: 'Search matches, players...',
                            hintStyle: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 14,
                            ),
                            prefixIcon: Icon(
                              Icons.search,
                              color: Colors.grey[400],
                              size: 20,
                            ),
                            filled: true,
                            fillColor: const Color(0xFF182634),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: Color(0xFF223649),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: Color(0xFF223649),
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 0,
                            ),
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),

                      if (!isDetailView) ...[
                        // --- LIST VIEW (Filters + Tournament List) ---
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Filters
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'FILTERS',
                                    style: GoogleFonts.splineSans(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey[500],
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => filterController.reset(),
                                    child: const Text(
                                      'Reset',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF0D7FF2),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Year',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                children: [2026, 2025].map((year) {
                                  final isSelected = filterController
                                      .selectedYears
                                      .contains(year);
                                  return ChoiceChip(
                                    label: Text(
                                      year.toString(),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    selected: isSelected,
                                    onSelected:
                                        (_) =>
                                            filterController.toggleYear(year),
                                    backgroundColor: const Color(0xFF182634),
                                    selectedColor: const Color(
                                      0xFF0D7FF2,
                                    ).withValues(alpha: 0.3),
                                    labelStyle: TextStyle(
                                      color:
                                          isSelected
                                              ? Colors.white
                                              : Colors.grey,
                                    ),
                                  );
                                }).toList(),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Tournament Type',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                runSpacing: 0,
                                children: TournamentType.values.map((type) {
                                  final isSelected = filterController
                                      .selectedTypes
                                      .contains(type);
                                  return ChoiceChip(
                                    label: Text(
                                      type.label,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    selected: isSelected,
                                    onSelected:
                                        (_) =>
                                            filterController.toggleType(type),
                                    backgroundColor: const Color(0xFF182634),
                                    selectedColor: const Color(
                                      0xFF0D7FF2,
                                    ).withValues(alpha: 0.3),
                                    labelStyle: TextStyle(
                                      color:
                                          isSelected
                                              ? Colors.white
                                              : Colors.grey,
                                    ),
                                  );
                                }).toList(),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Match Type',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                children: [
                                  FilterChip(
                                    label: const Text('Singles'),
                                    selected: filterController.showSingles,
                                    onSelected:
                                        (_) =>
                                            filterController
                                                .toggleShowSingles(),
                                    backgroundColor: const Color(0xFF182634),
                                    selectedColor: const Color(
                                      0xFF0D7FF2,
                                    ).withValues(alpha: 0.3),
                                    labelStyle: TextStyle(
                                      color:
                                          filterController.showSingles
                                              ? Colors.white
                                              : Colors.grey,
                                      fontSize: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      side: BorderSide.none,
                                    ),
                                    showCheckmark: false,
                                  ),
                                  FilterChip(
                                    label: const Text('Doubles'),
                                    selected: filterController.showDoubles,
                                    onSelected:
                                        (_) =>
                                            filterController
                                                .toggleShowDoubles(),
                                    backgroundColor: const Color(0xFF182634),
                                    selectedColor: const Color(
                                      0xFF0D7FF2,
                                    ).withValues(alpha: 0.3),
                                    labelStyle: TextStyle(
                                      color:
                                          filterController.showDoubles
                                              ? Colors.white
                                              : Colors.grey,
                                      fontSize: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      side: BorderSide.none,
                                    ),
                                    showCheckmark: false,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                              const Text(
                                'Tournaments',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              ...filterController.availableTournaments
                                  .asMap()
                                  .entries
                                  .map((entry) {
                                final index = entry.key;
                                final tournament = entry.value;
                                return TvFocusable(
                                  autoFocus: index == 0,
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                    horizontal: 12,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                  normalBackgroundColor: const Color(0xFF182634),
                                  normalBorderColor: const Color(0xFF223649),
                                  onTap:
                                      () => filterController.selectTournament(
                                        tournament.id,
                                      ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          tournament.name,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const Icon(
                                        Icons.chevron_right,
                                        size: 16,
                                        color: Color(0xFF0D7FF2),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ] else ...[
                        // --- DETAIL VIEW (Back Button + Matches) ---
                        Builder(
                          builder: (context) {
                            final tournament =
                                filterController.allTournaments.firstWhere(
                                  (t) => t.id == selectedTournamentId,
                                  orElse:
                                      () => const Tournament(
                                        id: '',
                                        name: 'Unknown',
                                        year: 0,
                                        type: TournamentType.contender,
                                        location: '',
                                      ),
                                );

                            final matches =
                                filterController.allMatches
                                    .where(
                                      (m) => m.tournamentId == tournament.id,
                                    )
                                    .where(
                                      (m) =>
                                          (m.tag == 'Singles' &&
                                              filterController.showSingles) ||
                                          (m.tag == 'Doubles' &&
                                              filterController.showDoubles),
                                    )
                                    .toList();

                            // Group matches by day and session
                            final Map<String, List<Match>> matchesByDay = {};
                            for (var m in matches) {
                              final groupKey = m.session != null ? '${m.day} - Round ${m.session}' : m.day;
                              matchesByDay.putIfAbsent(groupKey, () => []).add(m);
                            }
                            
                            // Sort groups by effectiveTimestamp (descending) then by session (descending)
                            final sortedDays = matchesByDay.keys.toList()
                              ..sort((a, b) {
                                final matchesA = matchesByDay[a]!;
                                final matchesB = matchesByDay[b]!;

                                DateTime? getMaxDate(List<Match> mList) {
                                  final dates = mList
                                      .map((m) => m.effectiveTimestamp)
                                      .whereType<DateTime>();
                                  if (dates.isEmpty) return null;
                                  return dates.reduce((curr, next) =>
                                      curr.isAfter(next) ? curr : next);
                                }

                                final dateA = getMaxDate(matchesA);
                                final dateB = getMaxDate(matchesB);

                                int dateCompare = 0;
                                if (dateA != null && dateB != null) {
                                  dateCompare = dateB.compareTo(dateA);
                                } else if (dateA == null && dateB != null) {
                                  dateCompare = 1;
                                } else if (dateB == null && dateA != null) {
                                  dateCompare = -1;
                                }
                                
                                if (dateCompare != 0) return dateCompare;

                                final sessionA = matchesA.first.session ?? 0;
                                final sessionB = matchesB.first.session ?? 0;
                                
                                return sessionB.compareTo(sessionA);
                              });

                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TvFocusable(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                      horizontal: 8,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                    onTap:
                                        () => filterController.selectTournament(
                                          '',
                                        ), // Go back
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.arrow_back,
                                          size: 16,
                                          color: Color(0xFF0D7FF2),
                                        ),
                                        SizedBox(width: 8),
                                        Text(
                                          'Back to Tournaments',
                                          style: TextStyle(
                                            color: Color(0xFF0D7FF2),
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    tournament.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  if (matches.isEmpty)
                                    const Text(
                                      'No matches found for current filters.',
                                      style: TextStyle(color: Colors.grey),
                                    ),
                                  FocusTraversalGroup(
                                    policy: WidgetOrderTraversalPolicy(),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        ...sortedDays.asMap().entries.map((dayEntry) {
                                          final dayIndex = dayEntry.key;
                                          final day = dayEntry.value;
                                          final dayMatches = matchesByDay[day]!;
                                          final isDayExpanded =
                                              filterController.isDayExpanded(
                                                tournament.id,
                                                day,
                                              );

                                          return Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              TvFocusable(
                                                autoFocus: dayIndex == 0,
                                                margin: const EdgeInsets.only(bottom: 4),
                                                padding: const EdgeInsets.symmetric(
                                                  vertical: 8,
                                                  horizontal: 6,
                                                ),
                                                borderRadius: BorderRadius.circular(6),
                                                onTap:
                                                    () => filterController.toggleDay(
                                                      tournament.id,
                                                      day,
                                                    ),
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      isDayExpanded
                                                          ? Icons
                                                              .keyboard_arrow_down
                                                          : Icons
                                                              .keyboard_arrow_right,
                                                      size: 18,
                                                      color: const Color(0xFF0D7FF2),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Text(
                                                        day,
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 13,
                                                          fontWeight: FontWeight.bold,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (isDayExpanded)
                                                ...dayMatches.asMap().entries.map((entry) {
                                                  final index = entry.key;
                                                  final match = entry.value;
                                                  final isMatchSelected =
                                                      filterController
                                                          .selectedMatch
                                                          .id ==
                                                      match.id;
                                                  return TvFocusable(
                                                    focusNode: isMatchSelected ? filterController.currentMatchFocusNode : null,
                                                    onRight: isMatchSelected ? () => filterController.focusPlayButton() : null,
                                                    margin: const EdgeInsets.only(bottom: 4),
                                                    padding: const EdgeInsets.symmetric(
                                                      vertical: 8,
                                                      horizontal: 8,
                                                    ),
                                                    borderRadius: BorderRadius.circular(6),
                                                    autoFocus: index == 0,
                                                    normalBackgroundColor: isMatchSelected
                                                        ? const Color(0xFF182634)
                                                        : Colors.transparent,
                                                    normalBorderColor: isMatchSelected
                                                        ? const Color(0xFF0D7FF2)
                                                        : Colors.transparent,
                                                    onTap:
                                                        () => filterController
                                                            .selectMatch(match),
                                                    child: Padding(
                                                      padding: const EdgeInsets.only(left: 14),
                                                      child: Row(
                                                        children: [
                                                          Icon(
                                                            Icons.play_circle_outline,
                                                            size: 16,
                                                            color: isMatchSelected
                                                                ? const Color(0xFF0D7FF2)
                                                                : Colors.grey[400],
                                                          ),
                                                          const SizedBox(width: 8),
                                                          Expanded(
                                                            child: Text(
                                                              match.title,
                                                              style: TextStyle(
                                                                fontSize: 12,
                                                                color: isMatchSelected
                                                                    ? Colors.white
                                                                    : Colors.grey[300],
                                                                fontWeight: isMatchSelected
                                                                    ? FontWeight.bold
                                                                    : FontWeight.normal,
                                                              ),
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  );
                                                }),
                                            ],
                                          );
                                        }),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // Diagnostics & Logs
              TvFocusable(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => const DiagnosticsScreen()),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0D1319),
                    border: Border(top: BorderSide(color: Color(0xFF223649))),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF0D7FF2),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.terminal, color: Colors.white, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Diagnostics',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              'App Logs & Telemetry',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[400],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
}

class VideoHero extends StatefulWidget {
  final ValueNotifier<bool>? resizingNotifier;

  const VideoHero({super.key, this.resizingNotifier});

  @override
  State<VideoHero> createState() => _VideoHeroState();
}

class _VideoHeroState extends State<VideoHero> {
  void _handleFullscreenToggle() {
    FullscreenService.toggleFullscreen((isFullscreen) {
      isFullscreenNotifier.value = isFullscreen;
    });
  }

  @override
  void initState() {
    super.initState();
    FullscreenService.registerGlobalHotkey(_handleFullscreenToggle);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: filterController,
      builder: (context, _) {
        final match = filterController.selectedMatch;
        return VideoPlayerWidget.create(
          key: const Key('main_video_player'),
          resizingNotifier: widget.resizingNotifier,
          matchId: match.id,
          youtubeId: match.youtubeId,
          imageUrl: match.imageUrl,
          offsetSeconds: match.offsetSeconds ?? 0,
          matchDurationSeconds: match.durationSeconds,
          onDoubleTap: _handleFullscreenToggle,
          autoPlay: filterController.hasUserSelectedMatch,
        );
      },
    );
  }
}

class MatchDetails extends StatelessWidget {
  const MatchDetails({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: filterController,
      builder: (context, _) {
        final match = filterController.selectedMatch;
        final tournament = filterController.allTournaments.firstWhere(
          (t) => t.id == match.tournamentId,
          orElse: () => const Tournament(
              id: '',
              name: 'Unknown',
              year: 0,
              type: TournamentType.contender,
              location: ''),
        );

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Tag & Tournament Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D7FF2).withValues(alpha: 0.2),
                      border: Border.all(
                        color: const Color(0xFF0D7FF2).withValues(alpha: 0.3),
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      match.tag,
                      style: const TextStyle(
                        color: Color(0xFF0D7FF2),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tournament.location.isNotEmpty
                          ? '${tournament.name} • ${tournament.location}'
                          : tournament.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 2. Main Match Title
              Text(
                match.title,
                style: GoogleFonts.splineSans(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  height: 1.15,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),

              // 3. YouTube-style Description Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF182634),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF223649)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Stats / Meta Chips
                    Wrap(
                      spacing: 20,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (match.views.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.visibility, size: 16, color: Colors.grey[400]),
                              const SizedBox(width: 6),
                              Text(
                                '${match.views} views',
                                style: TextStyle(
                                  color: Colors.grey[300],
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        if (match.date.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.calendar_today, size: 15, color: Colors.grey[400]),
                              const SizedBox(width: 6),
                              Text(
                                match.date,
                                style: TextStyle(
                                  color: Colors.grey[300],
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        if (match.durationFormatted.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.timer_outlined, size: 16, color: Color(0xFF0D7FF2)),
                              const SizedBox(width: 6),
                              Text(
                                match.durationFormatted,
                                style: const TextStyle(
                                  color: Color(0xFF0D7FF2),
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        if (match.day.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.sports_tennis, size: 16, color: Colors.grey[400]),
                              const SizedBox(width: 6),
                              Text(
                                match.session != null
                                    ? '${match.day} • Session ${match.session}'
                                    : match.day,
                                style: TextStyle(
                                  color: Colors.grey[300],
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Divider(color: Color(0xFF223649), height: 1),
                    const SizedBox(height: 14),

                    // Detailed Match Breakdown
                    Text(
                      'Tournament: ${tournament.name} (${tournament.year})\n'
                      'Location: ${tournament.location.isNotEmpty ? tournament.location : "International"}\n'
                      'Round: ${match.day}${match.session != null ? " • Session " + match.session.toString() : ""}'
                      '${match.time.isNotEmpty ? " • Scheduled Time: " + match.time : ""}\n'
                      '${match.youtubeId != null ? "YouTube Video: https://youtu.be/" + match.youtubeId! : ""}',
                      style: TextStyle(
                        color: Colors.grey[300],
                        height: 1.6,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class MobileBottomNav extends StatelessWidget {
  const MobileBottomNav({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF101922),
        border: Border(top: BorderSide(color: Color(0xFF223649))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(Icons.play_circle, 'Live', isActive: true),
              _buildNavItem(Icons.bookmarks, 'Saved'),
              _buildNavItem(
                Icons.terminal,
                'Diagnostics',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => const DiagnosticsScreen()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, {bool isActive = false, VoidCallback? onTap}) {
    final color = isActive ? const Color(0xFF0D7FF2) : const Color(0xFF90ADCB);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
