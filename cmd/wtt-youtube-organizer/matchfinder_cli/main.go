// Package matchfinder_cli provides a wrapper to run match-finder Docker container
// with automatic GPU group detection for Intel OpenVINO acceleration.
package matchfinder_cli

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"wtt-youtube-organizer/config"
	"wtt-youtube-organizer/db/importer"
	"wtt-youtube-organizer/utils"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const imageName = "wtt-stream-match-finder-openvino"

// logWriter is a multi-writer that writes to both console and log file
var logWriter io.Writer
var logFile *os.File

// setupLogging creates a log file and sets up dual logging (console + file)
func setupLogging() error {
	logDir := filepath.Join(config.GetProjectConfigDir(), "log")
	if err := os.MkdirAll(logDir, 0755); err != nil {
		return fmt.Errorf("failed to create log directory: %w", err)
	}

	timestamp := time.Now().Format("20060102-150405")
	logPath := filepath.Join(logDir, fmt.Sprintf("matchfinder-%s.log", timestamp))

	var err error
	logFile, err = os.Create(logPath)
	if err != nil {
		return fmt.Errorf("failed to create log file: %w", err)
	}

	logWriter = io.MultiWriter(os.Stdout, logFile)
	fmt.Fprintf(logWriter, "Log file: %s\n\n", logPath)
	return nil
}

// closeLogging closes the log file
func closeLogging() {
	if logFile != nil {
		logFile.Close()
	}
}

// logPrintf prints to both console and log file
func logPrintf(format string, a ...interface{}) {
	if logWriter != nil {
		fmt.Fprintf(logWriter, format, a...)
	} else {
		fmt.Printf(format, a...)
	}
}

// logPrintln prints to both console and log file
func logPrintln(a ...interface{}) {
	if logWriter != nil {
		fmt.Fprintln(logWriter, a...)
	} else {
		fmt.Println(a...)
	}
}

const example = `
		# Show new streams since last processed (dry run)
		{cmd} matchfinder --show_new_streams

		# Show new streams and save to file
		{cmd} matchfinder --show_new_streams --output_json /path/to/results.json

		# Process all new streams since last processed (uses database)
		{cmd} matchfinder --process_new_streams

		# Process all streams after a specific video ID
		{cmd} matchfinder --process_new_streams VIDEO_ID

		# Custom output location
		{cmd} matchfinder --output_json /path/to/results.json -- --youtube_video "https://youtube.com/watch?v=xyz123"

		# Pass additional flags to container after --
		{cmd} matchfinder --output_json /path/to/results.json -- --youtube_video "https://..." --only_extract_video_metadata
`

var (
	outputJSON       string
	addNewStreams    bool
	processQueueName string
	showNewStreams   bool
	excludeProcessed bool
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "matchfinder",
		Short: "Run match-finder in Docker container with GPU acceleration",
		Long: `Wrapper to run match-finder Docker container with automatic GPU group detection 
for Intel OpenVINO acceleration.

When --show_new_streams is provided:
  - Queries database for last_processed video ID
  - Runs Docker with --only_extract_video_metadata to show new streams
  - Shows list of new streams (dry run unless you process them)

When --process_new_streams is provided:
  - Uses VIDEO_ID arg if provided, otherwise uses last_processed from database
  - Generates temp output file automatically
  - Runs Docker container to find matches
  - Imports results to database automatically

For custom usage, use --output_json with -- separator for container flags.`,
		Example:      utils.FormatExample.Replace(example),
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runMatchFinder(args)
		},
	}
	initCmd(cmd.Flags())
	return cmd
}

func initCmd(flags *pflag.FlagSet) {
	flags.StringVar(&outputJSON, "output_json", "", "Output JSON file path (optional with --show_new_streams)")
	flags.BoolVar(&addNewStreams, "add_new_streams", false, "Fetch new streams and add to processing queue (optionally specify VIDEO_ID as arg)")
	flags.StringVar(&processQueueName, "process", "", "Process videos from the specified queue file (e.g., latest_streams)")
	flags.BoolVar(&showNewStreams, "show_new_streams", false, "Show new streams since last processed video (uses last_processed from database)")
	flags.BoolVar(&excludeProcessed, "exclude_processed", false, "When used with --show_new_streams, only show videos not yet processed")
}

