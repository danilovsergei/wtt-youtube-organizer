package wtt_cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"wtt-youtube-organizer/wtt_api"

	"github.com/jackc/pgx/v5"
	"github.com/spf13/cobra"
)

// NewCommand returns the root 'wtt' cobra command.
func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "wtt",
		Short: "Tools for fetching official WTT tournament results and aligning with database records",
		RunE: func(cmd *cobra.Command, args []string) error {
			return cmd.Help()
		},
	}

	cmd.AddCommand(newListEventsCommand())
	cmd.AddCommand(newListMatchesCommand())
	cmd.AddCommand(newGenerateReportCommand())
	cmd.AddCommand(newAuditAllCommand())
	return cmd
}

func newListEventsCommand() *cobra.Command {
	var query string
	var year int

	cmd := &cobra.Command{
		Use:   "list-events",
		Short: "Search and list official WTT events from the WTT CDN",
		RunE: func(cmd *cobra.Command, args []string) error {
			client := wtt_api.NewWTTClient()
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()

			events, err := client.FetchDropdownEvents(ctx)
			if err != nil {
				return fmt.Errorf("failed to fetch events: %w", err)
			}

			q := strings.ToLower(strings.TrimSpace(query))
			seen := make(map[int]bool)
			matchCount := 0

			fmt.Printf("%-8s | %-6s | %s\n", "EVENT ID", "YEAR", "EVENT NAME")
			fmt.Println(strings.Repeat("-", 80))

			for _, e := range events {
				if seen[e.EventID] {
					continue
				}
				nameLower := strings.ToLower(e.EventName)
				if q != "" && !strings.Contains(nameLower, q) {
					continue
				}
				if year > 0 && !strings.Contains(nameLower, fmt.Sprintf("%d", year)) {
					continue
				}

				seen[e.EventID] = true
				matchCount++
				fmt.Printf("%-8d | %-6d | %s\n", e.EventID, year, e.EventName)
			}

			fmt.Printf("\nFound %d matching events.\n", matchCount)
			return nil
		},
	}

	cmd.Flags().StringVarP(&query, "query", "q", "", "Search query for tournament name (e.g. 'Montpellier', 'China Smash')")
	cmd.Flags().IntVarP(&year, "year", "y", 0, "Filter by year (e.g. 2026)")
	return cmd
}

func newListMatchesCommand() *cobra.Command {
	var eventID int

	cmd := &cobra.Command{
		Use:   "list-matches",
		Short: "Fetch and list official matches for a specific WTT Event ID",
		RunE: func(cmd *cobra.Command, args []string) error {
			if eventID <= 0 {
				return fmt.Errorf("--event-id is required and must be > 0")
			}

			client := wtt_api.NewWTTClient()
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()

			matches, err := client.FetchOfficialResults(ctx, eventID)
			if err != nil {
				return fmt.Errorf("failed to fetch official results for event %d: %w", eventID, err)
			}

			fmt.Printf("Fetched %d official matches for Event ID: %d\n\n", len(matches), eventID)
			fmt.Printf("%-12s | %-14s | %-32s | %-8s | %s\n", "MATCH ID", "ROUND", "MATCHUP", "SCORE", "DATE (UTC)")
			fmt.Println(strings.Repeat("-", 100))

			for _, m := range matches {
				mc := m.MatchCard
				round := wtt_api.ExtractRoundFromDocumentCode(m.DocumentCode, mc.SubEventDescription)
				matchup := "TBD vs TBD"
				if len(mc.Competitors) >= 2 {
					c1 := mc.Competitors[0]
					c2 := mc.Competitors[1]
					matchup = fmt.Sprintf("%s (%s) vs %s (%s)", c1.CompetitorName, c1.CompetitorOrg, c2.CompetitorName, c2.CompetitorOrg)
				}
				fmt.Printf("%-12d | %-14s | %-32s | %-8s | %s\n",
					m.ID, round, matchup, mc.OverallScores, mc.MatchDateTime.StartDateUTC)
			}

			return nil
		},
	}

	cmd.Flags().IntVarP(&eventID, "event-id", "e", 0, "WTT Event ID (e.g. 3250)")
	_ = cmd.MarkFlagRequired("event-id")
	return cmd
}

