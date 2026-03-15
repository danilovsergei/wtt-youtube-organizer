package script

import (
	"bufio"
	"encoding/csv"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func VerifyDataMain() {
	// Open the CSV file
	csvFile, err := os.Open("testdata.csv")
	if err != nil {
		fmt.Printf("Error opening testdata.csv: %v\n", err)
		return
	}
	defer csvFile.Close()

	// Read all CSV records
	reader := csv.NewReader(csvFile)
	records, err := reader.ReadAll()
	if err != nil {
		fmt.Printf("Error reading CSV: %v\n", err)
		return
	}

	// Find all log files
	logFiles, err := filepath.Glob("*.log")
	if err != nil {
		fmt.Printf("Error finding log files: %v\n", err)
		return
	}

	fmt.Printf("Found %d log files.\n", len(logFiles))
	fmt.Printf("Verifying %d records from testdata.csv...\n", len(records))
	fmt.Println(strings.Repeat("=", 100))

	// Pre-load logs into memory
	logContent := make(map[string][]string)
	for _, logPath := range logFiles {
		file, err := os.Open(logPath)
		if err != nil {
			fmt.Printf("Error opening log file %s: %v\n", logPath, err)
			continue
		}

		var lines []string
		scanner := bufio.NewScanner(file)
		// Increase buffer size to 64MB to handle very long lines
		buf := make([]byte, 0, 64*1024)
		scanner.Buffer(buf, 64*1024*1024)

		for scanner.Scan() {
			lines = append(lines, scanner.Text())
		}
		if err := scanner.Err(); err != nil {
			fmt.Printf("Error scanning log file %s: %v\n", logPath, err)
		}
		file.Close()
		logContent[logPath] = lines
	}

	for i, record := range records {
		if len(record) == 0 {
			continue
		}
		imagePath := strings.TrimSpace(record[0])

		if len(record) < 7 {
			fmt.Printf("[%02d] Image: %s\n", i+1, imagePath)
			fmt.Printf("      WARNING: Invalid CSV record length: %d\n", len(record))
			continue
		}

		csvDisplay := fmt.Sprintf("Expected: '%s' vs '%s' (Set: %s-%s, Game: %s-%s)",
					  record[1], record[2], record[3], record[4], record[5], record[6])

		fmt.Printf("[%02d] Image: %s\n", i+1, imagePath)
		fmt.Printf("      CSV Data: %s\n", csvDisplay)

		foundInLogs := false
		for _, lines := range logContent {
			for _, line := range lines {
				if strings.Contains(line, imagePath) {
					if strings.Contains(line, "Sampling at") {
						fmt.Printf("      Log Line: %s\n", strings.TrimSpace(line))
						foundInLogs = true
					} else if strings.Contains(line, "OCR_NAME_VARIANCE") {
						fmt.Printf("      Variance: %s\n", strings.TrimSpace(line))
						foundInLogs = true
					}
				}
			}
		}

		if !foundInLogs {
			reallyFound := false
			for logName, lines := range logContent {
				for _, line := range lines {
					if strings.Contains(line, imagePath) {
						fmt.Printf("      Log Context (%s): %s\n", logName, strings.TrimSpace(line))
						reallyFound = true
					}
				}
			}
			if !reallyFound {
				fmt.Println("      WARNING: Image path not found in any log file.")
			}
		}
		fmt.Println(strings.Repeat("-", 100))
	}
}
