package utils

import (
	"log"
	"os"
)

func CreateFolderIfNoExist(folderPath string) string {
	if _, err := os.Stat(folderPath); os.IsNotExist(err) {
		err := os.MkdirAll(folderPath, 0755)
		if err != nil {
			log.Fatalf("Error creating folder %s: %v\n", folderPath, err)
		}
	}
	return folderPath
}
