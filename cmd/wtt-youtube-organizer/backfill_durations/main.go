package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

func main() {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		fmt.Println("DATABASE_URL environment variable is required")
		os.Exit(1)
	}

	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dbURL)
	if err != nil {
		fmt.Println("Failed to connect to database:", err)
		os.Exit(1)
	}
	defer conn.Close(ctx)

	fmt.Println("=== Phase 1: Fast SQL Backfill for Non-Last Matches ===")
	leadQuery := `
	WITH ranked_matches AS (
		SELECT 
			id,
			video_id,
			video_offset_seconds,
			LEAD(video_offset_seconds) OVER (
				PARTITION BY video_id 
				ORDER BY video_offset_seconds ASC
			) AS next_offset
		FROM matches
	)
	UPDATE matches m
	SET duration_seconds = rm.next_offset - rm.video_offset_seconds
	FROM ranked_matches rm
	WHERE m.id = rm.id 
	  AND rm.next_offset IS NOT NULL 
	  AND rm.next_offset > rm.video_offset_seconds;`

	res, err := conn.Exec(ctx, leadQuery)
	if err != nil {
		fmt.Println("Error in Phase 1:", err)
		os.Exit(1)
	}
	fmt.Println("Phase 1 complete: updated", res.RowsAffected(), "matches!")

	fmt.Println("=== Phase 2: Resolving Video Durations for Last Matches ===")
	rows, err := conn.Query(ctx, `
		SELECT DISTINCT v.id, v.youtube_id 
		FROM videos v 
		JOIN matches m ON m.video_id = v.id 
		WHERE m.duration_seconds IS NULL AND v.youtube_id IS NOT NULL AND v.youtube_id != ''
	`)
	if err != nil {
		fmt.Println("Failed to query videos for last matches:", err)
		os.Exit(1)
	}

	type VideoItem struct {
		ID        int64
		YoutubeID string
	}
	var videos []VideoItem
	for rows.Next() {
		var item VideoItem
		if err := rows.Scan(&item.ID, &item.YoutubeID); err == nil {
			videos = append(videos, item)
		}
	}
	rows.Close()

	fmt.Println("Found", len(videos), "videos with last matches needing duration.")
	updatedLast := 0
	for i, v := range videos {
		fmt.Printf("[%d/%d] Fetching duration for youtube_id: %s... ", i+1, len(videos), v.YoutubeID)
		cmd := exec.Command("yt-dlp", "--print", "duration", "--no-warnings", "https://www.youtube.com/watch?v="+v.YoutubeID)
		out, err := cmd.Output()
		if err != nil {
			fmt.Println("Skipped (yt-dlp error)")
			continue
		}
		durStr := strings.TrimSpace(string(out))
		durSec, err := strconv.Atoi(durStr)
		if err != nil || durSec <= 0 {
			// Try float parse
			if f, err2 := strconv.ParseFloat(durStr, 64); err2 == nil && f > 0 {
				durSec = int(f)
			} else {
				fmt.Println("Invalid duration output:", durStr)
				continue
			}
		}

		uRes, err := conn.Exec(ctx, `
			UPDATE matches 
			SET duration_seconds = $1 - video_offset_seconds 
			WHERE video_id = $2 AND duration_seconds IS NULL AND $1 > video_offset_seconds
		`, durSec, v.ID)
		if err != nil {
			fmt.Println("Update error:", err)
		} else {
			fmt.Println("OK! Updated", uRes.RowsAffected(), "match(es)")
			updatedLast += int(uRes.RowsAffected())
		}
		time.Sleep(100 * time.Millisecond)
	}

	var totalFilled, remaining int
	conn.QueryRow(ctx, "SELECT count(*) FROM matches WHERE duration_seconds IS NOT NULL").Scan(&totalFilled)
	conn.QueryRow(ctx, "SELECT count(*) FROM matches WHERE duration_seconds IS NULL").Scan(&remaining)
	fmt.Println("=== Backfill Summary ===")
	fmt.Println("Total matches with duration:", totalFilled)
	fmt.Println("Remaining:", remaining)
}
