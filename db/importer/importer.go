// Package importer provides database operations for importing match data from JSON files.
package importer

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// VideoJSON represents the structure of the match.json file
type VideoJSON struct {
	VideoID    string      `json:"video_id"`
	VideoTitle string      `json:"video_title"`
	UploadDate string      `json:"upload_date"` // Unix UTC timestamp string (e.g., "1747745671")
	Matches    []MatchJSON `json:"matches"`
	Error      string      `json:"error,omitempty"` // Processing error (e.g., "No match starts found")
}

// MatchJSON represents a single match entry in the JSON file
type MatchJSON struct {
	Timestamp int    `json:"timestamp"`
	Player1   string `json:"player1"`
	Player2   string `json:"player2"`
}

// parseUploadDate parses upload_date (Unix UTC timestamp string) to time.Time.
// Example: "1747745671" → 2025-05-20 10:34:31 UTC
func parseUploadDate(dateStr string) (time.Time, error) {
	if dateStr == "" {
		return time.Now(), fmt.Errorf("empty upload_date")
	}
	ts, err := strconv.ParseInt(dateStr, 10, 64)
	if err != nil {
		return time.Now(), fmt.Errorf("invalid upload_date %q: %w", dateStr, err)
	}
	return time.Unix(ts, 0).UTC(), nil
}

// parseTournamentFromTitle extracts tournament name and year from video title.
// Supports formats like:
//   - "LIVE! | Day 4 | WTT Star Contender Chennai 2026 | Finals"
//   - "LIVE! | Day 4 | WTT Star Contender Chennai 2026 | Singles SF & Mixed Doubles F"
func parseTournamentFromTitle(title string) (string, int, error) {
	parts := strings.Split(title, "|")
	if len(parts) < 3 {
		return "", 0, fmt.Errorf("title has %d pipe-separated parts, expected at least 3", len(parts))
	}

	// Try each part (from index 1 onwards) to find one with a valid year
	for i := 1; i < len(parts); i++ {
		part := strings.TrimSpace(parts[i])
		words := strings.Fields(part)
		if len(words) < 2 {
			continue
		}

		// Check if last word is a valid year (4-digit number starting with 20)
		yearStr := words[len(words)-1]
		year, err := strconv.Atoi(yearStr)
		if err != nil || year < 2020 || year > 2100 {
			continue
		}

		tournamentName := strings.ToLower(strings.Join(words[:len(words)-1], " "))
		return tournamentName, year, nil
	}

	return "", 0, fmt.Errorf("could not find tournament with year in title: %s", title)
}

// parsePlayerName parses a player name and returns a slice of player names.
func parsePlayerName(name string) []string {
	if strings.Contains(name, "/") {
		parts := strings.Split(name, "/")
		result := make([]string, 0, len(parts))
		for _, p := range parts {
			if trimmed := strings.TrimSpace(p); trimmed != "" {
				result = append(result, trimmed)
			}
		}
		return result
	}
	return []string{strings.TrimSpace(name)}
}

// GetProcessedVideoIDs checks which of the given youtube_ids exist in the videos table.
// Returns a map of youtube_id -> true for videos that are already in the database.
func GetProcessedVideoIDs(youtubeIDs []string) (map[string]bool, error) {
	if len(youtubeIDs) == 0 {
		return map[string]bool{}, nil
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL environment variable is required")
	}

	conn, err := pgx.Connect(context.Background(), databaseURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to database: %w", err)
	}
	defer conn.Close(context.Background())

	rows, err := conn.Query(context.Background(),
		"SELECT youtube_id FROM videos WHERE youtube_id = ANY($1)", youtubeIDs)
	if err != nil {
		return nil, fmt.Errorf("failed to query processed videos: %w", err)
	}
	defer rows.Close()

	processed := make(map[string]bool)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("failed to scan video id: %w", err)
		}
		processed[id] = true
	}

	return processed, nil
}