func runMatchFinder(extraArgs []string) error {
	// Setup dual logging (console + file)
	if err := setupLogging(); err != nil {
		fmt.Printf("Warning: could not setup logging: %v\n", err)
	}
	defer closeLogging()

	var absOutputJSON string

	// Handle --show_new_streams mode
	if showNewStreams {
		// Get video ID from args or database
		var lastVideoID string
		if len(extraArgs) > 0 {
			lastVideoID = extraArgs[0]
			logPrintf("Using provided video ID: %s\n", lastVideoID)
		} else {
			var err error
			lastVideoID, err = importer.GetLastProcessedVideoID()
			if err != nil {
				return fmt.Errorf("failed to get last processed video: %w", err)
			}
			if lastVideoID == "" {
				return fmt.Errorf("no last_processed video found in database")
			}
			logPrintf("Last processed video ID (from database): %s\n", lastVideoID)
		}

		// Always use a temp output file to capture metadata JSON
		tmpDir, err := os.MkdirTemp("", "matchfinder-")
		if err != nil {
			return fmt.Errorf("failed to create temp directory: %w", err)
		}
		if err := os.Chmod(tmpDir, 0777); err != nil {
			return fmt.Errorf("failed to set temp directory permissions: %w", err)
		}
		timestamp := time.Now().Format("20060102-150405")
		metadataJSON := filepath.Join(tmpDir, fmt.Sprintf("metadata-%s.json", timestamp))

		// Build container args for metadata-only extraction
		containerArgs := []string{
			"--only_extract_video_metadata",
			"--process_all_matches_after", lastVideoID,
		}

		// Run docker to get metadata JSON
		if err := runDockerContainer(metadataJSON, containerArgs); err != nil {
			return err
		}

		// Also save to user-specified path if provided
		if outputJSON != "" {
			absOut, err := filepath.Abs(outputJSON)
			if err == nil {
				data, readErr := os.ReadFile(metadataJSON)
				if readErr == nil {
					os.WriteFile(absOut, data, 0644)
				}
			}
		}

		// Parse the metadata JSON
		videos, err := importer.ParseVideoMetadataJSON(metadataJSON)
		if err != nil {
			logPrintf("Warning: could not parse metadata: %v\n", err)
			return nil
		}

		if len(videos) == 0 {
			logPrintln("No new streams found.")
			return nil
		}

		// Collect video IDs and check database
		youtubeIDs := make([]string, len(videos))
		for i, v := range videos {
			youtubeIDs[i] = v.VideoID
		}

		processedMap, err := importer.GetProcessedVideoIDs(youtubeIDs)
		if err != nil {
			logPrintf("Warning: could not check database: %v\n", err)
			processedMap = map[string]bool{}
		}

		// Print formatted table with PROCESSED column
		logPrintf("\nFound %d video(s) after %s:\n\n", len(videos), lastVideoID)
		logPrintf("%-12s %-16s %-10s %s\n", "UPLOAD_DATE", "VIDEO_ID", "PROCESSED", "TITLE")
		logPrintln(strings.Repeat("-", 120))

		processedCount := 0
		displayedCount := 0
		for _, v := range videos {
			isProcessed := processedMap[v.VideoID]
			if isProcessed {
				processedCount++
			}
			// Skip processed videos if --exclude_processed is set
			if excludeProcessed && isProcessed {
				continue
			}
			uploadDate := v.UploadDate
			if len(uploadDate) == 8 {
				uploadDate = uploadDate[:4] + "-" + uploadDate[4:6] + "-" + uploadDate[6:]
			}
			processed := "no"
			if isProcessed {
				processed = "yes"
			}
			logPrintf("%-12s %-16s %-10s %s\n", uploadDate, v.VideoID, processed, v.VideoTitle)
			displayedCount++
		}

		logPrintf("\nTotal: %d videos (%d processed, %d new)\n",
			len(videos), processedCount, len(videos)-processedCount)
		if excludeProcessed {
			logPrintf("Showing: %d unprocessed videos (--exclude_processed)\n", displayedCount)
		}

		return nil
	}

	// Handle --add_new_streams mode
	if addNewStreams {
		// Determine video_id and queue name
		var providedVideoID string
		if len(extraArgs) > 0 {
			providedVideoID = extraArgs[0]
			logPrintf("Fetching streams after video ID: %s\n", providedVideoID)
		}

		// Queue name depends on whether video_id was provided
		queueName := QueueFileName(providedVideoID)
		queuePath := QueueFilePath(queueName)

		// Determine afterVideoID for the docker container
		var afterVideoID string

		// Check if queue already exists
		existingQueue, err := LoadQueue(queuePath)
		if err != nil {
			return fmt.Errorf("failed to load queue: %w", err)
		}

		if len(existingQueue) > 0 {
			// Queue exists: use top entry (newest) as cutoff
			afterVideoID = existingQueue[0].VideoID
			logPrintf("Queue exists with %d entries. Using top video ID: %s\n",
				len(existingQueue), afterVideoID)
		} else if providedVideoID != "" {
			// New queue with provided video_id
			afterVideoID = providedVideoID
		} else {
			// New queue without video_id: use last_processed from DB
			afterVideoID, err = importer.GetLastProcessedVideoID()
			if err != nil {
				return fmt.Errorf("failed to get last processed video: %w", err)
			}
			if afterVideoID == "" {
				return fmt.Errorf("no last_processed video found in database")
			}
			logPrintf("Last processed video ID (from database): %s\n", afterVideoID)
		}

		// Create docker-based stream fetcher
		fetcher := &dockerStreamFetcher{}

		// Add new streams to queue
		// When video_id is provided, filter out already-processed videos
		var count int
		if providedVideoID != "" {
			checker := &dbProcessedChecker{}
			count, err = AddNewStreams(queuePath, afterVideoID, fetcher, checker)
		} else {
			count, err = AddNewStreams(queuePath, afterVideoID, fetcher)
		}
		if err != nil {
			return err
		}

		logPrintf("\n=== Queue Update ===\n")
		logPrintf("Queue file: %s\n", queuePath)
		logPrintf("New videos added: %d\n", count)

		// Reload to show current size
		updatedQueue, _ := LoadQueue(queuePath)
		logPrintf("Current queue size: %d\n", len(updatedQueue))

		return nil
	}

	// Handle --process mode
	if processQueueName != "" {
		// Add .json extension if not provided
		queueName := processQueueName
		if !strings.HasSuffix(queueName, ".json") {
			queueName = queueName + ".json"
		}
		queuePath := QueueFilePath(queueName)

		logPrintf("Processing queue: %s\n", queuePath)
		return processQueueVideos(queuePath)
	}

	// Standard mode - require --output_json and pass extra args to container
	if outputJSON == "" {
		return fmt.Errorf("--output_json is required (or use --add_new_streams)")
	}

	if len(extraArgs) == 0 {
		return fmt.Errorf("container arguments required after -- (e.g., --youtube_video URL)")
	}

	var err error
	absOutputJSON, err = filepath.Abs(outputJSON)
	if err != nil {
		return fmt.Errorf("invalid output path: %w", err)
	}

	return runDockerContainer(absOutputJSON, extraArgs)
}

