import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://yxegxufjztnsogjrqsqw.supabase.co',
    anonKey: 'sb_publishable_YLN9F1xMInlM8BbwF_dA3Q_rBU9V687',
  );
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
      title: 'WTT Match Explorer',
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
  smash('Smash'),
  youthContender('Youth Contender');

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
  });
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

  Future<void> fetchData() async {
    _isLoading = true;
    notifyListeners();
    try {
      final response = await Supabase.instance.client
          .from('v_tournament_schedule')
          .select()
          .order('upload_date', ascending: false);

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
        final offsetSeconds = row['video_offset_seconds'] as int?;

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
        ));
      }

      _allTournaments = tournamentsMap.values.toList();
      _allMatches = matches;

      // Update selected match if none selected
      if (_allMatches.isNotEmpty && _selectedMatch == null) {
        _selectedMatch = _allMatches.first;
      }
    } catch (e) {
      debugPrint('Error fetching data: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  TournamentType _inferType(String name) {
    if (name.contains('Champions')) return TournamentType.champions;
    if (name.contains('Smash')) return TournamentType.smash;
    if (name.contains('Youth Contender')) return TournamentType.youthContender;
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

  void selectMatch(Match match) {
    _selectedMatch = match;
    notifyListeners();
  }

  void selectTournament(String tournamentId) {
    if (_selectedTournamentId == tournamentId) {
      _selectedTournamentId = '';
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

  void toggleType(TournamentType type) {
    if (_selectedTypes.contains(type)) {
      _selectedTypes.remove(type);
    } else {
      _selectedTypes.add(type);
    }
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
      final typeMatch =
          _selectedTypes.isEmpty || _selectedTypes.contains(tournament.type);
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
      final typeMatch =
          _selectedTypes.isEmpty || _selectedTypes.contains(tournament.type);
      return yearMatch && typeMatch;
    }).toList();
  }
}

final filterController = FilterController();

// --- Main Layout ---

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  double _sidebarWidth = 320;
  final ValueNotifier<bool> _resizingNotifier = ValueNotifier(false);

  @override
  void dispose() {
    _resizingNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Determine screen size for responsiveness
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    return ListenableBuilder(
      listenable: filterController,
      builder: (context, _) {
        if (filterController.isLoading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return Scaffold(
          drawer: !isDesktop
              ? PointerInterceptor(
                  child: const Drawer(
                    backgroundColor: Colors.transparent,
                    child: Sidebar(),
                  ),
                )
              : null,
          body: Stack(
            children: [
              Row(
                children: [
                  if (isDesktop) ...[
                    SizedBox(
                      width: _sidebarWidth,
                      child: const Sidebar(),
                    ),
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragStart: (_) {
                          _resizingNotifier.value = true;
                        },
                        onHorizontalDragUpdate: (details) {
                          setState(() {
                            _sidebarWidth += details.delta.dx;
                            if (_sidebarWidth < 250) _sidebarWidth = 250;
                            if (_sidebarWidth > 600) _sidebarWidth = 600;
                          });
                        },
                        onHorizontalDragEnd: (_) {
                          _resizingNotifier.value = false;
                        },
                        onHorizontalDragCancel: () {
                          _resizingNotifier.value = false;
                        },
                        child: Container(
                          width: 12,
                          color: Colors.transparent,
                        ),
                      ),
                    ),
                  ],
                  Expanded(
                    child: Column(
                      children: [
                        if (!isDesktop) const MobileHeader(),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                VideoHero(resizingNotifier: _resizingNotifier),
                                const MatchDetails(),
                                const UpNextSection(),
                              ],
                            ),
                          ),
                        ),
                        if (!isDesktop) const MobileBottomNav(),
                      ],
                    ),
                  ),
                ],
              ),
              // We keep the PointerInterceptor as a safety net, though the thumbnail might be enough.
              // It doesn't hurt to keep it.
              ValueListenableBuilder<bool>(
                valueListenable: _resizingNotifier,
                builder: (context, isResizing, child) {
                  if (!isResizing) return const SizedBox.shrink();
                  return Positioned.fill(
                    child: PointerInterceptor(
                      child: Container(
                        color: Colors.transparent,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// --- Components ---

class MobileHeader extends StatelessWidget {
  const MobileHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF101922),
        border: Border(bottom: BorderSide(color: Color(0xFF223649))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.sports_tennis, color: Color(0xFF0D7FF2)),
              const SizedBox(width: 8),
              Text(
                'TT World',
                style: GoogleFonts.splineSans(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          IconButton(
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu, color: Colors.white),
          ),
        ],
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
                    const Icon(
                      Icons.sports_tennis,
                      color: Color(0xFF0D7FF2),
                      size: 30,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        'Match Explorer',
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
                              ...filterController.availableTournaments.map((
                                tournament,
                              ) {
                                return InkWell(
                                  onTap:
                                      () => filterController.selectTournament(
                                        tournament.id,
                                      ),
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 4),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                      horizontal: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(6),
                                      color: Colors.transparent,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            tournament.name,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: Colors.grey[400],
                                              fontWeight: FontWeight.normal,
                                            ),
                                          ),
                                        ),
                                        Icon(
                                          Icons.chevron_right,
                                          size: 16,
                                          color: Colors.grey[600],
                                        ),
                                      ],
                                    ),
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

                            // Group matches by day
                            final Map<String, List<Match>> matchesByDay = {};
                            for (var m in matches) {
                              matchesByDay.putIfAbsent(m.day, () => []).add(m);
                            }
                            
                            // Sort days by max uploadDate (descending)
                            final sortedDays = matchesByDay.keys.toList()
                              ..sort((a, b) {
                                final matchesA = matchesByDay[a]!;
                                final matchesB = matchesByDay[b]!;

                                DateTime? getMaxDate(List<Match> mList) {
                                  final dates = mList
                                      .map((m) => m.uploadDate)
                                      .whereType<DateTime>();
                                  if (dates.isEmpty) return null;
                                  return dates.reduce((curr, next) =>
                                      curr.isAfter(next) ? curr : next);
                                }

                                final dateA = getMaxDate(matchesA);
                                final dateB = getMaxDate(matchesB);

                                if (dateA == null && dateB == null) {
                                  return a.compareTo(b);
                                }
                                if (dateA == null) return 1;
                                if (dateB == null) return -1;
                                return dateB.compareTo(dateA);
                              });

                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  InkWell(
                                    onTap:
                                        () => filterController.selectTournament(
                                          '',
                                        ), // Go back
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      child: Row(
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
                                  ...sortedDays.map((day) {
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
                                        InkWell(
                                          onTap:
                                              () => filterController.toggleDay(
                                                tournament.id,
                                                day,
                                              ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 12,
                                              horizontal: 4,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  isDayExpanded
                                                      ? Icons
                                                          .keyboard_arrow_down
                                                      : Icons
                                                          .keyboard_arrow_right,
                                                  size: 16,
                                                  color: Colors.grey[500],
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  day,
                                                  style: TextStyle(
                                                    color: Colors.grey[400],
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        if (isDayExpanded)
                                          ...dayMatches.map((match) {
                                            final isMatchSelected =
                                                filterController
                                                    .selectedMatch
                                                    .id ==
                                                match.id;
                                            return InkWell(
                                              onTap:
                                                  () => filterController
                                                      .selectMatch(match),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 8,
                                                      horizontal: 8,
                                                    ),
                                                margin: const EdgeInsets.only(
                                                  left: 28,
                                                  bottom: 4,
                                                ),
                                                decoration: BoxDecoration(
                                                  color:
                                                      isMatchSelected
                                                          ? const Color(
                                                            0xFF182634,
                                                          )
                                                          : Colors.transparent,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      Icons.play_circle_outline,
                                                      size: 14,
                                                      color:
                                                          isMatchSelected
                                                              ? const Color(
                                                                0xFF0D7FF2,
                                                              )
                                                              : Colors.grey[
                                                                600
                                                              ],
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Text(
                                                        match.title,
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          color:
                                                              isMatchSelected
                                                                  ? Colors.white
                                                                  : Colors.grey[
                                                                    500
                                                                  ],
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
              // User Profile
              Container(
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
                        gradient: LinearGradient(
                          colors: [Color(0xFF0D7FF2), Colors.purple],
                        ),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'JD',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'John Doe',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Premium Member',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    const Icon(Icons.settings, color: Colors.grey, size: 20),
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

class VideoHero extends StatefulWidget {
  final ValueNotifier<bool>? resizingNotifier;

  const VideoHero({super.key, this.resizingNotifier});

  @override
  State<VideoHero> createState() => _VideoHeroState();
}

class _VideoHeroState extends State<VideoHero> {
  YoutubePlayerController? _controller;
  String? _lastMatchId;

  bool get _isPlayerSupported => kIsWeb;

  @override
  void initState() {
    super.initState();
    if (_isPlayerSupported) {
      _controller = YoutubePlayerController(
        params: const YoutubePlayerParams(
          showControls: true,
          showFullscreenButton: true,
          mute: false,
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: filterController,
      builder: (context, _) {
        final match = filterController.selectedMatch;

        if (match.id != _lastMatchId) {
          _lastMatchId = match.id;
          if (_controller != null) {
            if (match.youtubeId != null) {
              _controller!.loadVideoById(
                videoId: match.youtubeId!,
                startSeconds: match.offsetSeconds?.toDouble(),
              );
            } else {
              _controller!.stopVideo();
            }
          }
        }

        final thumbnailWidget = AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: NetworkImage(match.imageUrl),
                fit: BoxFit.cover,
                opacity: 0.8,
                onError: (exception, stackTrace) {},
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D7FF2).withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0D7FF2).withValues(alpha: 0.6),
                        blurRadius: 50,
                        spreadRadius: 10,
                      ),
                    ],
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                      width: 4,
                    ),
                  ),
                  child: const Icon(
                    Icons.play_arrow,
                    size: 48,
                    color: Colors.white,
                  ),
                ),
                Positioned(
                  top: 24,
                  left: 24,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 4),
                      ],
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.fiber_manual_record,
                          size: 8,
                          color: Colors.white,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'LIVE',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

        if (match.youtubeId == null || _controller == null) {
          return thumbnailWidget;
        }

        return AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand, // Ensures children fill the AspectRatio box
            children: [
              YoutubePlayer(
                controller: _controller!,
              ),
              if (widget.resizingNotifier != null)
                ValueListenableBuilder<bool>(
                  valueListenable: widget.resizingNotifier!,
                  builder: (context, isResizing, _) {
                    if (isResizing) {
                      return thumbnailWidget; // Show thumbnail during resize to hide heavy iframe
                    }
                    return const SizedBox.shrink();
                  },
                ),
            ],
          ),
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

        return Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFF223649))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF0D7FF2,
                                ).withValues(alpha: 0.2),
                                border: Border.all(
                                  color: const Color(
                                    0xFF0D7FF2,
                                  ).withValues(alpha: 0.2),
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                match.tag,
                                style: const TextStyle(
                                  color: Color(0xFF0D7FF2),
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              tournament.name,
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          match.title,
                          style: GoogleFonts.splineSans(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Icon(
                              Icons.visibility,
                              size: 16,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${match.views} views',
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Icon(
                              Icons.schedule,
                              size: 16,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(width: 4),
                            Text(
                              match.date,
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Witness the clash of titans in the grand final of ${tournament.name} at ${tournament.location}. ${match.title} in a match that promises spectacular rallies.',
                          style: TextStyle(
                            color: Colors.grey[400],
                            height: 1.5,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (MediaQuery.of(context).size.width > 768) ...[
                    const SizedBox(width: 24),
                    Row(
                      children: [
                        _buildActionButton(Icons.favorite, 'Save'),
                        const SizedBox(width: 12),
                        _buildActionButton(Icons.share, 'Share'),
                      ],
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionButton(IconData icon, String label) {
    return ElevatedButton.icon(
      onPressed: () {},
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF182634),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        side: const BorderSide(color: Color(0xFF223649)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

class UpNextSection extends StatelessWidget {
  const UpNextSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: filterController,
      builder: (context, _) {
        final filteredMatches = filterController.filteredMatches;

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    filteredMatches.isEmpty
                        ? 'No matches found'
                        : 'Explore Matches (${filteredMatches.length})',
                    style: GoogleFonts.splineSans(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Row(
                    children: [
                      _buildNavButton(Icons.chevron_left),
                      const SizedBox(width: 8),
                      _buildNavButton(Icons.chevron_right),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (filteredMatches.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Column(
                      children: [
                        Icon(
                          Icons.search_off,
                          size: 48,
                          color: Colors.grey[600],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Try adjusting your filters',
                          style: TextStyle(color: Colors.grey[400]),
                        ),
                      ],
                    ),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    int crossAxisCount = 1;
                    if (constraints.maxWidth > 900) {
                      crossAxisCount = 3;
                    } else if (constraints.maxWidth > 600) {
                      crossAxisCount = 2;
                    }

                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 20,
                        mainAxisSpacing: 20,
                        childAspectRatio: 16 / 12,
                      ),
                      itemCount: filteredMatches.length,
                      itemBuilder: (context, index) {
                        return _buildMatchCard(filteredMatches[index]);
                      },
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNavButton(IconData icon) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFF223649)),
      ),
      child: Icon(icon, color: Colors.grey[400], size: 20),
    );
  }

  Widget _buildMatchCard(Match match) {
    final tournament = filterController.allTournaments.firstWhere(
      (t) => t.id == match.tournamentId,
      orElse: () => const Tournament(
          id: '',
          name: 'Unknown',
          year: 0,
          type: TournamentType.contender,
          location: ''),
    );
    final isSelected = filterController.selectedMatch.id == match.id;

    return GestureDetector(
      onTap: () => filterController.selectMatch(match),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFF0D7FF2)
                      : const Color(0xFF223649),
                  width: isSelected ? 2 : 1,
                ),
                color: const Color(0xFF182634),
                image: DecorationImage(
                  image: NetworkImage(match.imageUrl),
                  fit: BoxFit.cover,
                  onError: (exception, stackTrace) {},
                ),
              ),
              child: Stack(
                children: [
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        match.time,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                  if (isSelected)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Color(0xFF0D7FF2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            match.title,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
              height: 1.2,
              color: isSelected ? const Color(0xFF0D7FF2) : Colors.white,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF223649),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  match.tag,
                  style: TextStyle(
                    color: Colors.grey[300],
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tournament.name,
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildNavItem(Icons.play_circle, 'Live', isActive: true),
          _buildNavItem(Icons.bookmarks, 'Saved'),
          _buildNavItem(Icons.person, 'Profile'),
        ],
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, {bool isActive = false}) {
    final color = isActive ? const Color(0xFF0D7FF2) : const Color(0xFF90ADCB);
    return Column(
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
    );
  }
}
