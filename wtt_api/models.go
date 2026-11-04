package wtt_api

import "time"

// WTTEventDropdownEntry represents an item from the WTT dropdown list.
type WTTEventDropdownEntry struct {
	EventID      int    `json:"eventId"`
	EventName    string `json:"eventName"`
	SubEventType string `json:"subEventType"`
}

// WTTEventSummary represents an event from wtt_all_events_only_name.json.
type WTTEventSummary struct {
	EventID   int    `json:"eventId"`
	EventName string `json:"eventName"`
	VenueName string `json:"venueName,omitempty"`
}

// WTTOfficialMatch represents a top-level match item from officialresult.json.
type WTTOfficialMatch struct {
	ID             int64        `json:"id"`
	EventID        string       `json:"eventId"`
	DocumentCode   string       `json:"documentCode"`
	SubEventType   string       `json:"subEventType"`
	FullResults    string       `json:"fullResults"`
	StartDateLocal string       `json:"startDateLocal"`
	MatchCard      WTTMatchCard `json:"match_card"`
}

// WTTMatchCard contains the detailed game and competitor info.
type WTTMatchCard struct {
	EventID             string          `json:"eventId"`
	DocumentCode        string          `json:"documentCode"`
	SubEventName        string          `json:"subEventName"`
	SubEventDescription string          `json:"subEventDescription"`
	TableNumber         string          `json:"tableNumber,omitempty"`
	TableName           string          `json:"tableName,omitempty"`
	VenueName           string          `json:"venueName,omitempty"`
	Competitors         []WTTCompetitor `json:"competitiors"`
	GameScores          string          `json:"gameScores"`
	OverallScores       string          `json:"overallScores"`
	ResultStatus        string          `json:"resultStatus"`
	MatchDateTime       WTTMatchDateTime`json:"matchDateTime"`
}

// WTTMatchDateTime contains scheduled timing.
type WTTMatchDateTime struct {
	StartDateUTC   string `json:"startDateUTC"`
	StartDateLocal string `json:"startDateLocal"`
	Duration       string `json:"duration,omitempty"`
}

// WTTCompetitor represents one competitor side (single player or doubles pair).
type WTTCompetitor struct {
	CompetitorType string      `json:"competitorType"`
	CompetitorID   string      `json:"competitiorId"`
	CompetitorName string      `json:"competitiorName"`
	CompetitorOrg  string      `json:"competitiorOrg"`
	Scores         string      `json:"scores,omitempty"`
	Players        []WTTPlayer `json:"players"`
}

// WTTPlayer represents an individual player within a competitor.
type WTTPlayer struct {
	PlayerID         string `json:"playerId"`
	PlayerName       string `json:"playerName"`
	PlayerGivenName  string `json:"playerGivenName,omitempty"`
	PlayerFamilyName string `json:"playerFamilyName,omitempty"`
	PlayerOrgCode    string `json:"playerOrgCode"`
	PlayerPosition   int    `json:"playerPosition,omitempty"`
}

// DBMatchRecord represents a match record retrieved from Supabase / Postgres.
type DBMatchRecord struct {
	ID                 int64     `json:"id"`
	TournamentID       int64     `json:"tournament_id"`
	TournamentName     string    `json:"tournament_name"`
	TournamentYear     int       `json:"tournament_year"`
	VideoID            int64     `json:"video_id"`
	YoutubeID          string    `json:"youtube_id"`
	VideoTitle         string    `json:"video_title"`
	Day                string    `json:"day"`
	Session            int       `json:"session"`
	VideoOffsetSeconds int       `json:"video_offset_seconds"`
	DurationSeconds    int       `json:"duration_seconds"`
	IsDoubles          bool      `json:"is_doubles"`
	TeamA              string    `json:"team_a"` // OCR names from DB
	TeamB              string    `json:"team_b"` // OCR names from DB
	CreatedAt          time.Time `json:"created_at"`
}

// MatchedRecord represents the merged view of a DB match and its corresponding WTT official result.
type MatchedRecord struct {
	IsMatched        bool       `json:"is_matched"`
	Confidence       float64    `json:"confidence"`
	FailureReason    string     `json:"failure_reason,omitempty"`
	TournamentName   string     `json:"tournament_name"`
	TournamentYear   int        `json:"tournament_year"`
	WTTEventID       int        `json:"wtt_event_id"`
	
	// OCR Player Names (from DB)
	OCRPlayerNames struct {
		TeamA string `json:"team_a"`
		TeamB string `json:"team_b"`
	} `json:"ocr_player_names"`

	// Authoritative WTT Player Names (from WTT)
	WTTPlayerNames struct {
		TeamA string `json:"team_a"`
		TeamB string `json:"team_b"`
	} `json:"wtt_player_names"`

	// WTT Official Country Codes
	WTTCountries struct {
		TeamA string `json:"team_a"`
		TeamB string `json:"team_b"`
	} `json:"wtt_countries"`

	// WTT Official Match Details
	WTTRound           string `json:"wtt_round,omitempty"`
	WTTGender          string `json:"wtt_gender,omitempty"`
	WTTScore           string `json:"wtt_score,omitempty"`
	WTTGameScores      string `json:"wtt_game_scores,omitempty"`
	WTTMatchStartUTC   string `json:"wtt_match_start_utc,omitempty"`
	WTTMatchID         int64  `json:"wtt_match_id,omitempty"`

	// Raw underlying records for reference
	DBMatch  *DBMatchRecord    `json:"db_match,omitempty"`
	WTTMatch *WTTOfficialMatch `json:"wtt_match,omitempty"`
}

// MatchAuditReport represents the final output JSON containing all matched and unmatched items.
type MatchAuditReport struct {
	GeneratedAt        time.Time       `json:"generated_at"`
	TournamentName     string          `json:"tournament_name"`
	TournamentYear     int             `json:"tournament_year"`
	WTTEventID         int             `json:"wtt_event_id"`
	TotalDBMatches     int             `json:"total_db_matches"`
	TotalWTTMatches    int             `json:"total_wtt_matches"`
	MatchedCount       int             `json:"matched_count"`
	UnmatchedDBCount   int             `json:"unmatched_db_count"`
	UnmatchedWTTCount  int             `json:"unmatched_wtt_count"`
	Matches            []MatchedRecord `json:"matches"`
}
