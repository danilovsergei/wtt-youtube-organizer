package matchfinder_cli

import (
	"fmt"
	"strings"
	"os"
	"path/filepath"
	"testing"
)

// --- Mock implementations ---

// mockStreamFetcher records the video_id it was called with and returns preset entries.
type mockStreamFetcher struct {
	calledWithVideoID string
	returnEntries     []QueueEntry
	returnErr         error
}

func (m *mockStreamFetcher) FetchStreamsAfter(afterVideoID string) ([]QueueEntry, error) {
	m.calledWithVideoID = afterVideoID
	return m.returnEntries, m.returnErr
}

// --- Helper functions ---

func entry(id, title, date string) QueueEntry {
	return QueueEntry{VideoID: id, VideoTitle: title, UploadDate: date}
}

func ids(entries []QueueEntry) []string {
	result := make([]string, len(entries))
	for i, e := range entries {
		result[i] = e.VideoID
	}
	return result
}

func assertIDs(t *testing.T, got []QueueEntry, wantIDs []string) {
	t.Helper()
	gotIDs := ids(got)
	if len(gotIDs) != len(wantIDs) {
		t.Fatalf("length mismatch: got %v, want %v", gotIDs, wantIDs)
	}
	for i := range gotIDs {
		if gotIDs[i] != wantIDs[i] {
			t.Fatalf("index %d: got %q, want %q\nfull got:  %v\nfull want: %v",
				i, gotIDs[i], wantIDs[i], gotIDs, wantIDs)
		}
	}
}

// --- Test: Queue naming ---

func TestQueueFileName_NoVideoID(t *testing.T) {
	name := QueueFileName("")
	if name != "latest_streams.json" {
		t.Fatalf("expected latest_streams.json, got %s", name)
	}
}

func TestQueueFileName_WithVideoID(t *testing.T) {
	name := QueueFileName("abc123")
	expected := "streams_after_abc123.json"
	if name != expected {
		t.Fatalf("expected %s, got %s", expected, name)
	}
}

// --- Test: add_new_streams without video_id creates latest_streams.json ---

func TestAddNewStreams_NoVideoID_CreatesLatestStreams(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("A", "Video A", "1771200000"),
			entry("B", "Video B", "1771113600"),
		},
	}

	count, err := AddNewStreams(queuePath,  "DB_LAST",  fetcher, "")
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}
	if count != 2 {
		t.Fatalf("expected 2 new entries, got %d", count)
	}

	queue, err := LoadQueue(queuePath)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}
	assertIDs(t, queue, []string{"A", "B"})

	if fetcher.calledWithVideoID != "DB_LAST" {
		t.Fatalf("expected fetcher called with DB_LAST, got %s", fetcher.calledWithVideoID)
	}
}

// --- Test: add_new_streams with video_id creates streams_after_<video_id>.json ---

func TestAddNewStreams_WithVideoID_CreatesNamedQueue(t *testing.T) {
	tmpDir := t.TempDir()
	queueName := QueueFileName("xyz789")
	queuePath := filepath.Join(tmpDir, queueName)

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("C", "Video C", "1771027200"),
		},
	}

	count, err := AddNewStreams(queuePath,  "xyz789",  fetcher, "")
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 new entry, got %d", count)
	}

	if _, err := os.Stat(queuePath); os.IsNotExist(err) {
		t.Fatalf("queue file not created at %s", queuePath)
	}

	if fetcher.calledWithVideoID != "xyz789" {
		t.Fatalf("expected fetcher called with xyz789, got %s", fetcher.calledWithVideoID)
	}
}

// --- Test: empty queue uses provided afterVideoID ---

func TestAddNewStreams_EmptyQueue_UsesAfterVideoID(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("NEW1", "New Video 1", "1771200000"),
		},
	}

	_, err := AddNewStreams(queuePath,  "DB_VIDEO_ID",  fetcher, "")
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}

	if fetcher.calledWithVideoID != "DB_VIDEO_ID" {
		t.Fatalf("expected fetcher called with DB_VIDEO_ID, got %s", fetcher.calledWithVideoID)
	}
}

