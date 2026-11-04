package wtt_api

import (
	"testing"
	"time"
)

func TestNameSimilarity_ExactAndAccents(t *testing.T) {
	tests := []struct {
		name1    string
		name2    string
		minScore float64
	}{
		{"JANG Woojin", "Woojin JANG", 1.0},
		{"Félix Lebrun", "FELIX LEBRUN", 1.0},
		{"Truls Möregårdh", "Truls Moregardh", 1.0},
		{"LIN YUN-JU", "Lin Yun Ju", 1.0},
		{"FRANZISKA", "FRANZISKA Patrick", 0.90},
		{"Wang Chuqin", "Wang Chuqin", 1.0},
		{"WANG CHUQlN", "Wang Chuqin", 0.85}, // 1-char OCR typo (l vs i)
	}

	for _, tt := range tests {
		score := NameSimilarity(tt.name1, tt.name2)
		if score < tt.minScore {
			t.Errorf("NameSimilarity(%q, %q) = %v, expected at least %v", tt.name1, tt.name2, score, tt.minScore)
		}
	}
}

func TestPairSimilarity_Symmetrical(t *testing.T) {
	// Direct orientation
	scoreDirect, isSwapped := PairSimilarity("Jang Woojin", "Franziska Patrick", "JANG Woojin", "FRANZISKA Patrick")
	if scoreDirect < 0.95 || isSwapped {
		t.Errorf("expected direct pair match, got score=%v, swapped=%v", scoreDirect, isSwapped)
	}

	// Swapped orientation (video OCR has players swapped left-to-right)
	scoreSwapped, isSwapped2 := PairSimilarity("Franziska", "Jang Woojin", "JANG Woojin", "FRANZISKA Patrick")
	if scoreSwapped < 0.90 || !isSwapped2 {
		t.Errorf("expected swapped pair match, got score=%v, swapped=%v", scoreSwapped, isSwapped2)
	}
}

func TestExtractRound(t *testing.T) {
	tests := []struct {
		code string
		desc string
		want string
	}{
		{"TTEMSINGLES-----------FNL-000100----------", "Men's Singles - Final - Match 1", "Final"},
		{"TTEMSINGLES-----------SFNL000100----------", "Men's Singles - Semi-Final - Match 1", "Semi-Final"},
		{"TTEMSINGLES-----------QFNL000100----------", "Men's Singles - Quarter-Final", "Quarter-Final"},
		{"TTEMSINGLES-----------R16-000100----------", "Men's Singles - Round of 16", "Round of 16"},
		{"TTEMSINGLES-----------R32-000100----------", "Men's Singles - Round of 32", "Round of 32"},
		{"UNKNOWN-CODE", "Women's Singles - Final", "Final"},
	}

	for _, tt := range tests {
		got := ExtractRoundFromDocumentCode(tt.code, tt.desc)
		if got != tt.want {
			t.Errorf("ExtractRound(%q, %q) = %q, want %q", tt.code, tt.desc, got, tt.want)
		}
	}
}