// dbProcessedChecker implements ProcessedChecker using the real database.
type dbProcessedChecker struct{}

func (d *dbProcessedChecker) GetProcessedVideoIDs(youtubeIDs []string) (map[string]bool, error) {
	return importer.GetProcessedVideoIDs(youtubeIDs)
}

// dockerStreamFetcher implements StreamFetcher using the Docker container.
type dockerStreamFetcher struct{}

func (d *dockerStreamFetcher) FetchStreamsAfter(afterVideoID string) ([]QueueEntry, error) {
	// Create temp directory for metadata output
	tmpDir, err := os.MkdirTemp("", "matchfinder-")
	if err != nil {
		return nil, fmt.Errorf("failed to create temp directory: %w", err)
	}
	if err := os.Chmod(tmpDir, 0777); err != nil {
		return nil, fmt.Errorf("failed to set temp directory permissions: %w", err)
	}
	ts := time.Now().Format("20060102-150405")
	metadataJSON := filepath.Join(tmpDir, fmt.Sprintf("metadata-%s.json", ts))

	containerArgs := []string{
		"--only_extract_video_metadata",
		"--process_all_matches_after", afterVideoID,
	}

	if err := runDockerContainer(metadataJSON, containerArgs); err != nil {
		return nil, fmt.Errorf("docker container failed: %w", err)
	}

	videos, err := importer.ParseVideoMetadataJSON(metadataJSON)
	if err != nil {
		return nil, fmt.Errorf("failed to parse metadata: %w", err)
	}

	return VideosToQueueEntries(videos), nil
}

