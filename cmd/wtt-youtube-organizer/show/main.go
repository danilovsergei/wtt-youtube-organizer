package show

import (
	"fmt"
	"wtt-youtube-organizer/utils"
	youtubeparser "wtt-youtube-organizer/youtube_parser"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const example = `
		{cmd} show
`

func NewCommand(filters *youtubeparser.Filters) *cobra.Command {
	cmd := &cobra.Command{
		Use:          "show",
		Short:        "Shows wtt videos in the console",
		Long:         "Shows wtt videos in the consol",
		Example:      utils.FormatExample.Replace(example),
		Args:         cobra.MaximumNArgs(1),
		SilenceUsage: true,
		Run: func(cmd *cobra.Command, args []string) {
			show(filters)
		},
	}
	initCmd(cmd.Flags())
	return cmd
}

func initCmd(_ *pflag.FlagSet) {
}

func show(filters *youtubeparser.Filters) {
	for _, video := range youtubeparser.FilterWttVideos(filters) {
		fmt.Printf("%s: %s - %s\n", video.UploadDate, video.Title, video.URL)
	}
}