// ParseVideoMetadataJSON reads and parses a video metadata JSON file.
// Returns the list of VideoJSON entries.
func ParseVideoMetadataJSON(jsonFilePath string) ([]VideoJSON, error) {
	data, err := os.ReadFile(jsonFilePath)
	if err != nil {
		return nil, fmt.Errorf("failed to read JSON file: %w", err)
	}

	var videos []VideoJSON
	if err := json.Unmarshal(data, &videos); err != nil {
		var singleVideo VideoJSON
		if err := json.Unmarshal(data, &singleVideo); err != nil {
			return nil, fmt.Errorf("failed to parse JSON: %w", err)
		}
		videos = []VideoJSON{singleVideo}
	}

	return videos, nil
}

// GetVideoIDBeforeLatestUploadDate returns a youtube_id from the day before the latest upload_date.
// This is used as the starting point for --show_new_streams / --add_new_streams when no video_id is provided.
// For example, if the latest upload_date is 2025-12-19, it returns a video_id from 2025-12-18.
func GetVideoIDBeforeLatestUploadDate() (string, error) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return "", fmt.Errorf("DATABASE_URL environment variable is required")
	}

	conn, err := pgx.Connect(context.Background(), databaseURL)
	if err != nil {
		return "", fmt.Errorf("failed to connect to database: %w", err)
	}
	defer conn.Close(context.Background())

	return GetVideoIDBeforeLatestUploadDateWithConn(context.Background(), conn)
}

// GetVideoIDBeforeLatestUploadDateWithConn is the testable version using a provided connection.
func GetVideoIDBeforeLatestUploadDateWithConn(ctx context.Context, conn *pgx.Conn) (string, error) {
	var videoID string
	err := conn.QueryRow(ctx, `
		SELECT youtube_id FROM videos
		WHERE upload_date::date = (SELECT MAX(upload_date::date) - INTERVAL '1 day' FROM videos)
		LIMIT 1`).Scan(&videoID)
	if err == pgx.ErrNoRows {
		return "", fmt.Errorf("no video found for the day before latest upload_date")
	}
	if err != nil {
		return "", fmt.Errorf("failed to query video before latest upload date: %w", err)
	}
	return videoID, nil
}

// GetVideoIDsWithLatestUploadDate returns all youtube_ids that have the latest (max) upload_date.
// These are the videos that docker will return as duplicates and need to be filtered out.
func GetVideoIDsWithLatestUploadDate() (map[string]bool, error) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL environment variable is required")
	}

	conn, err := pgx.Connect(context.Background(), databaseURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to database: %w", err)
	}
	defer conn.Close(context.Background())

	return GetVideoIDsWithLatestUploadDateWithConn(context.Background(), conn)
}

// GetVideoIDsWithLatestUploadDateWithConn is the testable version using a provided connection.
func GetVideoIDsWithLatestUploadDateWithConn(ctx context.Context, conn *pgx.Conn) (map[string]bool, error) {
	rows, err := conn.Query(ctx, `
		SELECT youtube_id FROM videos
		WHERE upload_date::date = (SELECT MAX(upload_date::date) FROM videos)`)
	if err != nil {
		return nil, fmt.Errorf("failed to query videos with latest upload date: %w", err)
	}
	defer rows.Close()

	result := make(map[string]bool)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("failed to scan video id: %w", err)
		}
		result[id] = true
	}
	return result, nil
}

// ImportMatchesFromJSON reads a JSON file and imports all matches to the database.
// The JSON can be either a single VideoJSON object or an array of VideoJSON objects.
// Requires DATABASE_URL environment variable to be set.
func ImportMatchesFromJSON(jsonFilePath string) error {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return fmt.Errorf("DATABASE_URL environment variable is required")
	}

	conn, err := pgx.Connect(context.Background(), databaseURL)
	if err != nil {
		return fmt.Errorf("failed to connect to database: %w", err)
	}
	defer conn.Close(context.Background())

	return ImportMatchesFromJSONWithConn(context.Background(), conn, jsonFilePath)
}

