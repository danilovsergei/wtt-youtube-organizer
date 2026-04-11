package delete_cmd

import (
	"context"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5"
	"github.com/spf13/cobra"
)

var tournamentName string

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "delete",
		Short: "Delete all videos and matches related to a specific tournament",
		RunE: func(cmd *cobra.Command, args []string) error {
			if tournamentName == "" {
				return fmt.Errorf("--tournament flag is required")
			}
			return deleteTournamentData(tournamentName)
		},
	}
	cmd.Flags().StringVarP(&tournamentName, "tournament", "t", "", "Tournament name to delete")
	cmd.MarkFlagRequired("tournament")
	return cmd
}

func deleteTournamentData(name string) error {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return fmt.Errorf("DATABASE_URL environment variable is required")
	}

	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dbURL)
	if err != nil {
		return fmt.Errorf("unable to connect to database: %w", err)
	}
	defer conn.Close(ctx)

	tx, err := conn.Begin(ctx)
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	// 1. Find tournament IDs
	rows, err := tx.Query(ctx, "SELECT id FROM tournaments WHERE name ILIKE $1", name)
	if err != nil {
		return fmt.Errorf("failed to query tournaments: %w", err)
	}
	var tournamentIDs []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			return fmt.Errorf("failed to scan tournament ID: %w", err)
		}
		tournamentIDs = append(tournamentIDs, id)
	}
	rows.Close()

	if len(tournamentIDs) == 0 {
		fmt.Printf("No tournament found matching name: %s\n", name)
		return nil
	}

	// 2. Find associated video IDs
	vRows, err := tx.Query(ctx, "SELECT DISTINCT video_id FROM matches WHERE tournament_id = ANY($1)", tournamentIDs)
	if err != nil {
		return fmt.Errorf("failed to query video IDs: %w", err)
	}
	var videoIDs []int
	for vRows.Next() {
		var vid int
		if err := vRows.Scan(&vid); err != nil {
			return fmt.Errorf("failed to scan video ID: %w", err)
		}
		videoIDs = append(videoIDs, vid)
	}
	vRows.Close()

	// 3. Delete match_participants
	mpRes, err := tx.Exec(ctx, "DELETE FROM match_participants WHERE match_id IN (SELECT id FROM matches WHERE tournament_id = ANY($1))", tournamentIDs)
	if err != nil {
		return fmt.Errorf("failed to delete match_participants: %w", err)
	}
	fmt.Printf("Deleted %d match_participants\n", mpRes.RowsAffected())

	// 4. Delete matches
	mRes, err := tx.Exec(ctx, "DELETE FROM matches WHERE tournament_id = ANY($1)", tournamentIDs)
	if err != nil {
		return fmt.Errorf("failed to delete matches: %w", err)
	}
	fmt.Printf("Deleted %d matches\n", mRes.RowsAffected())

	// 5. Delete videos
	if len(videoIDs) > 0 {
		vRes, err := tx.Exec(ctx, "DELETE FROM videos WHERE id = ANY($1)", videoIDs)
		if err != nil {
			return fmt.Errorf("failed to delete videos: %w", err)
		}
		fmt.Printf("Deleted %d videos\n", vRes.RowsAffected())
	} else {
		fmt.Printf("Deleted 0 videos\n")
	}

	// 6. Delete tournaments
	tRes, err := tx.Exec(ctx, "DELETE FROM tournaments WHERE id = ANY($1)", tournamentIDs)
	if err != nil {
		return fmt.Errorf("failed to delete tournaments: %w", err)
	}
	fmt.Printf("Deleted %d tournaments\n", tRes.RowsAffected())

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("failed to commit transaction: %w", err)
	}

	fmt.Printf("Successfully deleted all data related to tournament: %s\n", name)
	return nil
}
