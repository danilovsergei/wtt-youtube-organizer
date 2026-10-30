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

// TestAddNewStreamsWithFallback_BotConfirmationErrorDoesNotPurge tests that when yt-dlp returns
// "Sign in to confirm you’re not a bot", the candidate video is NOT purged from the queue.
func TestAddNewStreamsWithFallback_BotConfirmationErrorDoesNotPurge(t *testing.T) {
        tmpDir := t.TempDir()
        queuePath := filepath.Join(tmpDir, "test_queue.json")

        initialQueue := []QueueEntry{
                entry("BOT_CHALLENGED_VID", "Valid Stream", "1771200000"),
        }
        if err := SaveQueue(queuePath, initialQueue); err != nil {
                t.Fatalf("SaveQueue failed: %v", err)
        }

        botErr := fmt.Errorf("ERROR: [youtube] BOT_CHALLENGED_VID: Sign in to confirm you’re not a bot. Use --cookies-from-browser")

        fetcher := &mockFallbackFetcher{
                errors: map[string]error{
                        "BOT_CHALLENGED_VID": botErr,
                },
        }

        candidates := []string{"BOT_CHALLENGED_VID"}
        _, err := AddNewStreamsWithFallback(queuePath, candidates, fetcher, "")
        if err == nil {
                t.Fatalf("expected error, got nil")
        }

        // BOT_CHALLENGED_VID must NOT be purged from the queue
        remainingQueue, _ := LoadQueue(queuePath)
        if len(remainingQueue) != 1 || remainingQueue[0].VideoID != "BOT_CHALLENGED_VID" {
                t.Fatalf("expected BOT_CHALLENGED_VID to remain in queue, got: %+v", remainingQueue)
        }
}