// --- Test: existing queue uses top video ID as cutoff ---

func TestAddNewStreams_ExistingQueue_UsesTopVideoID(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	existingQueue := []QueueEntry{
		entry("EXISTING_TOP", "Existing Top", "1771027200"),
		entry("EXISTING_OLD", "Existing Old", "1770940800"),
	}
	if err := SaveQueue(queuePath, existingQueue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("NEWER1", "Newer 1", "1771200000"),
			entry("NEWER2", "Newer 2", "1771113600"),
		},
	}

	_, err := AddNewStreams(queuePath,  "IGNORED_DB_ID",  fetcher, "")
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}

	if fetcher.calledWithVideoID != "EXISTING_TOP" {
		t.Fatalf("expected fetcher called with EXISTING_TOP, got %s", fetcher.calledWithVideoID)
	}
}

// --- Test: new videos prepended to top of queue ---

func TestAddNewStreams_PrependsToTopOfQueue(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	existingQueue := []QueueEntry{
		entry("B", "Video B", "1771113600"),
		entry("C", "Video C", "1771027200"),
	}
	if err := SaveQueue(queuePath, existingQueue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("A", "Video A", "1771200000"),
		},
	}

	count, err := AddNewStreams(queuePath,  "",  fetcher, "")
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 new entry, got %d", count)
	}

	queue, err := LoadQueue(queuePath)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}
	assertIDs(t, queue, []string{"A", "B", "C"})
}

// --- Test: PrependToQueue ---

func TestPrependToQueue_Basic(t *testing.T) {
	existing := []QueueEntry{
		entry("B", "Video B", "1771113600"),
		entry("C", "Video C", "1771027200"),
	}
	newEntries := []QueueEntry{
		entry("A", "Video A", "1771200000"),
	}

	result := PrependToQueue(existing, newEntries)
	assertIDs(t, result, []string{"A", "B", "C"})
}

func TestPrependToQueue_EmptyNew(t *testing.T) {
	existing := []QueueEntry{entry("A", "Video A", "1771200000")}
	result := PrependToQueue(existing, nil)
	assertIDs(t, result, []string{"A"})
}

func TestPrependToQueue_EmptyExisting(t *testing.T) {
	newEntries := []QueueEntry{entry("A", "Video A", "1771200000")}
	result := PrependToQueue(nil, newEntries)
	assertIDs(t, result, []string{"A"})
}

// --- Test: RemoveLastEntry ---

func TestRemoveLastEntry_Basic(t *testing.T) {
	queue := []QueueEntry{
		entry("A", "Video A", "1771200000"),
		entry("B", "Video B", "1771113600"),
		entry("C", "Video C", "1771027200"),
	}

	removed, remaining := RemoveLastEntry(queue)
	if removed.VideoID != "C" {
		t.Fatalf("expected removed C, got %s", removed.VideoID)
	}
	assertIDs(t, remaining, []string{"A", "B"})
}

func TestRemoveLastEntry_Empty(t *testing.T) {
	removed, remaining := RemoveLastEntry([]QueueEntry{})
	if removed.VideoID != "" {
		t.Fatalf("expected empty entry, got %s", removed.VideoID)
	}
	if len(remaining) != 0 {
		t.Fatalf("expected empty queue, got %d", len(remaining))
	}
}

// --- Test: TopEntry ---

func TestTopEntry_Basic(t *testing.T) {
	queue := []QueueEntry{
		entry("A", "Video A", "1771200000"),
		entry("B", "Video B", "1771113600"),
	}
	top, ok := TopEntry(queue)
	if !ok || top.VideoID != "A" {
		t.Fatalf("expected A, got %s (ok=%v)", top.VideoID, ok)
	}
}

