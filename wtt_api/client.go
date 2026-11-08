package wtt_api

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/andybalholm/brotli"
)

var tournamentDatesRe = regexp.MustCompile(`\(\s*(\d{1,2}\s+[A-Za-z]{3}\s+\d{4})\s*-\s*(\d{1,2}\s+[A-Za-z]{3}\s+\d{4})\s*\)`)

const (
	defaultWTTTimeout = 30 * time.Second
	wttDropdownURL    = "https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitestaticapifiles/general/wtt_event_subevent_dropdown_list.json"
	wttAllEventsURL   = "https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitestaticapifiles/general/wtt_all_events_only_name.json"
	wttOfficialURLFmt = "https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitearchivedresults/%d/officialresult/officialresult.json"
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
	queryHasIII := strings.Contains(normQuery, " iii ") || strings.HasSuffix(normQuery, " iii") || strings.Contains(normQuery, " iii 20")
	queryHasII := (strings.Contains(normQuery, " ii ") || strings.HasSuffix(normQuery, " ii") || strings.Contains(normQuery, " ii 20")) && !queryHasIII

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

		eventHasIII := strings.Contains(normEventName, " iii ") || strings.Contains(normEventName, " iii-") || strings.HasSuffix(normEventName, " iii") || strings.Contains(normEventName, " iii 20")
		eventHasII := (strings.Contains(normEventName, " ii ") || strings.Contains(normEventName, " ii-") || strings.HasSuffix(normEventName, " ii") || strings.Contains(normEventName, " ii 20")) && !eventHasIII

		if queryHasIII != eventHasIII {
			continue
		}
		if queryHasII != eventHasII {
			continue
		}

		if strings.Contains(normEventName, normQuery) {
			return entry.EventID, entry.EventName, nil
		}
	}

	// Phase 2: Tokenized fallback respecting category filters
	rawTokens := strings.Fields(normQuery)
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

		eventHasIII := strings.Contains(normEventName, " iii ") || strings.Contains(normEventName, " iii-") || strings.HasSuffix(normEventName, " iii") || strings.Contains(normEventName, " iii 20")
		eventHasII := (strings.Contains(normEventName, " ii ") || strings.Contains(normEventName, " ii-") || strings.HasSuffix(normEventName, " ii") || strings.Contains(normEventName, " ii 20")) && !eventHasIII

		if queryHasIII != eventHasIII {
			continue
		}
		if queryHasII != eventHasII {
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

// ParseTournamentDates extracts the start and end dates from eventName (e.g. "WTT Finals Hong Kong 2027 (07 Dec 2027 - 12 Dec 2027)").
func ParseTournamentDates(eventName string) (time.Time, time.Time, error) {
	m := tournamentDatesRe.FindStringSubmatch(eventName)
	if len(m) < 3 {
		return time.Time{}, time.Time{}, fmt.Errorf("no date range found in event name %q", eventName)
	}
	start, err := time.Parse("02 Jan 2006", strings.TrimSpace(m[1]))
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("failed to parse start date %q: %w", m[1], err)
	}
	end, err := time.Parse("02 Jan 2006", strings.TrimSpace(m[2]))
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("failed to parse end date %q: %w", m[2], err)
	}
	return start.UTC(), end.UTC(), nil
}

// FindEventIDByDate resolves a tournament query and specific target date into an official WTT EventID.
func (c *WTTClient) FindEventIDByDate(ctx context.Context, query string, targetDate time.Time) (int, string, error) {
	summaries, err := c.FetchAllEvents(ctx)
	if err != nil {
		return c.FindEventIDByQuery(ctx, query, targetDate.Year())
	}

	normQuery := NormalizeTournamentName(query)
	targetUTC := targetDate.UTC()

	type candEvent struct {
		eventID   int
		eventName string
		start     time.Time
		end       time.Time
	}
	var candidates []candEvent

	for _, s := range summaries {
		normEvent := NormalizeTournamentName(s.EventName)
		if !strings.Contains(normEvent, normQuery) {
			continue
		}
		start, end, err := ParseTournamentDates(s.EventName)
		if err != nil {
			continue
		}
		candidates = append(candidates, candEvent{
			eventID:   s.EventID,
			eventName: s.EventName,
			start:     start,
			end:       end,
		})
	}

	// 1. Check if targetDate falls within [start - 1 day, end + 1 day]
	for _, cand := range candidates {
		bufferedStart := cand.start.Add(-24 * time.Hour)
		bufferedEnd := cand.end.Add(24 * time.Hour)
		if !targetUTC.Before(bufferedStart) && !targetUTC.After(bufferedEnd) {
			return cand.eventID, cand.eventName, nil
		}
	}

	// 2. Fall back to standard query by year
	return c.FindEventIDByQuery(ctx, query, targetDate.Year())
}

