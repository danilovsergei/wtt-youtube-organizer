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
		// relPath is e.g. "11dz3aCdet4/cropped_10620.0-a7d98c4e.jpg"
		relPath := strings.TrimSpace(record[0])

		// Construct full source path
		srcPath := filepath.Join(srcRoot, relPath)

		// FIX: Extract ONLY the filename (e.g., "cropped_10620.0-a7d98c4e.jpg")
		// This removes the "11dz3aCdet4/" prefix from the destination name
		fileName := filepath.Base(relPath)

		// Construct destination path: destDir + fileName
		destPath := filepath.Join(destDir, fileName)

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
	fmt.Printf("Copied %s to %s\n", src, dst)
	return err
}
