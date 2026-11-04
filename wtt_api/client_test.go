package wtt_api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/andybalholm/brotli"
)

func compressBrotli(data []byte) []byte {
	var buf bytes.Buffer
	w := brotli.NewWriter(&buf)
	w.Write(data)
	w.Close()
	return buf.Bytes()
}

func TestWTTClient_HermeticMockServer(t *testing.T) {
	mockDropdown := []WTTEventDropdownEntry{
		{
			EventID:      3250,
			EventName:    "WTT Champions Montpellier 2026",
			SubEventType: "Men Singles",
		},
		{
			EventID:      2942,
			EventName:    "China Smash 2024",
			SubEventType: "Men Singles",
		},
	}
	dropdownBytes, _ := json.Marshal(mockDropdown)

	mockOfficial := []WTTOfficialMatch{
		{
			ID:           16752548,
			DocumentCode: "TTEMSINGLES-----------FNL-000100----------",
			SubEventType: "Men Singles",
			MatchCard: WTTMatchCard{
				OverallScores: "4-3",
				Competitors: []WTTCompetitor{
					{CompetitorName: "JANG Woojin", CompetitorOrg: "KOR"},
					{CompetitorName: "FRANZISKA Patrick", CompetitorOrg: "GER"},
				},
			},
		},
	}
	officialBytes, _ := json.Marshal(mockOfficial)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/dropdown.json":
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Content-Encoding", "br")
			w.Write(compressBrotli(dropdownBytes))
		case "/official_3250.json":
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Content-Encoding", "br")
			w.Write(compressBrotli(officialBytes))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := NewWTTClient(WithBaseURL(server.URL))
	ctx := context.Background()

	// 1. Test FetchDropdownEvents
	entries, err := client.FetchDropdownEvents(ctx)
	if err != nil {
		t.Fatalf("FetchDropdownEvents failed: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}

	// 2. Test FindEventIDByQuery
	eventID, name, err := client.FindEventIDByQuery(ctx, "Montpellier", 2026)
	if err != nil {
		t.Fatalf("FindEventIDByQuery failed: %v", err)
	}
	if eventID != 3250 || name != "WTT Champions Montpellier 2026" {
		t.Errorf("unexpected eventID=%d, name=%s", eventID, name)
	}

	// 3. Test FetchOfficialResults
	matches, err := client.FetchOfficialResults(ctx, 3250)
	if err != nil {
		t.Fatalf("FetchOfficialResults failed: %v", err)
	}
	if len(matches) != 1 {
		t.Fatalf("expected 1 match, got %d", len(matches))
	}
	if matches[0].MatchCard.OverallScores != "4-3" {
		t.Errorf("expected score 4-3, got %s", matches[0].MatchCard.OverallScores)
	}
}