func TestTopEntry_Empty(t *testing.T) {
	_, ok := TopEntry([]QueueEntry{})
	if ok {
		t.Fatal("expected ok=false for empty queue")
	}
}

// --- Test: LoadQueue / SaveQueue ---

func TestLoadSaveQueue_Roundtrip(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "test_queue.json")

	queue := []QueueEntry{
		entry("A", "Video A", "1771200000"),
		entry("B", "Video B", "1771113600"),
	}

	if err := SaveQueue(path, queue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	loaded, err := LoadQueue(path)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}
	assertIDs(t, loaded, []string{"A", "B"})
	if loaded[0].VideoTitle != "Video A" {
		t.Errorf("title mismatch: got %q, want %q", loaded[0].VideoTitle, "Video A")
	}
}

func TestLoadQueue_NonExistent(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "nonexistent.json")

	queue, err := LoadQueue(path)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}
	if len(queue) != 0 {
		t.Fatalf("expected empty queue, got %d entries", len(queue))
	}
}

// --- Mock ProcessedChecker ---

type mockProcessedChecker struct {
	processedIDs map[string]bool
}

func (m *mockProcessedChecker) GetProcessedVideoIDs(youtubeIDs []string) (map[string]bool, error) {
	result := make(map[string]bool)
	for _, id := range youtubeIDs {
		if m.processedIDs[id] {
			result[id] = true
		}
	}
	return result, nil
}

// --- Test: FilterUnprocessed ---

func TestFilterUnprocessed_FiltersOutProcessed(t *testing.T) {
	entries := []QueueEntry{
		entry("A", "Video A", "1771200000"),
		entry("B", "Video B", "1771113600"),
		entry("C", "Video C", "1771027200"),
	}

	checker := &mockProcessedChecker{
		processedIDs: map[string]bool{"B": true},
	}

	filtered, err := FilterUnprocessed(entries, checker)
	if err != nil {
		t.Fatalf("FilterUnprocessed failed: %v", err)
	}

	assertIDs(t, filtered, []string{"A", "C"})
}

func TestFilterUnprocessed_AllProcessed(t *testing.T) {
	entries := []QueueEntry{
		entry("A", "Video A", "1771200000"),
		entry("B", "Video B", "1771113600"),
	}

	checker := &mockProcessedChecker{
		processedIDs: map[string]bool{"A": true, "B": true},
	}

	filtered, err := FilterUnprocessed(entries, checker)
	if err != nil {
		t.Fatalf("FilterUnprocessed failed: %v", err)
	}

	if len(filtered) != 0 {
		t.Fatalf("expected empty, got %v", ids(filtered))
	}
}

func TestFilterUnprocessed_NoneProcessed(t *testing.T) {
	entries := []QueueEntry{
		entry("A", "Video A", "1771200000"),
		entry("B", "Video B", "1771113600"),
	}

	checker := &mockProcessedChecker{
		processedIDs: map[string]bool{},
	}

	filtered, err := FilterUnprocessed(entries, checker)
	if err != nil {
		t.Fatalf("FilterUnprocessed failed: %v", err)
	}

	assertIDs(t, filtered, []string{"A", "B"})
}

// --- Test: FilterUnprocessed filters videos with latest upload_date existing in DB ---

