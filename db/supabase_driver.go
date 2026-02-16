package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/supabase-community/postgrest-go"
	"github.com/supabase-community/supabase-go"
)

type MatchRecord struct {
	Tournament         string `json:"tournament"`
	Year               int    `json:"year"`
	MatchTime          string `json:"match_time"`
	TeamA              string `json:"team_a"`
	TeamB              string `json:"team_b"`
	IsDoubles          bool   `json:"is_doubles"`
	YoutubeID          string `json:"youtube_id"`
	VideoTitle         string `json:"video_title"`
	VideoOffsetSeconds int    `json:"video_offset_seconds"` // seconds from video start
}

// buildYouTubeURL constructs a full YouTube URL with timestamp
// Example: https://youtu.be/2wOjD1O4Qow?t=2222 points to 37:02 in the video
func buildYouTubeURL(videoID string, timestampSeconds int) string {
	if timestampSeconds > 0 {
		return fmt.Sprintf("https://youtu.be/%s?t=%d", videoID, timestampSeconds)
	}
	return fmt.Sprintf("https://youtu.be/%s", videoID)
}

// VideoJSON represents the structure of the match.json file
type VideoJSON struct {
	VideoID    string      `json:"video_id"`
	VideoTitle string      `json:"video_title"`
	UploadDate string      `json:"upload_date"` // Format: YYYYMMDD
	Matches    []MatchJSON `json:"matches"`
}

// parseUploadDate parses upload_date from YYYYMMDD format to time.Time
func parseUploadDate(dateStr string) (time.Time, error) {
	if dateStr == "" {
		return time.Now(), fmt.Errorf("empty upload_date")
	}
	// Parse YYYYMMDD format
	return time.Parse("20060102", dateStr)
}

// MatchJSON represents a single match entry in the JSON file
type MatchJSON struct {
	Timestamp int    `json:"timestamp"`
	Player1   string `json:"player1"`
	Player2   string `json:"player2"`
}

func main() {
	// Retrieve values from OS environment variables
	supabaseUrl := "https://yxegxufjztnsogjrqsqw.supabase.co"
	supabaseKey := os.Getenv("SUPABASE_SERVICE_ROLE_KEY")

	// Quick check to ensure variables are set
	if supabaseKey == "" {
		log.Fatal("SUPABASE_SERVICE_ROLE_KEY must be set in your environment")
	}

	client, err := supabase.NewClient(supabaseUrl, supabaseKey, nil)
	if err != nil {
		log.Fatal("cannot initialize client: ", err)
	}

	// Check if a JSON file argument is provided
	if len(os.Args) > 1 {
		jsonFile := os.Args[1]
		// Connect to database
		conn, err := pgx.Connect(context.Background(), os.Getenv("DATABASE_URL"))
		if err != nil {
			log.Fatal("Failed to connect to database:", err)
		}
		defer conn.Close(context.Background())

		// Add video from JSON file (tournament name and year auto-extracted from title)
		err = AddVideo(context.Background(), conn, jsonFile)
		if err != nil {
			log.Fatal("Failed to add video:", err)
		}
	} else {
		fmt.Println("Usage: go run supabase_driver.go <match.json>")
		fmt.Println("No JSON file provided, showing existing matches...")
	}

	printMatches(client)
}

func printMatches(client *supabase.Client) {
	// Fetch from the View
	var schedule []MatchRecord
	_, err := client.From("v_tournament_schedule").
		Select("*", "exact", false).
		Order("match_time", &postgrest.OrderOpts{Ascending: true}).
		ExecuteTo(&schedule)

	if err != nil {
		log.Fatal("REST request failed: ", err)
	}

	fmt.Printf("%-25s %-25s vs %-25s %s\n", "TOURNAMENT", "TEAM A", "TEAM B", "YOUTUBE LINK")
	fmt.Println(strings.Repeat("-", 150))
	for _, r := range schedule {
		youtubeURL := buildYouTubeURL(r.YoutubeID, r.VideoOffsetSeconds)
		fmt.Printf("%-25s %-25s vs %-25s %s\n",
			r.Tournament, r.TeamA, r.TeamB, youtubeURL)
	}
}