func TestAlignMatches_GeneratesAuditReportWithBooleanHighlight(t *testing.T) {
	dbMatches := []DBMatchRecord{
		{
			ID:             101,
			TournamentName: "WTT Champions Montpellier",
			TournamentYear: 2026,
			TeamA:          "JANG WOOJIN",
			TeamB:          "FRANZISKA",
			YoutubeID:      "vid_final",
			VideoTitle:     "Montpellier Final",
		},
		{
			ID:             102,
			TournamentName: "WTT Champions Montpellier",
			TournamentYear: 2026,
			TeamA:          "FELIX LEBRUN",
			TeamB:          "ALEXIS LEBRUN",
			YoutubeID:      "vid_semifinal",
			VideoTitle:     "Montpellier SF",
		},
		{
			ID:             103,
			TournamentName: "WTT Champions Montpellier",
			TournamentYear: 2026,
			TeamA:          "UNKNOWN OCR A",
			TeamB:          "UNKNOWN OCR B",
			YoutubeID:      "vid_unmatched",
			VideoTitle:     "Unknown Match",
		},
	}

	wttMatches := []WTTOfficialMatch{
		{
			ID:           16752548,
			DocumentCode: "TTEMSINGLES-----------FNL-000100----------",
			SubEventType: "Men Singles",
			MatchCard: WTTMatchCard{
				SubEventName:        "Men's Singles",
				SubEventDescription: "Men's Singles - Final",
				OverallScores:       "4-3",
				GameScores:          "11-7, 11-9, 9-11, 11-8",
				Competitors: []WTTCompetitor{
					{
						CompetitorName: "JANG Woojin",
						CompetitorOrg:  "KOR",
					},
					{
						CompetitorName: "FRANZISKA Patrick",
						CompetitorOrg:  "GER",
					},
				},
				MatchDateTime: WTTMatchDateTime{
					StartDateUTC: "2026-11-01T17:30:00Z",
				},
			},
		},
		{
			ID:           16752549,
			DocumentCode: "TTEMSINGLES-----------SFNL000100----------",
			SubEventType: "Men Singles",
			MatchCard: WTTMatchCard{
				SubEventName:        "Men's Singles",
				SubEventDescription: "Men's Singles - Semi-Final",
				OverallScores:       "4-2",
				Competitors: []WTTCompetitor{
					{
						CompetitorName: "LEBRUN Felix",
						CompetitorOrg:  "FRA",
					},
					{
						CompetitorName: "LEBRUN Alexis",
						CompetitorOrg:  "FRA",
					},
				},
				MatchDateTime: WTTMatchDateTime{
					StartDateUTC: "2026-11-01T13:00:00Z",
				},
			},
		},
		{
			ID:           16752550,
			DocumentCode: "TTEMSINGLES-----------R16-000100----------",
			SubEventType: "Men Singles",
			MatchCard: WTTMatchCard{
				SubEventName:        "Men's Singles",
				SubEventDescription: "Men's Singles - R16",
				OverallScores:       "3-1",
				Competitors: []WTTCompetitor{
					{
						CompetitorName: "HARIMOTO Tomokazu",
						CompetitorOrg:  "JPN",
					},
					{
						CompetitorName: "MOREGARD Truls",
						CompetitorOrg:  "SWE",
					},
				},
			},
		},
	}

	report := AlignMatches("WTT Champions Montpellier", 2026, 3250, dbMatches, wttMatches, 0.75)

	if report.MatchedCount != 2 {
		t.Fatalf("expected 2 matched records, got %d", report.MatchedCount)
	}
	if report.UnmatchedDBCount != 1 {
		t.Fatalf("expected 1 unmatched DB record, got %d", report.UnmatchedDBCount)
	}
	if report.UnmatchedWTTCount != 1 {
		t.Fatalf("expected 1 unmatched WTT record, got %d", report.UnmatchedWTTCount)
	}

	// Verify boolean flags and field contents
	var foundFinal, foundUnknown, foundHarimoto bool
	for _, m := range report.Matches {
		if m.IsMatched && m.WTTRound == "Final" {
			foundFinal = true
			if m.WTTScore != "4-3" {
				t.Errorf("expected score 4-3, got %s", m.WTTScore)
			}
			if m.WTTCountries.TeamA != "KOR" || m.WTTCountries.TeamB != "GER" {
				t.Errorf("expected countries KOR vs GER, got %s vs %s", m.WTTCountries.TeamA, m.WTTCountries.TeamB)
			}
		}
		if !m.IsMatched && m.DBMatch != nil && m.DBMatch.TeamA == "UNKNOWN OCR A" {
			foundUnknown = true
			if m.FailureReason == "" {
				t.Errorf("expected failure reason for unmatched DB match")
			}
		}
		if !m.IsMatched && m.WTTMatch != nil && m.WTTPlayerNames.TeamA == "HARIMOTO Tomokazu" {
			foundHarimoto = true
		}
	}

	if !foundFinal {
		t.Errorf("Final match was not matched properly")
	}
	if !foundUnknown {
		t.Errorf("Unknown DB match was not recorded as unmatched")
	}
	if !foundHarimoto {
		t.Errorf("Harimoto WTT match was not recorded as unmatched")
	}
}

