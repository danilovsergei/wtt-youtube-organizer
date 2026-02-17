package matchfinder_cli

import (
	"fmt"
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

// mockLastProcessedDB is a hermetic in-memory database double.
type mockLastProcessedDB struct {
	lastProcessedVideoID    string
	lastProcessedUploadDate string
	updatedVideoID          string
	updateCalled            bool
}

func (m *mockLastProcessedDB) GetLastProcessedVideoID() (string, error) {
	if m.lastProcessedVideoID == "" {
		return "", fmt.Errorf("no last_processed video found")
	}
	return m.lastProcessedVideoID, nil
}

func (m *mockLastProcessedDB) GetLastProcessedUploadDate() (string, error) {
	return m.lastProcessedUploadDate, nil
}

func (m *mockLastProcessedDB) UpdateLastProcessed(youtubeID string) error {
	m.updateCalled = true
	m.updatedVideoID = youtubeID
	return nil
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

// --- Test 1: Queue naming ---

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

// --- Test 1: add_new_streams without video_id creates latest_streams.json ---

func TestAddNewStreams_NoVideoID_CreatesLatestStreams(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("A", "Video A", "20260216"),
			entry("B", "Video B", "20260215"),
		},
	}

	// afterVideoID comes from "last_processed in DB"
	count, err := AddNewStreams(queuePath, "DB_LAST", fetcher)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}
	if count != 2 {
		t.Fatalf("expected 2 new entries, got %d", count)
	}

	// Verify file was created
	queue, err := LoadQueue(queuePath)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}
	assertIDs(t, queue, []string{"A", "B"})

	// Verify fetcher was called with DB last_processed
	if fetcher.calledWithVideoID != "DB_LAST" {
		t.Fatalf("expected fetcher called with DB_LAST, got %s", fetcher.calledWithVideoID)
	}
}

// --- Test 1b: add_new_streams with video_id creates streams_after_<video_id>.json ---

func TestAddNewStreams_WithVideoID_CreatesNamedQueue(t *testing.T) {
	tmpDir := t.TempDir()
	queueName := QueueFileName("xyz789")
	queuePath := filepath.Join(tmpDir, queueName)

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("C", "Video C", "20260214"),
		},
	}

	count, err := AddNewStreams(queuePath, "xyz789", fetcher)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 new entry, got %d", count)
	}

	// Verify file was created with correct name
	if _, err := os.Stat(queuePath); os.IsNotExist(err) {
		t.Fatalf("queue file not created at %s", queuePath)
	}

	// Verify fetcher was called with the provided video_id
	if fetcher.calledWithVideoID != "xyz789" {
		t.Fatalf("expected fetcher called with xyz789, got %s", fetcher.calledWithVideoID)
	}
}

// --- Test 2: empty queue uses provided afterVideoID (from DB) ---

func TestAddNewStreams_EmptyQueue_UsesAfterVideoID(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("NEW1", "New Video 1", "20260216"),
		},
	}

	// Simulate: no queue exists, afterVideoID comes from DB mock
	dbLastProcessed := "DB_VIDEO_ID"
	_, err := AddNewStreams(queuePath, dbLastProcessed, fetcher)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}

	// Fetcher should have been called with the DB last_processed video ID
	if fetcher.calledWithVideoID != "DB_VIDEO_ID" {
		t.Fatalf("expected fetcher called with DB_VIDEO_ID, got %s", fetcher.calledWithVideoID)
	}
}

// --- Test 3: existing queue uses top video ID as cutoff ---

func TestAddNewStreams_ExistingQueue_UsesTopVideoID(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	// Create existing queue with some entries
	existingQueue := []QueueEntry{
		entry("EXISTING_TOP", "Existing Top", "20260214"),
		entry("EXISTING_OLD", "Existing Old", "20260213"),
	}
	if err := SaveQueue(queuePath, existingQueue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("NEWER1", "Newer 1", "20260216"),
			entry("NEWER2", "Newer 2", "20260215"),
		},
	}

	_, err := AddNewStreams(queuePath, "IGNORED_DB_ID", fetcher)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}

	// Fetcher should have been called with top video ID from queue, NOT the DB ID
	if fetcher.calledWithVideoID != "EXISTING_TOP" {
		t.Fatalf("expected fetcher called with EXISTING_TOP, got %s", fetcher.calledWithVideoID)
	}
}

// --- Test 4: new videos prepended to top of queue ---

func TestAddNewStreams_PrependsToTopOfQueue(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	// Existing queue: B (newer), C (older)
	existingQueue := []QueueEntry{
		entry("B", "Video B", "20260215"),
		entry("C", "Video C", "20260214"),
	}
	if err := SaveQueue(queuePath, existingQueue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	// Docker returns A (newest, after B)
	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("A", "Video A", "20260216"),
		},
	}

	count, err := AddNewStreams(queuePath, "", fetcher)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 new entry, got %d", count)
	}

	// Queue should be: A (newest, top), B, C (oldest, bottom)
	queue, err := LoadQueue(queuePath)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}
	assertIDs(t, queue, []string{"A", "B", "C"})
}

