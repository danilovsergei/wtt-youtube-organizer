package matchfinder_cli

import (
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestDockerRunExitCodePropagation(t *testing.T) {
	// Simulate docker run exiting with code 2
	mockRunDocker := func(outputFile string, containerArgs []string) error {
		cmd := exec.Command("sh", "-c", "exit 2")
		return cmd.Run()
	}

	fetcher := &dockerStreamFetcher{
		extraArgs: []string{},
		runDocker: mockRunDocker,
	}

	_, err := fetcher.FetchStreamsAfter("DELETED_VID")
	if err == nil {
		t.Fatalf("expected error, got nil")
	}

	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("expected *exec.ExitError, got %T", err)
	}

	if exitErr.ExitCode() != 2 {
		t.Fatalf("expected exit code 2, got %d", exitErr.ExitCode())
	}
}

type mockFallbackFetcher struct {
	calledWithVideoIDs []string
	results            map[string][]QueueEntry
	errors             map[string]error
}

func (m *mockFallbackFetcher) FetchStreamsAfter(videoID string) ([]QueueEntry, error) {
	m.calledWithVideoIDs = append(m.calledWithVideoIDs, videoID)
	if err, exists := m.errors[videoID]; exists && err != nil {
		return nil, err
	}
	if res, exists := m.results[videoID]; exists {
		return res, nil
	}
	return []QueueEntry{}, nil
}

// TestAddNewStreamsWithFallback_PurgesDeadVideoAndTriesNextCandidate tests that when the top
// video in existingQueue fails with exit code 2 (unavailable), it is removed from the queue
// and the next candidate video is attempted.
func TestAddNewStreamsWithFallback_PurgesDeadVideoAndTriesNextCandidate(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	initialQueue := []QueueEntry{
		entry("DEAD_TOP", "Dead Video", "1771200000"),
		entry("ALIVE_OLDER", "Alive Older Video", "1771100000"),
	}
	if err := SaveQueue(queuePath, initialQueue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	// Exit code 2 error
	exitCode2Err := exec.Command("sh", "-c", "exit 2").Run()

	fetcher := &mockFallbackFetcher{
		errors: map[string]error{
			"DEAD_TOP": exitCode2Err,
		},
		results: map[string][]QueueEntry{
			"ALIVE_OLDER": {
				entry("NEW_STREAM_1", "New Stream 1", "1771300000"),
			},
		},
	}

	candidates := []string{"DEAD_TOP", "ALIVE_OLDER", "DB_FALLBACK"}
	count, err := AddNewStreamsWithFallback(queuePath, candidates, fetcher, "")
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 new stream added, got %d", count)
	}

	// Verify DEAD_TOP was removed from the queue file, and NEW_STREAM_1 was prepended
	updatedQueue, err := LoadQueue(queuePath)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}

	expectedIDs := []string{"NEW_STREAM_1", "ALIVE_OLDER"}
	if len(updatedQueue) != len(expectedIDs) {
		t.Fatalf("expected %d entries, got %d: %+v", len(expectedIDs), len(updatedQueue), updatedQueue)
	}
	for i, expectedID := range expectedIDs {
		if updatedQueue[i].VideoID != expectedID {
			t.Errorf("expected queue[%d]=%s, got %s", i, expectedID, updatedQueue[i].VideoID)
		}
	}
}

// TestAddNewStreamsWithFallback_QueueAllDead_FallsBackToDatabaseCandidates tests that when all
// videos in the queue are dead, they are all purged, and the cutoff falls back to database IDs.
func TestAddNewStreamsWithFallback_QueueAllDead_FallsBackToDatabaseCandidates(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	initialQueue := []QueueEntry{
		entry("DEAD_ONLY", "Only Dead Video", "1771200000"),
	}
	if err := SaveQueue(queuePath, initialQueue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	exitCode2Err := exec.Command("sh", "-c", "exit 2").Run()

	fetcher := &mockFallbackFetcher{
		errors: map[string]error{
			"DEAD_ONLY": exitCode2Err,
		},
		results: map[string][]QueueEntry{
			"DB_FALLBACK": {
				entry("NEW_STREAM_DB", "New Stream from DB cutoff", "1771400000"),
			},
		},
	}

	candidates := []string{"DEAD_ONLY", "DB_FALLBACK"}
	count, err := AddNewStreamsWithFallback(queuePath, candidates, fetcher, "")
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 new stream added, got %d", count)
	}

	updatedQueue, _ := LoadQueue(queuePath)
	if len(updatedQueue) != 1 || updatedQueue[0].VideoID != "NEW_STREAM_DB" {
		t.Fatalf("expected queue to contain only NEW_STREAM_DB, got: %+v", updatedQueue)
	}
}

// TestAddNewStreamsWithFallback_NonCode2ErrorDoesNotPurge tests that general transient errors
// (e.g. exit code 1 or network failure) do not purge the video from the queue.
func TestAddNewStreamsWithFallback_NonCode2ErrorDoesNotPurge(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	initialQueue := []QueueEntry{
		entry("TOP_VID", "Top Video", "1771200000"),
	}
	if err := SaveQueue(queuePath, initialQueue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	transientErr := fmt.Errorf("connection timeout: exit status 1")

	fetcher := &mockFallbackFetcher{
		errors: map[string]error{
			"TOP_VID": transientErr,
		},
	}

	candidates := []string{"TOP_VID", "BACKUP_VID"}
	_, err := AddNewStreamsWithFallback(queuePath, candidates, fetcher, "")
	if err == nil {
		t.Fatalf("expected error, got nil")
	}

	// TOP_VID must NOT be purged from the queue
	remainingQueue, _ := LoadQueue(queuePath)
	if len(remainingQueue) != 1 || remainingQueue[0].VideoID != "TOP_VID" {
		t.Fatalf("expected TOP_VID to remain in queue on transient error, got: %+v", remainingQueue)
	}
}

// TestProcessQueue_RemovesUnavailableVideo_ExitCode2 tests that when docker exits with code 2
// during --process, the unavailable video is removed from the queue rather than retried.
func TestProcessQueue_RemovesUnavailableVideo_ExitCode2(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	queue := []QueueEntry{
		entry("DEAD_EXIT2", "Dead Video", "1771200000"),
		entry("ALIVE_VID", "Alive Video", "1771113600"),
	}
	if err := SaveQueue(queuePath, queue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	exitCode2Err := exec.Command("sh", "-c", "exit 2").Run()

	deps := queueProcessorDeps{
		runDocker: func(outputFile string, containerArgs []string) error {
			for _, arg := range containerArgs {
				if arg == "--youtube_video=https://www.youtube.com/watch?v=DEAD_EXIT2" {
					return exitCode2Err
				}
			}
			return nil
		},
		importJSON: func(jsonFilePath string) error {
			return nil
		},
	}

	err := processQueueVideosWithDeps(queuePath, deps, nil, "")
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}

	remaining, _ := LoadQueue(queuePath)
	if len(remaining) != 0 {
		t.Fatalf("expected 0 entries (DEAD_EXIT2 removed as exit code 2, ALIVE_VID processed), got %d: %+v", len(remaining), remaining)
	}
}
