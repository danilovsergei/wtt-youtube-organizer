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
	UploadDate string      `json:"upload_date"` // Format: YYYYMMDD
	Matches    []MatchJSON `json:"matches"`
}

// MatchJSON represents a single match entry in the JSON file
type MatchJSON struct {
	Timestamp int    `json:"timestamp"`
	Player1   string `json:"player1"`
	Player2   string `json:"player2"`
}

// parseUploadDate parses upload_date from YYYYMMDD format to time.Time
func parseUploadDate(dateStr string) (time.Time, error) {
	if dateStr == "" {
		return time.Now(), fmt.Errorf("empty upload_date")
	}
	return time.Parse("20060102", dateStr)
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

	// Try each part (from index 2 onwards) to find one with a valid year
	for i := 2; i < len(parts); i++ {
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

// GetLastProcessedVideoID returns the YouTube video ID of the video marked as last_processed=true.
// Returns empty string if no video is marked as last processed.
// Requires DATABASE_URL environment variable to be set.
func GetLastProcessedVideoID() (string, error) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return "", fmt.Errorf("DATABASE_URL environment variable is required")
	}

	conn, err := pgx.Connect(context.Background(), databaseURL)
	if err != nil {
		return "", fmt.Errorf("failed to connect to database: %w", err)
	}
	defer conn.Close(context.Background())

	var videoID string
	err = conn.QueryRow(context.Background(),
		"SELECT youtube_id FROM videos WHERE last_processed = true LIMIT 1").Scan(&videoID)
	if err == pgx.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("failed to query last processed video: %w", err)
	}

	return videoID, nil
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

	// First video in the array is the newest (top of yt-dlp playlist order)
	for videoIdx, videoJSON := range videos {
		isNewestVideo := videoIdx == 0

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
				_, err = tx.Exec(ctx, `INSERT INTO match_participants (match_id, player_id, side) VALUES ($1, $2, $3)`,
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
				_, err = tx.Exec(ctx, `INSERT INTO match_participants (match_id, player_id, side) VALUES ($1, $2, $3)`,
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

		if isNewestVideo {
			_, err = tx.Exec(ctx, `UPDATE videos SET last_processed = NULL WHERE last_processed = true`)
			if err != nil {
				return fmt.Errorf("failed to clear last_processed flags: %w", err)
			}
			_, err = tx.Exec(ctx, `UPDATE videos SET last_processed = true WHERE id = $1`, videoID)
			if err != nil {
				return fmt.Errorf("failed to set last_processed: %w", err)
			}
			fmt.Printf("Set last_processed=true for video ID: %d\n", videoID)
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
