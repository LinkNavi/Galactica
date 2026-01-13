package main

import (
	"fmt"
	"os/exec"
	"syscall"
)

// Mount mounts a filesystem
func Mount(source, target, fstype string) error {
	// Try using syscall first
	err := syscall.Mount(source, target, fstype, 0, "")
	if err == nil {
		return nil
	}
	
	// Fallback to mount command
	cmd := exec.Command("mount", "-t", fstype, source, target)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("mount failed: %w", err)
	}
	
	return nil
}

// Unmount unmounts a filesystem
func Unmount(target string) error {
	// Try using syscall first
	err := syscall.Unmount(target, 0)
	if err == nil {
		return nil
	}
	
	// Fallback to umount command
	cmd := exec.Command("umount", target)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("unmount failed: %w", err)
	}
	
	return nil
}