// AddMatch handles the complex logic of inserting a match transactionally
func AddMatch(ctx context.Context, conn *pgx.Conn, tName string, tYear int, matchTime time.Time, teamA []string, teamB []string, youtubeID string, videoTitle string) error {
	// 1. Start a Transaction (All or Nothing)
	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	// Rollback automatically if we don't commit (safety net)
	defer tx.Rollback(ctx)

	// 2. Get Tournament ID
	var tournamentID int
	err = tx.QueryRow(ctx, "SELECT id FROM tournaments WHERE name=$1 AND year=$2", tName, tYear).Scan(&tournamentID)
	if err != nil {
		return fmt.Errorf("tournament not found: %w", err)
	}

	// 3. Determine if it's doubles
	isDoubles := len(teamA) > 1 || len(teamB) > 1

	// 4. Insert Video record first
	var videoID int
	err = tx.QueryRow(ctx, `
		INSERT INTO videos (youtube_id, title, timestamp)
		VALUES ($1, $2, $3)
		RETURNING id`,
		youtubeID, videoTitle, matchTime).Scan(&videoID)
	if err != nil {
		return fmt.Errorf("failed to create video: %w", err)
	}

	// 5. Insert Match with video_id
	var matchID int
	err = tx.QueryRow(ctx, `
		INSERT INTO matches (tournament_id, match_timestamp, is_doubles, video_id)
		VALUES ($1, $2, $3, $4)
		RETURNING id`,
		tournamentID, matchTime, isDoubles, videoID).Scan(&matchID)
	if err != nil {
		return fmt.Errorf("failed to create match: %w", err)
	}

	// 5. Helper function to process a team
	addPlayers := func(players []string, side string) error {
		for _, name := range players {
			// A. Get or Create Player ID
			var playerID int
			// We try to SELECT first, if not found, INSERT
			// (This is a simplified "Upsert" logic for Go)
			err := tx.QueryRow(ctx, "SELECT id FROM players WHERE name=$1", name).Scan(&playerID)
			if err == pgx.ErrNoRows {
				// Player doesn't exist, create them
				err = tx.QueryRow(ctx, "INSERT INTO players (name) VALUES ($1) RETURNING id", name).Scan(&playerID)
			}
			if err != nil {
				return fmt.Errorf("failed to handle player %s: %w", name, err)
			}

			// B. Link to Match
			_, err = tx.Exec(ctx, `
				INSERT INTO match_participants (match_id, player_id, side)
				VALUES ($1, $2, $3)`,
				matchID, playerID, side)
			if err != nil {
				return fmt.Errorf("failed to link player %s: %w", name, err)
			}
		}
		return nil
	}

	// 6. Add both teams
	if err := addPlayers(teamA, "A"); err != nil {
		return err
	}
	if err := addPlayers(teamB, "B"); err != nil {
		return err
	}

	// 7. Commit the Transaction
	return tx.Commit(ctx)
}

// parseTournamentFromTitle extracts tournament name and year from video title.
// Expected format: "LIVE! | T2 | Day 2 | WTT Star Contender Chennai 2026 | Session 2"
// where the 4th pipe-separated segment is "<tournament name> <year>"
// Returns: tournament name (lowercase), year, and error if parsing fails
func parseTournamentFromTitle(title string) (string, int, error) {
	// Split by pipe character
	parts := strings.Split(title, "|")

	// We need at least 4 parts
	if len(parts) < 4 {
		return "", 0, fmt.Errorf("title has %d pipe-separated parts, expected at least 4", len(parts))
	}

	// Get the 4th part (index 3)
	tournamentPart := strings.TrimSpace(parts[3])

	// Split the tournament part to extract the year (last word should be the year)
	words := strings.Fields(tournamentPart)
	if len(words) < 2 {
		return "", 0, fmt.Errorf("tournament part '%s' doesn't have enough words", tournamentPart)
	}

	// Extract year (last word)
	yearStr := words[len(words)-1]
	year, err := strconv.Atoi(yearStr)
	if err != nil {
		return "", 0, fmt.Errorf("failed to parse year from '%s': %w", yearStr, err)
	}

	// Extract tournament name (all words except the last one)
	tournamentName := strings.Join(words[:len(words)-1], " ")
	// Convert to lowercase for database matching
	tournamentName = strings.ToLower(tournamentName)

	return tournamentName, year, nil
}