func newGenerateReportCommand() *cobra.Command {
	var tournamentName string
	var year int
	var eventID int
	var outputPath string
	var threshold float64

	cmd := &cobra.Command{
		Use:   "generate-report",
		Short: "Align DB matches with WTT official results and generate an audit JSON report",
		RunE: func(cmd *cobra.Command, args []string) error {
			if tournamentName == "" {
				return fmt.Errorf("--tournament-name is required (e.g. 'Montpellier')")
			}

			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()

			client := wtt_api.NewWTTClient()

			// Auto-resolve eventID if not explicitly provided
			if eventID <= 0 {
				fmt.Printf("Resolving official WTT Event ID for %q (year: %d)...\n", tournamentName, year)
				resolvedID, resolvedName, err := client.FindEventIDByQuery(ctx, tournamentName, year)
				if err != nil {
					return fmt.Errorf("failed to auto-resolve WTT event ID: %w", err)
				}
				eventID = resolvedID
				fmt.Printf("Resolved to Event ID: %d (%s)\n", eventID, resolvedName)
			}

			// 1. Fetch official WTT matches
			fmt.Printf("Fetching official WTT matches for Event ID %d...\n", eventID)
			wttMatches, err := client.FetchOfficialResults(ctx, eventID)
			if err != nil {
				return fmt.Errorf("failed to fetch official WTT results: %w", err)
			}
			fmt.Printf("Fetched %d official WTT matches.\n", len(wttMatches))

			// 2. Fetch DB matches from Supabase
			dbURL := os.Getenv("DATABASE_URL")
			if dbURL == "" {
				return fmt.Errorf("DATABASE_URL environment variable is required to load matches from database")
			}

			fmt.Println("Connecting to Supabase database...")
			conn, err := pgx.Connect(ctx, dbURL)
			if err != nil {
				return fmt.Errorf("failed to connect to database: %w", err)
			}
			defer conn.Close(ctx)

			dbMatches, err := queryDBMatches(ctx, conn, tournamentName, year)
			if err != nil {
				return fmt.Errorf("failed to query database matches: %w", err)
			}
			fmt.Printf("Found %d matches in database for tournament %q.\n", len(dbMatches), tournamentName)

			// 3. Run fuzzy alignment engine
			if threshold <= 0 {
				threshold = 0.70
			}
			fmt.Printf("Running fuzzy matching engine (similarity threshold: %.2f)...\n", threshold)
			report := wtt_api.AlignMatches(tournamentName, year, eventID, dbMatches, wttMatches, threshold)

			// 4. Default output filename
			if outputPath == "" {
				safeName := strings.ToLower(strings.ReplaceAll(tournamentName, " ", "_"))
				outputPath = fmt.Sprintf("wtt_match_report_%s_%d.json", safeName, eventID)
			}

			// 5. Serialize to JSON
			jsonData, err := json.MarshalIndent(report, "", "  ")
			if err != nil {
				return fmt.Errorf("failed to serialize audit report: %w", err)
			}

			if err := os.WriteFile(outputPath, jsonData, 0644); err != nil {
				return fmt.Errorf("failed to write audit report to %s: %w", outputPath, err)
			}

			// Print summary table
			fmt.Println("\n" + strings.Repeat("=", 60))
			fmt.Println("             WTT MATCH ALIGNMENT AUDIT SUMMARY")
			fmt.Println(strings.Repeat("=", 60))
			fmt.Printf("  Tournament:            %s (%d)\n", tournamentName, year)
			fmt.Printf("  WTT Event ID:          %d\n", eventID)
			fmt.Printf("  Total Matches in DB:   %d\n", report.TotalDBMatches)
			fmt.Printf("  Total Matches in WTT:  %d\n", report.TotalWTTMatches)
			fmt.Printf("  ✅ Successfully Matched: %d\n", report.MatchedCount)
			fmt.Printf("  ❌ Unmatched DB Rows:    %d\n", report.UnmatchedDBCount)
			fmt.Printf("  ℹ️  Unmatched WTT Rows:   %d\n", report.UnmatchedWTTCount)
			if report.TotalDBMatches > 0 {
				pct := float64(report.MatchedCount) / float64(report.TotalDBMatches) * 100.0
				fmt.Printf("  🎯 Database Match Rate: %.1f%%\n", pct)
			}
			fmt.Println(strings.Repeat("-", 60))
			fmt.Printf("  📄 Audit JSON generated: %s\n", outputPath)
			fmt.Println(strings.Repeat("=", 60))

			return nil
		},
	}

	cmd.Flags().StringVarP(&tournamentName, "tournament-name", "t", "", "Tournament name in database (e.g. 'Montpellier')")
	cmd.Flags().IntVarP(&year, "year", "y", 0, "Tournament year (e.g. 2026)")
	cmd.Flags().IntVarP(&eventID, "event-id", "e", 0, "WTT Event ID (optional; auto-resolved if omitted)")
	cmd.Flags().StringVarP(&outputPath, "output", "o", "", "Path to write output audit JSON file")
	cmd.Flags().Float64VarP(&threshold, "threshold", "s", 0.70, "Minimum similarity score threshold (0.0 - 1.0, default 0.70)")

	_ = cmd.MarkFlagRequired("tournament-name")
	return cmd
}