// Scenario: DB has videos with latest upload_date 2025-12-19.
// Docker returns videos including _vFHdnrgau4 and lxJIbTLc-2w (already in DB with 2025-12-19)
// and new_video_1, new_video_2 (upload_date 2025-12-19 but NOT in DB yet).
// The filter should remove only videos that exist in the DB.
func TestFilterUnprocessed_LatestUploadDateVideosInDB_FilteredOut(t *testing.T) {
	// Docker returned these videos (including some already processed with latest upload_date)
	entries := []QueueEntry{
		entry("new_video_2", "New Video 2", "1766188800"),
		entry("new_video_1", "New Video 1", "1766102400"),
		entry("lxJIbTLc-2w", "Existing Video 2", "1766102400"),
		entry("_vFHdnrgau4", "Existing Video 1", "1766102400"),
	}

	// DB has these two videos with the latest upload_date
	checker := &mockProcessedChecker{
		processedIDs: map[string]bool{
			"_vFHdnrgau4": true,
			"lxJIbTLc-2w": true,
		},
	}

	filtered, err := FilterUnprocessed(entries, checker)
	if err != nil {
		t.Fatalf("FilterUnprocessed failed: %v", err)
	}

	// Only new videos should remain (the ones NOT in DB)
	assertIDs(t, filtered, []string{"new_video_2", "new_video_1"})
}

// Scenario: Videos with latest upload_date NOT existing in the DB should remain.
func TestFilterUnprocessed_LatestUploadDateVideosNotInDB_Remaining(t *testing.T) {
	// Docker returned these - all have the latest upload_date, none in DB yet
	entries := []QueueEntry{
		entry("brand_new_1", "Brand New 1", "1766102400"),
		entry("brand_new_2", "Brand New 2", "1766102400"),
	}

	// DB has no videos at all
	checker := &mockProcessedChecker{
		processedIDs: map[string]bool{},
	}

	filtered, err := FilterUnprocessed(entries, checker)
	if err != nil {
		t.Fatalf("FilterUnprocessed failed: %v", err)
	}

	// All should remain since none are in DB
	assertIDs(t, filtered, []string{"brand_new_1", "brand_new_2"})
}

// --- Test: AddNewStreams with checker filters processed videos ---

func TestAddNewStreams_WithChecker_FiltersProcessed(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "streams_after_xyz.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("A", "Video A", "1771200000"),
			entry("B", "Video B", "1771113600"),
			entry("C", "Video C", "1771027200"),
		},
	}

	checker := &mockProcessedChecker{
		processedIDs: map[string]bool{"B": true},
	}

	count, err := AddNewStreams(queuePath,   "xyz",   fetcher, "", checker)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}

	if count != 2 {
		t.Fatalf("expected 2 new entries, got %d", count)
	}

	queue, err := LoadQueue(queuePath)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}

	assertIDs(t, queue, []string{"A", "C"})
}

func TestAddNewStreams_WithChecker_AllProcessed_NothingAdded(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "streams_after_xyz.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("A", "Video A", "1771200000"),
			entry("B", "Video B", "1771113600"),
		},
	}

	checker := &mockProcessedChecker{
		processedIDs: map[string]bool{"A": true, "B": true},
	}

	count, err := AddNewStreams(queuePath,   "xyz",   fetcher, "", checker)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}
	if count != 0 {
		t.Fatalf("expected 0 new entries, got %d", count)
	}

	if _, err := os.Stat(queuePath); !os.IsNotExist(err) {
		t.Fatal("queue file should not exist when all videos already processed")
	}
}

func TestAddNewStreams_WithoutChecker_NoFiltering(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("A", "Video A", "1771200000"),
			entry("B", "Video B", "1771113600"),
		},
	}

	count, err := AddNewStreams(queuePath,  "DB_LAST",  fetcher, "")
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}
	if count != 2 {
		t.Fatalf("expected 2, got %d", count)
	}

	queue, err := LoadQueue(queuePath)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}
	assertIDs(t, queue, []string{"A", "B"})
}

func TestAddNewStreams_NoNewStreams(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{},
	}

	count, err := AddNewStreams(queuePath,  "SOME_ID",  fetcher, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if count != 0 {
		t.Fatalf("expected 0 new entries, got %d", count)
	}

	if _, err := os.Stat(queuePath); !os.IsNotExist(err) {
		t.Fatal("queue file should not exist when no streams found")
	}
}

// --- Test: processQueueVideos ---

