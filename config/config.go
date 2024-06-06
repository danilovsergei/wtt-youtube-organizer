package config

import (
	"log"
	"os"
	"path/filepath"
)

const appName = "wtt-youtube-organizer"

func getConfigDir() string {
	configDir, err := os.UserConfigDir()
	if err != nil {
		log.Fatalln("Failed to get system config folder")
	}
	return configDir
}

func GetProjectConfigDir() string {
	return filepath.Join(getConfigDir(), appName)
}
