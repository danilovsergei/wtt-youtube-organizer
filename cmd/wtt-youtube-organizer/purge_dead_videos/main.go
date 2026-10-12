package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
)

type VideoCheck struct {
	ID        int64
	YoutubeID string
	Title     string
}

func main() {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		fmt.Println("DATABASE_URL required")
		os.Exit(1)
	}

	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dbURL)
	if err != nil {
		fmt.Println("Connect error:", err)
		os.Exit(1)
	}
	defer conn.Close(ctx)

	rows, err := conn.Query(ctx, "SELECT id, youtube_id, title FROM videos WHERE youtube_id IS NOT NULL AND youtube_id != '' ORDER BY id DESC")
	if err != nil {
		fmt.Println("Query error:", err)
		os.Exit(1)
	}

	var allVideos []VideoCheck
	for rows.Next() {
		var v VideoCheck
		if err := rows.Scan(&v.ID, &v.YoutubeID, &v.Title); err == nil {
			allVideos = append(allVideos, v)
		}
	}
	rows.Close()

	fmt.Println("Checking", len(allVideos), "videos for removed/terminated YouTube status...")

	var deadVideos []VideoCheck
	var mu sync.Mutex
	var completed int64
	ytdlpPath := "/home/geonix/Build/wtt-youtube-organizer/qwen_venv/bin/yt-dlp"

	jobs := make(chan VideoCheck, len(allVideos))
	for _, v := range allVideos {
		jobs <- v
	}
	close(jobs)

	const numWorkers = 8
	var wg sync.WaitGroup

	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for v := range jobs {
				cmd := exec.Command(ytdlpPath, "--skip-download", "--no-warnings", "--print", "id", "https://www.youtube.com/watch?v="+v.YoutubeID)
				out, err := cmd.CombinedOutput()
				if err != nil {
					outStr := string(out)
					isDead := strings.Contains(outStr, "This video is unavailable") ||
						strings.Contains(outStr, "Video unavailable") ||
						strings.Contains(outStr, "removed by the uploader") ||
						strings.Contains(outStr, "account associated with this video has been terminated") ||
						strings.Contains(outStr, "Private video")

					if isDead {
						mu.Lock()
						deadVideos = append(deadVideos, v)
						mu.Unlock()
						fmt.Println("DEAD VIDEO FOUND:", v.ID, v.YoutubeID, v.Title)
					}
				}
				c := atomic.AddInt64(&completed, 1)
				if c%100 == 0 || c == int64(len(allVideos)) {
					fmt.Println("Progress: [", c, "/", len(allVideos), "] checked")
				}
				time.Sleep(50 * time.Millisecond)
			}
		}()
	}

	wg.Wait()
	fmt.Println("Found", len(deadVideos ), "dead/terminated videos out of", len(allVideos), "checked.")

	if len(deadVideos) == 0 {
		fmt.Println("No dead videos to purge. Database is clean!")
		return
	}

	fmt.Println("Purging dead videos from database...")
	for _, v := range deadVideos {
		tx, err := conn.Begin(ctx)
		if err != nil {
			fmt.Println("Failed to begin tx for video", v.ID, err)
			continue
		}

		tx.Exec(ctx, "DELETE FROM match_participants WHERE match_id IN (SELECT id FROM matches WHERE video_id = $1)", v.ID)
		mRes, _ := tx.Exec(ctx, "DELETE FROM matches WHERE video_id = $1", v.ID)
		tx.Exec(ctx, "DELETE FROM videos WHERE id = $1", v.ID)

		if err := tx.Commit(ctx); err != nil {
			fmt.Println("Commit failed for video", v.ID, err)
		} else {
			fmt.Println("Purged video", v.ID, v.YoutubeID, "deleted", mRes.RowsAffected(), "matches")
		}
	}

	tRes, _ := conn.Exec(ctx, "DELETE FROM tournaments WHERE id NOT IN (SELECT DISTINCT tournament_id FROM matches)")
	if tRes.RowsAffected() > 0 {
		fmt.Println("Cleaned up", tRes.RowsAffected(), "empty tournaments")
	}

	fmt.Println("Purge complete!")
}
