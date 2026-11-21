package serve_cmd

import (
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
)

var (
	httpPort    int
	udpPort     int
	cookiesPath string
)

// NewCommand returns the 'serve' cobra command.
func NewCommand() *cobra.Command {
	home, _ := os.UserHomeDir()
	defaultCookies := filepath.Join(home, ".config", "wtt-youtube-organizer", "youtube_cookies.txt")

	cmd := &cobra.Command{
		Use:   "serve",
		Short: "Start HTTP media stream proxy and UDP LAN discovery server",
		RunE: func(cmd *cobra.Command, args []string) error {
			srv := NewServer(httpPort, udpPort, cookiesPath)
			return srv.Start()
		},
	}

	cmd.Flags().IntVar(&httpPort, "http-port", 8080, "HTTP stream proxy port")
	cmd.Flags().IntVar(&udpPort, "udp-port", 8081, "UDP broadcast discovery port")
	cmd.Flags().StringVar(&cookiesPath, "cookies", defaultCookies, "Path to Netscape youtube cookies file")

	return cmd
}
