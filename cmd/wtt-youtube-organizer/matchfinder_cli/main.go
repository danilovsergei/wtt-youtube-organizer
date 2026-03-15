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

var (
	imageName = "wtt-stream-match-finder-openvino"
	dockerDir = "docker/openvino"
)

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
		# Show new streams since latest upload date (dry run)
		{cmd} matchfinder --show_new_streams

		# Show new streams and save to file
		{cmd} matchfinder --show_new_streams --output_json /path/to/results.json

		# Process all new streams (uses database)
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
	cudaDeviceID     int
	getCookies       bool
)


func getCudaDevices() []string {
	cmd := exec.Command("nvidia-smi", "--query-gpu=index,name", "--format=csv,noheader")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	var devices []string
	for _, line := range lines {
		if strings.TrimSpace(line) != "" {
			devices = append(devices, strings.TrimSpace(line))
		}
	}
	return devices
}

func getCudaDeviceName(id int) string {
	devices := getCudaDevices()
	prefix := fmt.Sprintf("%d,", id)
	for _, dev := range devices {
		if strings.HasPrefix(strings.TrimSpace(dev), prefix) {
			// Extract just the name
			parts := strings.SplitN(dev, ",", 2)
			if len(parts) == 2 {
				return strings.TrimSpace(parts[1])
			}
		}
	}
	return ""
}

func hasCUDA() bool {

	err := exec.Command("nvidia-smi").Run()
	return err == nil
}

func hasNvidiaDocker() bool {
	// check if docker actually can mount gpus
	cmd := exec.Command("docker", "run", "--rm", "--gpus", "all", "ubuntu", "nvidia-smi")
	err := cmd.Run()
	if err == nil {
	    return true
	}
	
	// If standard fails, check if privileged works
	cmdPriv := exec.Command("docker", "run", "--rm", "--privileged", "--gpus", "all", "ubuntu", "nvidia-smi")
	errPriv := cmdPriv.Run()
	if errPriv == nil {
	    return true
	}
	
	return false
}


func getCookiesPath(outputDir string) (string, error) {
	if !getCookies {
		return "", nil
	}

	cmdPath, err := exec.LookPath("ytdlp-rookie")
	if err != nil {
		// fallback to checking bin/ytdlp-rookie in current dir since users run it from the root of the project!
		if _, err := os.Stat("bin/ytdlp-rookie"); err == nil {
			cmdPath = "bin/ytdlp-rookie"
		} else {
			return "", fmt.Errorf("--get_cookies specified but ytdlp-rookie binary not found in PATH or bin/ytdlp-rookie")
		}
	}

	if outputDir == "" {
		outputDir = os.TempDir()
	}
	cookieFile := filepath.Join(outputDir, "yt_cookies.txt")
	logPrintf("Extracting cookies using %s to %s...\n", cmdPath, cookieFile)

	cmd := exec.Command(cmdPath)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("failed to run ytdlp-rookie: %v\nOutput: %s", err, string(output))
	}

	if err := os.WriteFile(cookieFile, output, 0666); err != nil {
		return "", fmt.Errorf("failed to write cookies to file: %w", err)
	}
	os.Chmod(cookieFile, 0777) // Force the file mask immediately regardless of umask

	logPrintln("Cookies extracted successfully.")
	return cookieFile, nil
}

