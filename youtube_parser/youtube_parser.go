package youtubeparser

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"slices"
	"strings"
	"time"
	"wtt-youtube-organizer/shell"
)

type YoutubeVideoInt struct {
	URL            string `json:"url"`
	Title          string `json:"title"`
	UploadDate     string `json:"upload_date"`
	DurationString string `json:"duration_string"`
}

type YoutubeVideo struct {
	URL        string
	FullMatch  bool
	Players    string
	Gender     string
	Round      string
	Tournament string
	UploadDate string
	Duration   time.Duration
	Title      string
}

type NameParts struct {
	FullMatch  bool
	Players    string
	Gender     string
	Round      string
	Tournament string
}

type Filters struct {
	ShowWatched bool
	Tournament  string
	Filter      string
	Gender      string
	Full        bool
	TodayOnly   bool
}

type WatchHistory struct {
	Urls map[string]*YoutubeVideo
}

func FilterWttVideos(filters *Filters) []YoutubeVideo {
	out := shell.ExecuteScript("yt-dlp", "-j", "--flat-playlist", "--playlist-items", "1-200", "--extractor-args", "youtubetab:approximate_date", "https://www.youtube.com/@WTTGlobal/videos")
	if out.Err != "" {
		log.Fatalf("Error executing shell command: %s", out.Err)
	}
	videos := parseYtlpOutput(out.Out)
	var finalVideos []YoutubeVideo
	var watchHistory *WatchHistory
	if !filters.ShowWatched {
		watchHistory = GetWatchHistory()
	}
	for i := len(videos) - 1; i >= 0; i-- {
		video := videos[i]
		isTodayDate, err := isToday(video.UploadDate)
		if err != nil {
			log.Default().Fatalln(err)
		}
		if !filters.ShowWatched && watchHistory.Contains(video.URL) {
			continue
		}

		if len(filters.Tournament) > 0 && !strings.Contains(strings.ToLower(video.Tournament), strings.ToLower(filters.Tournament)) {
			continue
		}
		if len(filters.Filter) > 0 && !strings.Contains(strings.ToLower(video.Title), strings.ToLower(filters.Filter)) {
			continue
		}
		if len(filters.Gender) > 0 && !strings.EqualFold(video.Gender, filters.Gender) {
			continue
		}
		if filters.Full && !video.FullMatch {
			continue
		}
		if filters.TodayOnly && !isTodayDate {
			continue
		}
		finalVideos = append(finalVideos, video)
	}
	return finalVideos
}

func GetWatchHistory() *WatchHistory {
	out := shell.ExecuteScript("yt-dlp", "-j", "--cookies-from-browser", "CHROME", "--flat-playlist", "--playlist-items", "1-500", "--extractor-args", "youtubetab:approximate_date", "https://www.youtube.com/feed/history")
	if out.Err != "" {
		log.Fatalf("Error executing shell command: %s", out.Err)
	}
	videos := parseYtlpOutput(out.Out)
	watchHistory := NewWatchHistory()
	for _, video := range videos {
		watchHistory.AddVideo(&video)
	}
	return watchHistory
}

func parseYtlpOutput(ytDlpOutput string) []YoutubeVideo {
	// Split the output into individual JSON objects
	lines := strings.Split(ytDlpOutput, "\n")
	var videos []YoutubeVideo
	for _, line := range lines {
		if line == "" { // Handle empty lines
			continue
		}
		if !strings.HasPrefix(line, "{") || !strings.HasSuffix(line, "}") {
			continue // Skip this line if it doesn't look like valid JSON
		}
		var video YoutubeVideoInt
		err := json.Unmarshal([]byte(line), &video)

		if err != nil {
			fmt.Printf("Error unmarshalling JSON: %v\n", err)
			continue // Skip this line if there's an error
		}
		// shorts don't have a duration and that's since we don't need shorts
		if len(video.DurationString) == 0 {
			continue
		}
		titleParts, err := NameParts{}.Parse(video.Title)
		// Not interested in videos which are not parseable, eg. contain wrong title
		if err != nil {
			continue
		}
		duration, err := parseDuration(video.DurationString)
		if err != nil {
			log.Fatalf("Failed to parse video: %v from %v", err, video)
		}
		videoFinal := YoutubeVideo{
			URL:        video.URL,
			UploadDate: video.UploadDate,
			FullMatch:  titleParts.FullMatch,
			Players:    titleParts.Players,
			Gender:     titleParts.Gender,
			Round:      titleParts.Round,
			Tournament: titleParts.Tournament,
			Duration:   duration,
			Title:      video.Title}
		videos = append(videos, videoFinal)
	}
	return videos
}

