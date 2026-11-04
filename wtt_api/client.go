package wtt_api

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/andybalholm/brotli"
)

const (
	defaultWTTTimeout = 30 * time.Second
	wttDropdownURL    = "https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitestaticapifiles/general/wtt_event_subevent_dropdown_list.json"
	wttAllEventsURL   = "https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitestaticapifiles/general/wtt_all_events_only_name.json"
	wttOfficialURLFmt = "https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitearchivedresults/%d/officialresult/officialresult.json"
	wttLiveCacheURLFmt= "https://wtt-web-frontdoor-withoutcache-cqakg0andqf5hchn.a01.azurefd.net/websitecacheddata/%d/officialresult/officialresult_minimal.json"
)

// WTTClient fetches data from the official WTT Azure CDN endpoints.
type WTTClient struct {
	httpClient *http.Client
	baseURL    string // Optional override for hermetic testing
}

// NewWTTClient creates a client with default timeout.
func NewWTTClient(opts ...func(*WTTClient)) *WTTClient {
	c := &WTTClient{
		httpClient: &http.Client{
			Timeout: defaultWTTTimeout,
		},
	}
	for _, opt := range opts {
		opt(c)
	}
	return c
}

// WithHTTPClient overrides the underlying http.Client (e.g. for unit tests).
func WithHTTPClient(client *http.Client) func(*WTTClient) {
	return func(c *WTTClient) {
		c.httpClient = client
	}
}

// WithBaseURL overrides the base URL (e.g. for hermetic mock server).
func WithBaseURL(url string) func(*WTTClient) {
	return func(c *WTTClient) {
		c.baseURL = url
	}
}

func (c *WTTClient) fetchAndDecompress(ctx context.Context, targetURL string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, targetURL, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
	req.Header.Set("Accept-Encoding", "gzip, deflate, br")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("HTTP GET failed for %s: %w", targetURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP error %d for %s", resp.StatusCode, targetURL)
	}

	rawBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	encoding := strings.ToLower(resp.Header.Get("Content-Encoding"))

	// Check if body is Brotli compressed (either header specified or heuristic)
	if encoding == "br" {
		brReader := brotli.NewReader(bytes.NewReader(rawBody))
		decompressed, brErr := io.ReadAll(brReader)
		if brErr == nil && len(decompressed) > 0 {
			return decompressed, nil
		}
	} else if encoding == "gzip" {
		gzReader, gzErr := gzip.NewReader(bytes.NewReader(rawBody))
		if gzErr == nil {
			defer gzReader.Close()
			decompressed, err := io.ReadAll(gzReader)
			if err == nil && len(decompressed) > 0 {
				return decompressed, nil
			}
		}
	}

	// Try brotli fallback if rawBody is not valid JSON
	if len(rawBody) > 0 && rawBody[0] != '[' && rawBody[0] != '{' {
		brReader := brotli.NewReader(bytes.NewReader(rawBody))
		decompressed, brErr := io.ReadAll(brReader)
		if brErr == nil && len(decompressed) > 0 {
			return decompressed, nil
		}
	}

	return rawBody, nil
}

// FetchDropdownEvents retrieves the list of event/subevent pairs.
func (c *WTTClient) FetchDropdownEvents(ctx context.Context) ([]WTTEventDropdownEntry, error) {
	url := wttDropdownURL
	if c.baseURL != "" {
		url = c.baseURL + "/dropdown.json"
	}

	data, err := c.fetchAndDecompress(ctx, url)
	if err != nil {
		return nil, err
	}

	var entries []WTTEventDropdownEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return nil, fmt.Errorf("failed to parse dropdown JSON: %w", err)
	}
	return entries, nil
}

// FetchAllEvents retrieves all summarized events with dates.
func (c *WTTClient) FetchAllEvents(ctx context.Context) ([]WTTEventSummary, error) {
	url := wttAllEventsURL
	if c.baseURL != "" {
		url = c.baseURL + "/all_events.json"
	}

	data, err := c.fetchAndDecompress(ctx, url)
	if err != nil {
		return nil, err
	}

	var summaries []WTTEventSummary
	if err := json.Unmarshal(data, &summaries); err != nil {
		return nil, fmt.Errorf("failed to parse all events JSON: %w", err)
	}
	return summaries, nil
}

