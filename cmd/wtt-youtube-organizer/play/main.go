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
	"wtt-youtube-organizer/config"
	"wtt-youtube-organizer/shell"
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
const FORMAT = "bestvideo[height<=2160]+bestaudio/best"

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

// plays video/audio links received from yt-dlp directly in mpv
// mpv is responsible for mixing video and audio together
func play(_ *youtubeparser.Filters) {
	videoLink, audioLink := getVideoUrlsFromYtDlp(videoUrl)
	mpvCmd := runMpv(videoLink, audioLink, false)
	if err := mpvCmd.Wait(); err != nil {
		log.Fatal(err)
	}
}

func runMpv(directVideoLink string, directAudioLink string, verbose bool) *exec.Cmd {
	args := []string{"--no-resume-playback", "--player-operation-mode=pseudo-gui"}
	if saveWatchedTimeMpvScript != "" {
		args = append(args, fmt.Sprintf("--script=%s", saveWatchedTimeMpvScript))
	}

	if directAudioLink != "" {
		args = append(args, fmt.Sprintf("--audio-file=%s", directAudioLink))
	}
	watchedFileName, err := getWatchedFileName(videoUrl)
	if err != nil {
		log.Fatalf("Failed to construct watched time variable for %s: %v\n", videoUrl, err)
	}
	watchedSeconds, err := getCurrentWatchedTime(watchedFileName)
	if err != nil {
		log.Fatalf("Failed to receive watched seconds for the %s: %v", videoUrl, err)
	}
	if watchedSeconds > 0 {
		args = append(args, fmt.Sprintf("--start=%d", watchedSeconds))
	}
	if verbose {
		args = append(args, "-v")
	}
	args = append(args, directVideoLink)

	fmt.Printf("mpv args: %s\n", args)
	mpvCmd := exec.Command("mpv", args...)

	stdout, err := mpvCmd.StdoutPipe()
	if err != nil {
		log.Fatal(err)
	}
	stderr, err := mpvCmd.StderrPipe()
	if err != nil {
		log.Fatal(err)
	}
	mpvCmd.Env = os.Environ()

	mpvCmd.Env = append(mpvCmd.Env, fmt.Sprintf("%s=%s", WATCHED_FILE_NAME, watchedFileName))
	mpvCmd.Env = append(mpvCmd.Env, fmt.Sprintf("%s=%d", WATCHED_SECONDS, watchedSeconds))

	if err := mpvCmd.Start(); err != nil {
		log.Fatal(err)
	}
	stdoutChan := make(chan string)
	stderrChan := make(chan string)

	go func() {
		defer close(stdoutChan) // Close the channel when the goroutine exits
		buf := make([]byte, 1024)
		for {
			n, err := stdout.Read(buf)
			if n > 0 {
				stdoutChan <- string(buf[:n])
			}
			if err == io.EOF {
				return
			}
			if err != nil {
				log.Printf("Error reading stdout: %v\n", err)
				return
			}
		}
	}()

	go func() {
		defer close(stderrChan) // Close the channel when the goroutine exits
		buf := make([]byte, 1024)
		for {
			n, err := stderr.Read(buf)
			if n > 0 {
				stderrChan <- string(buf[:n])
			}
			if err == io.EOF {
				return
			}
			if err != nil {
				log.Printf("Error reading stderr: %v\n", err)
				return
			}
		}
	}()

	go func() {
		for line := range stdoutChan {
			if verbose {
				fmt.Println(line)
			}
		}
	}()

	go func() {
		for line := range stderrChan {
			if verbose {
				fmt.Fprintln(os.Stderr, line)
			}
		}
	}()

	return mpvCmd
}

// Gets the amount of watched seconds for the given watchedFileName
// returns 0 if file was not watched yet
//
// watchedFileName named as last part of youtube video
// https://www.youtube.com/watch?v=OdXQDJOQ27w -> becomes OdXQDJOQ27w
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

// Just get video and audio url from ytdlp without downloading or mixing them
func getVideoUrlsFromYtDlp(youtubeUrl string) (videoLink string, audioLink string) {
	args := []string{"-f", FORMAT, "--get-url"}
	args = append(args, youtubeUrl)
	out := shell.ExecuteScript("yt-dlp", args...)

	if out.Err != "" {
		log.Fatalf("Error executing shell command: %s", out.Err)
	}
	for _, link := range strings.Split(out.Out, "\n") {
		if link == "" {
			continue
		}
		link = strings.TrimSpace(link)
		if videoLink == "" {
			videoLink = link
			continue
		}
		if audioLink == "" {
			audioLink = link
		}
	}
	return videoLink, audioLink
}
