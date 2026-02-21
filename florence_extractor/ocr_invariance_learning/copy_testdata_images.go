package main

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: go run copy_images.go <destination_folder>")
		os.Exit(1)
	}
	destDir := os.Args[1]

	// Create destination directory
	if err := os.MkdirAll(destDir, 0755); err != nil {
		fmt.Printf("Error creating destination directory: %v\n", err)
		os.Exit(1)
	}

	csvFile, err := os.Open("testdata.csv")
	if err != nil {
		fmt.Printf("Error opening testdata.csv: %v\n", err)
		os.Exit(1)
	}
	defer csvFile.Close()

	reader := csv.NewReader(csvFile)
	records, err := reader.ReadAll()
	if err != nil {
		fmt.Printf("Error reading CSV: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Copying %d images to '%s'...\n", len(records), destDir)

	count := 0
	for _, record := range records {
		if len(record) == 0 {
			continue
		}
		srcPath := strings.TrimSpace(record[0])

		// Flatten path structure but preserve directory info in filename
		// Example: "folder/image.jpg" -> "folder_image.jpg"
		cleanSrc := filepath.Clean(srcPath)
		flatName := strings.ReplaceAll(cleanSrc, string(os.PathSeparator), "_")

		destPath := filepath.Join(destDir, flatName)

		err := copyFile(srcPath, destPath)
		if err != nil {
			fmt.Printf("Failed to copy %s: %v\n", srcPath, err)
		} else {
			count++
		}
	}
	fmt.Printf("Successfully copied %d images.\n", count)
}

func copyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()

	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destFile.Close()

	_, err = io.Copy(destFile, sourceFile)
	return err
}
