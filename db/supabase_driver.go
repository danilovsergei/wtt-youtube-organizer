package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/supabase-community/postgrest-go"
	"github.com/supabase-community/supabase-go"
)

type MatchRecord struct {
	Tournament string `json:"tournament"`
	Year       int    `json:"year"`
	MatchTime  string `json:"match_time"`
	TeamA      string `json:"team_a"`
	TeamB      string `json:"team_b"`
	IsDoubles  bool   `json:"is_doubles"`
	YoutubeID  string `json:"youtube_id"`
	VideoTitle string `json:"video_title"`
}

func main() {
	// Retrieve values from OS environment variables
	supabaseUrl := "https://yxegxufjztnsogjrqsqw.supabase.co"
	supabaseKey := os.Getenv("SUPABASE_SERVICE_ROLE_KEY")

	// Quick check to ensure variables are set
	if supabaseKey == "" {
		log.Fatal("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set in your environment")
	}

	client, err := supabase.NewClient(supabaseUrl, supabaseKey, nil)
	if err != nil {
		log.Fatal("cannot initialize client: ", err)
	}

	addOneMatch()
	printMatches(client)
}

func addOneMatch() {
	conn, err := pgx.Connect(context.Background(), os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close(context.Background())

	// Example Usage: Singles Match
	err = AddMatch(context.Background(), conn, "europe smash", 2026,
		time.Now().Add(2*time.Hour),                           // Match time
		[]string{"Lin Yun Ju"},                                // Team A
		[]string{"Tomokazu Harimoto"},                         // Team B
		"dQw4w9WgXcQ",                                         // Fake youtube_id
		"Lin Yun Ju vs Tomokazu Harimoto | Europe Smash 2026", // Fake video_title
	)
	if err != nil {
		log.Fatal("Failed to add singles match:", err)
	}

	// Example Usage: Doubles Match
	err = AddMatch(context.Background(), conn, "europe smash", 2026,
		time.Now().Add(3*time.Hour),
		[]string{"Zhang", "Bo"},           // Team A (Doubles pair)
		[]string{"Samsonov", "Schetinin"}, // Team B (Doubles pair)
		"xyzABC12345",                     // Fake youtube_id
		"Zhang/Bo vs Samsonov/Schetinin | Europe Smash 2026 Doubles", // Fake video_title
	)
	if err != nil {
		log.Fatal("Failed to add doubles match:", err)
	}

	fmt.Println("Matches added successfully!")
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

	fmt.Printf("%-20s %-15s %-25s vs %-25s %-15s %-50s\n", "TOURNAMENT", "TIME", "TEAM A", "TEAM B", "YOUTUBE_ID", "VIDEO_TITLE")
	fmt.Println("-------------------------------------------------------------------------------------------------------------------------------------------------")
	for _, r := range schedule {
		fmt.Printf("%-20s %-15s %-25s vs %-25s %-15s %-50s\n",
			r.Tournament, r.MatchTime, r.TeamA, r.TeamB, r.YoutubeID, r.VideoTitle)
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
