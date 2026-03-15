package config

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type Settings struct {
	ProcessFilter       string `json:"process_filter"`
	AddNewStreamsFilter string `json:"add_new_streams_filter"`
}

func LoadSettings() (*Settings, error) {
	settingsPath := filepath.Join(GetProjectConfigDir(), "settings.json")
	data, err := os.ReadFile(settingsPath)
	if err != nil {
		if os.IsNotExist(err) {
			return &Settings{}, nil // Return empty settings if file doesn't exist
		}
		return nil, err
	}

	var settings Settings
	if err := json.Unmarshal(data, &settings); err != nil {
		return nil, err
	}
	return &settings, nil
}