func TestAlignMatches_DoesNotRelyOnTableNumber(t *testing.T) {
	// Setup DB match without any table info
	streamStart := time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC)
	dbMatches := []DBMatchRecord{
		{
			ID:                 101,
			TeamA:              "DANG QIU",
			TeamB:              "ELIAS RANEFUR",
			VideoTitle:         "LIVE! Session 2", // No table in title
			VideoOffsetSeconds: 1800,              // 10:30 UTC
			StreamStartUTC:     &streamStart,
		},
	}

	wttMatches := []WTTOfficialMatch{
		{
			DocumentCode: "M001",
			MatchCard: WTTMatchCard{
				TableNumber: "T09", // Different or arbitrary table
				TableName:   "Table 9",
				Competitors: []WTTCompetitor{
					{CompetitorName: "QIU Dang", CompetitorOrg: "GER"},
					{CompetitorName: "RANEFUR Elias", CompetitorOrg: "SWE"},
				},
				MatchDateTime: WTTMatchDateTime{
					StartDateUTC: "2026-11-03T10:35:00Z", // Within 5 minutes
				},
				OverallScores: "3-1",
			},
		},
	}

	report := AlignMatches("Test Tournament", 2026, 3252, dbMatches, wttMatches, 0.70)
	if report.MatchedCount != 1 {
		t.Fatalf("expected 1 match, got %d", report.MatchedCount)
	}
	matched := report.Matches[0]
	if !matched.IsMatched {
		t.Errorf("expected match to be matched regardless of table number")
	}
	if matched.Confidence < 0.90 {
		t.Errorf("expected high confidence match, got %f", matched.Confidence)
	}
}

func TestParseWTTStartTime_AllFormats(t *testing.T) {
	tests := []struct {
		name     string
		match    WTTOfficialMatch
		expected time.Time
	}{
		{
			name: "RFC3339Nano with 7 decimal places",
			match: WTTOfficialMatch{
				MatchCard: WTTMatchCard{
					MatchDateTime: WTTMatchDateTime{
						StartDateUTC: "2026-11-03T21:06:43.9872362+00:00",
					},
				},
			},
			expected: time.Date(2026, 11, 3, 21, 6, 43, 987236200, time.UTC),
		},
		{
			name: "Standard RFC3339 with Z",
			match: WTTOfficialMatch{
				MatchCard: WTTMatchCard{
					MatchDateTime: WTTMatchDateTime{
						StartDateUTC: "2026-11-03T21:06:43Z",
					},
				},
			},
			expected: time.Date(2026, 11, 3, 21, 6, 43, 0, time.UTC),
		},
		{
			name: "Slashed Date Format",
			match: WTTOfficialMatch{
				MatchCard: WTTMatchCard{
					MatchDateTime: WTTMatchDateTime{
						StartDateUTC: "11/03/2026 21:06:43",
					},
				},
			},
			expected: time.Date(2026, 11, 3, 21, 6, 43, 0, time.UTC),
		},
		{
			name: "Fallback to StartDateLocal",
			match: WTTOfficialMatch{
				StartDateLocal: "2026-11-03T21:06:43",
			},
			expected: time.Date(2026, 11, 3, 21, 6, 43, 0, time.UTC),
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			parsed := ParseWTTStartTime(tc.match)
			if parsed == nil {
				t.Fatalf("expected non-nil parsed time")
			}
			if !parsed.Equal(tc.expected) {
				t.Errorf("expected %v, got %v", tc.expected, *parsed)
			}
		})
	}
}

