package main

import (
	"log"
	"wtt-youtube-organizer/cmd/wtt-youtube-organizer/folder"
	"wtt-youtube-organizer/cmd/wtt-youtube-organizer/play"
	"wtt-youtube-organizer/cmd/wtt-youtube-organizer/show"
	"wtt-youtube-organizer/utils"
	youtubeparser "wtt-youtube-organizer/youtube_parser"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

var filters youtubeparser.Filters

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   utils.MainCommand,
		Short: "CLI for WTT ping pong videos youtube channel",
		Args:  cobra.MinimumNArgs(0),
		RunE: func(cmd *cobra.Command, args []string) error {
			return cmd.Help()
		},
	}
	initCmd(cmd.PersistentFlags())
	cmd.AddCommand(show.NewCommand(&filters))
	cmd.AddCommand(folder.NewCommand(&filters))
	cmd.AddCommand(play.NewCommand(&filters))
	return cmd
}

func initCmd(flagSet *pflag.FlagSet) {
	flagSet.StringVar(&filters.Tournament, "tour", "", "Tournament name")
	flagSet.StringVar(&filters.Gender, "gender", "MS", "Tournament name")
	flagSet.StringVar(&filters.Filter, "filter", "", "Filter by anything")
	flagSet.BoolVar(&filters.TodayOnly, "today", false, "filters only today matches")
	flagSet.BoolVar(&filters.Full, "full", false, "filters only full matches")
	flagSet.BoolVar(&filters.ShowWatched, "showWatched", true, "shows already watched videos")
	flagSet.BoolVar(&filters.DisableAllFilters, "nofilters", false, "Disables all filters")
}

func main() {
	err := NewCommand().Execute()
	if err != nil {
		log.Fatalf("Failed to execute command : %v", err)
	}
}
