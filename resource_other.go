//go:build !darwin && !linux

package main

func noFileLimits() (current, maximum uint64, unlimited bool, err error) { return 0, 0, false, nil }
func setNoFileLimit(_ uint64) error                                      { return nil }
