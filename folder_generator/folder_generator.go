package foldergenerator

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"text/template"
	"wtt-youtube-organizer/utils"
	youtubeparser "wtt-youtube-organizer/youtube_parser"
)

const scriptTemplate = `#!/bin/sh
{{.EXECUTABLE}} play --videoUrl "{{.VIDEO_URL}}" {{.LUA_SCRIPT_ARG}}`

type ReplaceTemplate struct {
	VIDEO_URL      string
	EXECUTABLE     string
	LUA_SCRIPT_ARG string
}

func CreateFolders(videos []*youtubeparser.YoutubeVideo, saveWatchedTimeMpvScript string) error {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("Failed to get home directory: %v", err)
	}
	rootFolder := filepath.Join(homeDir, "wtt")
	utils.CreateFolderIfNoExist(rootFolder)

	emptyFolder(rootFolder)
	for _, video := range videos {
		tourPath := utils.CreateFolderIfNoExist(filepath.Join(rootFolder, video.Tournament))
		roundPath := utils.CreateFolderIfNoExist(filepath.Join(tourPath, video.Round))
		err := createShLauncher(roundPath, saveWatchedTimeMpvScript, video)
		if err != nil {
			return err
		}
	}
	return nil
}

func createShLauncher(folder string, saveWatchedTimeMpvScript string, video *youtubeparser.YoutubeVideo) error {
	filename := video.Players + ".sh"
	if video.FullMatch {
		filename = "FULL_" + filename
	}
	filename = strings.ReplaceAll(filename, "/", " and ")
	filename = filepath.Join(folder, filename)
	tmpl, err := template.New("script").Parse(scriptTemplate)
	if err != nil {
		return fmt.Errorf("error parsing template: %v", err)
	}
	file, err := os.Create(filename)
	if err != nil {
		return fmt.Errorf("error creating file %s: %v", filename, err)
	}
	defer file.Close()

	exePath, err := getExecutablePath()
	if err != nil {
		log.Fatalf("Failed to create sh launcher : %v", err)
	}
	var saveWatchedTimeArg string
	if saveWatchedTimeMpvScript != "" {
		saveWatchedTimeArg = fmt.Sprintf("--saveWatchedTimeMpvScript \"%s\"", saveWatchedTimeMpvScript)
	}
	// Execute the template with the URL data
	err = tmpl.Execute(file, ReplaceTemplate{VIDEO_URL: video.URL, EXECUTABLE: exePath, LUA_SCRIPT_ARG: saveWatchedTimeArg})
	if err != nil {
		return fmt.Errorf("error executing template: %v", err)
	}

	// Make the script executable
	err = os.Chmod(filename, 0755)
	if err != nil {
		return fmt.Errorf("error making script executable: %v", err)
	}
	return nil
}

func emptyFolder(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}

	for _, entry := range entries {
		if entry.Name() == "." || entry.Name() == ".." {
			continue
		}
		fullPath := filepath.Join(dir, entry.Name())
		if entry.IsDir() {
			err = os.RemoveAll(fullPath)
		} else {
			err = os.Remove(fullPath)
		}
		if err != nil {
			return err // Handle errors immediately if deletion fails
		}
	}

	return nil
}

func getExecutablePath() (string, error) {
	// Get the raw executable path
	exePath, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("Error retrieving executable path %v", err)
	}

	// Get the absolute path of the executable
	absExePath, err := filepath.Abs(exePath)
	if err != nil {
		return "", fmt.Errorf("Error getting absolute executable path %v", err)
	}
	return absExePath, nil
}
