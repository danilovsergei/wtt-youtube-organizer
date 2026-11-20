package importer

import (
	"context"
	"fmt"
	"time"

	"wtt-youtube-organizer/wtt_api"

	"github.com/jackc/pgx/v5"
)

// QueryTournamentDBMatches queries all matches for a tournament from PostgreSQL
func QueryTournamentDBMatches(ctx context.Context, conn *pgx.Conn, tournamentName string, year int) ([]wtt_api.DBMatchRecord, error) {
	query := `
		SELECT 
			m.id,
			m.tournament_id,
			t.name AS tournament_name,
			t.year AS tournament_year,
			m.video_id,
			v.youtube_id,
			v.title AS video_title,
			COALESCE(v.day, '') AS day,
			COALESCE(m.session, 1) AS session,
			m.video_offset_seconds,
			COALESCE(m.duration_seconds, 0) AS duration_seconds,
			m.is_doubles,
			COALESCE((SELECT string_agg(p.name, ' & ' ORDER BY p.name) FROM match_participants mp JOIN players p ON mp.player_id = p.id WHERE mp.match_id = m.id AND mp.side = 'A'), '') AS team_a,
			COALESCE((SELECT string_agg(p.name, ' & ' ORDER BY p.name) FROM match_participants mp JOIN players p ON mp.player_id = p.id WHERE mp.match_id = m.id AND mp.side = 'B'), '') AS team_b,
			v.stream_start_utc,
			m.created_at
		FROM matches m
		JOIN tournaments t ON m.tournament_id = t.id
		JOIN videos v ON m.video_id = v.id
		WHERE t.name ILIKE $1 AND ($2 = 0 OR t.year = $2)
		ORDER BY m.id;
	`
	rows, err := conn.Query(ctx, query, "%"+tournamentName+"%", year)
	if err != nil {
		return nil, fmt.Errorf("failed to query DB matches: %w", err)
	}
	defer rows.Close()

	var matches []wtt_api.DBMatchRecord
	for rows.Next() {
		var m wtt_api.DBMatchRecord
		err := rows.Scan(
			&m.ID,
			&m.TournamentID,
			&m.TournamentName,
			&m.TournamentYear,
			&m.VideoID,
			&m.YoutubeID,
			&m.VideoTitle,
			&m.Day,
			&m.Session,
			&m.VideoOffsetSeconds,
			&m.DurationSeconds,
			&m.IsDoubles,
			&m.TeamA,
			&m.TeamB,
			&m.StreamStartUTC,
			&m.CreatedAt,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan DB match: %w", err)
		}
		matches = append(matches, m)
	}
	return matches, nil
}

// PersistMatchedRecordsBatch updates matches in PostgreSQL with official WTT data and resolved stages via pgx.Batch
func PersistMatchedRecordsBatch(ctx context.Context, conn *pgx.Conn, matches []wtt_api.MatchedRecord) (int, error) {
	batch := &pgx.Batch{}
	count := 0

	for _, m := range matches {
		if m.DBMatch == nil || m.IsDuplicate {
			continue
		}

		var wttMatchID *int64
		if m.WTTMatchID > 0 {
			wttMatchID = &m.WTTMatchID
		}

		var startTime *time.Time
		if m.WTTMatchStartUTC != "" {
			if t, err := time.Parse("02/01/2006 15:04:05", m.WTTMatchStartUTC); err == nil {
				startTime = &t
			} else if t, err := time.Parse(time.RFC3339, m.WTTMatchStartUTC); err == nil {
				startTime = &t
			}
		}

		stage := m.WTTRound
		if stage == "" {
			stage = "Round Match"
		}
		stageOrder := m.StageOrder
		if stageOrder <= 0 {
			stageOrder = 1
		}

		batch.Queue(`
			UPDATE matches SET
				wtt_match_id = $1,
				wtt_round = $2,
				stage_order = $3,
				is_broadcast_match = $4,
				wtt_gender = $5,
				wtt_score = $6,
				wtt_game_scores = $7,
				wtt_match_start_utc = $8
			WHERE id = $9;
		`,
			wttMatchID,
			stage,
			stageOrder,
			m.IsBroadcastMatch,
			m.WTTGender,
			m.WTTScore,
			m.WTTGameScores,
			startTime,
			m.DBMatch.ID,
		)
		count++
	}

	if count == 0 {
		return 0, nil
	}

	br := conn.SendBatch(ctx, batch)
	defer br.Close()

	for i := 0; i < count; i++ {
		_, err := br.Exec()
		if err != nil {
			return i, fmt.Errorf("batch exec failed at %d: %w", i, err)
		}
	}

	return count, nil
}

// AlignTournamentWithWTT aligns the given tournament's matches with official WTT results and persists stages.
func AlignTournamentWithWTT(ctx context.Context, conn *pgx.Conn, tournamentName string, year int, opts ...func(*wtt_api.WTTClient)) error {
	client := wtt_api.NewWTTClient(opts...)
	eventID, eventName, err := client.FindEventIDByQuery(ctx, tournamentName, year)
	if err != nil {
		return fmt.Errorf("WTT event not found: %w", err)
	}

	wttMatches, err := client.FetchOfficialResults(ctx, eventID)
	if err != nil {
		return fmt.Errorf("WTT results unavailable: %w", err)
	}

	dbMatches, err := QueryTournamentDBMatches(ctx, conn, tournamentName, year)
	if err != nil {
		return fmt.Errorf("failed to query DB matches: %w", err)
	}

	report := wtt_api.AlignMatches(tournamentName, year, eventID, dbMatches, wttMatches, 0.70)
	count, err := PersistMatchedRecordsBatch(ctx, conn, report.Matches)
	if err != nil {
		return fmt.Errorf("failed to persist matches: %w", err)
	}

	fmt.Printf("Successfully aligned %d matches with WTT Event %s (%d)\n", count, eventName, eventID)
	return nil
}