func TestAlignMatches_IntraStreamDuplicates(t *testing.T) {
	streamStart := time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC)

	// Two DB matches in the same stream matching the same player matchup
	dbMatches := []DBMatchRecord{
		{
			ID:                 201,
			YoutubeID:          "stream_xyz",
			TeamA:              "WANG CHUQIN",
			TeamB:              "LIN YUN-JU",
			VideoTitle:         "Day 1 Stream",
			VideoOffsetSeconds: 1000,
			StreamStartUTC:     &streamStart,
		},
		{
			ID:                 202,
			YoutubeID:          "stream_xyz", // Same stream
			TeamA:              "WANG CHUQIN",
			TeamB:              "LIN YUN-JU",
			VideoTitle:         "Day 1 Stream",
			VideoOffsetSeconds: 7000, // Later replay / highlight in the stream
			StreamStartUTC:     &streamStart,
		},
	}

	wttMatches := []WTTOfficialMatch{
		{
			ID:           5001,
			DocumentCode: "M_CHUQIN_LIN",
			MatchCard: WTTMatchCard{
				Competitors: []WTTCompetitor{
					{CompetitorName: "WANG Chuqin", CompetitorOrg: "CHN"},
					{CompetitorName: "LIN Yun-Ju", CompetitorOrg: "TPE"},
				},
				MatchDateTime: WTTMatchDateTime{
					StartDateUTC: "2026-11-03T10:15:00Z",
				},
				OverallScores: "3-0",
			},
		},
	}

	report := AlignMatches("Test Tournament", 2026, 9999, dbMatches, wttMatches, 0.70)

	if report.MatchedCount != 1 {
		t.Fatalf("expected exactly 1 primary match, got %d", report.MatchedCount)
	}

	var primaryMatched, duplicateFound bool
	for _, m := range report.Matches {
		if m.DBMatch != nil && m.DBMatch.ID == 201 {
			if m.IsMatched && !m.IsDuplicate {
				primaryMatched = true
			}
		}
		if m.DBMatch != nil && m.DBMatch.ID == 202 {
			if !m.IsMatched && m.IsDuplicate {
				duplicateFound = true
			}
		}
	}

	if !primaryMatched {
		t.Errorf("expected first match (ID 201) to be primary matched")
	}
	if !duplicateFound {
		t.Errorf("expected second match (ID 202) to be flagged as intra-stream duplicate")
	}
}

func TestAlignMatches_TimeWindowPruningAndTolerance(t *testing.T) {
	streamStart := time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC)

	dbMatches := []DBMatchRecord{
		{
			ID:                 301,
			TeamA:              "FALCK", // Partial OCR (similarity ~0.75, weak candidate)
			TeamB:              "MOREGARD",
			VideoOffsetSeconds: 1200, // 10:20 UTC
			StreamStartUTC:     &streamStart,
		},
		{
			ID:                 302,
			TeamA:              "LEBRUN",   // Partial OCR + typo (similarity ~0.78, weak candidate)
			TeamB:              "HARINOTO", // Typo in Harimoto
			VideoOffsetSeconds: 20000,      // 15:33 UTC (5.5 hours later)
			StreamStartUTC:     &streamStart,
		},
		{
			ID:                 303,
			TeamA:              "FELIX LEBRUN", // Exact match (similarity ~1.0)
			TeamB:              "TOMOKAZU HARIMOTO",
			VideoOffsetSeconds: 20000, // 15:33 UTC (5.5 hours later, but 100% exact names)
			StreamStartUTC:     &streamStart,
		},
	}

	wttMatches := []WTTOfficialMatch{
		{
			ID:           6001,
			DocumentCode: "M_FALCK_MOREGARD",
			MatchCard: WTTMatchCard{
				Competitors: []WTTCompetitor{
					{CompetitorName: "FALCK Mattias", CompetitorOrg: "SWE"},
					{CompetitorName: "MOREGARD Truls", CompetitorOrg: "SWE"},
				},
				MatchDateTime: WTTMatchDateTime{
					StartDateUTC: "2026-11-03T10:30:00Z", // Within 10 mins (inside window)
				},
			},
		},
		{
			ID:           6002,
			DocumentCode: "M_LEBRUN_HARIMOTO",
			MatchCard: WTTMatchCard{
				Competitors: []WTTCompetitor{
					{CompetitorName: "LEBRUN Felix", CompetitorOrg: "FRA"},
					{CompetitorName: "HARIMOTO Tomokazu", CompetitorOrg: "JPN"},
				},
				MatchDateTime: WTTMatchDateTime{
					StartDateUTC: "2026-11-03T10:00:00Z", // Scheduled at 10:00 UTC
				},
			},
		},
	}

	report := AlignMatches("Test Tournament", 2026, 9999, dbMatches, wttMatches, 0.70)

	matchedMap := make(map[int64]bool)
	for _, m := range report.Matches {
		if m.DBMatch != nil && m.IsMatched {
			matchedMap[m.DBMatch.ID] = true
		}
	}

	// 1. Match 301 is weak (0.75) but inside time window -> SHOULD match
	if !matchedMap[301] {
		t.Errorf("expected match 301 to be matched within empirical time window")
	}

	// 2. Match 302 is weak (0.75) and far outside time window (5.5h) -> SHOULD BE PRUNED
	if matchedMap[302] {
		t.Errorf("expected match 302 to be pruned by time window")
	}

	// 3. Match 303 is exact (1.0) despite being far outside window -> MUST NOT BE PRUNED
	if !matchedMap[303] {
		t.Errorf("expected match 303 to be preserved due to high confidence baseScore >= 0.85")
	}
}

