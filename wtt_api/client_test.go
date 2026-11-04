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

func TestWTTClient_DistinguishesYouthAndSenior(t *testing.T) {
	mockDropdown := []WTTEventDropdownEntry{
		{
			EventID:      3335,
			EventName:    "China Youth Smash 2026 Presented by Beijing Shijingshan Culture & Tourism Group",
			SubEventType: "Men Singles",
		},
		{
			EventID:      3249,
			EventName:    "China Smash 2026 Presented by Beijing Shijingshan Culture & Tourism Group",
			SubEventType: "Men Singles",
		},
		{
			EventID:      3250,
			EventName:    "WTT Champions Montpellier 2026",
			SubEventType: "Men Singles",
		},
	}
	dropdownBytes, _ := json.Marshal(mockDropdown)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/dropdown.json":
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Content-Encoding", "br")
			w.Write(compressBrotli(dropdownBytes))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := NewWTTClient(WithBaseURL(server.URL))
	ctx := context.Background()

	// 1. Querying "China Smash" MUST resolve to Senior event 3249, NOT Youth event 3335
	seniorID, seniorName, err := client.FindEventIDByQuery(ctx, "China Smash", 2026)
	if err != nil {
		t.Fatalf("FindEventIDByQuery for Senior failed: %v", err)
	}
	if seniorID != 3249 {
		t.Errorf("expected Senior Event ID 3249, got %d (%s)", seniorID, seniorName)
	}

	// 2. Querying "China Youth Smash" MUST resolve to Youth event 3335
	youthID, youthName, err := client.FindEventIDByQuery(ctx, "China Youth Smash", 2026)
	if err != nil {
		t.Fatalf("FindEventIDByQuery for Youth failed: %v", err)
	}
	if youthID != 3335 {
		t.Errorf("expected Youth Event ID 3335, got %d (%s)", youthID, youthName)
	}
}

func TestFindEventIDByQuery_RomanNumerals_II_vs_III(t *testing.T) {
	mockDropdown := []WTTEventDropdownEntry{
		{EventID: 3478, EventName: "WTT Youth Contender San Francisco II 2026 Presented by MongoDB"},
		{EventID: 3479, EventName: "WTT Youth Contender San Francisco III 2026 Presented by MongoDB"},
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/dropdown.json" {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(mockDropdown)
			return
		}
		http.NotFound(w, r)
	}))
	defer server.Close()

	client := NewWTTClient(WithBaseURL(server.URL))
	ctx := context.Background()

	idII, nameII, errII := client.FindEventIDByQuery(ctx, "WTT Youth Contender San Francisco II", 2026)
	if errII != nil || idII != 3478 {
		t.Fatalf("expected Event ID 3478 for San Francisco II, got %d (%s), err: %v", idII, nameII, errII)
	}

	idIII, nameIII, errIII := client.FindEventIDByQuery(ctx, "WTT Youth Contender San Francisco III", 2026)
	if errIII != nil || idIII != 3479 {
		t.Fatalf("expected Event ID 3479 for San Francisco III, got %d (%s), err: %v", idIII, nameIII, errIII)
	}
}
