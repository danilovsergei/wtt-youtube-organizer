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
	)

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
	t, err := time.Parse(time.RFC3339Nano, strings.ReplaceAll(dtStr, "Z", "+00:00"))
	if err == nil {
		utc := t.UTC()
		return &utc
	}
	t, err = time.Parse(time.RFC3339, strings.ReplaceAll(dtStr, "Z", "+00:00"))
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

func filterInitials(tokens []string) []string {
	var filtered []string
	for _, t := range tokens {
		if len([]rune(t)) > 1 {
			filtered = append(filtered, t)
		}
	}
	if len(filtered) == 0 {
		return tokens
	}
	return filtered
}

func tokenSimilarity(tokens1, tokens2 []string) float64 {
	tokens1 = filterInitials(tokens1)
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

			// Compound/concatenated token support (e.g. "ANTOINEMICHARD" contains "ANTOINE" and "MICHARD")
			if (len(t2) >= 4 && strings.Contains(t1, t2)) || (len(t1) >= 4 && strings.Contains(t2, t1)) {
				if 1.0 > score {
					score = 1.0
				}
			}

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

func extractAgePrefix(docCode, subEventDesc string) string {
	combined := strings.ToUpper(docCode + " " + subEventDesc)
	for _, age := range []string{"U19", "U17", "U15", "U13", "U11"} {
		if strings.Contains(combined, age) {
			return age + " "
		}
	}
	return ""
}

func ExtractRoundFromDocumentCode(docCode, subEventDesc string) string {
	doc := strings.ToUpper(docCode)
	agePrefix := extractAgePrefix(docCode, subEventDesc)

	if strings.Contains(doc, "FNL-000100") || strings.Contains(doc, "-FNL-") || strings.Contains(doc, "---FNL") {
		return agePrefix + "Final"
	}
	if strings.Contains(doc, "-SFNL-") || strings.Contains(doc, "---SFNL") {
		return agePrefix + "Semi-Final"
	}
	if strings.Contains(doc, "-QFNL-") || strings.Contains(doc, "---QFNL") {
		return agePrefix + "Quarter-Final"
	}
	if strings.Contains(doc, "-R16-") || strings.Contains(doc, "-8FNL-") || strings.Contains(doc, "---8FNL") {
		return agePrefix + "Round of 16"
	}
	if strings.Contains(doc, "-R32-") || strings.Contains(doc, "---R32") {
		return agePrefix + "Round of 32"
	}
	if strings.Contains(doc, "-R64-") || strings.Contains(doc, "---R64") {
		return agePrefix + "Round of 64"
	}
	if strings.Contains(doc, "-R128-") || strings.Contains(doc, "---R128") {
		return agePrefix + "Round of 128"
	}
	if strings.Contains(doc, "-QUAL-") || strings.Contains(doc, "-RND1-") || strings.Contains(doc, "-RND2-") || strings.Contains(doc, "-RND3-") || strings.Contains(doc, "---RND") {
		return agePrefix + "Qualifying"
	}
	if strings.Contains(doc, "-GP") || strings.Contains(doc, "-GROUP") {
		return agePrefix + "Group Stage"
	}

	desc := strings.ToLower(subEventDesc)
	if strings.Contains(desc, "final") && !strings.Contains(desc, "semi") && !strings.Contains(desc, "quarter") {
		return agePrefix + "Final"
	}
	if strings.Contains(desc, "semi-final") || strings.Contains(desc, "semifinal") {
		return agePrefix + "Semi-Final"
	}
	if strings.Contains(desc, "quarter-final") || strings.Contains(desc, "quarterfinal") {
		return agePrefix + "Quarter-Final"
	}
	if strings.Contains(desc, "round of 16") || strings.Contains(desc, "r16") {
		return agePrefix + "Round of 16"
	}
	if strings.Contains(desc, "round of 32") || strings.Contains(desc, "r32") {
		return agePrefix + "Round of 32"
	}
	if strings.Contains(desc, "round of 64") || strings.Contains(desc, "r64") {
		return agePrefix + "Round of 64"
	}
	if strings.Contains(desc, "round of 128") || strings.Contains(desc, "r128") {
		return agePrefix + "Round of 128"
	}
	if strings.Contains(desc, "group") {
		return agePrefix + "Group Stage"
	}
	if strings.Contains(desc, "qualifying") || strings.Contains(desc, "preliminary") {
		return agePrefix + "Qualifying"
	}

	return agePrefix + "Round Match"
}

// GetStageOrder maps standard stage names to deterministic bracket sorting integers (1..8)
func GetStageOrder(stage string) int {
	s := strings.ToLower(stage)
	if strings.Contains(s, "final") && !strings.Contains(s, "semi") && !strings.Contains(s, "quarter") {
		return 8
	}
	if strings.Contains(s, "semi") {
		return 7
	}
	if strings.Contains(s, "quarter") {
		return 6
	}
	if strings.Contains(s, "16") {
		return 5
	}
	if strings.Contains(s, "32") {
		return 4
	}
	if strings.Contains(s, "64") {
		return 3
	}
	if strings.Contains(s, "128") {
		return 2
	}
	if strings.Contains(s, "group") || strings.Contains(s, "qualifying") || strings.Contains(s, "prelim") {
		return 1
	}
	return 1
}

// InferStageForUnmatched infers stage name and order for unmatched DB matches using stream sibling context and title/day fallback
func InferStageForUnmatched(dbm *DBMatchRecord, allMatches []MatchedRecord) (string, int) {
	if dbm == nil {
		return "Round Match", 1
	}

	// 1. Sibling matches sharing the exact same video_id (court stream)
	for _, m := range allMatches {
		if m.DBMatch != nil && m.DBMatch.VideoID == dbm.VideoID && m.WTTRound != "" && m.IsMatched {
			return m.WTTRound, GetStageOrder(m.WTTRound)
		}
	}

	// 2. Title and day inspection
	combined := strings.ToUpper(dbm.VideoTitle + " " + dbm.Day)
	agePrefix := ""
	for _, age := range []string{"U19", "U17", "U15", "U13", "U11"} {
		if strings.Contains(combined, age) {
			agePrefix = age + " "
			break
		}
	}

	titleAndDay := strings.ToLower(combined)
	if strings.Contains(titleAndDay, "final") && !strings.Contains(titleAndDay, "semi") && !strings.Contains(titleAndDay, "quarter") {
		return agePrefix + "Final", 8
	}
	if strings.Contains(titleAndDay, "semi") {
		return agePrefix + "Semi-Final", 7
	}
	if strings.Contains(titleAndDay, "quarter") {
		return agePrefix + "Quarter-Final", 6
	}
	if strings.Contains(titleAndDay, "r16") || strings.Contains(titleAndDay, "round of 16") || strings.Contains(titleAndDay, "8fnl") {
		return agePrefix + "Round of 16", 5
	}
	if strings.Contains(titleAndDay, "r32") || strings.Contains(titleAndDay, "round of 32") {
		return agePrefix + "Round of 32", 4
	}
	if strings.Contains(titleAndDay, "r64") || strings.Contains(titleAndDay, "round of 64") {
		return agePrefix + "Round of 64", 3
	}
	if strings.Contains(titleAndDay, "qual") || strings.Contains(titleAndDay, "q day") {
		return agePrefix + "Qualifying", 1
	}

	// 3. Fallback based on broadcast day number
	if strings.Contains(titleAndDay, "day 7") {
		return agePrefix + "Final", 8
	}
	if strings.Contains(titleAndDay, "day 6") {
		return agePrefix + "Quarter-Final", 6
	}
	if strings.Contains(titleAndDay, "day 5") {
		return agePrefix + "Round of 16", 5
	}
	if strings.Contains(titleAndDay, "day 4") {
		return agePrefix + "Round of 32", 4
	}
	if strings.Contains(titleAndDay, "day 3") {
		return agePrefix + "Round of 64", 3
	}

	return agePrefix + "Round Match", 1
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
	dbCalcTimes := make([]*time.Time, len(dbMatches))

	for i, m := range dbMatches {
		cA, tA := NormalizeName(m.TeamA)
		cB, tB := NormalizeName(m.TeamB)
		normDB[i] = preNormMatch{cleanA: cA, tokensA: tA, cleanB: cB, tokensB: tB}

		if m.StreamStartUTC != nil {
			calcT := m.StreamStartUTC.Add(time.Duration(m.VideoOffsetSeconds) * time.Second)
			dbCalcTimes[i] = &calcT
		}
	}

	// 2. Pre-normalize WTT matches once
	normWTT := make([]preNormMatch, len(wttMatches))
	wttTimes := make([]*time.Time, len(wttMatches))

	for i, m := range wttMatches {
		if len(m.MatchCard.Competitors) >= 2 {
			cA, tA := NormalizeName(m.MatchCard.Competitors[0].CompetitorName)
			cB, tB := NormalizeName(m.MatchCard.Competitors[1].CompetitorName)
			normWTT[i] = preNormMatch{cleanA: cA, tokensA: tA, cleanB: cB, tokensB: tB}
		}
		wttTimes[i] = ParseWTTStartTime(m)
	}

	// 3. Score candidate pairs with Fuzzy Name Matching and Time Correlation
	var candidates []matchPairCandidate
	for dIdx := range dbMatches {
		ndb := normDB[dIdx]
		calcT := dbCalcTimes[dIdx]

		for wIdx := range wttMatches {
			nwtt := normWTT[wIdx]
			if nwtt.cleanA == "" && nwtt.cleanB == "" {
				continue
			}

			wttTime := wttTimes[wIdx]

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

			timeDeltaMin := 0.0
			timeBonus := 0.0

			if calcT != nil && wttTime != nil {
				diffMin := calcT.Sub(*wttTime).Minutes()
				timeDeltaMin = diffMin

				// Time proximity guard for weak candidates: skip if outside empirical window
				if (diffMin < -45.0 || diffMin > 150.0) && baseScore < 0.85 {
					continue
				}

				if math.Abs(diffMin) <= 15.0 {
					timeBonus = 0.10 * (1.0 - math.Abs(diffMin)/30.0)
				}
			}

			compositeScore := baseScore + timeBonus
			if compositeScore > 1.0 {
				compositeScore = 1.0
			}

			if compositeScore >= threshold {
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
			IsMatched:        !isDup,
			IsDuplicate:      isDup,
			Confidence:       math.Round(cand.score*100) / 100,
			TimeDeltaMinutes: math.Round(cand.timeDelta*10) / 10,
			TournamentName:   tournamentName,
			TournamentYear:   tournamentYear,
			WTTEventID:       wttEventID,
			DBMatch:          &dbm,
			WTTMatch:         &wttm,
			WTTRound:         ExtractRoundFromDocumentCode(wttm.DocumentCode, mc.SubEventDescription),
			StageOrder:       GetStageOrder(ExtractRoundFromDocumentCode(wttm.DocumentCode, mc.SubEventDescription)),
			IsBroadcastMatch: false,
			WTTGender:        ExtractGender(wttm.SubEventType, wttm.DocumentCode),
			WTTScore:         mc.OverallScores,
			WTTGameScores:    mc.GameScores,
			WTTMatchID:       wttm.ID,
		}

		if isDup {
			rec.FailureReason = fmt.Sprintf("Intra-stream duplicate/continuation of match %d", primaryID)
			report.DuplicateCount++
		} else {
			report.MatchedCount++
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

// MatchedCount tracked per non-duplicate match above

	// Collect unmatched DB matches
	for dIdx, dbm := range dbMatches {
		if assignedDB[dIdx] {
			continue
		}
		inferredRound, stageOrder := InferStageForUnmatched(&dbm, report.Matches)
		unmatchedRec := MatchedRecord{
			IsMatched:        false,
			IsBroadcastMatch: true,
			Confidence:       0.0,
			FailureReason:    "No matching official WTT match found above confidence threshold",
			TournamentName:   tournamentName,
			TournamentYear:   tournamentYear,
			WTTEventID:       wttEventID,
			DBMatch:          &dbm,
			WTTRound:         inferredRound,
			StageOrder:       stageOrder,
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
			WTTRound:         ExtractRoundFromDocumentCode(wttm.DocumentCode, mc.SubEventDescription),
			StageOrder:       GetStageOrder(ExtractRoundFromDocumentCode(wttm.DocumentCode, mc.SubEventDescription)),
			IsBroadcastMatch: false,
			WTTGender:        ExtractGender(wttm.SubEventType, wttm.DocumentCode),
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

var (
	wttYearRegex    = regexp.MustCompile(`\b(20\d\d)\b`)
	wttSponsorRegex = regexp.MustCompile(`(?i)\s*(presented by|supported by|by)\s+.*$`)
	wttDayRegex     = regexp.MustCompile(`(?i)\b(Q\s*Day\s*\d+|Day\s*\d+|Finals?|Semi-?finals?|Quarter-?finals?)\b`)
)

// MatchVideoToWTTEvent matches a raw YouTube video title and upload year against official WTT dropdown events.
// It returns the official event ID, clean tournament name, official year, and whether a match was found.
func MatchVideoToWTTEvent(entries []WTTEventDropdownEntry, title string, uploadYear int) (int, string, int, bool) {
	normTitle := NormalizeTournamentName(title)

	var bestEntry *WTTEventDropdownEntry
	bestLen := 0
	bestYear := uploadYear

	for _, e := range entries {
		// Clean event name from sponsors and dates
		cleanOfficial := wttSponsorRegex.ReplaceAllString(e.EventName, "")
		normEvent := NormalizeTournamentName(cleanOfficial)

		// Extract year from official event name
		eventYear := uploadYear
		if m := wttYearRegex.FindString(normEvent); m != "" {
			if y, err := strconv.Atoi(m); err == nil {
				eventYear = y
			}
		}

		if uploadYear > 0 && eventYear != uploadYear {
			continue
		}

		// Strip year from event name to get the pure name (e.g. "singapore smash")
		eventBase := strings.TrimSpace(wttYearRegex.ReplaceAllString(normEvent, ""))

		if strings.Contains(normTitle, eventBase) {
			if len(eventBase) > bestLen {
				bestLen = len(eventBase)
				entryCopy := e
				bestEntry = &entryCopy
				bestYear = eventYear
			}
		}
	}

	if bestEntry != nil {
		cleanName := strings.TrimSpace(wttYearRegex.ReplaceAllString(wttSponsorRegex.ReplaceAllString(bestEntry.EventName, ""), ""))
		return bestEntry.EventID, cleanName, bestYear, true
	}
	return 0, "", 0, false
}

// ExtractDayFromTitle extracts simple day indicators ("Q Day 1", "Day 4", "Finals") from a video title.
func ExtractDayFromTitle(title string) string {
	parts := strings.Split(title, "|")
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if m := wttDayRegex.FindString(trimmed); m != "" {
			return m
		}
	}
	if m := wttDayRegex.FindString(title); m != "" {
		return m
	}
	return "Day 1"
}
