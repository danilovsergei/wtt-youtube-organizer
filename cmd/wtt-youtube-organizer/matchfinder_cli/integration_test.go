package matchfinder_cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// getGoldenDataset returns the path to the golden JSON on the host.
func getGoldenDataset(t *testing.T) string {
	srcPath := filepath.Join(getProjectRoot(), "florence_extractor", "testing", "frames_hJXfBULLDro", "hJXfBULLDro_golden.json")
	if _, err := os.Stat(srcPath); os.IsNotExist(err) {
		t.Fatalf("Golden dataset not found at %s. Cannot run integration test.", srcPath)
	}
	return srcPath
}

// injectGoldenToDocker intercepts the docker run call, copies the golden dataset
// into the output directory (which gets mounted as /output in the container),
// and dynamically modifies the containerArgs to pass the internal path.
func injectGoldenToDocker(outputFile string, containerArgs []string, hostGoldenPath string) error {
	outputDir := filepath.Dir(outputFile)
	destGolden := filepath.Join(outputDir, "hJXfBULLDro_golden.json")
	
	data, err := os.ReadFile(hostGoldenPath)
	if err != nil {
		return err
	}
	
	if err := os.WriteFile(destGolden, data, 0666); err != nil {
		return err
	}
	

	// Add the container-relative path to the arguments
	containerArgs = append(containerArgs, "--test_golden_dataset", "/output/hJXfBULLDro_golden.json")
	
	fmt.Printf("DEBUG INJECTED CONTAINER ARGS: %v\n", containerArgs)

	
	return runDockerContainer(outputFile, containerArgs)
}

func TestIntegration_AddNewStreams(t *testing.T) {
	if os.Getenv("SKIP_DOCKER_TESTS") == "1" {
		t.Skip("Skipping Docker integration test because SKIP_DOCKER_TESTS=1")
	}

	goldenPath := getGoldenDataset(t)
	dockerDir = "docker/cuda"
	imageName = "geonix/wtt-stream-match-finder-cuda:latest"
	
	fetcher := &dockerStreamFetcher{
		extraArgs: []string{},
		runDocker: func(outputFile string, args []string) error {
			return injectGoldenToDocker(outputFile, args, goldenPath)
		},
	}
	
	videos, err := fetcher.FetchStreamsAfter("dummy_id")
	if err != nil {
		t.Fatalf("dockerStreamFetcher failed to fetch streams: %v", err)
	}
	
	if len(videos) == 0 {
		t.Fatalf("Expected at least 1 video from the golden TestWttVideoProcessor, got 0")
	}
	
	if videos[0].VideoID != "hJXfBULLDro" {
		t.Errorf("Expected video ID 'hJXfBULLDro', got '%s'", videos[0].VideoID)
	}
}

func TestIntegration_ProcessQueue(t *testing.T) {
	if os.Getenv("SKIP_DOCKER_TESTS") == "1" {
		t.Skip("Skipping Docker integration test because SKIP_DOCKER_TESTS=1")
	}

	goldenPath := getGoldenDataset(t)
	dockerDir = "docker/cuda"
	imageName = "geonix/wtt-stream-match-finder-cuda:latest"

	queueFile, err := os.CreateTemp("", "integration_queue_*.json")
	if err != nil {
		t.Fatalf("failed to create temp queue file: %v", err)
	}
	defer os.Remove(queueFile.Name())

	entries := []QueueEntry{
		{
			VideoID:    "hJXfBULLDro",
			VideoTitle: "Test Integration Video",
			UploadDate: "2026-01-01",
		},
	}
	
	if err := SaveQueue(queueFile.Name(), entries); err != nil {
		t.Fatalf("failed to save temp queue: %v", err)
	}

	var importedJSONPath string
	mockImport := func(jsonFilePath string) error {
		importedJSONPath = jsonFilePath
		return nil
	}

	deps := queueProcessorDeps{
		runDocker: func(outputFile string, args []string) error {
			return injectGoldenToDocker(outputFile, args, goldenPath)
		},
		importJSON: mockImport,
	}

	err = processQueueVideosWithDeps(queueFile.Name(),  deps,  []string{}, "")
	if err != nil {
		t.Fatalf("processQueueVideosWithDeps failed: %v", err)
	}

	if importedJSONPath == "" {
		t.Fatalf("importJSON was never called, meaning the Docker container failed to run or process the video")
	}

	data, err := os.ReadFile(importedJSONPath)
	if err != nil {
		t.Fatalf("failed to read imported JSON file: %v", err)
	}

	var result struct {
		VideoID string `json:"video_id"`
		Matches []struct {
			Timestamp int    `json:"timestamp"`
			Player1   string `json:"player1"`
			Player2   string `json:"player2"`
		} `json:"matches"`
	}

	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatalf("failed to unmarshal output JSON: %v", err)
	}

	if len(result.Matches) != 2 {
		t.Fatalf("Expected exactly 2 matches, got %d", len(result.Matches))
	}
	
	if result.Matches[0].Player1 != "SUN YINGSHA" || result.Matches[0].Player2 != "WANG MANYU" {
		t.Errorf("Match 1 players incorrect: %s vs %s", result.Matches[0].Player1, result.Matches[0].Player2)
	}
	
	if result.Matches[1].Player1 != "WANG CHUQIN" || result.Matches[1].Player2 != "LIN YUN-JU" {
		t.Errorf("Match 2 players incorrect: %s vs %s", result.Matches[1].Player1, result.Matches[1].Player2)
	}
}
func TestIntegration_AddNewStreams_OpenVINO(t *testing.T) {
	if os.Getenv("SKIP_DOCKER_TESTS") == "1" {
		t.Skip("Skipping Docker integration test because SKIP_DOCKER_TESTS=1")
	}

	goldenPath := getGoldenDataset(t)
	dockerDir = "docker/openvino"
	imageName = "wtt-stream-match-finder-openvino:latest"
	os.Setenv("FORCE_OPENVINO", "1")
	defer os.Unsetenv("FORCE_OPENVINO")
	
	fetcher := &dockerStreamFetcher{
		extraArgs: []string{},
		runDocker: func(outputFile string, args []string) error {
			return injectGoldenToDocker(outputFile, args, goldenPath)
		},
	}
	
	videos, err := fetcher.FetchStreamsAfter("dummy_id")
	if err != nil {
		t.Fatalf("dockerStreamFetcher failed to fetch streams: %v", err)
	}
	
	if len(videos) == 0 {
		t.Fatalf("Expected at least 1 video from the golden TestWttVideoProcessor, got 0")
	}
	
	if videos[0].VideoID != "hJXfBULLDro" {
		t.Errorf("Expected video ID 'hJXfBULLDro', got '%s'", videos[0].VideoID)
	}
}