// FetchOfficialResults retrieves the official match records for a given WTT event ID.
// Seamlessly falls back to live in-progress schedule and top-10 cache for active tournaments.
func (c *WTTClient) FetchOfficialResults(ctx context.Context, eventID int) ([]WTTOfficialMatch, error) {
	url := fmt.Sprintf(wttOfficialURLFmt, eventID)
	if c.baseURL != "" {
		url = fmt.Sprintf("%s/official_%d.json", c.baseURL, eventID)
	}

	cardCount := 0
	var archivedMatches []WTTOfficialMatch
	data, err := c.fetchAndDecompress(ctx, url)
	if err == nil {
		if jErr := json.Unmarshal(data, &archivedMatches); jErr == nil && len(archivedMatches) > 0 {
			for _, m := range archivedMatches {
				if len(m.MatchCard.Competitors) >= 2 {
					cardCount++
				}
			}
		}
	}

	// Active/In-Progress live fallback (e.g. Frankfurt 2026, Gaia 2026)
	liveMatches, liveErr := c.fetchLiveScheduleMatches(ctx, eventID)
	if liveErr == nil && len(liveMatches) > cardCount {
		return liveMatches, nil
	}
	if cardCount > 10 && cardCount >= len(archivedMatches)/2 {
		return archivedMatches, nil
	}
	if cardCount > 0 {
		return archivedMatches, nil
	}

	if err != nil {
		return nil, fmt.Errorf("failed to fetch official results for event %d: %w", eventID, err)
	}
	return nil, fmt.Errorf("no valid official matches found for event %d", eventID)
}