// --- Test 5: last_processed update logic ---

func TestShouldUpdateLastProcessed_FresherDate(t *testing.T) {
	// Video date is fresher than DB date
	if !ShouldUpdateLastProcessed("20260216", "20260215") {
		t.Fatal("expected true: video date is fresher")
	}
}

func TestShouldUpdateLastProcessed_SameDate(t *testing.T) {
	// Video date equals DB date
	if !ShouldUpdateLastProcessed("20260215", "20260215") {
		t.Fatal("expected true: video date equals DB date")
	}
}

func TestShouldUpdateLastProcessed_OlderDate(t *testing.T) {
	// Video date is older than DB date
	if ShouldUpdateLastProcessed("20260214", "20260215") {
		t.Fatal("expected false: video date is older")
	}
}

func TestShouldUpdateLastProcessed_EmptyDBDate(t *testing.T) {
	// No last_processed in DB
	if !ShouldUpdateLastProcessed("20260214", "") {
		t.Fatal("expected true: empty DB date should always update")
	}
}

// --- Test: PrependToQueue ---

func TestPrependToQueue_Basic(t *testing.T) {
	existing := []QueueEntry{
		entry("B", "Video B", "20260215"),
		entry("C", "Video C", "20260214"),
	}
	newEntries := []QueueEntry{
		entry("A", "Video A", "20260216"),
	}

	result := PrependToQueue(existing, newEntries)
	assertIDs(t, result, []string{"A", "B", "C"})
}

func TestPrependToQueue_EmptyNew(t *testing.T) {
	existing := []QueueEntry{entry("A", "Video A", "20260216")}
	result := PrependToQueue(existing, nil)
	assertIDs(t, result, []string{"A"})
}

func TestPrependToQueue_EmptyExisting(t *testing.T) {
	newEntries := []QueueEntry{entry("A", "Video A", "20260216")}
	result := PrependToQueue(nil, newEntries)
	assertIDs(t, result, []string{"A"})
}

// --- Test: RemoveLastEntry ---