func TestAlignMatches_DoublesMatchupPermutations(t *testing.T) {
	dbMatches := []DBMatchRecord{
		{
			ID:    401,
			TeamA: "LIN SHIDONG & KUAI MAN",
			TeamB: "WONG CHUN TING & DOO HOI KEM",
		},
	}

	// WTT has partners in reverse order and teams swapped left-to-right
	wttMatches := []WTTOfficialMatch{
		{
			ID:           7001,
			DocumentCode: "XDOUBLES_FNL",
			MatchCard: WTTMatchCard{
				Competitors: []WTTCompetitor{
					{CompetitorName: "DOO Hoi Kem/WONG Chun Ting", CompetitorOrg: "HKG"},
					{CompetitorName: "KUAI Man/LIN Shidong", CompetitorOrg: "CHN"},
				},
				OverallScores: "3-2",
			},
		},
	}

	report := AlignMatches("Test Tournament", 2026, 9999, dbMatches, wttMatches, 0.70)

	if report.MatchedCount != 1 {
		t.Fatalf("expected doubles match to align successfully, got matched count: %d", report.MatchedCount)
	}

	m := report.Matches[0]
	if !m.IsMatched {
		t.Errorf("expected doubles match to be matched")
	}
	if m.Confidence < 0.90 {
		t.Errorf("expected high confidence for doubles pair permutation, got %f", m.Confidence)
	}
}