// contains checks if s contains substr
func contains(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func TestProcessQueue_SkipsDockerError_ContinuesProcessing(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	// Queue: C (newest) → B → A (oldest, processed first)
	queue := []QueueEntry{
		entry("C", "Video C", "1771200000"),
		entry("B", "Video B", "1771113600"),
		entry("A", "Video A", "1771027200"),
	}
	if err := SaveQueue(queuePath, queue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	var dockerCalls []string
	var importCalls []string

	deps := queueProcessorDeps{
		runDocker: func(outputFile string, containerArgs []string) error {
			for _, arg := range containerArgs {
				if strings.HasPrefix(arg, "--youtube_video=") {
					url := strings.TrimPrefix(arg, "--youtube_video=")
					vid := url[len("https://www.youtube.com/watch?v="):]
					dockerCalls = append(dockerCalls, vid)

					if vid == "B" {
						// Docker fails for B
						return fmt.Errorf("docker run failed: exit code 1")
					}
					jsonData := fmt.Sprintf(`{"video_id":"%s","video_title":"Video %s","upload_date":"1771113600","matches":[{"timestamp":100,"player1":"P1","player2":"P2"}]}`, vid, vid)
					os.WriteFile(outputFile, []byte(jsonData), 0644)
				}
			}
			return nil
		},
		importJSON: func(jsonFilePath string) error {
			data, err := os.ReadFile(jsonFilePath)
			if err != nil {
				return err
			}
			content := string(data)
			for _, vid := range []string{"A", "B", "C"} {
				if contains(content, fmt.Sprintf(`"video_id":"%s"`, vid)) {
					importCalls = append(importCalls, vid)
				}
			}
			return nil
		},
	}

	// Should NOT return error (docker errors are skipped, processing continues)
	err := processQueueVideosWithDeps(queuePath,  deps,  nil, "")
	if err != nil {
		t.Fatalf("processQueueVideos should not fail: %v", err)
	}

	// All 3 videos should have been attempted (oldest first: A, B, C)
	if len(dockerCalls) != 3 {
		t.Fatalf("expected 3 docker calls, got %d: %v", len(dockerCalls), dockerCalls)
	}
	if dockerCalls[0] != "A" || dockerCalls[1] != "B" || dockerCalls[2] != "C" {
		t.Fatalf("expected docker calls [A, B, C], got %v", dockerCalls)
	}

	// Import should have been called for A and C only (B had docker error, skipped)
	if len(importCalls) != 2 {
		t.Fatalf("expected 2 import calls, got %d: %v", len(importCalls), importCalls)
	}

	// Only B should remain in queue (A and C succeeded)
	remaining, _ := LoadQueue(queuePath)
	if len(remaining) != 1 {
		t.Fatalf("expected 1 entry in queue (B kept for retry), got %d", len(remaining))
	}
	assertIDs(t, remaining, []string{"B"})
}

// TestProcessQueue_DockerFailsForAll_AllRemainInQueue tests that when
// docker fails for all videos, all remain in queue and no error is returned
// (docker errors are skipped, not fatal).
func TestProcessQueue_DockerFailsForAll_AllRemainInQueue(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	queue := []QueueEntry{
		entry("B", "Video B", "1771200000"),
		entry("A", "Video A", "1771113600"),
	}
	if err := SaveQueue(queuePath, queue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	deps := queueProcessorDeps{
		runDocker: func(outputFile string, containerArgs []string) error {
			// Docker fails for every video
			return fmt.Errorf("docker run failed: exit code 1")
		},
		importJSON: func(jsonFilePath string) error {
			t.Fatal("importJSON should not be called when docker fails")
			return nil
		},
	}

	// Should NOT return error (docker errors are skipped)
	err := processQueueVideosWithDeps(queuePath,  deps,  nil, "")
	if err != nil {
		t.Fatalf("processQueueVideos should not fail: %v", err)
	}

	// Both videos should remain in queue
	remaining, _ := LoadQueue(queuePath)
	if len(remaining) != 2 {
		t.Fatalf("expected 2 entries still in queue, got %d", len(remaining))
	}
	assertIDs(t, remaining, []string{"B", "A"})
}

func TestProcessQueue_StopsOnImportError_VideoRemainsInQueue(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	queue := []QueueEntry{
		entry("B", "Video B", "1771200000"),
		entry("A", "Video A", "1771113600"),
	}
	if err := SaveQueue(queuePath, queue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	deps := queueProcessorDeps{
		runDocker: func(outputFile string, containerArgs []string) error {
			for _, arg := range containerArgs {
				if strings.HasPrefix(arg, "--youtube_video=") {
					url := strings.TrimPrefix(arg, "--youtube_video=")
					vid := url[len("https://www.youtube.com/watch?v="):]
					jsonData := fmt.Sprintf(`{"video_id":"%s","video_title":"Video %s","upload_date":"1771113600","matches":[]}`, vid, vid)
					os.WriteFile(outputFile, []byte(jsonData), 0644)
				}
			}
			return nil
		},
		importJSON: func(jsonFilePath string) error {
			data, _ := os.ReadFile(jsonFilePath)
			content := string(data)
			if contains(content, `"video_id":"A"`) {
				return fmt.Errorf("DATABASE_URL environment variable is required")
			}
			return nil
		},
	}

	err := processQueueVideosWithDeps(queuePath,  deps,  nil, "")

	if err == nil {
		t.Fatal("expected error from processQueueVideos, got nil")
	}
	if !contains(err.Error(), "failed to import video A") {
		t.Fatalf("expected import error for video A, got: %v", err)
	}

	remaining, _ := LoadQueue(queuePath)
	if len(remaining) != 2 {
		t.Fatalf("expected 2 entries still in queue (A failed), got %d", len(remaining))
	}
	assertIDs(t, remaining, []string{"B", "A"})
}

func TestProcessQueue_RemovesVideoOnSuccessfulImport(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	queue := []QueueEntry{
		entry("B", "Video B", "1771200000"),
		entry("A", "Video A", "1771113600"),
	}
	if err := SaveQueue(queuePath, queue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	deps := queueProcessorDeps{
		runDocker: func(outputFile string, containerArgs []string) error {
			for _, arg := range containerArgs {
				if strings.HasPrefix(arg, "--youtube_video=") {
					url := strings.TrimPrefix(arg, "--youtube_video=")
					vid := url[len("https://www.youtube.com/watch?v="):]
					jsonData := fmt.Sprintf(`{"video_id":"%s","video_title":"Video %s","upload_date":"1771113600","matches":[{"timestamp":100,"player1":"P1","player2":"P2"}]}`, vid, vid)
					os.WriteFile(outputFile, []byte(jsonData), 0644)
				}
			}
			return nil
		},
		importJSON: func(jsonFilePath string) error {
			return nil
		},
	}

	err := processQueueVideosWithDeps(queuePath,  deps,  nil, "")
	if err != nil {
		t.Fatalf("processQueueVideos should not fail: %v", err)
	}

	remaining, _ := LoadQueue(queuePath)
	if len(remaining) != 0 {
		t.Fatalf("expected empty queue, got %d entries", len(remaining))
	}
}

// --- Tests for Filtering AddNewStreams ---
func TestAddNewStreams_WithFilter_FiltersOutNonMatching(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	// Set up a mock fetcher returning multiple streams
	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			{VideoID: "1", VideoTitle: "WTT Champions Chongqing 2026 - Match 1"},
			{VideoID: "2", VideoTitle: "WTT Star Contender 2026 - Match 2"},
			{VideoID: "3", VideoTitle: "WTT Champions Chongqing 2026 - Match 3"},
		},
	}

	filterTitle := "WTT Champions Chongqing 2026"
	
	// Execute AddNewStreams with the filter
	count, err := AddNewStreams(queuePath, "dummy_id", fetcher, filterTitle, nil)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}

	if count != 2 {
		t.Errorf("Expected 2 videos to be added, got %d", count)
	}

	// Verify only the matching videos were saved
	queue, _ := LoadQueue(queuePath)
	if len(queue) != 2 {
		t.Fatalf("Expected 2 videos in queue, got %d", len(queue))
	}
	
	if queue[0].VideoID != "1" || queue[1].VideoID != "3" {
		t.Errorf("Incorrect videos in queue: %v", queue)
	}
}

func TestAddNewStreams_SkipsCeremonyAndShowExceptFinals(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			{VideoID: "1", VideoTitle: "LIVE! | Opening Ceremony | WTT Singapore Smash"}, // Should skip
			{VideoID: "2", VideoTitle: "LIVE! | WTT Singapore Smash | Pre-Show"},         // Should skip
			{VideoID: "3", VideoTitle: "LIVE! | WTT Singapore Smash | Semi-Finals"},      // Should keep
			{VideoID: "4", VideoTitle: "LIVE! | WTT Singapore Smash | Finals & Closing Ceremony"}, // Should keep
			{VideoID: "5", VideoTitle: "LIVE! | Award Ceremony for Finals"},              // Should keep
		},
	}

	// Execute AddNewStreams without an explicit text filter
	count, err := AddNewStreams(queuePath, "dummy_id", fetcher, "", nil)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}

	if count != 3 {
		t.Errorf("Expected 3 videos to be added, got %d", count)
	}

	// Verify the correct ones were saved
	queue, _ := LoadQueue(queuePath)
	if len(queue) != 3 {
		t.Fatalf("Expected 3 videos in queue, got %d", len(queue))
	}

	expectedIDs := []string{"3", "4", "5"}
	assertIDs(t, queue, expectedIDs)
}

