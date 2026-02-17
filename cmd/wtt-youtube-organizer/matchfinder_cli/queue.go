package matchfinder_cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"wtt-youtube-organizer/config"
	"wtt-youtube-organizer/db/importer"
)

// QueueEntry represents a video in the processing queue.
// Queue order: index 0 = newest (top), last index = oldest (bottom).
type QueueEntry struct {
	VideoID    string `json:"video_id"`
	VideoTitle string `json:"video_title"`
	UploadDate string `json:"upload_date"` // Format: YYYYMMDD
}

// --- Interfaces for dependency injection (testability) ---

// StreamFetcher fetches video metadata from YouTube (via Docker container).
// Returns videos in playlist order: newest first.
type StreamFetcher interface {
	FetchStreamsAfter(afterVideoID string) ([]QueueEntry, error)
}

// LastProcessedDB provides access to the last_processed video in the database.
type LastProcessedDB interface {
	GetLastProcessedVideoID() (string, error)
	GetLastProcessedUploadDate() (string, error)
	UpdateLastProcessed(youtubeID string) error
}

// ProcessedChecker checks which videos are already processed in the database.
type ProcessedChecker interface {
	GetProcessedVideoIDs(youtubeIDs []string) (map[string]bool, error)
}

// --- Queue file naming ---

const latestStreamsQueue = "latest_streams.json"

// QueueFileName returns the queue file name based on whether a video_id was provided.
//   - No video_id: "latest_streams.json"
//   - With video_id: "streams_after_<video_id>.json"
func QueueFileName(videoID string) string {
	if videoID == "" {
		return latestStreamsQueue
	}
	return fmt.Sprintf("streams_after_%s.json", videoID)
}

// QueueFilePath returns the full path to a queue file in the project config dir.
func QueueFilePath(queueName string) string {
	return filepath.Join(config.GetProjectConfigDir(), queueName)
}

// --- Queue I/O ---

// LoadQueue reads the queue from disk. Returns empty slice if file doesn't exist.
func LoadQueue(path string) ([]QueueEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return []QueueEntry{}, nil
		}
		return nil, fmt.Errorf("failed to read queue file: %w", err)
	}

	var queue []QueueEntry
	if err := json.Unmarshal(data, &queue); err != nil {
		return nil, fmt.Errorf("failed to parse queue file: %w", err)
	}
	return queue, nil
}

// SaveQueue writes the queue to disk.
func SaveQueue(path string, queue []QueueEntry) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create queue directory: %w", err)
	}

	data, err := json.MarshalIndent(queue, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal queue: %w", err)
	}

	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("failed to write queue file: %w", err)
	}
	return nil
}

// --- Queue operations ---

// PrependToQueue adds new entries to the top of the queue (newest first).
// The newEntries should already be in playlist order (newest first).
// Returns the updated queue.
func PrependToQueue(existingQueue []QueueEntry, newEntries []QueueEntry) []QueueEntry {
	if len(newEntries) == 0 {
		return existingQueue
	}
	result := make([]QueueEntry, 0, len(newEntries)+len(existingQueue))
	result = append(result, newEntries...)
	result = append(result, existingQueue...)
	return result
}

// RemoveLastEntry removes the last (oldest) entry from the queue.
// Returns the removed entry and the updated queue.
func RemoveLastEntry(queue []QueueEntry) (QueueEntry, []QueueEntry) {
	if len(queue) == 0 {
		return QueueEntry{}, queue
	}
	last := queue[len(queue)-1]
	return last, queue[:len(queue)-1]
}

// TopEntry returns the first (newest) entry in the queue, or empty if queue is empty.
func TopEntry(queue []QueueEntry) (QueueEntry, bool) {
	if len(queue) == 0 {
		return QueueEntry{}, false
	}
	return queue[0], true
}

// --- Add streams logic ---

// FilterUnprocessed removes entries that are already processed in the database.
// Returns only entries whose video IDs are NOT in the processedMap.
func FilterUnprocessed(entries []QueueEntry, checker ProcessedChecker) ([]QueueEntry, error) {
	if len(entries) == 0 {
		return entries, nil
	}

	// Collect all video IDs
	ids := make([]string, len(entries))
	for i, e := range entries {
		ids[i] = e.VideoID
	}

	// Check which are already processed
	processedMap, err := checker.GetProcessedVideoIDs(ids)
	if err != nil {
		return nil, fmt.Errorf("failed to check processed videos: %w", err)
	}

	// Filter out processed entries
	var filtered []QueueEntry
	for _, e := range entries {
		if !processedMap[e.VideoID] {
			filtered = append(filtered, e)
		}
	}

	return filtered, nil
}

// AddNewStreams fetches new streams and adds them to the queue.
// If the queue already exists and is non-empty, uses the top video ID as the cutoff.
// If the queue is empty/new, uses the provided afterVideoID.
// If checker is non-nil, filters out already-processed videos before adding.
// Returns the number of new entries added.
func AddNewStreams(queuePath string, afterVideoID string, fetcher StreamFetcher, checker ...ProcessedChecker) (int, error) {
	// Load existing queue
	existingQueue, err := LoadQueue(queuePath)
	if err != nil {
		return 0, fmt.Errorf("failed to load queue: %w", err)
	}

	// Determine which video_id to use as cutoff
	cutoffVideoID := afterVideoID
	if len(existingQueue) > 0 {
		// Queue exists: use top entry (newest) as cutoff
		cutoffVideoID = existingQueue[0].VideoID
	}

	if cutoffVideoID == "" {
		return 0, fmt.Errorf("no cutoff video ID available")
	}

	// Fetch new streams after cutoff
	newEntries, err := fetcher.FetchStreamsAfter(cutoffVideoID)
	if err != nil {
		return 0, fmt.Errorf("failed to fetch streams: %w", err)
	}

	if len(newEntries) == 0 {
		return 0, nil
	}

	// Filter out already-processed videos if checker is provided
	if len(checker) > 0 && checker[0] != nil {
		filtered, err := FilterUnprocessed(newEntries, checker[0])
		if err != nil {
			return 0, fmt.Errorf("failed to filter processed videos: %w", err)
		}
		newEntries = filtered
		if len(newEntries) == 0 {
			return 0, nil
		}
	}

	// Prepend new entries to top of queue
	updatedQueue := PrependToQueue(existingQueue, newEntries)

	// Save updated queue
	if err := SaveQueue(queuePath, updatedQueue); err != nil {
		return 0, fmt.Errorf("failed to save queue: %w", err)
	}

	return len(newEntries), nil
}

// --- Helpers ---

// VideosToQueueEntries converts importer.VideoJSON slice to QueueEntry slice.
func VideosToQueueEntries(videos []importer.VideoJSON) []QueueEntry {
	entries := make([]QueueEntry, len(videos))
	for i, v := range videos {
		entries[i] = QueueEntry{
			VideoID:    v.VideoID,
			VideoTitle: v.VideoTitle,
			UploadDate: v.UploadDate,
		}
	}
	return entries
}

// ShouldUpdateLastProcessed checks if the video's upload_date is >= the
// current last_processed upload_date in the database.
func ShouldUpdateLastProcessed(videoUploadDate string, dbUploadDate string) bool {
	if dbUploadDate == "" {
		return true
	}
	// YYYYMMDD format: string comparison works for date ordering
	return videoUploadDate >= dbUploadDate
}