// processQueueVideos processes videos from the queue one by one (oldest first).
// After each video is successfully processed and imported, it's removed from the queue.
// When the queue is fully processed, updates last_processed in the database
// if the top video's upload_date is >= the current last_processed upload_date.
func processQueueVideos(queuePath string) error {
	for {
		// Reload queue each iteration (in case of crash recovery)
		queue, err := LoadQueue(queuePath)
		if err != nil {
			return fmt.Errorf("failed to load queue: %w", err)
		}

		if len(queue) == 0 {
			logPrintln("\n=== Queue is empty. All videos processed! ===")
			return nil
		}

		// Process the last entry (oldest, since queue is newest-first)
		entry := queue[len(queue)-1]
		isLastItem := len(queue) == 1 // This is the top (newest) entry
		logPrintf("\n=== Processing queue [%d remaining] ===\n", len(queue))
		logPrintf("Video: %s (%s)\n", entry.VideoTitle, entry.VideoID)

		// Create temp directory for this video's output
		tmpDir, err := os.MkdirTemp("", "matchfinder-")
		if err != nil {
			return fmt.Errorf("failed to create temp directory: %w", err)
		}
		if err := os.Chmod(tmpDir, 0777); err != nil {
			return fmt.Errorf("failed to set temp directory permissions: %w", err)
		}
		ts := time.Now().Format("20060102-150405")
		outputFile := filepath.Join(tmpDir, fmt.Sprintf("matches-%s-%s.json", entry.VideoID, ts))

		// Run docker to process this single video
		youtubeURL := fmt.Sprintf("https://www.youtube.com/watch?v=%s", entry.VideoID)
		containerArgs := []string{
			"--youtube_video", youtubeURL,
		}

		if err := runDockerContainer(outputFile, containerArgs); err != nil {
			logPrintf("ERROR processing video %s: %v\n", entry.VideoID, err)
			logPrintf("JSON file: %s\n", outputFile)
			return fmt.Errorf("failed to process video %s: %w", entry.VideoID, err)
		}

		// Import results to database
		logPrintln("\n=== Importing results to database ===")
		if err := importer.ImportMatchesFromJSON(outputFile); err != nil {
			logPrintf("ERROR importing video %s: %v\n", entry.VideoID, err)
			logPrintf("JSON file: %s\n", outputFile)
			return fmt.Errorf("failed to import video %s: %w", entry.VideoID, err)
		}

		// Remove processed video from queue (last entry)
		queue = queue[:len(queue)-1]
		if err := SaveQueue(queuePath, queue); err != nil {
			return fmt.Errorf("failed to update queue: %w", err)
		}

		logPrintf("Successfully processed and removed from queue: %s\n", entry.VideoID)
		logPrintf("Remaining in queue: %d\n", len(queue))

		// Update last_processed when the last item (top/newest) is processed
		if isLastItem {
			dbUploadDate, err := importer.GetLastProcessedUploadDate()
			if err != nil {
				logPrintf("Warning: could not get DB upload date: %v\n", err)
			}
			if ShouldUpdateLastProcessed(entry.UploadDate, dbUploadDate) {
				logPrintf("Updating last_processed to: %s (upload_date: %s)\n",
					entry.VideoID, entry.UploadDate)
				if err := importer.UpdateLastProcessed(entry.VideoID); err != nil {
					return fmt.Errorf("failed to update last_processed: %w", err)
				}
				logPrintln("last_processed updated successfully")
			} else {
				logPrintf("Skipping last_processed update: video upload_date (%s) < DB upload_date (%s)\n",
					entry.UploadDate, dbUploadDate)
			}
		}
	}
}

// getLogWriter returns logWriter if available, otherwise os.Stdout
func getLogWriter() io.Writer {
	if logWriter != nil {
		return logWriter
	}
	return os.Stdout
}

// runDockerContainerNoOutput runs the container without any output file (stdout only)
func runDockerContainerNoOutput(containerArgs []string) error {
	scriptDir := filepath.Join(getProjectRoot(), "florence_extractor", "docker")

	if !dockerImageExists(imageName) {
		logPrintf("Image '%s' not found. Building...\n", imageName)
		if err := dockerComposeBuild(scriptDir); err != nil {
			return fmt.Errorf("failed to build image: %w", err)
		}
		logPrintln()
	}

	videoGID := getGroupID("video", 44)
	renderGID := getGroupID("render", 0)

	logPrintln("Detected GPU groups:")
	logPrintf("  video GID: %d\n", videoGID)
	if renderGID > 0 {
		logPrintf("  render GID: %d\n", renderGID)
	} else {
		logPrintln("  render GID: not found")
	}

	logPrintln("Intel GPU: Using container's built-in drivers")
	logPrintln()

	args := buildDockerRunArgsNoOutput(imageName, videoGID, renderGID, containerArgs)

	cmd := exec.Command("docker", args...)
	cmd.Stdout = getLogWriter()
	cmd.Stderr = getLogWriter()
	cmd.Stdin = os.Stdin

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("docker run failed: %w", err)
	}

	return nil
}

