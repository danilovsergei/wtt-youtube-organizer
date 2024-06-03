package shell

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type ExecScriptOut struct {
	ScriptName string
	Err        string
	Out        string
	Combined   string
	ErrOut     string
}

func ExecuteScript(command string, args ...string) *ExecScriptOut {
	cmd := exec.Command(command, args...)
	cmd.Env = os.Environ()

	fmt.Printf("Execute: %s %s\n", command, strings.Join(args, " "))

	// Set output to Byte Buffers
	if cmd.Stdout != nil || cmd.Stderr != nil {
		return &ExecScriptOut{
			ScriptName: filepath.Base(command),
			Err:        "Stdout/StdErr already set"}
	}

	var outb, errb bytes.Buffer
	cmd.Stdout = &outb
	cmd.Stderr = &errb
	err := cmd.Run()
	errString := ""
	if err != nil {
		errString = err.Error()
		// Add more information from error output in case of critical error
		if errb.String() != "" {
			errString = errString + "\n" + errb.String()
		}
	}
	return &ExecScriptOut{
		ScriptName: filepath.Base(command),
		Out:        outb.String(),
		ErrOut:     errb.String(),
		Combined:   outb.String() + "\n" + errb.String(),
		Err:        errString}
}