func queryDBMatches(ctx context.Context, conn *pgx.Conn, tournamentName string, year int) ([]wtt_api.DBMatchRecord, error) {
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
			m.created_at
		FROM matches m
		JOIN tournaments t ON m.tournament_id = t.id
		JOIN videos v ON m.video_id = v.id
		WHERE t.name ILIKE $1 AND ($2 = 0 OR t.year = $2)
		ORDER BY m.id;
	`

	rows, err := conn.Query(ctx, query, "%"+tournamentName+"%", year)
	if err != nil {
		return nil, fmt.Errorf("query failed: %w", err)
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
			&m.CreatedAt,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan match row: %w", err)
		}
		matches = append(matches, m)
	}

	return matches, rows.Err()
}

func newAuditAllCommand() *cobra.Command {
	var outputPath string
	var threshold float64

	cmd := &cobra.Command{
		Use:   "audit-all",
		Short: "Run full-database audit aligning all tournaments and matches with official WTT records",
		RunE: func(cmd *cobra.Command, args []string) error {
			if outputPath == "" {
				outputPath = "/home/geonix/Build/wtt_full_database_mapping_audit.json"
			}
			if threshold <= 0 {
				threshold = 0.70
			}

			dbURL := os.Getenv("DATABASE_URL")
			if dbURL == "" {
				return fmt.Errorf("DATABASE_URL environment variable is required")
			}

			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer cancel()

			fmt.Println("Connecting to Supabase...")
			conn, err := pgx.Connect(ctx, dbURL)
			if err != nil {
				return fmt.Errorf("failed to connect to database: %w", err)
			}
			defer conn.Close(ctx)

			// 1. Query all tournaments
			tRows, err := conn.Query(ctx, "SELECT id, name, year, COALESCE(category, 'Senior') FROM tournaments ORDER BY name;")
			if err != nil {
				return fmt.Errorf("failed to query tournaments: %w", err)
			}
			defer tRows.Close()

			type tourneyInfo struct {
				id       int64
				name     string
				year     int
				category string
			}
			var tournaments []tourneyInfo
			for tRows.Next() {
				var t tourneyInfo
				if err := tRows.Scan(&t.id, &t.name, &t.year, &t.category); err != nil {
					return err
				}
				tournaments = append(tournaments, t)
			}
			tRows.Close()
			fmt.Printf("Loaded %d tournaments from database.\n", len(tournaments))

			// 2. Query all matches grouped by tournament_id
			fmt.Println("Loading all matches from database...")
			mRows, err := conn.Query(ctx, `
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
					m.created_at
				FROM matches m
				JOIN tournaments t ON m.tournament_id = t.id
				JOIN videos v ON m.video_id = v.id
				ORDER BY m.tournament_id, m.id;
			`)
			if err != nil {
				return fmt.Errorf("failed to query matches: %w", err)
			}
			defer mRows.Close()

			matchesByTourney := make(map[int64][]wtt_api.DBMatchRecord)
			totalDBMatches := 0
			for mRows.Next() {
				var m wtt_api.DBMatchRecord
				if err := mRows.Scan(
					&m.ID, &m.TournamentID, &m.TournamentName, &m.TournamentYear,
					&m.VideoID, &m.YoutubeID, &m.VideoTitle, &m.Day, &m.Session,
					&m.VideoOffsetSeconds, &m.DurationSeconds, &m.IsDoubles,
					&m.TeamA, &m.TeamB, &m.CreatedAt,
				); err != nil {
					return err
				}
				matchesByTourney[m.TournamentID] = append(matchesByTourney[m.TournamentID], m)
				totalDBMatches++
			}
			mRows.Close()
			fmt.Printf("Loaded %d matches across %d tournaments.\n\n", totalDBMatches, len(matchesByTourney))

			client := wtt_api.NewWTTClient()
			masterReport := wtt_api.MasterAuditReport{
				GeneratedAt: time.Now().UTC(),
			}

			totalMatchedMatches := 0
			totalUnmatchedDBMatches := 0
			totalMatchedTournaments := 0
			totalUnmatchedTournaments := 0

			for idx, t := range tournaments {
				dbMatches := matchesByTourney[t.id]
				fmt.Printf("[%d/%d] Auditing %s (%d, %s) - %d DB matches...\n",
					idx+1, len(tournaments), t.name, t.year, t.category, len(dbMatches))

				eventID, eventName, err := client.FindEventIDByQuery(ctx, t.name, t.year)
				if err != nil {
					totalUnmatchedTournaments++
					totalUnmatchedDBMatches += len(dbMatches)

					unmatchedTourney := wtt_api.TournamentAuditEntry{
						IsTournamentMatched:   false,
						DBTournamentID:        t.id,
						TournamentName:        t.name,
						Year:                  t.year,
						Category:              t.category,
						TotalDBMatches:        len(dbMatches),
						UnmatchedMatchesCount: len(dbMatches),
						FailureReason:         err.Error(),
					}

					for _, dbm := range dbMatches {
						rec := wtt_api.MatchedRecord{
							IsMatched:      false,
							Confidence:     0.0,
							FailureReason:  "Tournament not found in official WTT events list",
							TournamentName: t.name,
							TournamentYear: t.year,
							DBMatch:        &dbm,
						}
						rec.OCRPlayerNames.TeamA = dbm.TeamA
						rec.OCRPlayerNames.TeamB = dbm.TeamB
						unmatchedTourney.Matches = append(unmatchedTourney.Matches, rec)
					}

					masterReport.UnmatchedTournaments = append(masterReport.UnmatchedTournaments, unmatchedTourney)
					masterReport.Tournaments = append(masterReport.Tournaments, unmatchedTourney)
					continue
				}

				totalMatchedTournaments++

				// Fetch official results
				wttMatches, wErr := client.FetchOfficialResults(ctx, eventID)
				if wErr != nil {
					// Tournament matched, but results not found
					unmatchedTourney := wtt_api.TournamentAuditEntry{
						IsTournamentMatched:   true,
						DBTournamentID:        t.id,
						TournamentName:        t.name,
						Year:                  t.year,
						Category:              t.category,
						WTTEventID:            eventID,
						WTTEventName:          eventName,
						TotalDBMatches:        len(dbMatches),
						UnmatchedMatchesCount: len(dbMatches),
						FailureReason:         fmt.Sprintf("Failed to fetch official results for Event ID %d: %v", eventID, wErr),
					}
					for _, dbm := range dbMatches {
						rec := wtt_api.MatchedRecord{
							IsMatched:      false,
							Confidence:     0.0,
							FailureReason:  fmt.Sprintf("WTT results unavailable for event %d", eventID),
							TournamentName: t.name,
							TournamentYear: t.year,
							WTTEventID:     eventID,
							DBMatch:        &dbm,
						}
						rec.OCRPlayerNames.TeamA = dbm.TeamA
						rec.OCRPlayerNames.TeamB = dbm.TeamB
						unmatchedTourney.Matches = append(unmatchedTourney.Matches, rec)
					}
					totalUnmatchedDBMatches += len(dbMatches)
					masterReport.Tournaments = append(masterReport.Tournaments, unmatchedTourney)
					continue
				}

				// Run alignment
				tourneyReport := wtt_api.AlignMatches(t.name, t.year, eventID, dbMatches, wttMatches, threshold)
				totalMatchedMatches += tourneyReport.MatchedCount
				totalUnmatchedDBMatches += tourneyReport.UnmatchedDBCount

				tEntry := wtt_api.TournamentAuditEntry{
					IsTournamentMatched:   true,
					DBTournamentID:        t.id,
					TournamentName:        t.name,
					Year:                  t.year,
					Category:              t.category,
					WTTEventID:            eventID,
					WTTEventName:          eventName,
					TotalDBMatches:        tourneyReport.TotalDBMatches,
					TotalWTTMatches:       tourneyReport.TotalWTTMatches,
					MatchedMatchesCount:   tourneyReport.MatchedCount,
					UnmatchedMatchesCount: tourneyReport.UnmatchedDBCount,
					Matches:               tourneyReport.Matches,
				}
				masterReport.Tournaments = append(masterReport.Tournaments, tEntry)
			}

			// Populate summary
			masterReport.Summary.TotalTournaments = len(tournaments)
			masterReport.Summary.MatchedTournaments = totalMatchedTournaments
			masterReport.Summary.UnmatchedTournaments = totalUnmatchedTournaments
			masterReport.Summary.TotalDBMatches = totalDBMatches
			masterReport.Summary.MatchedDBMatches = totalMatchedMatches
			masterReport.Summary.UnmatchedDBMatches = totalUnmatchedDBMatches
			if totalDBMatches > 0 {
				masterReport.Summary.MatchRatePercentage = float64(totalMatchedMatches) / float64(totalDBMatches) * 100.0
			}

			// Save to JSON
			jsonData, err := json.MarshalIndent(masterReport, "", "  ")
			if err != nil {
				return fmt.Errorf("failed to serialize master audit report: %w", err)
			}

			if err := os.WriteFile(outputPath, jsonData, 0644); err != nil {
				return fmt.Errorf("failed to write audit report to %s: %w", outputPath, err)
			}

			fmt.Println("\n" + strings.Repeat("=", 65))
			fmt.Println("             FULL DATABASE WTT MAPPING AUDIT REPORT")
			fmt.Println(strings.Repeat("=", 65))
			fmt.Printf("  Total Tournaments in DB:   %d\n", masterReport.Summary.TotalTournaments)
			fmt.Printf("  ✅ Matched Tournaments:    %d\n", masterReport.Summary.MatchedTournaments)
			fmt.Printf("  ❌ Unmatched Tournaments:  %d\n", masterReport.Summary.UnmatchedTournaments)
			fmt.Println(strings.Repeat("-", 65))
			fmt.Printf("  Total Matches in DB:       %d\n", masterReport.Summary.TotalDBMatches)
			fmt.Printf("  ✅ Matched Matches:        %d\n", masterReport.Summary.MatchedDBMatches)
			fmt.Printf("  ❌ Unmatched Matches:      %d\n", masterReport.Summary.UnmatchedDBMatches)
			fmt.Printf("  🎯 Overall Match Rate:     %.1f%%\n", masterReport.Summary.MatchRatePercentage)
			fmt.Println(strings.Repeat("=", 65))
			fmt.Printf("  📄 Master Audit JSON generated at:\n     %s\n", outputPath)
			fmt.Println(strings.Repeat("=", 65))

			return nil
		},
	}

	cmd.Flags().StringVarP(&outputPath, "output", "o", "/home/geonix/Build/wtt_full_database_mapping_audit.json", "Output master audit JSON path")
	cmd.Flags().Float64VarP(&threshold, "threshold", "s", 0.70, "Minimum similarity score threshold (0.0 - 1.0, default 0.70)")
	return cmd
}