// ImportMatchesFromJSONWithConn reads a JSON file and imports all matches to the database
// using the provided connection.
func ImportMatchesFromJSONWithConn(ctx context.Context, conn *pgx.Conn, jsonFilePath string) error {
	data, err := os.ReadFile(jsonFilePath)
	if err != nil {
		return fmt.Errorf("failed to read JSON file: %w", err)
	}

	var videos []VideoJSON
	if err := json.Unmarshal(data, &videos); err != nil {
		var singleVideo VideoJSON
		if err := json.Unmarshal(data, &singleVideo); err != nil {
			return fmt.Errorf("failed to parse JSON: %w", err)
		}
		videos = []VideoJSON{singleVideo}
	}

	if len(videos) == 0 {
		return fmt.Errorf("no videos found in JSON file")
	}

	fmt.Printf("Found %d video(s) in JSON file\n", len(videos))

	for videoIdx, videoJSON := range videos {
		fmt.Printf("\n[%d/%d] Processing video: %s\n", videoIdx+1, len(videos), videoJSON.VideoTitle)
		fmt.Printf("Video ID: %s\n", videoJSON.VideoID)
		fmt.Printf("Found %d matches\n", len(videoJSON.Matches))

		tournamentName, tournamentYear, err := parseTournamentFromTitle(videoJSON.VideoTitle)
		if err != nil {
			return fmt.Errorf("failed to parse tournament from title: %w", err)
		}
		fmt.Printf("Tournament: %s (%d)\n", tournamentName, tournamentYear)

		tx, err := conn.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)

		// Get or Create Tournament
		var tournamentID int
		err = tx.QueryRow(ctx, "SELECT id FROM tournaments WHERE name=$1 AND year=$2",
			tournamentName, tournamentYear).Scan(&tournamentID)
		if err == pgx.ErrNoRows {
			err = tx.QueryRow(ctx, "INSERT INTO tournaments (name, year) VALUES ($1, $2) RETURNING id",
				tournamentName, tournamentYear).Scan(&tournamentID)
			if err != nil {
				return fmt.Errorf("failed to create tournament '%s' %d: %w", tournamentName, tournamentYear, err)
			}
			fmt.Printf("Created new tournament: %s (%d)\n", tournamentName, tournamentYear)
		} else if err != nil {
			return fmt.Errorf("failed to query tournament: %w", err)
		}

		uploadDate, err := parseUploadDate(videoJSON.UploadDate)
		if err != nil {
			fmt.Printf("Warning: %v, using current time\n", err)
			uploadDate = time.Now()
		}
		fmt.Printf("Upload Date: %s\n", uploadDate.Format("2006-01-02"))

		var videoID int

		err = tx.QueryRow(ctx, "SELECT id FROM videos WHERE youtube_id=$1", videoJSON.VideoID).Scan(&videoID)
		if err == pgx.ErrNoRows {
			err = tx.QueryRow(ctx, `
				INSERT INTO videos (youtube_id, title, upload_date)
				VALUES ($1, $2, $3)
				RETURNING id`,
				videoJSON.VideoID, videoJSON.VideoTitle, uploadDate).Scan(&videoID)
			if err != nil {
				return fmt.Errorf("failed to create video: %w", err)
			}
			fmt.Printf("Created video record with ID: %d\n", videoID)
		} else if err != nil {
			return fmt.Errorf("failed to query video: %w", err)
		} else {
			_, err = tx.Exec(ctx, `UPDATE videos SET title=$1, upload_date=$2 WHERE id=$3`,
				videoJSON.VideoTitle, uploadDate, videoID)
			if err != nil {
				return fmt.Errorf("failed to update video: %w", err)
			}
			fmt.Printf("Video already exists (ID: %d), updating matches...\n", videoID)

			_, err = tx.Exec(ctx, `
				DELETE FROM match_participants 
				WHERE match_id IN (SELECT id FROM matches WHERE video_id=$1)`, videoID)
			if err != nil {
				return fmt.Errorf("failed to delete old match participants: %w", err)
			}

			result, err := tx.Exec(ctx, "DELETE FROM matches WHERE video_id=$1", videoID)
			if err != nil {
				return fmt.Errorf("failed to delete old matches: %w", err)
			}
			fmt.Printf("Deleted %d existing matches\n", result.RowsAffected())
		}

		// Handle processing error: save error to DB and skip match import
		if videoJSON.Error != "" {
			fmt.Printf("Processing error for video: %s\n", videoJSON.Error)
			_, err = tx.Exec(ctx,
				`UPDATE videos SET processing_error = $1 WHERE id = $2`,
				videoJSON.Error, videoID)
			if err != nil {
				return fmt.Errorf("failed to save processing_error: %w", err)
			}

			if err := tx.Commit(ctx); err != nil {
				return fmt.Errorf("failed to commit: %w", err)
			}
			fmt.Printf("Saved processing error for video (no matches imported)\n")
			continue
		}

		// Clear any previous processing error on successful re-import
		_, err = tx.Exec(ctx,
			`UPDATE videos SET processing_error = NULL WHERE id = $1`, videoID)
		if err != nil {
			return fmt.Errorf("failed to clear processing_error: %w", err)
		}

		for i, matchJSON := range videoJSON.Matches {
			teamA := parsePlayerName(matchJSON.Player1)
			teamB := parsePlayerName(matchJSON.Player2)
			isDoubles := len(teamA) > 1 || len(teamB) > 1
			matchTime := uploadDate.Add(time.Duration(matchJSON.Timestamp) * time.Second)

			var matchID int
			err = tx.QueryRow(ctx, `
				INSERT INTO matches (tournament_id, match_timestamp, is_doubles, video_id)
				VALUES ($1, $2, $3, $4)
				RETURNING id`,
				tournamentID, matchTime, isDoubles, videoID).Scan(&matchID)
			if err != nil {
				return fmt.Errorf("failed to create match %d: %w", i+1, err)
			}

			for _, name := range teamA {
				var playerID int
				err := tx.QueryRow(ctx, "SELECT id FROM players WHERE name=$1", name).Scan(&playerID)
				if err == pgx.ErrNoRows {
					err = tx.QueryRow(ctx, "INSERT INTO players (name) VALUES ($1) RETURNING id", name).Scan(&playerID)
				}
				if err != nil {
					return fmt.Errorf("failed to handle player %s: %w", name, err)
				}
				_, err = tx.Exec(ctx, `INSERT INTO match_participants (match_id, player_id, side) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
					matchID, playerID, "A")
				if err != nil {
					return fmt.Errorf("failed to link player %s: %w", name, err)
				}
			}

			for _, name := range teamB {
				var playerID int
				err := tx.QueryRow(ctx, "SELECT id FROM players WHERE name=$1", name).Scan(&playerID)
				if err == pgx.ErrNoRows {
					err = tx.QueryRow(ctx, "INSERT INTO players (name) VALUES ($1) RETURNING id", name).Scan(&playerID)
				}
				if err != nil {
					return fmt.Errorf("failed to handle player %s: %w", name, err)
				}
				_, err = tx.Exec(ctx, `INSERT INTO match_participants (match_id, player_id, side) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
					matchID, playerID, "B")
				if err != nil {
					return fmt.Errorf("failed to link player %s: %w", name, err)
				}
			}

			matchType := "Singles"
			if isDoubles {
				matchType = "Doubles"
			}
			fmt.Printf("  Match %d: %s vs %s (%s) at %ds\n",
				i+1, matchJSON.Player1, matchJSON.Player2, matchType, matchJSON.Timestamp)
		}

		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("failed to commit: %w", err)
		}
		fmt.Printf("Successfully added %d matches from video\n", len(videoJSON.Matches))
	}

	fmt.Printf("\n=== Summary ===\n")
	fmt.Printf("Processed %d video(s) from JSON file\n", len(videos))
	return nil
}
