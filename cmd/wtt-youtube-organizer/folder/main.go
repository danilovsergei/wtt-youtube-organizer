package folder

import (
	"flag"
	"fmt"
	foldergenerator "wtt-youtube-organizer/folder_generator"
	"wtt-youtube-organizer/utils"
	youtubeparser "wtt-youtube-organizer/youtube_parser"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const example = `
		{cmd} folder
`

func NewCommand(filters *youtubeparser.Filters) *cobra.Command {
	cmd := &cobra.Command{
		Use:          "folder",
		Short:        "Generates folder structure from WTT videos",
		Long:         "Generates folder structure from WTT videos",
		Example:      utils.FormatExample.Replace(example),
		Args:         cobra.MaximumNArgs(1),
		SilenceUsage: true,
		Run: func(cmd *cobra.Command, args []string) {
			generateFolders(filters)
		},
	}
	initCmd(cmd.Flags())
	return cmd
}

func initCmd(_ *pflag.FlagSet) {
	flag.Parse()
}

func generateFolders(filters *youtubeparser.Filters) {
	fmt.Println("Execute wtt-youtube-organizer folder generator")
	err := foldergenerator.CreateFolders(youtubeparser.FilterWttVideos(filters))
	if err != nil {
		fmt.Println(err)
	}
}
