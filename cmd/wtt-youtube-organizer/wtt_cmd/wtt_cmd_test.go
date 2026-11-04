package wtt_cmd

import (
	"bytes"
	"testing"
)

func TestNewCommand_Structure(t *testing.T) {
	cmd := NewCommand()
	if cmd.Use != "wtt" {
		t.Errorf("expected use 'wtt', got %s", cmd.Use)
	}

	subCommands := cmd.Commands()
	expectedSubs := map[string]bool{
		"list-events":     false,
		"list-matches":    false,
		"generate-report": false,
	}

	for _, sub := range subCommands {
		if _, ok := expectedSubs[sub.Name()]; ok {
			expectedSubs[sub.Name()] = true
		}
	}

	for name, found := range expectedSubs {
		if !found {
			t.Errorf("missing expected subcommand: %s", name)
		}
	}
}

func TestListMatchesCommand_RequiresEventID(t *testing.T) {
	cmd := newListMatchesCommand()
	cmd.SetArgs([]string{}) // Missing --event-id
	var buf bytes.Buffer
	cmd.SetOut(&buf)
	cmd.SetErr(&buf)

	err := cmd.Execute()
	if err == nil {
		t.Fatalf("expected error when --event-id is omitted, got nil")
	}
}

func TestGenerateReportCommand_RequiresTournamentName(t *testing.T) {
	cmd := newGenerateReportCommand()
	cmd.SetArgs([]string{}) // Missing --tournament-name
	var buf bytes.Buffer
	cmd.SetOut(&buf)
	cmd.SetErr(&buf)

	err := cmd.Execute()
	if err == nil {
		t.Fatalf("expected error when --tournament-name is omitted, got nil")
	}
}
