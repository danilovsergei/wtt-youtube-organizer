package importer

import (
	"context"
	"testing"
	"time"
)

// Add test coverage for session logic
func TestSessionAssignment(t *testing.T) {
	conn, cleanup := setupTestDB(t)
	defer cleanup()

	ctx := context.Background()

	// Scenario 1: Current video has 2 matches with same player on the same day.
	// Expected: session 1 for lower offset, session 2 for higher offset.
	video1 := VideoJSON{
		VideoID:    "D9vyeFsjlNQ",
		VideoTitle: "LIVE! | Day 4 | WTT Test Tournament 2026 | Session 1",
		UploadDate: "1775444016", // 2026-04-07 02:53:36
		Matches: []MatchJSON{
			{Timestamp: 4680, Player1: "Fan Zhendong", Player2: "Truls Moregard"},
			{Timestamp: 4682, Player1: "Fan Zhendong", Player2: "Hugo Calderano"},
		},
	}

	jsonPath1 := writeTestJSON(t, []VideoJSON{video1})
	if err := ImportMatchesFromJSONWithConn(ctx, conn, jsonPath1); err != nil {
		t.Fatalf("first import failed: %v", err)
	}

	// Verify Fan Zhendong matches
	var s1, s2 int
	err := conn.QueryRow(ctx, "SELECT session FROM matches WHERE video_id=(SELECT id FROM videos WHERE youtube_id=$1) AND video_offset_seconds=$2", "D9vyeFsjlNQ", 4680).Scan(&s1)
	if err != nil {
		t.Fatalf("failed to query s1: %v", err)
	}
	err = conn.QueryRow(ctx, "SELECT session FROM matches WHERE video_id=(SELECT id FROM videos WHERE youtube_id=$1) AND video_offset_seconds=$2", "D9vyeFsjlNQ", 4682).Scan(&s2)
	if err != nil {
		t.Fatalf("failed to query s2: %v", err)
	}
	if s1 != 1 {
		t.Errorf("expected session 1 for first match, got %d", s1)
	}
	if s2 != 2 {
		t.Errorf("expected session 2 for second match, got %d", s2)
	}

	// Scenario 2: DB has matches with upload dates < 30 mins apart.
	// We use Day 5 to isolate from Scenario 1
	// Stream 1: uploaded at 10:00:00
	videoT1 := VideoJSON{
		VideoID:    "gaHop0oN8ms",
		VideoTitle: "LIVE! | Day 5 | WTT Test Tournament 2026 | Session 1",
		UploadDate: "1775469600", // 2026-04-07 10:00:00
		Matches: []MatchJSON{
			{Timestamp: 5000, Player1: "Ma Long", Player2: "Timo Boll"}, // Will be session 2 because it has a higher offset than the match in Stream 2
		},
	}

	// Stream 2: uploaded at 10:20:00 (less than 30 mins after Stream 1)
	videoT2 := VideoJSON{
		VideoID:    "olderVideo",
		VideoTitle: "LIVE! | Day 5 | WTT Test Tournament 2026 | Session 2",
		UploadDate: "1775470800", // 2026-04-07 10:20:00
		Matches: []MatchJSON{
			{Timestamp: 1000, Player1: "Ma Long", Player2: "Lin Yun-Ju"}, // Will be session 1 because it has a lower offset
		},
	}
	
	if err := ImportMatchesFromJSONWithConn(ctx, conn, writeTestJSON(t, []VideoJSON{videoT1})); err != nil {
		t.Fatalf("import T1 failed: %v", err)
	}
	if err := ImportMatchesFromJSONWithConn(ctx, conn, writeTestJSON(t, []VideoJSON{videoT2})); err != nil {
		t.Fatalf("import T2 failed: %v", err)
	}

	// Check sessions.
	// Since they are < 30 mins apart, they are grouped together.
	// Match 1: 1000 offset -> session 1
	// Match 2: 5000 offset -> session 2
	err = conn.QueryRow(ctx, "SELECT session FROM matches WHERE video_id=(SELECT id FROM videos WHERE youtube_id=$1) AND video_offset_seconds=$2", "olderVideo", 1000).Scan(&s1)
	if err != nil { t.Fatalf("failed to query s1: %v", err) }
	
	err = conn.QueryRow(ctx, "SELECT session FROM matches WHERE video_id=(SELECT id FROM videos WHERE youtube_id=$1) AND video_offset_seconds=$2", "gaHop0oN8ms", 5000).Scan(&s2)
	if err != nil { t.Fatalf("failed to query s2: %v", err) }

	rows, _ := conn.Query(ctx, `
		SELECT m.id, v.youtube_id, v.upload_date, m.video_offset_seconds, 
		FLOOR(EXTRACT(EPOCH FROM (v.upload_date - MIN(v.upload_date) OVER ())) / 1800) as bucket,
		m.session
		FROM matches m
		JOIN videos v ON m.video_id = v.id
		WHERE v.day = 'Day 5'
		ORDER BY bucket ASC, m.video_offset_seconds ASC
	`)
	for rows.Next() {
		var id, offset, bucket, session int
		var yt string
		var ud time.Time
		rows.Scan(&id, &yt, &ud, &offset, &bucket, &session)
		t.Logf("id: %d, yt: %s, upload: %v, offset: %d, bucket: %d, session: %d\n", id, yt, ud, offset, bucket, session)
	}
	rows.Close()

	if s1 != 1 { t.Errorf("expected session 1 for lower offset match in parallel stream, got %d", s1) }
	if s2 != 2 { t.Errorf("expected session 2 for higher offset match in parallel stream, got %d", s2) }

	// Scenario 3: DB has matches with upload dates > 30 mins apart.
	// We use Day 6 to isolate
	// Stream 3: uploaded at 12:00:00
	videoT3 := VideoJSON{
		VideoID:    "video3",
		VideoTitle: "LIVE! | Day 6 | WTT Test Tournament 2026 | Session 1",
		UploadDate: "1775476800", // 2026-04-07 12:00:00
		Matches: []MatchJSON{
			{Timestamp: 5000, Player1: "Chen Meng", Player2: "Mima Ito"}, // Will be session 1 because stream is earlier
		},
	}

	// Stream 4: uploaded at 12:45:00 (more than 30 mins after Stream 3)
	videoT4 := VideoJSON{
		VideoID:    "video4",
		VideoTitle: "LIVE! | Day 6 | WTT Test Tournament 2026 | Session 2",
		UploadDate: "1775479500", // 2026-04-07 12:45:00
		Matches: []MatchJSON{
			{Timestamp: 1000, Player1: "Chen Meng", Player2: "Sun Yingsha"}, // Will be session 2 because stream is later
		},
	}

	if err := ImportMatchesFromJSONWithConn(ctx, conn, writeTestJSON(t, []VideoJSON{videoT3})); err != nil {
		t.Fatalf("import T3 failed: %v", err)
	}
	if err := ImportMatchesFromJSONWithConn(ctx, conn, writeTestJSON(t, []VideoJSON{videoT4})); err != nil {
		t.Fatalf("import T4 failed: %v", err)
	}

	// Check sessions.
	// Since they are > 30 mins apart, they are NOT grouped together.
	// video3 (12:00:00) -> session 1
	// video4 (12:45:00) -> session 2
	err = conn.QueryRow(ctx, "SELECT session FROM matches WHERE video_id=(SELECT id FROM videos WHERE youtube_id=$1) AND video_offset_seconds=$2", "video3", 5000).Scan(&s1)
	if err != nil { t.Fatalf("failed to query s1: %v", err) }
	
	err = conn.QueryRow(ctx, "SELECT session FROM matches WHERE video_id=(SELECT id FROM videos WHERE youtube_id=$1) AND video_offset_seconds=$2", "video4", 1000).Scan(&s2)
	if err != nil { t.Fatalf("failed to query s2: %v", err) }

	if s1 != 1 { t.Errorf("expected session 1 for earlier stream match, got %d", s1) }
	if s2 != 2 { t.Errorf("expected session 2 for later stream match, got %d", s2) }
}
