package importer

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"wtt-youtube-organizer/wtt_api"

	"github.com/andybalholm/brotli"
)

func compressBr(data []byte) []byte {
	var buf bytes.Buffer
	w := brotli.NewWriter(&buf)
	w.Write(data)
	w.Close()
	return buf.Bytes()
}

// TestHermeticWTTBackendIntegration tests 100% of REST interactions, fallbacks,
// stage mapping, and database persistence against an isolated mock WTT server and Postgres testcontainer.
func TestHermeticWTTBackendIntegration(t *testing.T) {
	conn, cleanup := setupTestDB(t)
	defer cleanup()

	ctx := context.Background()

	// 1. Create Fake WTT Backend Server
	var mu sync.Mutex
	recordedRequests := make([]string, 0)

	// Mock Dropdown Data
	mockDropdown := []wtt_api.WTTEventDropdownEntry{
		{
			EventID:      5001,
			EventName:    "WTT Champions Frankfurt 2026",
			SubEventType: "Men Singles",
		},
		{
			EventID:      5002,
			EventName:    "WTT Feeder Live Test 2026",
			SubEventType: "Men Singles",
		},
		{
			EventID:      5003,
			EventName:    "WTT Youth Contender Test 2026",
			SubEventType: "U19 Boys Singles",
		},
	}
	dropdownBytes, _ := json.Marshal(mockDropdown)

	// Mock Official Draw for Event 5001 (Finished Tournament)
	mockOfficial5001 := []wtt_api.WTTOfficialMatch{
		{
			ID:           500101,
			DocumentCode: "TTEMSINGLES-----------FNL-000100----------",
			SubEventType: "Men Singles",
			MatchCard: wtt_api.WTTMatchCard{
				DocumentCode:  "TTEMSINGLES-----------FNL-000100----------",
				OverallScores: "4-2",
				MatchDateTime: wtt_api.WTTMatchDateTime{
					StartDateUTC: "15/11/2026 18:00:00",
				},
				Competitors: []wtt_api.WTTCompetitor{
					{CompetitorName: "HARIMOTO Tomokazu", CompetitorOrg: "JPN"},
					{CompetitorName: "WANG Chuqin", CompetitorOrg: "CHN"},
				},
			},
		},
		{
			ID:           500102,
			DocumentCode: "TTEMSINGLES-----------QFNL000100----------",
			SubEventType: "Men Singles",
			MatchCard: wtt_api.WTTMatchCard{
				DocumentCode:  "TTEMSINGLES-----------QFNL000100----------",
				OverallScores: "3-1",
				MatchDateTime: wtt_api.WTTMatchDateTime{
					StartDateUTC: "14/11/2026 15:00:00",
				},
				Competitors: []wtt_api.WTTCompetitor{
					{CompetitorName: "LEBRUN Felix", CompetitorOrg: "FRA"},
					{CompetitorName: "LIND Anders", CompetitorOrg: "DEN"},
				},
			},
		},
	}
	official5001Bytes, _ := json.Marshal(mockOfficial5001)

	// Mock Youth Event 5003 Data
	mockOfficial5003 := []wtt_api.WTTOfficialMatch{
		{
			ID:           500301,
			DocumentCode: "TTEMSINGLES--------U19FNL-000100----------",
			SubEventType: "U19 Boys Singles",
			MatchCard: wtt_api.WTTMatchCard{
				DocumentCode:        "TTEMSINGLES--------U19FNL-000100----------",
				SubEventName:        "U19 Boys' Singles",
				SubEventDescription: "U19 Boys' Singles - Final",
				OverallScores:       "3-2",
				MatchDateTime: wtt_api.WTTMatchDateTime{
					StartDateUTC: "18/11/2026 15:00:00",
				},
				Competitors: []wtt_api.WTTCompetitor{
					{CompetitorName: "YANG Hao-Jen", CompetitorOrg: "TPE"},
					{CompetitorName: "ITO Yuta", CompetitorOrg: "JPN"},
				},
			},
		},
	}
	official5003Bytes, _ := json.Marshal(mockOfficial5003)

	// Mock Live CMS Data for Event 5002 (In-Progress Tournament)
	mockLiveCMS5002 := []wtt_api.WTTOfficialMatch{
		{
			ID:           500201,
			DocumentCode: "TTEMSINGLES-----------8FNL000100----------",
			SubEventType: "Men Singles",
			MatchCard: wtt_api.WTTMatchCard{
				DocumentCode:  "TTEMSINGLES-----------8FNL000100----------",
				OverallScores: "3-0",
				MatchDateTime: wtt_api.WTTMatchDateTime{
					StartDateUTC: "18/11/2026 10:00:00",
				},
				Competitors: []wtt_api.WTTCompetitor{
					{CompetitorName: "MOREGARD Truls", CompetitorOrg: "SWE"},
					{CompetitorName: "CALDERANO Hugo", CompetitorOrg: "BRA"},
				},
			},
		},
	}
	liveCMS5002Bytes, _ := json.Marshal(mockLiveCMS5002)

	fakeWTTServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		recordedRequests = append(recordedRequests, fmt.Sprintf("%s %s", r.Method, r.URL.Path))
		mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Encoding", "br")

		switch r.URL.Path {
		case "/dropdown.json":
			w.Write(compressBr(dropdownBytes))
		case "/official_5001.json":
			w.Write(compressBr(official5001Bytes))
		case "/official_5003.json":
			w.Write(compressBr(official5003Bytes))
		case "/official_5002.json":
			// Cold archive returns 404 for active in-progress event to trigger CMS fallback
			w.WriteHeader(http.StatusNotFound)
		case "/live_api_5002.json":
			// CMS Live API returns active in-progress match
			w.Write(compressBr(liveCMS5002Bytes))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer fakeWTTServer.Close()

	// 2. Scenario 1: Import video matches for Event 5001 (Frankfurt)
	// Includes:
	//   - Match 1: Felix Lebrun vs Anders Lind (Quarter-Final)
	//   - Match 2: Tomokazu Harimoto vs Wang Chuqin (Final)
	//   - Match 3: Unmatched mystery broadcast match sharing same video_id
	videoFrankfurt := VideoJSON{
		VideoID:       "vid_frankfurt_1",
		VideoTitle:    "LIVE! | T1 | Day 5 | WTT Champions Frankfurt 2026 | Session 1",
		UploadDate:    "1794700800", // 2026-11-14 12:00:00 UTC
		VideoDuration: 7200,
		Matches: []MatchJSON{
			{Timestamp: 600, Player1: "Felix Lebrun", Player2: "Anders Lind"},
			{Timestamp: 2400, Player1: "Tomokazu Harimoto", Player2: "Wang Chuqin"},
			{Timestamp: 4800, Player1: "Mystery Player A", Player2: "Mystery Player B"},
		},
	}

	jsonPath1 := writeTestJSON(t, []VideoJSON{videoFrankfurt})
	err := ImportMatchesFromJSONWithConn(ctx, conn, jsonPath1, wtt_api.WithBaseURL(fakeWTTServer.URL))
	if err != nil {
		t.Fatalf("ImportMatchesFromJSONWithConn for Frankfurt failed: %v", err)
	}

	// 3. Scenario 2: Import video matches for Event 5002 (In-Progress CMS Fallback)
	videoLiveFeeder := VideoJSON{
		VideoID:       "vid_live_feeder_1",
		VideoTitle:    "LIVE! | T1 | Day 2 | WTT Feeder Live Test 2026 | Session 1",
		UploadDate:    "1795000000",
		VideoDuration: 3600,
		Matches: []MatchJSON{
			{Timestamp: 300, Player1: "Truls Moregard", Player2: "Hugo Calderano"},
		},
	}

	jsonPath2 := writeTestJSON(t, []VideoJSON{videoLiveFeeder})
	err = ImportMatchesFromJSONWithConn(ctx, conn, jsonPath2, wtt_api.WithBaseURL(fakeWTTServer.URL))
	if err != nil {
		t.Fatalf("ImportMatchesFromJSONWithConn for Live Feeder failed: %v", err)
	}

	// 4. Scenario 3: Import video matches for Youth Event 5003
	videoYouth := VideoJSON{
		VideoID:       "vid_youth_1",
		VideoTitle:    "LIVE! | T1 | Day 4 | WTT Youth Contender Test 2026 | Session 1",
		UploadDate:    "1795010000",
		VideoDuration: 3600,
		Matches: []MatchJSON{
			{Timestamp: 500, Player1: "Yang Hao-Jen", Player2: "Ito Yuta"},
			{Timestamp: 1500, Player1: "Youth Mystery A", Player2: "Youth Mystery B"},
		},
	}

	jsonPath3 := writeTestJSON(t, []VideoJSON{videoYouth})
	err = ImportMatchesFromJSONWithConn(ctx, conn, jsonPath3, wtt_api.WithBaseURL(fakeWTTServer.URL))
	if err != nil {
		t.Fatalf("ImportMatchesFromJSONWithConn for Youth failed: %v", err)
	}

	// =========================================================================
	// ASSERTION 1: 100% of Expected REST Endpoints Were Called
	// =========================================================================
	mu.Lock()
	reqs := append([]string{}, recordedRequests...)
	mu.Unlock()

	hasReq := func(pattern string) bool {
		for _, r := range reqs {
			if r == pattern {
				return true
			}
		}
		return false
	}

	if !hasReq("GET /dropdown.json") {
		t.Errorf("Expected fake WTT server to receive 'GET /dropdown.json', got: %v", reqs)
	}
	if !hasReq("GET /official_5001.json") {
		t.Errorf("Expected fake WTT server to receive 'GET /official_5001.json', got: %v", reqs)
	}
	if !hasReq("GET /official_5002.json") {
		t.Errorf("Expected fake WTT server to probe 'GET /official_5002.json', got: %v", reqs)
	}
	if !hasReq("GET /live_api_5002.json") {
		t.Errorf("Expected fake WTT server to fallback to 'GET /live_api_5002.json', got: %v", reqs)
	}

	// =========================================================================
	// ASSERTION 2: Database Persistence & Correct Stage Ordering for Frankfurt
	// =========================================================================
	var matchQFRound, matchFRound, matchUnmatchedRound string
	var matchQFOrder, matchFOrder, matchUnmatchedOrder int
	var isBroadcastQF, isBroadcastF, isBroadcastUnmatched bool
	var wttScoreQF, wttScoreF string

	// Match 1: Felix Lebrun vs Anders Lind (Quarter-Final)
	err = conn.QueryRow(ctx, `
		SELECT wtt_round, stage_order, is_broadcast_match, COALESCE(wtt_score, '')
		FROM matches 
		WHERE video_offset_seconds = 600`).Scan(&matchQFRound, &matchQFOrder, &isBroadcastQF, &wttScoreQF)
	if err != nil {
		t.Fatalf("failed to query Quarter-Final match: %v", err)
	}

	if matchQFRound != "Quarter-Final" {
		t.Errorf("Expected match 1 to have stage 'Quarter-Final', got %q", matchQFRound)
	}
	if matchQFOrder != 6 {
		t.Errorf("Expected match 1 to have stage_order 6, got %d", matchQFOrder)
	}
	if isBroadcastQF {
		t.Errorf("Expected matched match 1 to have is_broadcast_match=false, got true")
	}
	if wttScoreQF != "3-1" {
		t.Errorf("Expected match 1 score '3-1', got %q", wttScoreQF)
	}



	// Match 2: Tomokazu Harimoto vs Wang Chuqin (Final)
	err = conn.QueryRow(ctx, `
		SELECT wtt_round, stage_order, is_broadcast_match, COALESCE(wtt_score, '')
		FROM matches 
		WHERE video_offset_seconds = 2400`).Scan(&matchFRound, &matchFOrder, &isBroadcastF, &wttScoreF)
	if err != nil {
		t.Fatalf("failed to query Final match: %v", err)
	}

	if matchFRound != "Final" {
		t.Errorf("Expected match 2 to have stage 'Final', got %q", matchFRound)
	}
	if matchFOrder != 8 {
		t.Errorf("Expected match 2 to have stage_order 8, got %d", matchFOrder)
	}
	if isBroadcastF {
		t.Errorf("Expected matched match 2 to have is_broadcast_match=false, got true")
	}
	if wttScoreF != "4-2" {
		t.Errorf("Expected match 2 score '4-2', got %q", wttScoreF)
	}

	// Match 3: Mystery Player A vs Mystery Player B (Unmatched Inferred Match)
	err = conn.QueryRow(ctx, `
		SELECT wtt_round, stage_order, is_broadcast_match
		FROM matches 
		WHERE video_offset_seconds = 4800`).Scan(&matchUnmatchedRound, &matchUnmatchedOrder, &isBroadcastUnmatched)
	if err != nil {
		t.Fatalf("failed to query Unmatched match: %v", err)
	}

	if !isBroadcastUnmatched {
		t.Errorf("Expected unmatched match 3 to have is_broadcast_match=true, got false")
	}
	if matchUnmatchedRound == "" || matchUnmatchedRound == "Round Match" {
		t.Errorf("Expected unmatched match 3 to inherit stage from stream siblings, got %q", matchUnmatchedRound)
	}
	if matchUnmatchedOrder < 1 {
		t.Errorf("Expected unmatched match 3 to have stage_order >= 1, got %d", matchUnmatchedOrder)
	}

	// =========================================================================
	// ASSERTION 3: Database Persistence for In-Progress Event (CMS Live API)
	// =========================================================================
	var liveRound string
	var liveOrder int
	var liveBroadcast bool
	var liveScore string

	err = conn.QueryRow(ctx, `
		SELECT wtt_round, stage_order, is_broadcast_match, COALESCE(wtt_score, '')
		FROM matches 
		WHERE video_offset_seconds = 300`).Scan(&liveRound, &liveOrder, &liveBroadcast, &liveScore)
	if err != nil {
		t.Fatalf("failed to query Live CMS match: %v", err)
	}

	if liveRound != "Round of 16" {
		t.Errorf("Expected Live CMS match to have stage 'Round of 16', got %q", liveRound)
	}
	if liveOrder != 5 {
		t.Errorf("Expected Live CMS match to have stage_order 5, got %d", liveOrder)
	}
	if liveBroadcast {
		t.Errorf("Expected Live CMS matched match to have is_broadcast_match=false, got true")
	}
	if liveScore != "3-0" {
		t.Errorf("Expected Live CMS match score '3-0', got %q", liveScore)
	}

	// =========================================================================
	// ASSERTION 4: Youth Stage Name Has Age Prefix (U19 Final)
	// =========================================================================
	var youthFRound, youthUnmatchedRound string
	var youthFOrder, youthUnmatchedOrder int
	var youthFBc, youthUnmatchedBc bool

	err = conn.QueryRow(ctx, `
		SELECT wtt_round, stage_order, is_broadcast_match
		FROM matches 
		WHERE video_offset_seconds = 500`).Scan(&youthFRound, &youthFOrder, &youthFBc)
	if err != nil {
		t.Fatalf("failed to query Youth Final match: %v", err)
	}

	if youthFRound != "U19 Final" {
		t.Errorf("Expected youth match to have stage 'U19 Final', got %q", youthFRound)
	}
	if youthFOrder != 8 {
		t.Errorf("Expected youth match to have stage_order 8, got %d", youthFOrder)
	}
	if youthFBc {
		t.Errorf("Expected matched youth match to have is_broadcast_match=false, got true")
	}

	// Unmatched youth match inheriting U19 Final from court sibling
	err = conn.QueryRow(ctx, `
		SELECT wtt_round, stage_order, is_broadcast_match
		FROM matches 
		WHERE video_offset_seconds = 1500`).Scan(&youthUnmatchedRound, &youthUnmatchedOrder, &youthUnmatchedBc)
	if err != nil {
		t.Fatalf("failed to query Unmatched Youth match: %v", err)
	}

	if youthUnmatchedRound != "U19 Final" {
		t.Errorf("Expected unmatched youth match to inherit 'U19 Final' from sibling, got %q", youthUnmatchedRound)
	}
	if youthUnmatchedOrder != 8 {
		t.Errorf("Expected unmatched youth match to have stage_order 8, got %d", youthUnmatchedOrder)
	}
	if !youthUnmatchedBc {
		t.Errorf("Expected unmatched youth match to have is_broadcast_match=true, got false")
	}
}