func TestIntegration_ProcessQueue_OpenVINO(t *testing.T) {
	if os.Getenv("SKIP_DOCKER_TESTS") == "1" {
		t.Skip("Skipping Docker integration test because SKIP_DOCKER_TESTS=1")
	}

	goldenPath := getGoldenDataset(t)
	dockerDir = "docker/openvino"
	imageName = "wtt-stream-match-finder-openvino:latest"
	os.Setenv("FORCE_OPENVINO", "1")
	defer os.Unsetenv("FORCE_OPENVINO")

	queueFile, err := os.CreateTemp("", "integration_queue_*.json")
	if err != nil {
		t.Fatalf("failed to create temp queue file: %v", err)
	}
	defer os.Remove(queueFile.Name())

	entries := []QueueEntry{
		{
			VideoID:    "hJXfBULLDro",
			VideoTitle: "Test Integration Video",
			UploadDate: "2026-01-01",
		},
	}
	
	if err := SaveQueue(queueFile.Name(), entries); err != nil {
		t.Fatalf("failed to save temp queue: %v", err)
	}

	var importedJSONPath string
	mockImport := func(jsonFilePath string) error {
		importedJSONPath = jsonFilePath
		return nil
	}

	deps := queueProcessorDeps{
		runDocker: func(outputFile string, args []string) error {
			return injectGoldenToDocker(outputFile, args, goldenPath)
		},
		importJSON: mockImport,
	}

	err = processQueueVideosWithDeps(queueFile.Name(),  deps,  []string{}, "")
	if err != nil {
		t.Fatalf("processQueueVideosWithDeps failed: %v", err)
	}

	if importedJSONPath == "" {
		t.Fatalf("importJSON was never called, meaning the Docker container failed to run or process the video")
	}

	data, err := os.ReadFile(importedJSONPath)
	if err != nil {
		t.Fatalf("failed to read imported JSON file: %v", err)
	}

	var result struct {
		VideoID string `json:"video_id"`
		Matches []struct {
			Timestamp int    `json:"timestamp"`
			Player1   string `json:"player1"`
			Player2   string `json:"player2"`
		} `json:"matches"`
	}

	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatalf("failed to unmarshal output JSON: %v", err)
	}

	if len(result.Matches) != 2 {
		t.Fatalf("Expected exactly 2 matches, got %d", len(result.Matches))
	}
	
	if result.Matches[0].Player1 != "SUN YINGSHA" || result.Matches[0].Player2 != "WANG MANYU" {
		t.Errorf("Match 1 players incorrect: %s vs %s", result.Matches[0].Player1, result.Matches[0].Player2)
	}
	
	if result.Matches[1].Player1 != "WANG CHUQIN" || result.Matches[1].Player2 != "LIN YUN-JU" {
		t.Errorf("Match 2 players incorrect: %s vs %s", result.Matches[1].Player1, result.Matches[1].Player2)
	}
}
