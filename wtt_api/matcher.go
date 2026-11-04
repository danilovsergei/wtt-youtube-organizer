package wtt_api

import (
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"golang.org/x/text/runes"
	"golang.org/x/text/transform"
	"golang.org/x/text/unicode/norm"
)

var (
	nonAlphaNumRe    = regexp.MustCompile(`[^a-zA-Z0-9\s]`)
	multipleSpacesRe = regexp.MustCompile(`\s+`)
	tablePatternRe   = regexp.MustCompile(`(?i)\bT0*([1-9][0-9]?)\b`)
	tableWordRe      = regexp.MustCompile(`(?i)\bTABLE\s*0*([1-9][0-9]?)\b`)
)

// ExtractTableFromTitle extracts standardized table numbers like "T01", "T04" from video titles.
func ExtractTableFromTitle(title string) string {
	t := strings.ToUpper(title)
	if strings.Contains(t, "ARENA") && !tablePatternRe.MatchString(t) {
		return "T01"
	}
	if m := tablePatternRe.FindStringSubmatch(t); len(m) > 1 {
		num, _ := strconv.Atoi(m[1])
		return fmt.Sprintf("T%02d", num)
	}
	if m := tableWordRe.FindStringSubmatch(t); len(m) > 1 {
		num, _ := strconv.Atoi(m[1])
		return fmt.Sprintf("T%02d", num)
	}
	return ""
}

// ParseWTTStartTime parses UTC start timestamp from WTT match object.
func ParseWTTStartTime(m WTTOfficialMatch) *time.Time {
	dtStr := m.MatchCard.MatchDateTime.StartDateUTC
	if dtStr == "" {
		dtStr = m.StartDateLocal
	}
	if dtStr == "" {
		return nil
	}
	dtStr = strings.TrimSpace(dtStr)
	if strings.Contains(dtStr, "/") {
		t, err := time.Parse("01/02/2006 15:04:05", dtStr)
		if err == nil {
			utc := t.UTC()
			return &utc
		}
	}
	t, err := time.Parse(time.RFC3339, strings.ReplaceAll(dtStr, "Z", "+00:00"))
	if err == nil {
		utc := t.UTC()
		return &utc
	}
	t, err = time.Parse("2006-01-02T15:04:05", dtStr)
	if err == nil {
		utc := t.UTC()
		return &utc
	}
	return nil
}

// NormalizeName strips accents, punctuation, and returns uppercase token list.
func NormalizeName(name string) (string, []string) {
	t := transform.Chain(norm.NFD, runes.Remove(runes.In(unicode.Mn)), norm.NFC)
	normalized, _, _ := transform.String(t, name)

	clean := nonAlphaNumRe.ReplaceAllString(normalized, " ")
	clean = strings.ToUpper(strings.TrimSpace(multipleSpacesRe.ReplaceAllString(clean, " ")))

	tokens := strings.Fields(clean)
	sort.Strings(tokens)
	return clean, tokens
}

// NormalizeTournamentName strips accents, quotes, and cleans spaces for event title matching.
func NormalizeTournamentName(name string) string {
	t := transform.Chain(norm.NFD, runes.Remove(runes.In(unicode.Mn)), norm.NFC)
	normalized, _, _ := transform.String(t, name)
	s := strings.ReplaceAll(normalized, "’", "'")
	s = strings.ReplaceAll(s, "-", " ")
	return strings.ToLower(strings.TrimSpace(multipleSpacesRe.ReplaceAllString(s, " ")))
}

// LevenshteinDistance calculates minimum edit operations between two strings.
func LevenshteinDistance(s1, s2 string) int {
	r1, r2 := []rune(s1), []rune(s2)
	n, m := len(r1), len(r2)
	if n == 0 {
		return m
	}
	if m == 0 {
		return n
	}

	dp := make([][]int, n+1)
	for i := range dp {
		dp[i] = make([]int, m+1)
		dp[i][0] = i
	}
	for j := 0; j <= m; j++ {
		dp[0][j] = j
	}

	for i := 1; i <= n; i++ {
		for j := 1; j <= m; j++ {
			cost := 0
			if r1[i-1] != r2[j-1] {
				cost = 1
			}
			dp[i][j] = int(math.Min(
				float64(dp[i-1][j]+1),
				math.Min(
					float64(dp[i][j-1]+1),
					float64(dp[i-1][j-1]+cost),
				),
			))
		}
	}
	return dp[n][m]
}

