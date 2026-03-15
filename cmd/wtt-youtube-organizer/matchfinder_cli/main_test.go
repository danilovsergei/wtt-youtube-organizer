package matchfinder_cli

import (
	"testing"
	"strings"
	"os"
)

func TestDockerRunArgsCookies(t *testing.T) {
	// Set the global dockerDir to mock environment
	dockerDir = "docker/cuda"
	
	// Test passing no cookies
	argsWithoutCookies := buildDockerRunArgsNoOutput("test-image", 100, 200, []string{"--some-flag"}, "")
	
	hasCookiesMount := false
	for _, arg := range argsWithoutCookies {
		if strings.Contains(arg, "/tmp/cookies.txt") {
			hasCookiesMount = true
		}
	}
	
	if hasCookiesMount {
		t.Errorf("Expected no cookie mount when cookieFile is empty, but found: %v", argsWithoutCookies)
	}
	
	// Test passing a cookies file
	mockCookieFile := "/tmp/mock_yt_cookies.txt"
	argsWithCookies := buildDockerRunArgsNoOutput("test-image", 100, 200, []string{"--some-flag"}, mockCookieFile)
	
	hasCookiesMount = false
	expectedMount := "-v"
	expectedTarget := "/tmp/mock_yt_cookies.txt:/tmp/cookies.txt"
	
	for i, arg := range argsWithCookies {
		if arg == expectedMount && i+1 < len(argsWithCookies) && argsWithCookies[i+1] == expectedTarget {
			hasCookiesMount = true
			break
		}
	}
	
	if !hasCookiesMount {
		t.Errorf("Expected to find '-v /tmp/mock_yt_cookies.txt:/tmp/cookies.txt:ro' in args, but got: %v", argsWithCookies)
	}
}

func TestDockerRunArgsFullCookies(t *testing.T) {
	dockerDir = "docker/cuda"
	
	// Ensure buildDockerRunArgs (the one with output dir) also sets it
	argsWithCookies := buildDockerRunArgs("test-image", "/out", 100, 200, []string{"--some-flag"}, "/tmp/mock_yt_cookies.txt")
	
	hasCookiesMount := false
	for i, arg := range argsWithCookies {
		if arg == "-v" && i+1 < len(argsWithCookies) && argsWithCookies[i+1] == "/tmp/mock_yt_cookies.txt:/tmp/cookies.txt:ro" {
			hasCookiesMount = true
			break
		}
	}
	
	// In full build args, we NO LONGER mount cookies file explicitly. We mount it via the parent /output directory!
	if hasCookiesMount {
		t.Errorf("Expected NO explicit cookie mount in full build args (should use /output), but got: %v", argsWithCookies)
	}
}


func TestGetCookiesPathFailsWhenNotInPath(t *testing.T) {
	// Enable the flag for the test
	getCookies = true
	defer func() { getCookies = false }()

	// Save original PATH
	origPath := os.Getenv("PATH")
	defer os.Setenv("PATH", origPath)

	// Wipe out PATH so exec.LookPath is guaranteed to fail
	os.Setenv("PATH", "/this/path/does/not/exist")

	_, err := getCookiesPath("/tmp")
	
	if err == nil {
		t.Fatal("Expected an error because ytdlp-rookie is not in PATH, but got nil")
	}

	expectedErrorMsg := "--get_cookies specified but ytdlp-rookie binary not found"
	if !strings.Contains(err.Error(), expectedErrorMsg) {
		t.Errorf("Expected error to contain %q, but got: %v", expectedErrorMsg, err)
	}
}
