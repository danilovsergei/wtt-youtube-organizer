package matchfinder_cli

import (
	"errors"
	"os/exec"
	"testing"
)

func TestDockerRunExitCodePropagation(t *testing.T) {
	// Simulate docker run exiting with code 2
	mockRunDocker := func(outputFile string, containerArgs []string) error {
		// Run a command that exits with 2
		cmd := exec.Command("sh", "-c", "exit 2")
		return cmd.Run()
	}

	fetcher := &dockerStreamFetcher{
		extraArgs: []string{},
		runDocker: mockRunDocker,
	}

	_, err := fetcher.FetchStreamsAfter("DELETED_VID")
	if err == nil {
		t.Fatalf("expected error, got nil")
	}

	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("expected *exec.ExitError, got %T", err)
	}

	if exitErr.ExitCode() != 2 {
		t.Fatalf("expected exit code 2, got %d", exitErr.ExitCode())
	}
}