func runDockerContainer(absOutputJSON string, containerArgs []string) error {
	outputDir := filepath.Dir(absOutputJSON)
	outputFilename := filepath.Base(absOutputJSON)

	scriptDir := filepath.Join(getProjectRoot(), "florence_extractor", "docker")

	if !dockerImageExists(imageName) {
		logPrintf("Image '%s' not found. Building...\n", imageName)
		if err := dockerComposeBuild(scriptDir); err != nil {
			return fmt.Errorf("failed to build image: %w", err)
		}
		logPrintln()
	}

	videoGID := getGroupID("video", 44)
	renderGID := getGroupID("render", 0)

	logPrintln("Detected GPU groups:")
	logPrintf("  video GID: %d\n", videoGID)
	if renderGID > 0 {
		logPrintf("  render GID: %d\n", renderGID)
	} else {
		logPrintln("  render GID: not found")
	}

	logPrintln("Intel GPU: Using container's built-in drivers")

	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("failed to create output directory: %w", err)
	}

	logPrintf("Output directory: %s\n", outputDir)
	logPrintf("Output file: %s\n\n", outputFilename)

	fullContainerArgs := append(containerArgs, "--output_json_file", "/output/"+outputFilename)
	args := buildDockerRunArgs(imageName, outputDir, videoGID, renderGID, fullContainerArgs)

	cmd := exec.Command("docker", args...)
	cmd.Stdout = getLogWriter()
	cmd.Stderr = getLogWriter()
	cmd.Stdin = os.Stdin

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("docker run failed: %w", err)
	}

	if _, err := os.Stat(absOutputJSON); err == nil {
		logPrintf("\nMatches details saved to: %s\n", absOutputJSON)
	}

	return nil
}

func getProjectRoot() string {
	dir, err := os.Getwd()
	if err != nil {
		return "."
	}

	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}

	cwd, _ := os.Getwd()
	return cwd
}

func dockerImageExists(imageName string) bool {
	cmd := exec.Command("docker", "image", "inspect", imageName)
	cmd.Stdout = nil
	cmd.Stderr = nil
	return cmd.Run() == nil
}

func dockerComposeBuild(dir string) error {
	cmd := exec.Command("docker-compose", "build")
	cmd.Dir = dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func getGroupID(groupName string, defaultGID int) int {
	file, err := os.Open("/etc/group")
	if err != nil {
		return defaultGID
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.Split(line, ":")
		if len(parts) >= 3 && parts[0] == groupName {
			gid, err := strconv.Atoi(parts[2])
			if err == nil {
				return gid
			}
		}
	}

	return defaultGID
}

// getCropLogDir returns the host path for cropped image logs.
func getCropLogDir() string {
	return filepath.Join(config.GetProjectConfigDir(), "log")
}

func buildDockerRunArgs(imageName, outputDir string, videoGID, renderGID int, containerArgs []string) []string {
	args := []string{
		"run", "--rm",
		"--device", "/dev/dri:/dev/dri",
		"--group-add", strconv.Itoa(videoGID),
	}

	if renderGID > 0 {
		args = append(args, "--group-add", strconv.Itoa(renderGID))
	}

	// Mount output dir and log dir for cropped images
	cropLogDir := getCropLogDir()
	os.MkdirAll(cropLogDir, 0755)

	args = append(args,
		"-v", fmt.Sprintf("%s:/output", outputDir),
		"-v", fmt.Sprintf("%s:/log", cropLogDir),
		imageName,
	)

	// Always pass --crop_output_dir so cropped images are saved
	containerArgs = append(containerArgs, "--crop_output_dir", "/log")
	args = append(args, containerArgs...)

	return args
}

// buildDockerRunArgsNoOutput builds docker run args without volume mount (no output file)
func buildDockerRunArgsNoOutput(imageName string, videoGID, renderGID int, containerArgs []string) []string {
	args := []string{
		"run", "--rm",
		"--device", "/dev/dri:/dev/dri",
		"--group-add", strconv.Itoa(videoGID),
	}

	if renderGID > 0 {
		args = append(args, "--group-add", strconv.Itoa(renderGID))
	}

	args = append(args, imageName)
	args = append(args, containerArgs...)

	return args
}