func (c *WTTClient) fetchLiveScheduleMatches(ctx context.Context, eventID int) ([]WTTOfficialMatch, error) {
	cacheBuster := time.Now().Unix()

	// 1. Fetch scores map from top 10 results and live cache
	scoresMap := make(map[string]WTTMatchCard)
	top10URLs := []string{
		fmt.Sprintf("https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitestaticapifiles/%d/%d_take_10_official_results.json?q=%d", eventID, eventID, cacheBuster),
		fmt.Sprintf("https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitecacheddata/%d/officialresult/officialresult_top10.json?q=%d", eventID, cacheBuster),
		fmt.Sprintf("https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitecacheddata/%d/officialresult/officialresult.json?q=%d", eventID, cacheBuster),
	}
	for _, u := range top10URLs {
		data, err := c.fetchAndDecompress(ctx, u)
		if err == nil {
			var rawList []WTTOfficialMatch
			if err := json.Unmarshal(data, &rawList); err == nil {
				for _, rm := range rawList {
					if rm.DocumentCode != "" && rm.MatchCard.OverallScores != "" {
						trimmed := strings.TrimRight(rm.DocumentCode, "-")
						scoresMap[trimmed] = rm.MatchCard
					}
				}
			}
		}
	}

	// 2. Fetch live schedule_filtered.json and schedule.json
	schedURLs := []string{
		fmt.Sprintf("https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitecacheddata/%d/schedule/schedule.json?q=%d", eventID, cacheBuster),
		fmt.Sprintf("https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitecacheddata/%d/schedule/schedule_filtered.json", eventID),
		fmt.Sprintf("https://wtt-web-frontdoor-cthahjeqhbh6aqe3.a01.azurefd.net/websitecacheddata/%d/schedule/schedule.json", eventID),
	}
	if c.baseURL != "" {
		schedURLs = []string{fmt.Sprintf("%s/schedule_%d.json", c.baseURL, eventID)}
	}

	var result []WTTOfficialMatch
	seenCodes := make(map[string]bool)

	for _, schedURL := range schedURLs {
		schedData, err := c.fetchAndDecompress(ctx, schedURL)
		if err != nil || len(schedData) == 0 {
			continue
		}

		var schedItems []struct {
			Competition struct {
				Unit []struct {
					Code             string `json:"Code"`
					ScheduleStatus   string `json:"ScheduleStatus"`
					SubEvent         string `json:"SubEvent"`
					Round            string `json:"Round"`
					StartDate        string `json:"StartDate"`
					ActualStartDate  string `json:"ActualStartDate"`
					Location         string `json:"Location"`
					VenueDescription struct {
						LocationName string `json:"LocationName"`
						VenueName    string `json:"VenueName"`
					} `json:"VenueDescription"`
					ItemDescription []struct {
						Language string `json:"Language"`
						Value    string `json:"Value"`
					} `json:"ItemDescription"`
					StartList struct {
						Start []struct {
							Competitor *struct {
								Code         string `json:"Code"`
								Organization string `json:"Organization"`
								Description  *struct {
									TeamName string `json:"TeamName"`
								} `json:"Description"`
							} `json:"Competitor"`
						} `json:"Start"`
					} `json:"StartList"`
				} `json:"Unit"`
			} `json:"Competition"`
		}
		_ = json.Unmarshal(schedData, &schedItems)

		for _, item := range schedItems {
			for _, u := range item.Competition.Unit {
			codeTrimmed := strings.TrimRight(u.Code, "-")
			if codeTrimmed == "" || seenCodes[codeTrimmed] {
				continue
			}

			starts := u.StartList.Start
			if len(starts) < 2 || starts[0].Competitor == nil || starts[1].Competitor == nil {
				continue
			}

			c1 := starts[0].Competitor
			c2 := starts[1].Competitor
			if c1.Description == nil || c2.Description == nil {
				continue
			}

			c1Name := c1.Description.TeamName
			c1Org := c1.Organization
			c2Name := c2.Description.TeamName
			c2Org := c2.Organization
			if c1Name == "" || c2Name == "" {
				continue
			}

			seenCodes[codeTrimmed] = true

			desc := ""
			for _, d := range u.ItemDescription {
				if d.Language == "ENG" {
					desc = d.Value
					break
				}
			}

			tableName := u.Location
			if tableName == "" {
				tableName = u.VenueDescription.LocationName
			}

			mc := WTTMatchCard{
				EventID:             strconv.Itoa(eventID),
				DocumentCode:        u.Code,
				SubEventName:        u.SubEvent,
				SubEventDescription: desc,
				TableNumber:         u.Location,
				TableName:           tableName,
				VenueName:           u.VenueDescription.VenueName,
				Competitors: []WTTCompetitor{
					{CompetitorName: c1Name, CompetitorOrg: c1Org},
					{CompetitorName: c2Name, CompetitorOrg: c2Org},
				},
				MatchDateTime: WTTMatchDateTime{
					StartDateUTC:   u.ActualStartDate,
					StartDateLocal: u.StartDate,
				},
			}

			if card, ok := scoresMap[codeTrimmed]; ok {
				mc.OverallScores = card.OverallScores
				mc.GameScores = card.GameScores
				mc.ResultStatus = "OFFICIAL"
			} else {
				mc.OverallScores = "Scheduled"
				mc.ResultStatus = u.ScheduleStatus
			}

			result = append(result, WTTOfficialMatch{
				EventID:        strconv.Itoa(eventID),
				DocumentCode:   u.Code,
				SubEventType:   u.SubEvent,
				FullResults:    "OFFICIAL",
				StartDateLocal: u.StartDate,
				MatchCard:      mc,
			})
		}
	}
	}

	return result, nil
}