// --- Tests for Filtering ProcessQueueVideos ---
func TestProcessQueue_WithFilter_SkipsNonMatching(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	entries := []QueueEntry{
		{VideoID: "1", VideoTitle: "WTT Champions Chongqing 2026 - Match 1"},
		{VideoID: "2", VideoTitle: "WTT Star Contender 2026 - Match 2"},
		{VideoID: "3", VideoTitle: "WTT Champions Chongqing 2026 - Match 3"},
	}
	SaveQueue(queuePath, entries)

	var processedIDs []string
	deps := queueProcessorDeps{
		runDocker: func(outputFile string, args []string) error { return nil },
		importJSON: func(jsonFilePath string) error {
			// Extract video ID from mock json file path to verify which ones ran
			// (processQueueVideos creates matches-<videoID>-<timestamp>.json)
			for _, id := range []string{"1", "2", "3"} {
				if strings.Contains(jsonFilePath, "matches-"+id+"-") {
					processedIDs = append(processedIDs, id)
				}
			}
			return nil
		},
	}

	processFilter := "WTT Champions Chongqing 2026"
	err := processQueueVideosWithDeps(queuePath, deps, []string{}, processFilter)
	if err != nil {
		t.Fatalf("processQueueVideosWithDeps failed: %v", err)
	}

	// Verify that ONLY video 1 and 3 were processed
	if len(processedIDs) != 2 {
		t.Fatalf("Expected 2 videos to be processed, got %d: %v", len(processedIDs), processedIDs)
	}
	// Oldest first! So it processes the end of the array first.
	if processedIDs[0] != "3" || processedIDs[1] != "1" { 
		t.Errorf("Expected videos 3 and 1 to be processed, got %v", processedIDs)
	}

	// Verify that video 2 REMAINS in the queue because it was skipped
	queue, _ := LoadQueue(queuePath)
	if len(queue) != 1 {
		t.Fatalf("Expected 1 video left in queue, got %d", len(queue))
	}
	if queue[0].VideoID != "2" {
		t.Errorf("Expected video 2 to remain in queue, got %s", queue[0].VideoID)
	}
}