func initDockerVars(extraArgs []string) {
	if hasCUDA() {
		if !hasNvidiaDocker() {
			fmt.Println("\nERROR: NVIDIA GPU detected, but Docker is missing the NVIDIA Container Toolkit.")
			fmt.Println("To enable GPU acceleration in Docker, please run:")
			fmt.Println("  sudo apt-get install -y nvidia-container-toolkit")
			fmt.Println("  sudo nvidia-ctk runtime configure --runtime=docker")
			fmt.Println("  sudo systemctl restart docker")
			os.Exit(1)
		}
		
		// Check for multiple GPUs and require explicit selection
		devices := getCudaDevices()
		if len(devices) > 1 {
			// Check if the cobra flag was set, or if it was passed manually in extraArgs
			hasDeviceFlag := cudaDeviceID >= 0
			for _, arg := range extraArgs {
				if strings.Contains(arg, "--cuda_device_id") {
					hasDeviceFlag = true
					break
				}
			}
			if !hasDeviceFlag {
				fmt.Println("\nERROR: Multiple NVIDIA GPUs detected. You must explicitly specify which one to use.")
				fmt.Println("Available devices:")
				for _, dev := range devices {
					fmt.Printf("  %s\n", dev)
				}
				fmt.Println("\nPlease run the command again and append: --cuda_device_id <number>")
				os.Exit(1)
			}
		}

		imageName = "geonix/wtt-stream-match-finder-cuda:latest"
		dockerDir = "docker/cuda"
	}
}

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "matchfinder",
		Short: "Run match-finder in Docker container with GPU acceleration",
		Long: `Wrapper to run match-finder Docker container with automatic GPU group detection 
for Intel OpenVINO acceleration.

When --show_new_streams is provided:
  - Queries database for video ID from day before latest upload date
  - Runs Docker with --only_extract_video_metadata to show new streams
  - Shows list of new streams (dry run unless you process them)

When --process_new_streams is provided:
  - Uses VIDEO_ID arg if provided, otherwise queries database for latest upload date
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
	flags.BoolVar(&showNewStreams, "show_new_streams", false, "Show new streams since day before latest upload date in database")
	flags.BoolVar(&excludeProcessed, "exclude_processed", false, "When used with --show_new_streams, only show videos not yet processed")
	flags.IntVar(&cudaDeviceID, "cuda_device_id", -1, "The ID of the CUDA device to use for PyTorch (if multiple are available)")
	flags.BoolVar(&getCookies, "get_cookies", false, "Run ytdlp-rookie to extract browser cookies and pass them to yt-dlp")
}

// buildContainerArgs constructs the additional arguments to be passed to the Docker container
// based on CLI flags, without mutating the original positional arguments.
func buildContainerArgs(deviceID int) []string {
	var containerArgs []string
	if deviceID >= 0 {
		containerArgs = append(containerArgs, "--cuda_device_id", strconv.Itoa(deviceID))
		if devName := getCudaDeviceName(deviceID); devName != "" {
			containerArgs = append(containerArgs, "--cuda_device_name", devName)
		}
	}
	return containerArgs
}

func getProvidedVideoID(extraArgs []string) string {
	if len(extraArgs) > 0 {
		return extraArgs[0]
	}
	return ""
}

func runMatchFinder(extraArgs []string) error {
	// Keep the original extraArgs intact for positional argument parsing (like Video ID for add_new_streams)
	// We will build a specific containerArgs slice when we actually execute the docker container.
	var containerArgs []string
	if cudaDeviceID >= 0 {
		containerArgs = append(containerArgs, "--cuda_device_id", strconv.Itoa(cudaDeviceID))
		if devName := getCudaDeviceName(cudaDeviceID); devName != "" {
			containerArgs = append(containerArgs, "--cuda_device_name", devName)
		}
	}
	
	// Temporarily inject into extraArgs strictly for initDockerVars to check --backend openvino
	tempInitArgs := append(extraArgs, containerArgs...)
	initDockerVars(tempInitArgs)
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
			lastVideoID, err = importer.GetLatestUploadDateVideoID()
			if err != nil {
				return fmt.Errorf("failed to get video ID from database: %w", err)
			}
			logPrintf("Using latest video ID from database: %s\n", lastVideoID)
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
		containerArgs = append(containerArgs, extraArgs...)

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
			if ts, err := strconv.ParseInt(uploadDate, 10, 64); err == nil {
				uploadDate = time.Unix(ts, 0).UTC().Format("2006-01-02")
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
			// New queue without video_id: use latest video from database
			afterVideoID, err = importer.GetLatestUploadDateVideoID()
			if err != nil {
				return fmt.Errorf("failed to get video ID from database: %w", err)
			}
			logPrintf("Using latest video ID from database: %s\n", afterVideoID)
		}

		// Create docker-based stream fetcher
		fetcher := &dockerStreamFetcher{}

		// Always filter out already-processed videos
		// (docker may return duplicates from the latest upload_date that are already in DB)
		checker := &dbProcessedChecker{}
		var count int
		count, err = AddNewStreams(queuePath, afterVideoID, fetcher, checker)
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

	return runDockerContainer(absOutputJSON, append(extraArgs, containerArgs...))
}

// dbProcessedChecker implements ProcessedChecker using the real database.
type dbProcessedChecker struct{}

func (d *dbProcessedChecker) GetProcessedVideoIDs(youtubeIDs []string) (map[string]bool, error) {
	return importer.GetProcessedVideoIDs(youtubeIDs)
}

// dockerStreamFetcher implements StreamFetcher using the Docker container.
type dockerStreamFetcher struct{}

func (d *dockerStreamFetcher) FetchStreamsAfter(afterVideoID string) ([]QueueEntry, error) {
	initDockerVars([]string{})
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

	// If the metadata JSON doesn't exist, Docker exited successfully but
	// found no new videos (e.g., all streams are older than afterVideoID).
	if _, err := os.Stat(metadataJSON); os.IsNotExist(err) {
		logPrintln("No new streams found (metadata file not created).")
		return []QueueEntry{}, nil
	}

	videos, err := importer.ParseVideoMetadataJSON(metadataJSON)
	if err != nil {
		return nil, fmt.Errorf("failed to parse metadata: %w", err)
	}

	return VideosToQueueEntries(videos), nil
}

// queueProcessorDeps holds injectable dependencies for processQueueVideos.
type queueProcessorDeps struct {
	// runDocker runs the Docker container and writes output JSON.
	runDocker func(outputFile string, containerArgs []string) error
	// importJSON imports matches from a JSON file to the database.
	importJSON func(jsonFilePath string) error
}

// defaultQueueDeps returns real production dependencies.
func defaultQueueDeps() queueProcessorDeps {
	return queueProcessorDeps{
		runDocker:  runDockerContainer,
		importJSON: importer.ImportMatchesFromJSON,
	}
}

// processQueueVideos processes videos from the queue one by one (oldest first).
// After each video is successfully processed and imported, it's removed from the queue.
func processQueueVideos(queuePath string) error {
	return processQueueVideosWithDeps(queuePath, defaultQueueDeps())
}

// processQueueVideosWithDeps is the testable implementation of processQueueVideos.
// Processes videos oldest-first: successful videos are removed from queue,
// failed videos (docker error) are kept in queue for retry and processing continues.
func processQueueVideosWithDeps(queuePath string, deps queueProcessorDeps) error {
	queue, err := LoadQueue(queuePath)
	if err != nil {
		return fmt.Errorf("failed to load queue: %w", err)
	}

	if len(queue) == 0 {
		logPrintln("\n=== Queue is empty. All videos processed! ===")
		return nil
	}

	// Process from end (oldest) to start (newest)
	failedCount := 0
	for i := len(queue) - 1; i >= 0; i-- {
		entry := queue[i]
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
		
		// Inject CUDA args if missing
		if cudaDeviceID >= 0 && !strings.Contains(strings.Join(containerArgs, " "), "--cuda_device_id") {
			containerArgs = append(containerArgs, "--cuda_device_id", strconv.Itoa(cudaDeviceID))
			if devName := getCudaDeviceName(cudaDeviceID); devName != "" {
				containerArgs = append(containerArgs, "--cuda_device_name", devName)
			}
		}

		dockerErr := deps.runDocker(outputFile, containerArgs)
		if dockerErr != nil {
			logPrintf("ERROR processing video %s: %v\n", entry.VideoID, dockerErr)
			logPrintf("Video %s kept in queue for retry. Continuing to next video...\n", entry.VideoID)
			failedCount++
			continue
		}

		// Import results to database
		logPrintln("\n=== Importing results to database ===")
		if importErr := deps.importJSON(outputFile); importErr != nil {
			logPrintf("ERROR importing video %s: %v\n", entry.VideoID, importErr)
			logPrintf("JSON file: %s\n", outputFile)
			return fmt.Errorf("failed to import video %s: %w", entry.VideoID, importErr)
		}

		// Remove from queue after successful docker + import
		queue = append(queue[:i], queue[i+1:]...)
		if err := SaveQueue(queuePath, queue); err != nil {
			return fmt.Errorf("failed to update queue: %w", err)
		}

		logPrintf("Successfully processed and removed from queue: %s\n", entry.VideoID)
		logPrintf("Remaining in queue: %d\n", len(queue))
	}

	if failedCount > 0 {
		logPrintf("\n=== %d video(s) failed and remain in queue for retry ===\n", failedCount)
	} else {
		logPrintln("\n=== Queue is empty. All videos processed! ===")
	}

	return nil
}

// killStaleMatchFinderContainers finds and kills any running Docker containers
// using the match-finder image. This prevents stale containers from accumulating
// when previous runs didn't clean up properly.
func killStaleMatchFinderContainers() {
	// Find running containers using our image
	cmd := exec.Command("docker", "ps", "-q", "--filter", fmt.Sprintf("ancestor=%s", imageName))
	output, err := cmd.Output()
	if err != nil {
		return // silently ignore errors (docker might not be available)
	}

	containerIDs := strings.TrimSpace(string(output))
	if containerIDs == "" {
		return // no running containers
	}

	// Split by newline in case there are multiple containers
	ids := strings.Fields(containerIDs)
	logPrintf("Killing %d stale match-finder container(s)...\n", len(ids))

	for _, id := range ids {
		killCmd := exec.Command("docker", "kill", id)
		if err := killCmd.Run(); err != nil {
			logPrintf("Warning: failed to kill container %s: %v\n", id, err)
		} else {
			logPrintf("Killed stale container: %s\n", id)
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
	cookieFile, err := getCookiesPath("")
	if err != nil {
		return err
	}
	if cookieFile != "" {
		containerArgs = append(containerArgs, "--cookies_file", "/tmp/cookies.txt")
		// chmod the temp file explicitly just in case
		os.Chmod(cookieFile, 0666)
	}
	killStaleMatchFinderContainers()

	scriptDir := filepath.Join(getProjectRoot(), "florence_extractor", dockerDir)

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

	if dockerDir == "docker/cuda" { logPrintln("NVIDIA GPU: Using CUDA and --gpus all") } else { logPrintln("Intel GPU: Using container's built-in drivers") }
	logPrintln()

	
	args := buildDockerRunArgsNoOutput(imageName, videoGID, renderGID, containerArgs, cookieFile)

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
	killStaleMatchFinderContainers()

	outputDir := filepath.Dir(absOutputJSON)
	outputFilename := filepath.Base(absOutputJSON)

	scriptDir := filepath.Join(getProjectRoot(), "florence_extractor", dockerDir)

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

	if dockerDir == "docker/cuda" { logPrintln("NVIDIA GPU: Using CUDA and --gpus all") } else { logPrintln("Intel GPU: Using container's built-in drivers") }

	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("failed to create output directory: %w", err)
	}

	logPrintf("Output directory: %s\n", outputDir)
	logPrintf("Output file: %s\n\n", outputFilename)

	fullContainerArgs := append(containerArgs, "--output_json_file", "/output/"+outputFilename)
	
	// Pass the exact same outputDir that is being bind-mounted to docker!
	cookieFile, err := getCookiesPath(outputDir)
	if err != nil {
		return err
	}
	if cookieFile != "" {
		fullContainerArgs = append(fullContainerArgs, "--cookies_file", "/output/yt_cookies.txt")
	}
	
	args := buildDockerRunArgs(imageName, outputDir, videoGID, renderGID, fullContainerArgs, cookieFile)

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
	cmd := exec.Command("docker", "compose", "build")
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

func buildDockerRunArgs(imageName, outputDir string, videoGID, renderGID int, containerArgs []string, cookieFile string) []string {
	args := []string{"run", "--rm"}

	if dockerDir == "docker/cuda" {
		// Modern gLinux / Debian environments often require --privileged 
		// alongside --gpus all due to strict cgroups device isolation.
		args = append(args, "--privileged", "--gpus", "all")
	} else {
		args = append(args, "--device", "/dev/dri:/dev/dri", "--group-add", strconv.Itoa(videoGID))
		if renderGID > 0 {
			args = append(args, "--group-add", strconv.Itoa(renderGID))
		}
	}



	// Mount output dir and log dir for cropped images
	cropLogDir := getCropLogDir()
	os.MkdirAll(cropLogDir, 0755)

	args = append(args,
		"-v", fmt.Sprintf("%s:/output", outputDir),
		"-v", fmt.Sprintf("%s:/log", cropLogDir))

	args = append(args, imageName)

	// Always pass --crop_output_dir so cropped images are saved
	containerArgs = append(containerArgs, "--crop_output_dir", "/log")
	args = append(args, containerArgs...)

	return args
}

// buildDockerRunArgsNoOutput builds docker run args without volume mount (no output file)
func buildDockerRunArgsNoOutput(imageName string, videoGID, renderGID int, containerArgs []string, cookieFile string) []string {
	args := []string{"run", "--rm"}

	if dockerDir == "docker/cuda" {
		// Modern gLinux / Debian environments often require --privileged 
		// alongside --gpus all due to strict cgroups device isolation.
		args = append(args, "--privileged", "--gpus", "all")
	} else {
		args = append(args, "--device", "/dev/dri:/dev/dri", "--group-add", strconv.Itoa(videoGID))
		if renderGID > 0 {
			args = append(args, "--group-add", strconv.Itoa(renderGID))
		}
	}

	if cookieFile != "" {
		args = append(args, "-v", cookieFile+":/tmp/cookies.txt")
	}

	args = append(args, imageName)
	args = append(args, containerArgs...)

	return args
}
