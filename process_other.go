//go:build !darwin && !linux

package main

import (
	"os"
	"os/exec"
)

func configureProcess(_ *exec.Cmd, _ bool) {}

func interruptProcess(cmd *exec.Cmd, _ bool) error { return cmd.Process.Signal(os.Interrupt) }

func killProcess(cmd *exec.Cmd, _ bool) error { return cmd.Process.Kill() }