// TestProcessQueue_BotConfirmationErrorKeepsVideoInQueue tests that when yt-dlp encounters
// a bot challenge during processQueueVideos, the video is kept in the queue for retry instead of being deleted.
func TestProcessQueue_BotConfirmationErrorKeepsVideoInQueue(t *testing.T) {
        tmpDir := t.TempDir()
        queuePath := filepath.Join(tmpDir, "test_queue.json")

        queue := []QueueEntry{
                entry("BOT_VID", "Challenged Video", "1771200000"),
        }
        if err := SaveQueue(queuePath, queue); err != nil {
                t.Fatalf("SaveQueue failed: %v", err)
        }

        deps := queueProcessorDeps{
                runDocker: func(outputFile string, containerArgs []string) error {
                        return fmt.Errorf("ERROR: [youtube] BOT_VID: Sign in to confirm you’re not a bot.")
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
        if len(remaining) != 1 || remaining[0].VideoID != "BOT_VID" {
                t.Fatalf("expected BOT_VID to remain in queue for retry, got: %+v", remaining)
        }
}

// TestAddNewStreamsWithFallback_ExitCode1_RetainsVideoInQueueAndTriesNextCandidate tests that
// when a video fails with exit code 1 (live event processing / temporary error), it is NOT
// purged from the queue, and AddNewStreamsWithFallback continues to the next fallback candidate.
func TestAddNewStreamsWithFallback_ExitCode1_RetainsVideoInQueueAndTriesNextCandidate(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	initialQueue := []QueueEntry{
		entry("RETRYABLE_TOP", "Processing Live Stream", "1771200000"),
	}
	if err := SaveQueue(queuePath, initialQueue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	exitCode1Err := exec.Command("sh", "-c", "exit 1").Run()

	fetcher := &mockFallbackFetcher{
		errors: map[string]error{
			"RETRYABLE_TOP": exitCode1Err,
		},
		results: map[string][]QueueEntry{
			"FALLBACK_DB_ID": {
				entry("NEW_STREAM_UNBLOCKED", "New Stream Discovered", "1771300000"),
			},
		},
	}

	candidates := []string{"RETRYABLE_TOP", "FALLBACK_DB_ID"}
	count, err := AddNewStreamsWithFallback(queuePath, candidates, fetcher, "")
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 new stream added, got %d", count)
	}

	// Verify both candidates were attempted in order
	if len(fetcher.calledWithVideoIDs) != 2 ||
		fetcher.calledWithVideoIDs[0] != "RETRYABLE_TOP" ||
		fetcher.calledWithVideoIDs[1] != "FALLBACK_DB_ID" {
		t.Fatalf("expected fetcher called with [RETRYABLE_TOP, FALLBACK_DB_ID], got %v", fetcher.calledWithVideoIDs)
	}

	// Verify RETRYABLE_TOP was RETAINED in queue, and NEW_STREAM_UNBLOCKED was prepended to the top
	updatedQueue, err := LoadQueue(queuePath)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}

	expectedIDs := []string{"NEW_STREAM_UNBLOCKED", "RETRYABLE_TOP"}
	if len(updatedQueue) != len(expectedIDs) {
		t.Fatalf("expected %d entries, got %d: %+v", len(expectedIDs), len(updatedQueue), updatedQueue)
	}
	for i, expectedID := range expectedIDs {
		if updatedQueue[i].VideoID != expectedID {
			t.Errorf("expected queue[%d]=%s, got %s", i, expectedID, updatedQueue[i].VideoID)
		}
	}
}

// TestAddNewStreamsWithFallback_ExitCode1_AllRetryable_RetainsAllInQueueAndReturnsError tests
// that when all candidates fail with exit code 1, none are purged, and the error is returned.
func TestAddNewStreamsWithFallback_ExitCode1_AllRetryable_RetainsAllInQueueAndReturnsError(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	initialQueue := []QueueEntry{
		entry("RETRYABLE_1", "Processing Live Stream 1", "1771200000"),
		entry("RETRYABLE_2", "Processing Live Stream 2", "1771100000"),
	}
	if err := SaveQueue(queuePath, initialQueue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	exitCode1Err := exec.Command("sh", "-c", "exit 1").Run()

	fetcher := &mockFallbackFetcher{
		errors: map[string]error{
			"RETRYABLE_1": exitCode1Err,
			"RETRYABLE_2": exitCode1Err,
		},
	}

	candidates := []string{"RETRYABLE_1", "RETRYABLE_2"}
	count, err := AddNewStreamsWithFallback(queuePath, candidates, fetcher, "")
	if err == nil {
		t.Fatalf("expected error when all candidates fail with exit code 1, got nil (count=%d)", count)
	}

	// Verify neither candidate was purged from the queue
	remainingQueue, err := LoadQueue(queuePath)
	if err != nil {
		t.Fatalf("LoadQueue failed: %v", err)
	}
	if len(remainingQueue) != 2 ||
		remainingQueue[0].VideoID != "RETRYABLE_1" ||
		remainingQueue[1].VideoID != "RETRYABLE_2" {
		t.Fatalf("expected both retryable videos to remain in queue, got: %+v", remainingQueue)
	}
}

// TestAddNewStreamsWithCutoff_UsesExplicitCutoffEvenIfQueueHasEntries tests that AddNewStreamsWithCutoff
// always queries the exact requested cutoff video ID rather than overriding it with queue[0].VideoID.
func TestAddNewStreamsWithCutoff_UsesExplicitCutoffEvenIfQueueHasEntries(t *testing.T) {
	tmpDir := t.TempDir()
	queuePath := filepath.Join(tmpDir, "test_queue.json")

	initialQueue := []QueueEntry{
		entry("EXISTING_TOP", "Top Entry", "1771200000"),
	}
	if err := SaveQueue(queuePath, initialQueue); err != nil {
		t.Fatalf("SaveQueue failed: %v", err)
	}

	fetcher := &mockFallbackFetcher{
		results: map[string][]QueueEntry{
			"FALLBACK_CANDIDATE": {
				entry("DISCOVERED_STREAM", "Discovered Stream", "1771300000"),
			},
		},
	}

	count, err := AddNewStreamsWithCutoff(queuePath, "FALLBACK_CANDIDATE", fetcher, "")
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 new stream added, got %d", count)
	}

	if len(fetcher.calledWithVideoIDs) != 1 || fetcher.calledWithVideoIDs[0] != "FALLBACK_CANDIDATE" {
		t.Fatalf("expected fetcher called with FALLBACK_CANDIDATE, got %v", fetcher.calledWithVideoIDs)
	}

	updatedQueue, _ := LoadQueue(queuePath)
	if len(updatedQueue) != 2 || updatedQueue[0].VideoID != "DISCOVERED_STREAM" || updatedQueue[1].VideoID != "EXISTING_TOP" {
		t.Fatalf("unexpected updated queue: %+v", updatedQueue)
	}
}
