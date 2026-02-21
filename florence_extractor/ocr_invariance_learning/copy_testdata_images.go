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
	if len(os.Args) < 4 {
		fmt.Println("Usage: go run copy_images.go <path_to_testdata.csv> <source_images_root> <destination_folder>")
		os.Exit(1)
	}
	csvPath := os.Args[1]
	srcRoot := os.Args[2]
	destDir := os.Args[3]

	// Create destination directory
	if err := os.MkdirAll(destDir, 0755); err != nil {
		fmt.Printf("Error creating destination directory: %v\n", err)
		os.Exit(1)
	}

	csvFile, err := os.Open(csvPath)
	if err != nil {
		fmt.Printf("Error opening CSV file: %v\n", err)
		os.Exit(1)
	}
	defer csvFile.Close()

	reader := csv.NewReader(csvFile)
	records, err := reader.ReadAll()
	if err != nil {
		fmt.Printf("Error reading CSV: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Processing %d records from '%s'...\n", len(records), csvPath)
	fmt.Printf("Copying images from '%s' to '%s'...\n", srcRoot, destDir)

	count := 0
	for _, record := range records {
		if len(record) == 0 {
			continue
		}
		// CSV record[0] is the relative path found in logs (e.g. "subdir/image.jpg")
		relPath := strings.TrimSpace(record[0])

		// Construct full source path
		srcPath := filepath.Join(srcRoot, relPath)

		// Flatten path structure for destination filename to avoid overwrites/deep nesting
		// Example: "folder/image.jpg" -> "folder_image.jpg"
		cleanRel := filepath.Clean(relPath)
		flatName := strings.ReplaceAll(cleanRel, string(os.PathSeparator), "_")

		// Basic sanitization for colons (Windows compatibility or just cleanliness)
		flatName = strings.ReplaceAll(flatName, ":", "_")

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
