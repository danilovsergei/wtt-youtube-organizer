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
	outputJSON        string
	processNewStreams bool
	showNewStreams    bool
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
	flags.BoolVar(&processNewStreams, "process_new_streams", false, "Process all new streams and import to database (optionally specify VIDEO_ID as arg)")
	flags.BoolVar(&showNewStreams, "show_new_streams", false, "Show new streams since last processed video (uses last_processed from database)")
}

func runMatchFinder(extraArgs []string) error {
	// Setup dual logging (console + file)
	if err := setupLogging(); err != nil {
		fmt.Printf("Warning: could not setup logging: %v\n", err)
	}
	defer closeLogging()

	var absOutputJSON string
	var tempFile bool

	// Handle --show_new_streams mode
	if showNewStreams {
		// Get last processed video ID from database
		lastVideoID, err := importer.GetLastProcessedVideoID()
		if err != nil {
			return fmt.Errorf("failed to get last processed video: %w", err)
		}
		if lastVideoID == "" {
			return fmt.Errorf("no last_processed video found in database")
		}
		logPrintf("Last processed video ID: %s\n", lastVideoID)

		// Build container args for metadata-only extraction
		containerArgs := []string{
			"--only_extract_video_metadata",
			"--process_all_matches_after", lastVideoID,
		}

		// Only pass output file if --output_json is explicitly provided
		if outputJSON != "" {
			absOutputJSON, err = filepath.Abs(outputJSON)
			if err != nil {
				return fmt.Errorf("invalid output path: %w", err)
			}
			// Run with output file
			if err := runDockerContainer(absOutputJSON, containerArgs); err != nil {
				return err
			}
		} else {
			// Run without output file - just display to stdout
			if err := runDockerContainerNoOutput(containerArgs); err != nil {
				return err
			}
		}

		return nil
	}

	// Handle --process_new_streams mode
	if processNewStreams {
		// Get video ID from args or database
		var videoID string
		if len(extraArgs) > 0 {
			videoID = extraArgs[0]
			logPrintf("Processing streams after video ID: %s\n", videoID)
		} else {
			// Get last processed video ID from database
			var err error
			videoID, err = importer.GetLastProcessedVideoID()
			if err != nil {
				return fmt.Errorf("failed to get last processed video: %w", err)
			}
			if videoID == "" {
				return fmt.Errorf("no last_processed video found in database")
			}
			logPrintf("Last processed video ID (from database): %s\n", videoID)
		}

		// Auto-generate temp file if not specified
		if outputJSON == "" {
			// Create temp directory in /tmp with world-writable permissions
			// Docker root can then create files inside it
			tmpDir, err := os.MkdirTemp("", "matchfinder-")
			if err != nil {
				return fmt.Errorf("failed to create temp directory: %w", err)
			}
			if err := os.Chmod(tmpDir, 0777); err != nil {
				return fmt.Errorf("failed to set temp directory permissions: %w", err)
			}
			// Use unique filename with timestamp
			timestamp := time.Now().Format("20060102-150405")
			absOutputJSON = filepath.Join(tmpDir, fmt.Sprintf("matches-%s.json", timestamp))
			tempFile = true
			logPrintf("Using temp output: %s\n", absOutputJSON)
		} else {
			var err error
			absOutputJSON, err = filepath.Abs(outputJSON)
			if err != nil {
				return fmt.Errorf("invalid output path: %w", err)
			}
		}

		// Build container args for batch processing
		containerArgs := []string{
			"--process_all_matches_after", videoID,
		}

		// Run the docker container
		if err := runDockerContainer(absOutputJSON, containerArgs); err != nil {
			logPrintf("JSON file: %s\n", absOutputJSON)
			return err
		}

		// Import results to database
		logPrintln("\n=== Importing results to database ===")
		if err := importer.ImportMatchesFromJSON(absOutputJSON); err != nil {
			logPrintf("JSON file: %s\n", absOutputJSON)
			return fmt.Errorf("failed to import matches: %w", err)
		}

		// Keep temp files for debugging - never delete
		if tempFile {
			logPrintf("JSON file preserved at: %s\n", absOutputJSON)
		}

		return nil
	}

	// Standard mode - require --output_json and pass extra args to container
	if outputJSON == "" {
		return fmt.Errorf("--output_json is required (or use --process_new_streams)")
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

	logPrintln("Intel GPU: Using container's built-in drivers\n")

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

func buildDockerRunArgs(imageName, outputDir string, videoGID, renderGID int, containerArgs []string) []string {
	args := []string{
		"run", "--rm",
		"--device", "/dev/dri:/dev/dri",
		"--group-add", strconv.Itoa(videoGID),
	}

	if renderGID > 0 {
		args = append(args, "--group-add", strconv.Itoa(renderGID))
	}

	args = append(args,
		"-v", fmt.Sprintf("%s:/output", outputDir),
		imageName,
	)

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
