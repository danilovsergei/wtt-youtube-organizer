package foldergenerator

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"text/template"
	"wtt-youtube-organizer/utils"
	youtubeparser "wtt-youtube-organizer/youtube_parser"
)

const scriptTemplate = `#!/bin/sh
source ~/.profile
wtt-youtube-organizer play --videoUrl "{{.VIDEO_URL}}"`

type ReplaceTemplate struct {
	VIDEO_URL string
}

func CreateFolders(videos []*youtubeparser.YoutubeVideo) error {
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
		err := createShLauncher(roundPath, video)
		if err != nil {
			return err
		}
	}
	return nil
}

func createShLauncher(folder string, video *youtubeparser.YoutubeVideo) error {
	filename := video.Players + ".sh"
	if video.FullMatch {
		filename = "FULL_" + filename
	}
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

	// Execute the template with the URL data
	err = tmpl.Execute(file, ReplaceTemplate{VIDEO_URL: video.URL})
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