func isToday(dateStr string) (bool, error) {
	layout := "20060102"

	// Parse the date string
	parsedDate, err := time.Parse(layout, dateStr)
	if err != nil {
		return false, fmt.Errorf("error parsing date:%v", err)
	}

	// Get current time in your location (adjust timezone as needed)
	location, _ := time.LoadLocation("America/Los_Angeles")
	now := time.Now().In(location)

	// Calculate 24 hours from now
	last24Hours := now.Add(-48 * time.Hour)

	// Check if parsedDate is within the next 24 hours
	if parsedDate.After(last24Hours) {
		return true, nil
	} else {
		return false, nil
	}
}

func parseDuration(durationString string) (time.Duration, error) {
	parts := strings.Split(durationString, ":")
	if len(parts) == 1 {
		seconds, err := time.ParseDuration(durationString + "s")
		if err != nil {
			return 0, fmt.Errorf("failed to parse video duration: %s", durationString)
		}
		return seconds, nil
	} else if len(parts) == 2 {
		minutes, _ := time.ParseDuration(parts[0] + "m")
		seconds, _ := time.ParseDuration(parts[1] + "s")
		return minutes + seconds, nil

	} else if len(parts) == 3 {
		hours, _ := time.ParseDuration(parts[0] + "h")
		minutes, _ := time.ParseDuration(parts[1] + "m")
		seconds, _ := time.ParseDuration(parts[2] + "s")
		return hours + minutes + seconds, nil
	}
	return 0, fmt.Errorf("unkown durationString format: %s", durationString)
}

func (h *WatchHistory) Contains(url string) bool {
	_, ok := h.Urls[url]
	return ok
}

func (h *WatchHistory) AddVideo(video *YoutubeVideo) {
	h.Urls[video.URL] = video
}

func NewWatchHistory() *WatchHistory {
	return &WatchHistory{Urls: make(map[string]*YoutubeVideo)}
}

func (n NameParts) Parse(name string) (*NameParts, error) {
	parts := strings.Split(name, "|")
	parsedName := NameParts{}

	partInd := 0
	for partInd < len(parts) {
		part := strings.TrimSpace(parts[partInd])
		if part == "FULL MATCH" {
			parsedName.FullMatch = true
			partInd = partInd + 1
			continue
		}
		if slices.Contains(strings.Fields(part), "vs") {
			parsedName.Players = part
			partInd = partInd + 1
			continue

		}
		// Unexpected format. There is no players or full match at first two parts
		if partInd == 0 && !parsedName.FullMatch && parsedName.Players == "" {
			return &parsedName, fmt.Errorf("failed to parse player/match_duration for %s", name)
		}
		if partInd == 1 && parsedName.FullMatch && parsedName.Players == "" {
			return &parsedName, fmt.Errorf("failed to parse player/match_duration for %s", name)
		}
		genderAndRoundParts := strings.Fields(part)
		if slices.Contains([]string{"MS", "WS", "MD", "WD", "XD"}, genderAndRoundParts[0]) {
			roundPart := strings.Split(part, " ")
			parsedName.Gender = roundPart[0]
			parsedName.Round = roundPart[1]
			partInd = partInd + 1
			continue
		}
		// Unexpected format. There is round and gender part
		if partInd == 1 && !parsedName.FullMatch && parsedName.Round == "" {
			return &parsedName, fmt.Errorf("failed to parse round and gender for part %s in name %s", part, name)
		}
		if partInd == 2 && parsedName.FullMatch && parsedName.Round == "" {
			return &parsedName, fmt.Errorf("failed to parse round and gender for part %s in name %s", part, name)
		}

		parsedName.Tournament = strings.ReplaceAll(part, "#", "")
		return &parsedName, nil
	}
	return nil, errors.New("failed to parse name")
}
