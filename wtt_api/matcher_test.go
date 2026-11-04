package wtt_api

import (
	"testing"
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
