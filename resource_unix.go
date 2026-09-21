//go:build darwin || linux

package main

import "syscall"

func noFileLimits() (current, maximum uint64, unlimited bool, err error) {
	var limit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &limit); err != nil {
		return 0, 0, false, err
	}
	return limit.Cur, limit.Max, limit.Max == ^uint64(0), nil
}

func setNoFileLimit(value uint64) error {
	limit := syscall.Rlimit{Cur: value, Max: value}
	if _, maximum, unlimited, err := noFileLimits(); err == nil {
		limit.Max = maximum
		if unlimited || maximum >= value {
			return syscall.Setrlimit(syscall.RLIMIT_NOFILE, &limit)
		}
	}
	return syscall.Setrlimit(syscall.RLIMIT_NOFILE, &limit)
}
