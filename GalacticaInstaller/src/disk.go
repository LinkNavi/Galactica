package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// DiskInfo represents information about a disk
type DiskInfo struct {
	Device    string
	Size      uint64
	Model     string
	SizeHuman string
}

// TESTING MODE - Set to true to only show loop/test devices
const TESTING_MODE = true

// ScanDisks scans for available disks on the system
func ScanDisks() ([]DiskInfo, error) {
	var disks []DiskInfo
	
	// Read from /sys/block to find disks
	entries, err := os.ReadDir("/sys/block")
	if err != nil {
		return nil, fmt.Errorf("failed to read /sys/block: %w", err)
	}
	
	for _, entry := range entries {
		name := entry.Name()
		
		// In testing mode, ONLY show loop devices
		if TESTING_MODE {
			if !strings.HasPrefix(name, "loop") {
				continue
			}
		} else {
			// In production mode, skip loop devices, ram disks, etc.
			if strings.HasPrefix(name, "loop") || 
			   strings.HasPrefix(name, "ram") ||
			   strings.HasPrefix(name, "dm-") ||
			   strings.HasPrefix(name, "zram") {
				continue
			}
		}
		
		// Check if it's a real disk (has a size)
		sizePath := filepath.Join("/sys/block", name, "size")
		sizeData, err := os.ReadFile(sizePath)
		if err != nil {
			continue
		}
		
		// Size is in 512-byte sectors
		sectors, err := strconv.ParseUint(strings.TrimSpace(string(sizeData)), 10, 64)
		if err != nil || sectors == 0 {
			continue
		}
		
		sizeBytes := sectors * 512
		
		// Read model name
		modelPath := filepath.Join("/sys/block", name, "device/model")
		modelData, _ := os.ReadFile(modelPath)
		model := strings.TrimSpace(string(modelData))
		if model == "" {
			if strings.HasPrefix(name, "loop") {
				model = "Test Loop Device"
			} else {
				model = "Unknown"
			}
		}
		
		disks = append(disks, DiskInfo{
			Device:    "/dev/" + name,
			Size:      sizeBytes,
			Model:     model,
			SizeHuman: formatSize(sizeBytes),
		})
	}
	
	if len(disks) == 0 {
		if TESTING_MODE {
			return nil, fmt.Errorf("no loop devices found - did you create a test disk?")
		}
		return nil, fmt.Errorf("no disks found")
	}
	
	return disks, nil
}

// formatSize formats bytes into human-readable size
func formatSize(bytes uint64) string {
	const (
		KB = 1024
		MB = KB * 1024
		GB = MB * 1024
		TB = GB * 1024
	)
	
	switch {
	case bytes >= TB:
		return fmt.Sprintf("%.2f TB", float64(bytes)/float64(TB))
	case bytes >= GB:
		return fmt.Sprintf("%.2f GB", float64(bytes)/float64(GB))
	case bytes >= MB:
		return fmt.Sprintf("%.2f MB", float64(bytes)/float64(MB))
	case bytes >= KB:
		return fmt.Sprintf("%.2f KB", float64(bytes)/float64(KB))
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}

// UnmountDisk unmounts all partitions on a disk
func UnmountDisk(device string) error {
	// Read /proc/mounts to find mounted partitions
	file, err := os.Open("/proc/mounts")
	if err != nil {
		return err
	}
	defer file.Close()
	
	var toUnmount []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 {
			continue
		}
		mountDevice := fields[0]
		mountPoint := fields[1]
		
		// Check if this partition belongs to our disk
		if strings.HasPrefix(mountDevice, device) {
			toUnmount = append(toUnmount, mountPoint)
		}
	}
	
	// Unmount in reverse order (deepest first)
	for i := len(toUnmount) - 1; i >= 0; i-- {
		if err := Unmount(toUnmount[i]); err != nil {
			return fmt.Errorf("failed to unmount %s: %w", toUnmount[i], err)
		}
	}
	
	return nil
}