func tokenSimilarity(tokens1, tokens2 []string) float64 {
	if len(tokens1) == 0 || len(tokens2) == 0 {
		return 0.0
	}
	totalScore := 0.0
	for _, t1 := range tokens1 {
		maxTScore := 0.0
		for _, t2 := range tokens2 {
			maxLen := math.Max(float64(len([]rune(t1))), float64(len([]rune(t2))))
			if maxLen == 0 {
				continue
			}
			dist := LevenshteinDistance(t1, t2)
			score := 1.0 - (float64(dist) / maxLen)
			if score > maxTScore {
				maxTScore = score
			}
		}
		totalScore += maxTScore
	}
	return totalScore / float64(len(tokens1))
}

// NameSimilarityPreNormalized computes similarity using pre-tokenized names.
func NameSimilarityPreNormalized(clean1 string, tokens1 []string, clean2 string, tokens2 []string) float64 {
	if clean1 == "" || clean2 == "" {
		return 0.0
	}
	if clean1 == clean2 {
		return 1.0
	}

	// Token set equality
	if len(tokens1) == len(tokens2) && strings.Join(tokens1, " ") == strings.Join(tokens2, " ") {
		return 1.0
	}

	// Subset match check
	matchCount := 0
	tokensSet2 := make(map[string]bool, len(tokens2))
	for _, t := range tokens2 {
		tokensSet2[t] = true
	}
	for _, t := range tokens1 {
		if tokensSet2[t] {
			matchCount++
		}
	}
	if len(tokens1) > 0 && matchCount == len(tokens1) {
		return 0.90
	}

	tokensSet1 := make(map[string]bool, len(tokens1))
	for _, t := range tokens1 {
		tokensSet1[t] = true
	}
	matchCount2 := 0
	for _, t := range tokens2 {
		if tokensSet1[t] {
			matchCount2++
		}
	}
	if len(tokens2) > 0 && matchCount2 == len(tokens2) {
		return 0.90
	}

	// Token-level bipartite similarity
	tokSim1 := tokenSimilarity(tokens1, tokens2)
	tokSim2 := tokenSimilarity(tokens2, tokens1)
	tokSim := (tokSim1 + tokSim2) / 2.0

	// Full string Levenshtein ratio
	maxLen := math.Max(float64(len([]rune(clean1))), float64(len([]rune(clean2))))
	dist := LevenshteinDistance(clean1, clean2)
	levScore := 1.0 - (float64(dist) / maxLen)
	if levScore < 0 {
		levScore = 0
	}

	return math.Max(tokSim, levScore)
}

// NameSimilarity calculates fuzzy similarity between two names (0.0 to 1.0).
func NameSimilarity(name1, name2 string) float64 {
	c1, t1 := NormalizeName(name1)
	c2, t2 := NormalizeName(name2)
	return NameSimilarityPreNormalized(c1, t1, c2, t2)
}

// PairSimilarity calculates symmetrical match score for two opposing sides.
func PairSimilarity(dbA, dbB, wttA, wttB string) (float64, bool) {
	cDBA, tDBA := NormalizeName(dbA)
	cDBB, tDBB := NormalizeName(dbB)
	cWTTA, tWTTA := NormalizeName(wttA)
	cWTTB, tWTTB := NormalizeName(wttB)

	direct := (NameSimilarityPreNormalized(cDBA, tDBA, cWTTA, tWTTA) + NameSimilarityPreNormalized(cDBB, tDBB, cWTTB, tWTTB)) / 2.0
	swapped := (NameSimilarityPreNormalized(cDBA, tDBA, cWTTB, tWTTB) + NameSimilarityPreNormalized(cDBB, tDBB, cWTTA, tWTTA)) / 2.0

	if direct >= swapped {
		return direct, false
	}
	return swapped, true
}

