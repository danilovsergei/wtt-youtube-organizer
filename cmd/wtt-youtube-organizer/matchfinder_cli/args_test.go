package matchfinder_cli

import (
	"reflect"
	"testing"
	"os"
)

func TestBuildContainerArgs_NoCuda(t *testing.T) {
	// If cudaDeviceID is < 0 (the default -1), no args should be added
	args := buildContainerArgs(-1)
	if len(args) != 0 {
		t.Errorf("Expected 0 args for cudaDeviceID=-1, got %d: %v", len(args), args)
	}
}

func TestBuildContainerArgs_WithCuda(t *testing.T) {
	// If cudaDeviceID >= 0, it should append the flags
	// NOTE: getCudaDeviceName(1) might return "" in tests depending on the environment,
	// so we mainly verify that "--cuda_device_id" and "1" are present.
	args := buildContainerArgs(1)
	
	if len(args) < 2 {
		t.Fatalf("Expected at least 2 args for cudaDeviceID=1, got %d: %v", len(args), args)
	}
	
	if args[0] != "--cuda_device_id" || args[1] != "1" {
		t.Errorf("Expected ['--cuda_device_id', '1'], got %v", args)
	}
}

func TestGetProvidedVideoID_Empty(t *testing.T) {
	// If extraArgs is empty, no video ID should be returned
	extraArgs := []string{}
	vid := getProvidedVideoID(extraArgs)
	if vid != "" {
		t.Errorf("Expected empty video ID for empty extraArgs, got '%s'", vid)
	}
}

func TestGetProvidedVideoID_Provided(t *testing.T) {
	// If extraArgs contains positional args from cobra, it should return the first one
	extraArgs := []string{"tJMjCRO8t94"}
	vid := getProvidedVideoID(extraArgs)
	if vid != "tJMjCRO8t94" {
		t.Errorf("Expected 'tJMjCRO8t94', got '%s'", vid)
	}
}

func TestContainerArgsSeparation_BugRegression(t *testing.T) {
	// This specifically tests the regression that broke --add_new_streams.
	// Cobra passes us the exact un-parsed positional arguments.
	// If the user runs `matchfinder --add_new_streams --cuda_device_id 1`, 
	// Cobra will process the flags and pass us empty positional arguments!
	cobraPositionalArgs := []string{}
	
	// We simulate extracting the video ID from what Cobra gave us
	vid := getProvidedVideoID(cobraPositionalArgs)
	if vid != "" {
		t.Errorf("Regression: providedVideoID should be empty, but got '%s'", vid)
	}
	
	// We simulate building the internal container arguments from the global flags
	containerArgs := buildContainerArgs(1)
	if len(containerArgs) < 2 || containerArgs[0] != "--cuda_device_id" || containerArgs[1] != "1" {
		t.Errorf("Regression: containerArgs should contain CUDA flags independently")
	}
	
	// We verify that the original positional arguments are completely unmodified
	if len(cobraPositionalArgs) != 0 {
		t.Errorf("Regression: cobraPositionalArgs slice was modified!")
	}
	
	// Ensure that appending them together (as runDockerContainer does) works
	finalArgs := append(cobraPositionalArgs, containerArgs...)
	expected := []string{"--cuda_device_id", "1"}
	
	// We check the prefix because getCudaDeviceName might append more
	if !reflect.DeepEqual(finalArgs[:2], expected) {
		t.Errorf("Expected final args to start with %v, got %v", expected, finalArgs)
	}
}

func TestHyphenatedVideoID_AddNewStreams(t *testing.T) {
	// This tests a regression where video IDs starting with hyphens (e.g. "-8NJu5XO23U")
	// were interpreted by Python's argparse as command line flags instead of values.
	
	var capturedArgs []string
	
	fetcher := &dockerStreamFetcher{
		extraArgs: []string{},
		runDocker: func(outputFile string, args []string) error {
			capturedArgs = args
			// Write empty JSON to satisfy the Go JSON parser
			return os.WriteFile(outputFile, []byte("[]"), 0644)
		},
	}
	
	_, err := fetcher.FetchStreamsAfter("-8NJu5XO23U")
	if err != nil {
		t.Fatalf("FetchStreamsAfter failed: %v", err)
	}
	
	// Assert the arguments use the "=" syntax
	foundCorrectSyntax := false
	for _, arg := range capturedArgs {
		if arg == "--process_all_matches_after=-8NJu5XO23U" {
			foundCorrectSyntax = true
		}
		if arg == "--process_all_matches_after" {
			t.Errorf("Found separated flag '--process_all_matches_after', which breaks Python argparse for hyphenated IDs!")
		}
	}
	
	if !foundCorrectSyntax {
		t.Errorf("Expected to find '--process_all_matches_after=-8NJu5XO23U' in args, got: %v", capturedArgs)
	}
}

func TestHyphenatedVideoID_ProcessQueue(t *testing.T) {
	// This tests the same regression but for the --process command
	
	queueFile, err := os.CreateTemp("", "hyphen_queue_*.json")
	if err != nil {
		t.Fatalf("failed to create temp queue file: %v", err)
	}
	defer os.Remove(queueFile.Name())

	entries := []QueueEntry{
		{
			VideoID:    "-8NJu5XO23U",
			VideoTitle: "Test Hyphen Video",
			UploadDate: "2026-01-01",
		},
	}
	
	if err := SaveQueue(queueFile.Name(), entries); err != nil {
		t.Fatalf("failed to save temp queue: %v", err)
	}

	var capturedArgs []string
	deps := queueProcessorDeps{
		runDocker: func(outputFile string, args []string) error {
			capturedArgs = args
			// Write a dummy result to satisfy the Go JSON importer
			dummyResult := `{"video_id": "-8NJu5XO23U", "matches": []}`
			return os.WriteFile(outputFile, []byte(dummyResult), 0644)
		},
		importJSON: func(jsonFilePath string) error {
			return nil
		},
	}

	err = processQueueVideosWithDeps(queueFile.Name(), deps, []string{})
	if err != nil {
		t.Fatalf("processQueueVideosWithDeps failed: %v", err)
	}

	// Assert the arguments use the "=" syntax
	foundCorrectSyntax := false
	for _, arg := range capturedArgs {
		if arg == "--youtube_video=https://www.youtube.com/watch?v=-8NJu5XO23U" {
			foundCorrectSyntax = true
		}
		if arg == "--youtube_video" {
			t.Errorf("Found separated flag '--youtube_video', which breaks Python argparse for hyphenated URLs/IDs!")
		}
	}
	
	if !foundCorrectSyntax {
		t.Errorf("Expected to find '--youtube_video=https://www.youtube.com/watch?v=-8NJu5XO23U' in args, got: %v", capturedArgs)
	}
}