// parsePlayerName parses a player name and returns a slice of player names.
// For doubles matches (indicated by "/"), it splits into individual players.
// For singles, it returns a slice with a single player name.
func parsePlayerName(name string) []string {
	// Check if it's a doubles team (contains "/")
	if strings.Contains(name, "/") {
		parts := strings.Split(name, "/")
		result := make([]string, 0, len(parts))
		for _, p := range parts {
			trimmed := strings.TrimSpace(p)
			if trimmed != "" {
				result = append(result, trimmed)
			}
		}
		return result
	}
	// Singles player
	return []string{strings.TrimSpace(name)}
}

// AddVideo reads a JSON file and adds all matches from the video(s) to the database.
// The JSON can be either a single VideoJSON object or an array of VideoJSON objects.
// Tournament name and year are extracted from the video_title field.
// The last video in the array gets last_processed=true, clearing it from other videos.
func AddVideo(ctx context.Context, conn *pgx.Conn, jsonFilePath string) error {
	// 1. Read and parse JSON file
	data, err := os.ReadFile(jsonFilePath)
	if err != nil {
		return fmt.Errorf("failed to read JSON file: %w", err)
	}

	// Try to parse as array first, then as single object
	var videos []VideoJSON
	if err := json.Unmarshal(data, &videos); err != nil {
		// Try as single object
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

	// Process each video
	for videoIdx, videoJSON := range videos {
		isLastVideo := videoIdx == len(videos)-1

		fmt.Printf("\n[%d/%d] Processing video: %s\n", videoIdx+1, len(videos), videoJSON.VideoTitle)
		fmt.Printf("Video ID: %s\n", videoJSON.VideoID)
		fmt.Printf("Found %d matches\n", len(videoJSON.Matches))

		// 2. Parse tournament name and year from video title
		tournamentName, tournamentYear, err := parseTournamentFromTitle(videoJSON.VideoTitle)
		if err != nil {
			return fmt.Errorf("failed to parse tournament from title: %w", err)
		}
		fmt.Printf("Tournament: %s (%d)\n", tournamentName, tournamentYear)

		// 3. Start a Transaction
		tx, err := conn.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)

		// 4. Get or Create Tournament
		var tournamentID int
		err = tx.QueryRow(ctx, "SELECT id FROM tournaments WHERE name=$1 AND year=$2",
			tournamentName, tournamentYear).Scan(&tournamentID)
		if err == pgx.ErrNoRows {
			// Tournament doesn't exist, create it
			err = tx.QueryRow(ctx, "INSERT INTO tournaments (name, year) VALUES ($1, $2) RETURNING id",
				tournamentName, tournamentYear).Scan(&tournamentID)
			if err != nil {
				return fmt.Errorf("failed to create tournament '%s' %d: %w", tournamentName, tournamentYear, err)
			}
			fmt.Printf("Created new tournament: %s (%d)\n", tournamentName, tournamentYear)
		} else if err != nil {
			return fmt.Errorf("failed to query tournament: %w", err)
		}

		// 5. Parse upload_date from JSON
		uploadDate, err := parseUploadDate(videoJSON.UploadDate)
		if err != nil {
			fmt.Printf("Warning: %v, using current time\n", err)
			uploadDate = time.Now()
		}
		fmt.Printf("Upload Date: %s\n", uploadDate.Format("2006-01-02"))

		var videoID int
		var videoExists bool

		// Check if video already exists
		err = tx.QueryRow(ctx, "SELECT id FROM videos WHERE youtube_id=$1", videoJSON.VideoID).Scan(&videoID)
		if err == pgx.ErrNoRows {
			// Video doesn't exist, create it
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
			// Video exists - update title and upload_date, delete old matches
			videoExists = true
			_, err = tx.Exec(ctx, `
				UPDATE videos SET title=$1, upload_date=$2 WHERE id=$3`,
				videoJSON.VideoTitle, uploadDate, videoID)
			if err != nil {
				return fmt.Errorf("failed to update video: %w", err)
			}
			fmt.Printf("Video already exists (ID: %d), updating matches...\n", videoID)

			// Delete existing match participants for this video's matches
			_, err = tx.Exec(ctx, `
				DELETE FROM match_participants 
				WHERE match_id IN (SELECT id FROM matches WHERE video_id=$1)`, videoID)
			if err != nil {
				return fmt.Errorf("failed to delete old match participants: %w", err)
			}

			// Delete existing matches for this video
			result, err := tx.Exec(ctx, "DELETE FROM matches WHERE video_id=$1", videoID)
			if err != nil {
				return fmt.Errorf("failed to delete old matches: %w", err)
			}
			deletedCount := result.RowsAffected()
			fmt.Printf("Deleted %d existing matches\n", deletedCount)
		}

		_ = videoExists // suppress unused variable warning

		// 6. Process each match
		for i, matchJSON := range videoJSON.Matches {
			teamA := parsePlayerName(matchJSON.Player1)
			teamB := parsePlayerName(matchJSON.Player2)
			isDoubles := len(teamA) > 1 || len(teamB) > 1

			// Convert timestamp (seconds) to time based on upload date
			matchTime := uploadDate.Add(time.Duration(matchJSON.Timestamp) * time.Second)

			// Insert Match
			var matchID int
			err = tx.QueryRow(ctx, `
				INSERT INTO matches (tournament_id, match_timestamp, is_doubles, video_id)
				VALUES ($1, $2, $3, $4)
				RETURNING id`,
				tournamentID, matchTime, isDoubles, videoID).Scan(&matchID)
			if err != nil {
				return fmt.Errorf("failed to create match %d: %w", i+1, err)
			}

			// Add players for team A
			for _, name := range teamA {
				var playerID int
				err := tx.QueryRow(ctx, "SELECT id FROM players WHERE name=$1", name).Scan(&playerID)
				if err == pgx.ErrNoRows {
					err = tx.QueryRow(ctx, "INSERT INTO players (name) VALUES ($1) RETURNING id", name).Scan(&playerID)
				}
				if err != nil {
					return fmt.Errorf("failed to handle player %s: %w", name, err)
				}
				_, err = tx.Exec(ctx, `
					INSERT INTO match_participants (match_id, player_id, side)
					VALUES ($1, $2, $3)`,
					matchID, playerID, "A")
				if err != nil {
					return fmt.Errorf("failed to link player %s: %w", name, err)
				}
			}

			// Add players for team B
			for _, name := range teamB {
				var playerID int
				err := tx.QueryRow(ctx, "SELECT id FROM players WHERE name=$1", name).Scan(&playerID)
				if err == pgx.ErrNoRows {
					err = tx.QueryRow(ctx, "INSERT INTO players (name) VALUES ($1) RETURNING id", name).Scan(&playerID)
				}
				if err != nil {
					return fmt.Errorf("failed to handle player %s: %w", name, err)
				}
				_, err = tx.Exec(ctx, `
					INSERT INTO match_participants (match_id, player_id, side)
					VALUES ($1, $2, $3)`,
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

		// 7. Handle last_processed flag (only for the last video in the array)
		if isLastVideo {
			// Clear last_processed from all other videos
			_, err = tx.Exec(ctx, `
				UPDATE videos SET last_processed = NULL WHERE last_processed = true`)
			if err != nil {
				return fmt.Errorf("failed to clear last_processed flags: %w", err)
			}

			// Set last_processed for this video
			_, err = tx.Exec(ctx, `
				UPDATE videos SET last_processed = true WHERE id = $1`, videoID)
			if err != nil {
				return fmt.Errorf("failed to set last_processed: %w", err)
			}
			fmt.Printf("Set last_processed=true for video ID: %d\n", videoID)
		}

		// 8. Commit the Transaction
		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("failed to commit: %w", err)
		}

		fmt.Printf("Successfully added %d matches from video\n", len(videoJSON.Matches))
	}

	fmt.Printf("\n=== Summary ===\n")
	fmt.Printf("Processed %d video(s) from JSON file\n", len(videos))
	return nil
}