func TestAlignMatches_DisambiguatesRematchUsingTime(t *testing.T) {
	morningStreamStart := time.Date(2026, 11, 3, 9, 30, 0, 0, time.UTC)
	eveningStreamStart := time.Date(2026, 11, 3, 17, 30, 0, 0, time.UTC)

	// Two DB segments from two different video streams featuring the exact same players
	dbMatches := []DBMatchRecord{
		{
			ID:                 501,
			YoutubeID:          "morning_stream",
			TeamA:              "MA LONG",
			TeamB:              "FAN ZHENDONG",
			VideoTitle:         "Day 1 Morning Session",
			VideoOffsetSeconds: 1800, // 10:00 UTC
			StreamStartUTC:     &morningStreamStart,
		},
		{
			ID:                 502,
			YoutubeID:          "evening_stream",
			TeamA:              "MA LONG",
			TeamB:              "FAN ZHENDONG",
			VideoTitle:         "Day 1 Evening Session",
			VideoOffsetSeconds: 1800, // 18:00 UTC
			StreamStartUTC:     &eveningStreamStart,
		},
	}

	// Two official WTT matches with the same players at 10:00 UTC and 18:00 UTC
	wttMatches := []WTTOfficialMatch{
		{
			ID:           8001,
			DocumentCode: "M_GROUP_STAGE",
			MatchCard: WTTMatchCard{
				SubEventDescription: "Men's Singles - Group Stage",
				Competitors: []WTTCompetitor{
					{CompetitorName: "MA Long", CompetitorOrg: "CHN"},
					{CompetitorName: "FAN Zhendong", CompetitorOrg: "CHN"},
				},
				MatchDateTime: WTTMatchDateTime{
					StartDateUTC: "2026-11-03T10:00:00Z",
				},
				OverallScores: "3-1",
			},
		},
		{
			ID:           8002,
			DocumentCode: "M_FINAL_STAGE",
			MatchCard: WTTMatchCard{
				SubEventDescription: "Men's Singles - Final",
				Competitors: []WTTCompetitor{
					{CompetitorName: "MA Long", CompetitorOrg: "CHN"},
					{CompetitorName: "FAN Zhendong", CompetitorOrg: "CHN"},
				},
				MatchDateTime: WTTMatchDateTime{
					StartDateUTC: "2026-11-03T18:00:00Z",
				},
				OverallScores: "4-3",
			},
		},
	}

	report := AlignMatches("Test Tournament", 2026, 9999, dbMatches, wttMatches, 0.70)

	if report.MatchedCount != 2 {
		t.Fatalf("expected both rematches to be matched, got %d", report.MatchedCount)
	}

	var morningCorrect, eveningCorrect bool
	for _, m := range report.Matches {
		if m.DBMatch != nil && m.DBMatch.ID == 501 && m.WTTMatchID == 8001 {
			morningCorrect = true
		}
		if m.DBMatch != nil && m.DBMatch.ID == 502 && m.WTTMatchID == 8002 {
			eveningCorrect = true
		}
	}

	if !morningCorrect {
		t.Errorf("morning video segment was not routed to the morning WTT match using time")
	}
	if !eveningCorrect {
		t.Errorf("evening video segment was not routed to the evening WTT match using time")
	}
}

func TestAlignMatches_TimeBonusElevatesNearThresholdMatch(t *testing.T) {
	streamStart := time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC)

	// OCR corrupted names giving ~0.66 similarity (strictly below 0.70 threshold)
	dbMatches := []DBMatchRecord{
		{
			ID:                 601,
			TeamA:              "MOREGAHD", // OCR typos (base score ~0.66 < 0.70)
			TeamB:              "FALC",
			VideoOffsetSeconds: 600, // 10:10 UTC (within 5 mins of scheduled 10:15)
			StreamStartUTC:     &streamStart,
		},
		{
			ID:                 602,
			TeamA:              "MOREGAHD", // Same corrupted names
			TeamB:              "FALC",
			VideoOffsetSeconds: 18000, // 15:00 UTC (5 hours away, no time bonus)
			StreamStartUTC:     &streamStart,
		},
	}

	wttMatches := []WTTOfficialMatch{
		{
			ID:           9001,
			DocumentCode: "M_FALCK_MOREGARD",
			MatchCard: WTTMatchCard{
				Competitors: []WTTCompetitor{
					{CompetitorName: "MOREGARD Truls", CompetitorOrg: "SWE"},
					{CompetitorName: "FALCK Mattias", CompetitorOrg: "SWE"},
				},
				MatchDateTime: WTTMatchDateTime{
					StartDateUTC: "2026-11-03T10:15:00Z",
				},
				OverallScores: "3-0",
			},
		},
	}

	report := AlignMatches("Test Tournament", 2026, 9999, dbMatches, wttMatches, 0.70)

	matchedMap := make(map[int64]bool)
	for _, m := range report.Matches {
		if m.DBMatch != nil && m.IsMatched {
			matchedMap[m.DBMatch.ID] = true
		}
	}

	// 1. Match 601 earns time proximity bonus, reaching >= 0.70
	if !matchedMap[601] {
		t.Errorf("expected match 601 to be elevated above threshold by time proximity bonus")
	}

	// 2. Match 602 gets no time bonus, fails to reach threshold
	if matchedMap[602] {
		t.Errorf("expected match 602 to remain unmatched without time bonus")
	}
}