// FindEventIDByQuery resolves a tournament query and optional year into an official WTT EventID.
// Strictly respects tournament category tiers: Youth vs Senior, Para vs Regular, Star vs Regular.
func (c *WTTClient) FindEventIDByQuery(ctx context.Context, query string, year int) (int, string, error) {
	entries, err := c.FetchDropdownEvents(ctx)
	if err != nil {
		return 0, "", err
	}

	normQuery := NormalizeTournamentName(query)
	yearStr := ""
	if year > 0 {
		yearStr = strconv.Itoa(year)
	}

	queryHasYouth := strings.Contains(normQuery, "youth")
	queryHasPara := strings.Contains(normQuery, "para")
	queryHasStar := strings.Contains(normQuery, "star")
	queryHasFeeder := strings.Contains(normQuery, "feeder")

	// Phase 1: Exact substring match respecting category filters
	for _, entry := range entries {
		normEventName := NormalizeTournamentName(entry.EventName)
		if yearStr != "" && !strings.Contains(normEventName, yearStr) {
			continue
		}

		eventHasYouth := strings.Contains(normEventName, "youth")
		if queryHasYouth != eventHasYouth {
			continue
		}

		eventHasPara := strings.Contains(normEventName, "para")
		if queryHasPara != eventHasPara {
			continue
		}

		eventHasStar := strings.Contains(normEventName, "star")
		if queryHasStar != eventHasStar {
			continue
		}

		eventHasFeeder := strings.Contains(normEventName, "feeder")
		if queryHasFeeder != eventHasFeeder {
			continue
		}

		if strings.Contains(normEventName, normQuery) {
			return entry.EventID, entry.EventName, nil
		}
	}

	// Phase 2: Tokenized fallback respecting category filters
	rawTokens := strings.Fields(normQuery)
	// Filter out common noise tokens
	var tokens []string
	for _, t := range rawTokens {
		if t != "wtt" && t != "presented" && t != "by" && t != "event" && t != "the" {
			tokens = append(tokens, t)
		}
	}
	if len(tokens) == 0 {
		tokens = rawTokens
	}

	for _, entry := range entries {
		normEventName := NormalizeTournamentName(entry.EventName)
		if yearStr != "" && !strings.Contains(normEventName, yearStr) {
			continue
		}

		eventHasYouth := strings.Contains(normEventName, "youth")
		if queryHasYouth != eventHasYouth {
			continue
		}

		eventHasPara := strings.Contains(normEventName, "para")
		if queryHasPara != eventHasPara {
			continue
		}

		eventHasStar := strings.Contains(normEventName, "star")
		if queryHasStar != eventHasStar {
			continue
		}

		eventHasFeeder := strings.Contains(normEventName, "feeder")
		if queryHasFeeder != eventHasFeeder {
			continue
		}

		allTokensMatch := true
		for _, tok := range tokens {
			if !strings.Contains(normEventName, tok) {
				allTokensMatch = false
				break
			}
		}
		if allTokensMatch {
			return entry.EventID, entry.EventName, nil
		}
	}

	// Phase 3: Lenient fallback without year check (handles cases where video had offset year)
	for _, entry := range entries {
		normEventName := NormalizeTournamentName(entry.EventName)
		eventHasYouth := strings.Contains(normEventName, "youth")
		if queryHasYouth != eventHasYouth {
			continue
		}
		eventHasPara := strings.Contains(normEventName, "para")
		if queryHasPara != eventHasPara {
			continue
		}

		allTokensMatch := true
		for _, tok := range tokens {
			if !strings.Contains(normEventName, tok) {
				allTokensMatch = false
				break
			}
		}
		if allTokensMatch {
			return entry.EventID, entry.EventName, nil
		}
	}

	return 0, "", fmt.Errorf("no WTT event found matching query %q (year: %d)", query, year)
}

// FetchOfficialResults retrieves the official match records for a given WTT event ID.
func (c *WTTClient) FetchOfficialResults(ctx context.Context, eventID int) ([]WTTOfficialMatch, error) {
	url := fmt.Sprintf(wttOfficialURLFmt, eventID)
	if c.baseURL != "" {
		url = fmt.Sprintf("%s/official_%d.json", c.baseURL, eventID)
	}

	data, err := c.fetchAndDecompress(ctx, url)
	if err != nil {
		// Try live cache endpoint as fallback
		liveURL := fmt.Sprintf(wttLiveCacheURLFmt, eventID)
		if c.baseURL != "" {
			liveURL = fmt.Sprintf("%s/live_%d.json", c.baseURL, eventID)
		}
		liveData, liveErr := c.fetchAndDecompress(ctx, liveURL)
		if liveErr != nil {
			return nil, fmt.Errorf("failed to fetch both archived results (%v) and live cache (%v)", err, liveErr)
		}
		data = liveData
	}

	var matches []WTTOfficialMatch
	if err := json.Unmarshal(data, &matches); err != nil {
		return nil, fmt.Errorf("failed to parse official results JSON for event %d: %w", eventID, err)
	}

	return matches, nil
}