func ExtractRoundFromDocumentCode(docCode, subEventDesc string) string {
	doc := strings.ToUpper(docCode)
	if strings.Contains(doc, "FNL-000100") || strings.Contains(doc, "-FNL-") {
		return "Final"
	}
	if strings.Contains(doc, "-SFNL-") {
		return "Semi-Final"
	}
	if strings.Contains(doc, "-QFNL-") {
		return "Quarter-Final"
	}
	if strings.Contains(doc, "-R16-") {
		return "Round of 16"
	}
	if strings.Contains(doc, "-R32-") {
		return "Round of 32"
	}
	if strings.Contains(doc, "-R64-") {
		return "Round of 64"
	}
	if strings.Contains(doc, "-R128-") {
		return "Round of 128"
	}
	if strings.Contains(doc, "-QUAL-") {
		return "Qualifying"
	}

	desc := strings.ToLower(subEventDesc)
	if strings.Contains(desc, "final") && !strings.Contains(desc, "semi") && !strings.Contains(desc, "quarter") {
		return "Final"
	}
	if strings.Contains(desc, "semi-final") || strings.Contains(desc, "semifinal") {
		return "Semi-Final"
	}
	if strings.Contains(desc, "quarter-final") || strings.Contains(desc, "quarterfinal") {
		return "Quarter-Final"
	}
	if strings.Contains(desc, "round of 16") {
		return "Round of 16"
	}
	if strings.Contains(desc, "round of 32") {
		return "Round of 32"
	}

	return "Round Match"
}

func ExtractGender(subEventType, docCode string) string {
	combined := strings.ToUpper(subEventType + " " + docCode)
	if strings.Contains(combined, "MIXED") {
		return "Mixed"
	}
	if strings.Contains(combined, "WOMEN") || strings.Contains(combined, "TTWSINGLES") || strings.Contains(combined, "TTWDOUBLES") {
		return "Women"
	}
	if strings.Contains(combined, "MEN") || strings.Contains(combined, "TTEMSINGLES") || strings.Contains(combined, "TTEMDOUBLES") {
		return "Men"
	}
	return "Open"
}

type matchPairCandidate struct {
	dbIdx     int
	wttIdx    int
	score     float64
	isSwapped bool
	timeDelta float64
}

type preNormMatch struct {
	cleanA  string
	tokensA []string
	cleanB  string
	tokensB []string
}

