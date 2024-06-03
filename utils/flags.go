package utils

import "strings"

const MainCommand = "wtt-youtube-organizer"

var FormatExample *strings.Replacer = strings.NewReplacer(
	"{cmd}", MainCommand,
)
