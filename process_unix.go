//go:build darwin || linux

package main

import (
	"os"
	"os/exec"
	"syscall"
)

func configureProcess(cmd *exec.Cmd, processGroup bool) {
	if processGroup {
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	}
}

func interruptProcess(cmd *exec.Cmd, processGroup bool) error {
	if processGroup {
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGINT)
	}
	return cmd.Process.Signal(os.Interrupt)
}

func killProcess(cmd *exec.Cmd, processGroup bool) error {
	if processGroup {
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	return cmd.Process.Kill()
}