// AlignMatches executes time-window and table-aware bipartite matching.
func AlignMatches(
	tournamentName string,
	tournamentYear int,
	wttEventID int,
	dbMatches []DBMatchRecord,
	wttMatches []WTTOfficialMatch,
	threshold float64,
) MatchAuditReport {
	report := MatchAuditReport{
		GeneratedAt:     time.Now().UTC(),
		TournamentName:  tournamentName,
		TournamentYear:  tournamentYear,
		WTTEventID:      wttEventID,
		TotalDBMatches:  len(dbMatches),
		TotalWTTMatches: len(wttMatches),
		Matches:         []MatchedRecord{},
	}

	if threshold <= 0 {
		threshold = 0.70
	}

	// 1. Pre-normalize DB matches once
	normDB := make([]preNormMatch, len(dbMatches))
	dbTables := make([]string, len(dbMatches))
	dbCalcTimes := make([]*time.Time, len(dbMatches))

	for i, m := range dbMatches {
		cA, tA := NormalizeName(m.TeamA)
		cB, tB := NormalizeName(m.TeamB)
		normDB[i] = preNormMatch{cleanA: cA, tokensA: tA, cleanB: cB, tokensB: tB}

		tbl := m.Table
		if tbl == "" {
			tbl = ExtractTableFromTitle(m.VideoTitle)
		}
		dbTables[i] = tbl

		if m.StreamStartUTC != nil {
			calcT := m.StreamStartUTC.Add(time.Duration(m.VideoOffsetSeconds) * time.Second)
			dbCalcTimes[i] = &calcT
		}
	}

	// 2. Pre-normalize WTT matches once
	normWTT := make([]preNormMatch, len(wttMatches))
	wttTables := make([]string, len(wttMatches))
	wttTimes := make([]*time.Time, len(wttMatches))

	for i, m := range wttMatches {
		if len(m.MatchCard.Competitors) >= 2 {
			cA, tA := NormalizeName(m.MatchCard.Competitors[0].CompetitorName)
			cB, tB := NormalizeName(m.MatchCard.Competitors[1].CompetitorName)
			normWTT[i] = preNormMatch{cleanA: cA, tokensA: tA, cleanB: cB, tokensB: tB}
		}

		tbl := strings.ToUpper(strings.TrimSpace(m.MatchCard.TableNumber))
		if tbl == "" {
			tbl = ExtractTableFromTitle(m.MatchCard.TableName)
		}
		wttTables[i] = tbl
		wttTimes[i] = ParseWTTStartTime(m)
	}

	// 3. Score candidate pairs with Time Window and Table Bonus
	var candidates []matchPairCandidate
	for dIdx := range dbMatches {
		ndb := normDB[dIdx]
		dbTable := dbTables[dIdx]
		calcT := dbCalcTimes[dIdx]

		for wIdx := range wttMatches {
			nwtt := normWTT[wIdx]
			if nwtt.cleanA == "" && nwtt.cleanB == "" {
				continue
			}

			wttTable := wttTables[wIdx]
			wttTime := wttTimes[wIdx]

			timeDeltaMin := 0.0
			timeBonus := 0.0
			hasTimeComparison := false

			if calcT != nil && wttTime != nil {
				hasTimeComparison = true
				diffMin := calcT.Sub(*wttTime).Minutes()
				timeDeltaMin = diffMin

				// Asymmetric empirical window: -30 min to +120 min
				if diffMin < -30.0 || diffMin > 120.0 {
					continue
				}

				if math.Abs(diffMin) <= 15.0 {
					timeBonus = 0.10 * (1.0 - math.Abs(diffMin)/30.0)
				}
			}

			tableBonus := 0.0
			if dbTable != "" && wttTable != "" {
				if dbTable == wttTable {
					tableBonus = 0.15
				} else if hasTimeComparison {
					// Time is around now, but table is different -> skip
					continue
				}
			}

			direct := (NameSimilarityPreNormalized(ndb.cleanA, ndb.tokensA, nwtt.cleanA, nwtt.tokensA) +
				NameSimilarityPreNormalized(ndb.cleanB, ndb.tokensB, nwtt.cleanB, nwtt.tokensB)) / 2.0

			swapped := (NameSimilarityPreNormalized(ndb.cleanA, ndb.tokensA, nwtt.cleanB, nwtt.tokensB) +
				NameSimilarityPreNormalized(ndb.cleanB, ndb.tokensB, nwtt.cleanA, nwtt.tokensA)) / 2.0

			baseScore := direct
			isSwapped := false
			if swapped > direct {
				baseScore = swapped
				isSwapped = true
			}

			// Composite score
			compositeScore := baseScore + tableBonus + timeBonus
			if compositeScore > 1.0 {
				compositeScore = 1.0
			}

			// If exact table and time align, allow slightly more permissive OCR threshold (e.g. 0.50)
			minReq := threshold
			if hasTimeComparison && tableBonus > 0 && baseScore >= 0.50 {
				minReq = 0.60
			}

			if compositeScore >= minReq {
				candidates = append(candidates, matchPairCandidate{
					dbIdx:     dIdx,
					wttIdx:    wIdx,
					score:     compositeScore,
					isSwapped: isSwapped,
					timeDelta: timeDeltaMin,
				})
			}
		}
	}

	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].score > candidates[j].score
	})

	assignedDB := make(map[int]bool, len(dbMatches))
	assignedWTT := make(map[int]bool, len(wttMatches))
	seenStreamMatch := make(map[string]int64) // youtube_id + "_" + wttID -> primary dbMatchID

	for _, cand := range candidates {
		if assignedDB[cand.dbIdx] {
			continue
		}

		dbm := dbMatches[cand.dbIdx]
		wttm := wttMatches[cand.wttIdx]
		mc := wttm.MatchCard

		// Intra-stream duplicate check:
		// If another match in this same video already claimed this WTT match, mark as duplicate!
		streamKey := fmt.Sprintf("%s_%d", dbm.YoutubeID, wttm.ID)
		primaryID, isDup := seenStreamMatch[streamKey]

		if !isDup && assignedWTT[cand.wttIdx] {
			// WTT match was claimed by a DIFFERENT video, and this is NOT a duplicate within the same video
			continue
		}

		assignedDB[cand.dbIdx] = true
		if !isDup {
			assignedWTT[cand.wttIdx] = true
			seenStreamMatch[streamKey] = dbm.ID
		}

		rec := MatchedRecord{
			IsMatched:        true,
			IsDuplicate:      isDup,
			Confidence:       math.Round(cand.score*100) / 100,
			TimeDeltaMinutes: math.Round(cand.timeDelta*10) / 10,
			TournamentName:   tournamentName,
			TournamentYear:   tournamentYear,
			WTTEventID:       wttEventID,
			DBMatch:          &dbm,
			WTTMatch:         &wttm,
			WTTRound:         ExtractRoundFromDocumentCode(wttm.DocumentCode, mc.SubEventDescription),
			WTTGender:        ExtractGender(wttm.SubEventType, wttm.DocumentCode),
			WTTScore:         mc.OverallScores,
			WTTGameScores:    mc.GameScores,
			WTTMatchID:       wttm.ID,
		}

		if isDup {
			rec.FailureReason = fmt.Sprintf("Intra-stream duplicate/continuation of match %d", primaryID)
		}

		if mc.MatchDateTime.StartDateUTC != "" {
			rec.WTTMatchStartUTC = mc.MatchDateTime.StartDateUTC
		} else {
			rec.WTTMatchStartUTC = wttm.StartDateLocal
		}

		rec.OCRPlayerNames.TeamA = dbm.TeamA
		rec.OCRPlayerNames.TeamB = dbm.TeamB

		if !cand.isSwapped {
			rec.WTTPlayerNames.TeamA = mc.Competitors[0].CompetitorName
			rec.WTTPlayerNames.TeamB = mc.Competitors[1].CompetitorName
			rec.WTTCountries.TeamA = mc.Competitors[0].CompetitorOrg
			rec.WTTCountries.TeamB = mc.Competitors[1].CompetitorOrg
		} else {
			rec.WTTPlayerNames.TeamA = mc.Competitors[1].CompetitorName
			rec.WTTPlayerNames.TeamB = mc.Competitors[0].CompetitorName
			rec.WTTCountries.TeamA = mc.Competitors[1].CompetitorOrg
			rec.WTTCountries.TeamB = mc.Competitors[0].CompetitorOrg
		}

		report.Matches = append(report.Matches, rec)
	}

	report.MatchedCount = len(report.Matches)

	// Collect unmatched DB matches
	for dIdx, dbm := range dbMatches {
		if assignedDB[dIdx] {
			continue
		}
		unmatchedRec := MatchedRecord{
			IsMatched:      false,
			Confidence:     0.0,
			FailureReason:  "No matching official WTT match found above confidence threshold",
			TournamentName: tournamentName,
			TournamentYear: tournamentYear,
			WTTEventID:     wttEventID,
			DBMatch:        &dbm,
		}
		unmatchedRec.OCRPlayerNames.TeamA = dbm.TeamA
		unmatchedRec.OCRPlayerNames.TeamB = dbm.TeamB
		report.Matches = append(report.Matches, unmatchedRec)
		report.UnmatchedDBCount++
	}

	// Collect unmatched WTT matches
	for wIdx, wttm := range wttMatches {
		if assignedWTT[wIdx] {
			continue
		}
		mc := wttm.MatchCard
		unmatchedWttRec := MatchedRecord{
			IsMatched:      false,
			Confidence:     0.0,
			FailureReason:  "Official WTT match not found in database video records",
			TournamentName: tournamentName,
			TournamentYear: tournamentYear,
			WTTEventID:     wttEventID,
			WTTMatch:       &wttm,
			WTTRound:       ExtractRoundFromDocumentCode(wttm.DocumentCode, mc.SubEventDescription),
			WTTGender:      ExtractGender(wttm.SubEventType, wttm.DocumentCode),
			WTTScore:       mc.OverallScores,
			WTTGameScores:  mc.GameScores,
			WTTMatchID:     wttm.ID,
		}
		if len(mc.Competitors) >= 2 {
			unmatchedWttRec.WTTPlayerNames.TeamA = mc.Competitors[0].CompetitorName
			unmatchedWttRec.WTTPlayerNames.TeamB = mc.Competitors[1].CompetitorName
			unmatchedWttRec.WTTCountries.TeamA = mc.Competitors[0].CompetitorOrg
			unmatchedWttRec.WTTCountries.TeamB = mc.Competitors[1].CompetitorOrg
		}
		report.Matches = append(report.Matches, unmatchedWttRec)
		report.UnmatchedWTTCount++
	}

	return report
}
