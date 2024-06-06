package play

import (
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"wtt-youtube-organizer/config"
	"wtt-youtube-organizer/utils"
	youtubeparser "wtt-youtube-organizer/youtube_parser"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const example = `
		{cmd} play
`

const WATCHED_FILE_NAME = "WATCHED_FILE_NAME"
const WATCHED_SECONDS = "WATCHED_SECONDS"
const WATCHED_DIR = "watched"

var videoUrl string
var saveWatchedTimeMpvScript string

func NewCommand(filters *youtubeparser.Filters) *cobra.Command {
	cmd := &cobra.Command{
		Use:          "play",
		Short:        "Plays youtube video",
		Long:         "Plays youtube video using yt-dlp and mpv",
		Example:      utils.FormatExample.Replace(example),
		Args:         cobra.MaximumNArgs(1),
		SilenceUsage: true,
		Run: func(cmd *cobra.Command, args []string) {
			if videoUrl == "" {
				log.Fatalln("--videoUrl arg must be provided with valid youtube url")
			}
			play(filters)
		},
	}
	initCmd(cmd.Flags())
	return cmd
}

func initCmd(flagSet *pflag.FlagSet) {
	flagSet.StringVar(&videoUrl, "videoUrl", "", "Youtube video URL")
	flagSet.StringVar(&saveWatchedTimeMpvScript, "saveWatchedTimeMpvScript", "", "Lua script to save watched time of the youtube video")
}

func play(_ *youtubeparser.Filters) {
	var wg sync.WaitGroup
	wg.Add(2)

	ytDlpCmd, ytDlpOut := runYtDlp(videoUrl)
	mpvCmd, mpvIn := runMpv(videoUrl)

	go pipeYtDlpToMpv(mpvIn, ytDlpOut, &wg)

	// Stop waiting if either of the mpv or yt-dlp quits
	go waitForCompletion(mpvCmd, &wg)
	go waitForCompletion(ytDlpCmd, &wg)

	wg.Wait()
}

func runYtDlp(videoUrl string) (*exec.Cmd, io.ReadCloser) {
	args := []string{"-f", "bestvideo[height<=1440]+bestaudio/best", "-o", "-", "--buffer-size", "60M"}
	downloadSectionsArg := getYtDlpDownloadSectionsArg(videoUrl)
	if downloadSectionsArg != nil {
		args = append(args, downloadSectionsArg...)
	}
	args = append(args, videoUrl)

	fmt.Printf("yt-dlp args: %s\n", args)

	ytCmd := exec.Command("yt-dlp", args...)
	ytOut, err := ytCmd.StdoutPipe()
	if err != nil {
		log.Fatal(err)
	}
	ytCmd.Stderr = os.Stderr
	if err := ytCmd.Start(); err != nil {
		log.Fatal(err)
	}
	return ytCmd, ytOut
}

func runMpv(videoUrl string) (*exec.Cmd, io.WriteCloser) {
	args := []string{"--no-resume-playback"}
	if saveWatchedTimeMpvScript != "" {
		args = append(args, fmt.Sprintf("--script=%s", saveWatchedTimeMpvScript))
	}
	args = append(args, "-")
	fmt.Printf("mpv args: %s\n", args)
	mpvCmd := exec.Command("mpv", args...)
	mpvIn, err := mpvCmd.StdinPipe()
	if err != nil {
		log.Fatal(err)
	}
	mpvCmd.Stdout = os.Stdout
	mpvCmd.Stderr = os.Stderr
	watchedFileName, err := getWatchedFileName(videoUrl)
	if err != nil {
		log.Fatalf("Failed to construct watched time variable for %s: %v\n", videoUrl, err)
	}
	watchedSeconds, err := getCurrentWatchedTime(watchedFileName)
	if err != nil {
		log.Fatalf("Failed to receive watched seconds for the %s: %v", videoUrl, err)
	}
	mpvCmd.Env = os.Environ()
	mpvCmd.Env = append(mpvCmd.Env, fmt.Sprintf("%s=%s", WATCHED_FILE_NAME, watchedFileName))
	mpvCmd.Env = append(mpvCmd.Env, fmt.Sprintf("%s=%d", WATCHED_SECONDS, watchedSeconds))
	if err := mpvCmd.Start(); err != nil {
		log.Fatal(err)
	}
	return mpvCmd, mpvIn
}

func getYtDlpDownloadSectionsArg(videoUrl string) []string {
	watchedFileName, err := getWatchedFileName(videoUrl)
	if err != nil {
		log.Fatalf("Failed to construct watched time variable for %s: %v\n", videoUrl, err)
	}
	watchedSeconds, err := getCurrentWatchedTime(watchedFileName)
	if err != nil {
		log.Fatalf("Failed to receive watched seconds for the %s: %v", videoUrl, err)
	}
	if watchedSeconds == 0 {
		return nil
	}
	minutes := watchedSeconds / 60
	remainingSeconds := watchedSeconds % 60
	ytDlpTimeFormat := fmt.Sprintf("*%02d:%02d-", minutes, remainingSeconds)
	return []string{"--download-sections", ytDlpTimeFormat}

}

func getCurrentWatchedTime(watchedFileName string) (uint32, error) {
	// Read file contents
	data, err := os.ReadFile(watchedFileName)
	if err != nil {
		// Valid case. Watching video first time
		if os.IsNotExist(err) {
			return 0, nil
		} else {
			return 0, fmt.Errorf("error reading file %s: %v", watchedFileName, err)
		}
	}
	numberStr := strings.TrimSpace(string(data))
	number, err := strconv.ParseUint(numberStr, 10, 32)
	if err != nil {
		return 0, fmt.Errorf("error parsing watched seconds %s from %s: %v", numberStr, watchedFileName, err)
	}
	return uint32(number), nil
}

func pipeYtDlpToMpv(ytDlpOut io.WriteCloser, mpvIn io.ReadCloser, wg *sync.WaitGroup) {
	defer wg.Done()
	defer ytDlpOut.Close()
	defer mpvIn.Close()

	_, err := io.Copy(ytDlpOut, mpvIn)
	if err != nil {
		log.Fatal(err)
	}
}

func waitForCompletion(cmd *exec.Cmd, wg *sync.WaitGroup) {
	defer wg.Done()
	if err := cmd.Wait(); err != nil {
		log.Fatal(err)
	}
}

func getWatchedFileName(videoUrl string) (string, error) {
	youtubeId, err := getYouTubeId(videoUrl)
	configDir := utils.CreateFolderIfNoExist(config.GetProjectConfigDir())
	watchedDir := utils.CreateFolderIfNoExist(filepath.Join(configDir, WATCHED_DIR))

	if err != nil {
		return "", err
	}
	return filepath.Join(watchedDir, youtubeId), nil

}

func getYouTubeId(videoUrl string) (string, error) {
	re := regexp.MustCompile(`(?:v=|/)([0-9A-Za-z_-]{11}).*`)
	matches := re.FindStringSubmatch(videoUrl)
	if len(matches) < 2 {
		return "", fmt.Errorf("invalid YouTube URL")
	}
	return matches[1], nil
}
