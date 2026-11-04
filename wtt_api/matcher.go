package wtt_api

import (
	"math"
	"regexp"
	"sort"
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

// NormalizeName strips accents, punctuation, and returns uppercase token list.
func NormalizeName(name string) (string, []string) {
	// Strip accents via unicode Decomposition (NFD)
	t := transform.Chain(norm.NFD, runes.Remove(runes.In(unicode.Mn)), norm.NFC)
	normalized, _, _ := transform.String(t, name)

	// Replace non-alphanumeric characters with spaces
	clean := nonAlphaNumRe.ReplaceAllString(normalized, " ")
	clean = strings.ToUpper(strings.TrimSpace(multipleSpacesRe.ReplaceAllString(clean, " ")))

	tokens := strings.Fields(clean)
	sort.Strings(tokens)
	return clean, tokens
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
				float64(dp[i-1][j]+1), // deletion
				math.Min(
					float64(dp[i][j-1]+1),      // insertion
					float64(dp[i-1][j-1]+cost), // substitution
				),
			))
		}
	}
	return dp[n][m]
}

// tokenSimilarity computes average best-token match from tokens1 into tokens2.
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

// NameSimilarity calculates fuzzy similarity between two names (0.0 to 1.0).
func NameSimilarity(name1, name2 string) float64 {
	clean1, tokens1 := NormalizeName(name1)
	clean2, tokens2 := NormalizeName(name2)

	if clean1 == "" || clean2 == "" {
		return 0.0
	}
	if clean1 == clean2 {
		return 1.0
	}

	// Token set equality (handles "JANG Woojin" vs "Woojin JANG")
	joined1 := strings.Join(tokens1, " ")
	joined2 := strings.Join(tokens2, " ")
	if joined1 == joined2 {
		return 1.0
	}

	// Token-level bipartite similarity (handles reversed word order + character typos)
	tokSim1 := tokenSimilarity(tokens1, tokens2)
	tokSim2 := tokenSimilarity(tokens2, tokens1)
	tokSim := (tokSim1 + tokSim2) / 2.0

	// Subset match (e.g. "FRANZISKA" vs "FRANZISKA Patrick")
	tokensSet1 := make(map[string]bool)
	for _, t := range tokens1 {
		tokensSet1[t] = true
	}
	tokensSet2 := make(map[string]bool)
	for _, t := range tokens2 {
		tokensSet2[t] = true
	}

	matchCount := 0
	smallerSet := tokensSet1
	largerSet := tokensSet2
	if len(tokensSet1) > len(tokensSet2) {
		smallerSet = tokensSet2
		largerSet = tokensSet1
	}

	for tok := range smallerSet {
		if largerSet[tok] {
			matchCount++
		}
	}

	var subsetScore float64
	if len(smallerSet) > 0 && matchCount == len(smallerSet) {
		subsetScore = 0.90
	}

	// Full string Levenshtein ratio
	maxLen := math.Max(float64(len([]rune(clean1))), float64(len([]rune(clean2))))
	dist := LevenshteinDistance(clean1, clean2)
	levScore := 1.0 - (float64(dist) / maxLen)
	if levScore < 0 {
		levScore = 0
	}

	return math.Max(tokSim, math.Max(subsetScore, levScore))
}

// PairSimilarity calculates symmetrical match score for two opposing sides.
func PairSimilarity(dbA, dbB, wttA, wttB string) (float64, bool) {
	direct := (NameSimilarity(dbA, wttA) + NameSimilarity(dbB, wttB)) / 2.0
	swapped := (NameSimilarity(dbA, wttB) + NameSimilarity(dbB, wttA)) / 2.0

	if direct >= swapped {
		return direct, false
	}
	return swapped, true
}

// ExtractRoundFromDocumentCode converts ITTF document codes into clean round names.
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

	// Fallback to subEventDescription if available
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

// ExtractGender parses gender division from subEventType or documentCode.
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
}

// AlignMatches executes optimal 1-to-1 bipartite fuzzy matching between DB matches and WTT official results.
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

	// Build candidate pairs matrix
	var candidates []matchPairCandidate
	for dIdx, dbm := range dbMatches {
		for wIdx, wttm := range wttMatches {
			mc := wttm.MatchCard
			if len(mc.Competitors) < 2 {
				continue
			}

			wttTeamA := mc.Competitors[0].CompetitorName
			wttTeamB := mc.Competitors[1].CompetitorName

			score, isSwapped := PairSimilarity(dbm.TeamA, dbm.TeamB, wttTeamA, wttTeamB)
			if score >= threshold {
				candidates = append(candidates, matchPairCandidate{
					dbIdx:     dIdx,
					wttIdx:    wIdx,
					score:     score,
					isSwapped: isSwapped,
				})
			}
		}
	}

	// Sort candidates by score descending for greedy 1-to-1 assignment
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].score > candidates[j].score
	})

	assignedDB := make(map[int]bool)
	assignedWTT := make(map[int]bool)

	for _, cand := range candidates {
		if assignedDB[cand.dbIdx] || assignedWTT[cand.wttIdx] {
			continue
		}

		dbm := dbMatches[cand.dbIdx]
		wttm := wttMatches[cand.wttIdx]
		mc := wttm.MatchCard

		assignedDB[cand.dbIdx] = true
		assignedWTT[cand.wttIdx] = true

		rec := MatchedRecord{
			IsMatched:      true,
			Confidence:     math.Round(cand.score*100) / 100,
			TournamentName: tournamentName,
			TournamentYear: tournamentYear,
			WTTEventID:     wttEventID,
			DBMatch:        &dbm,
			WTTMatch:       &wttm,
			WTTRound:       ExtractRoundFromDocumentCode(wttm.DocumentCode, mc.SubEventDescription),
			WTTGender:      ExtractGender(wttm.SubEventType, wttm.DocumentCode),
			WTTScore:       mc.OverallScores,
			WTTGameScores:  mc.GameScores,
			WTTMatchID:     wttm.ID,
		}

		if mc.MatchDateTime.StartDateUTC != "" {
			rec.WTTMatchStartUTC = mc.MatchDateTime.StartDateUTC
		} else {
			rec.WTTMatchStartUTC = wttm.StartDateLocal
		}

		// DB OCR Names
		rec.OCRPlayerNames.TeamA = dbm.TeamA
		rec.OCRPlayerNames.TeamB = dbm.TeamB

		// Authoritative WTT Names and Countries (oriented to match DB Team A/B)
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