func TestRemoveLastEntry_Basic(t *testing.T) {
	queue := []QueueEntry{
		entry("A", "Video A", "20260216"),
		entry("B", "Video B", "20260215"),
		entry("C", "Video C", "20260214"),
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
		entry("A", "Video A", "20260216"),
		entry("B", "Video B", "20260215"),
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
		entry("A", "Video A", "20260216"),
		entry("B", "Video B", "20260215"),
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

// --- Test 5: last_processed update called once, only if date is fresh enough ---

func TestLastProcessedUpdate_CalledOnceWhenFresher(t *testing.T) {
	db := &mockLastProcessedDB{
		lastProcessedVideoID:    "OLD_VIDEO",
		lastProcessedUploadDate: "20260210",
	}

	// Simulate processing a queue where top entry has fresher date
	topEntry := entry("NEW_TOP", "Newest Video", "20260216")

	// Check condition
	dbDate, _ := db.GetLastProcessedUploadDate()
	if !ShouldUpdateLastProcessed(topEntry.UploadDate, dbDate) {
		t.Fatal("expected ShouldUpdateLastProcessed=true for fresher date")
	}

	// Simulate the update
	if err := db.UpdateLastProcessed(topEntry.VideoID); err != nil {
		t.Fatalf("UpdateLastProcessed failed: %v", err)
	}

	// Verify it was called exactly once with the correct video ID
	if !db.updateCalled {
		t.Fatal("expected UpdateLastProcessed to be called")
	}
	if db.updatedVideoID != "NEW_TOP" {
		t.Fatalf("expected updated video ID NEW_TOP, got %s", db.updatedVideoID)
	}
}

func TestLastProcessedUpdate_NotCalledWhenOlder(t *testing.T) {
	db := &mockLastProcessedDB{
		lastProcessedVideoID:    "CURRENT_VIDEO",
		lastProcessedUploadDate: "20260220", // DB has newer date
	}

	// Top entry has older date
	topEntry := entry("OLD_TOP", "Older Video", "20260210")

	// Check condition - should NOT update
	dbDate, _ := db.GetLastProcessedUploadDate()
	if ShouldUpdateLastProcessed(topEntry.UploadDate, dbDate) {
		t.Fatal("expected ShouldUpdateLastProcessed=false for older date")
	}

	// UpdateLastProcessed should NOT be called
	if db.updateCalled {
		t.Fatal("expected UpdateLastProcessed to NOT be called")
	}
}

func TestLastProcessedUpdate_CalledWhenSameDate(t *testing.T) {
	db := &mockLastProcessedDB{
		lastProcessedVideoID:    "SAME_DATE_VIDEO",
		lastProcessedUploadDate: "20260215",
	}

	topEntry := entry("NEW_TOP", "Same Date Video", "20260215")

	dbDate, _ := db.GetLastProcessedUploadDate()
	if !ShouldUpdateLastProcessed(topEntry.UploadDate, dbDate) {
		t.Fatal("expected ShouldUpdateLastProcessed=true for same date")
	}

	if err := db.UpdateLastProcessed(topEntry.VideoID); err != nil {
		t.Fatalf("UpdateLastProcessed failed: %v", err)
	}
	if db.updatedVideoID != "NEW_TOP" {
		t.Fatalf("expected updated video ID NEW_TOP, got %s", db.updatedVideoID)
	}
}

func TestLastProcessedUpdate_CalledWhenDBEmpty(t *testing.T) {
	db := &mockLastProcessedDB{
		lastProcessedVideoID:    "",
		lastProcessedUploadDate: "", // No last_processed in DB
	}

	topEntry := entry("FIRST_VIDEO", "First Video", "20260210")

	dbDate, _ := db.GetLastProcessedUploadDate()
	if !ShouldUpdateLastProcessed(topEntry.UploadDate, dbDate) {
		t.Fatal("expected ShouldUpdateLastProcessed=true when DB is empty")
	}

	if err := db.UpdateLastProcessed(topEntry.VideoID); err != nil {
		t.Fatalf("UpdateLastProcessed failed: %v", err)
	}
	if db.updatedVideoID != "FIRST_VIDEO" {
		t.Fatalf("expected updated video ID FIRST_VIDEO, got %s", db.updatedVideoID)
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
		entry("A", "Video A", "20260216"),
		entry("B", "Video B", "20260215"),
		entry("C", "Video C", "20260214"),
	}

	checker := &mockProcessedChecker{
		processedIDs: map[string]bool{"B": true}, // B is already in DB
	}

	filtered, err := FilterUnprocessed(entries, checker)
	if err != nil {
		t.Fatalf("FilterUnprocessed failed: %v", err)
	}

	// B should be filtered out, A and C remain
	assertIDs(t, filtered, []string{"A", "C"})
}

func TestFilterUnprocessed_AllProcessed(t *testing.T) {
	entries := []QueueEntry{
		entry("A", "Video A", "20260216"),
		entry("B", "Video B", "20260215"),
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
		entry("A", "Video A", "20260216"),
		entry("B", "Video B", "20260215"),
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

// --- Test: AddNewStreams with checker filters processed videos ---

func TestAddNewStreams_WithChecker_FiltersProcessed(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "streams_after_xyz.json")

	// Docker returns 3 videos
	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("A", "Video A", "20260216"),
			entry("B", "Video B", "20260215"),
			entry("C", "Video C", "20260214"),
		},
	}

	// B is already in the database
	checker := &mockProcessedChecker{
		processedIDs: map[string]bool{"B": true},
	}

	count, err := AddNewStreams(queuePath, "xyz", fetcher, checker)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}

	// Only 2 should be added (A and C, not B)
	if count != 2 {
		t.Fatalf("expected 2 new entries, got %d", count)
	}

	queue, err := LoadQueue(queuePath)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}

	// Queue should contain A and C only
	assertIDs(t, queue, []string{"A", "C"})
}

func TestAddNewStreams_WithChecker_AllProcessed_NothingAdded(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "streams_after_xyz.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("A", "Video A", "20260216"),
			entry("B", "Video B", "20260215"),
		},
	}

	// All already processed
	checker := &mockProcessedChecker{
		processedIDs: map[string]bool{"A": true, "B": true},
	}

	count, err := AddNewStreams(queuePath, "xyz", fetcher, checker)
	if err != nil {
		t.Fatalf("AddNewStreams failed: %v", err)
	}
	if count != 0 {
		t.Fatalf("expected 0 new entries, got %d", count)
	}

	// Queue file should not be created
	if _, err := os.Stat(queuePath); !os.IsNotExist(err) {
		t.Fatal("queue file should not exist when all videos already processed")
	}
}

func TestAddNewStreams_WithoutChecker_NoFiltering(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{
			entry("A", "Video A", "20260216"),
			entry("B", "Video B", "20260215"),
		},
	}

	// No checker passed - all videos should be added
	count, err := AddNewStreams(queuePath, "DB_LAST", fetcher)
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

// --- Test: AddNewStreams with no new results ---

func TestAddNewStreams_NoNewStreams(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "latest_streams.json")

	fetcher := &mockStreamFetcher{
		returnEntries: []QueueEntry{}, // nothing new
	}

	count, err := AddNewStreams(queuePath, "SOME_ID", fetcher)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if count != 0 {
		t.Fatalf("expected 0 new entries, got %d", count)
	}

	// Queue file should not be created
	if _, err := os.Stat(queuePath); !os.IsNotExist(err) {
		t.Fatal("queue file should not exist when no streams found")
	}
}
