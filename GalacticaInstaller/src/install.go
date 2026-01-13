package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const (
	MOUNT_POINT = "/mnt/galactica"
	SOURCE_DIR  = "../../galactica-build/"  // Where your galactica-build is
)

// InstallProgressMsg is sent during installation
type InstallProgressMsg struct {
	step int
	err  error
}

// InstallCompleteMsg is sent when installation is complete
type InstallCompleteMsg struct{}

// doInstall performs the actual installation
func (m Model) doInstall() tea.Cmd {
	return func() tea.Msg {
		// Step 0: Unmount any existing partitions
		if err := UnmountDisk(m.selectedDisk); err != nil {
			return InstallProgressMsg{step: 0, err: fmt.Errorf("unmount failed: %w", err)}
		}
		
		// Step 1: Partition disk
		time.Sleep(500 * time.Millisecond) // Small delay for UI
		if err := PartitionDisk(m.selectedDisk); err != nil {
			return InstallProgressMsg{step: 0, err: fmt.Errorf("partitioning failed: %w", err)}
		}
		
		// Wait for kernel to recognize new partitions
		time.Sleep(2 * time.Second)
		
		// Force kernel to re-read partition table
		exec.Command("partprobe", m.selectedDisk).Run()
		time.Sleep(1 * time.Second)
		
		// Step 2: Format filesystems
		if err := FormatFilesystems(m.selectedDisk); err != nil {
			return InstallProgressMsg{step: 1, err: fmt.Errorf("formatting failed: %w", err)}
		}
		
		// Step 3: Mount filesystems
		if err := MountFilesystems(m.selectedDisk); err != nil {
			return InstallProgressMsg{step: 2, err: fmt.Errorf("mounting failed: %w", err)}
		}
		
		// Step 4: Install base system
		if err := InstallBaseSystem(); err != nil {
			return InstallProgressMsg{step: 3, err: fmt.Errorf("base system install failed: %w", err)}
		}
		
		// Step 5: Install kernel
		if err := InstallKernel(); err != nil {
			return InstallProgressMsg{step: 4, err: fmt.Errorf("kernel install failed: %w", err)}
		}
		
		// Step 6: Configure system
		if err := ConfigureSystem(m.hostname); err != nil {
			return InstallProgressMsg{step: 5, err: fmt.Errorf("system configuration failed: %w", err)}
		}
		
		// Step 7: Install bootloader
		if err := InstallBootloader(m.selectedDisk); err != nil {
			return InstallProgressMsg{step: 6, err: fmt.Errorf("bootloader install failed: %w", err)}
		}
		
		// Step 8: Setup users
		if err := SetupUsers(m.rootPassword, m.username, m.userPassword); err != nil {
			return InstallProgressMsg{step: 7, err: fmt.Errorf("user setup failed: %w", err)}
		}
		
		// Step 9: Generate fstab
		if err := GenerateFstab(m.selectedDisk); err != nil {
			return InstallProgressMsg{step: 8, err: fmt.Errorf("fstab generation failed: %w", err)}
		}
		
		// Step 10: Finalize
		if err := FinalizeInstallation(); err != nil {
			return InstallProgressMsg{step: 9, err: fmt.Errorf("finalization failed: %w", err)}
		}
		
		return InstallCompleteMsg{}
	}
}

// getPartitionPath returns the correct partition path for a device
func getPartitionPath(device string, partNum int) string {
	// Loop devices and nvme devices use 'p' separator
	if strings.Contains(device, "loop") || strings.Contains(device, "nvme") {
		return fmt.Sprintf("%sp%d", device, partNum)
	}
	// Regular disks (sda, sdb, etc.) just append the number
	return fmt.Sprintf("%s%d", device, partNum)
}

// PartitionDisk creates partitions on the disk
func PartitionDisk(device string) error {
	// For loop devices, we need special handling
	isLoopDevice := strings.Contains(device, "loop")
	
	// Wipe existing partition table
	cmd := exec.Command("dd", "if=/dev/zero", "of="+device, "bs=512", "count=1")
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to wipe disk: %w (output: %s)", err, string(output))
	}
	
	// Sync to ensure write is complete
	exec.Command("sync").Run()
	time.Sleep(500 * time.Millisecond)
	
	// Create new partition table (MSDOS/MBR for simplicity)
	cmd = exec.Command("parted", "-s", device, "mklabel", "msdos")
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to create partition table: %w (output: %s)", err, string(output))
	}
	
	// Create boot partition (512MB)
	cmd = exec.Command("parted", "-s", "-a", "optimal", device, "mkpart", "primary", "ext4", "1MiB", "513MiB")
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to create boot partition: %w (output: %s)", err, string(output))
	}
	
	// Mark as bootable
	cmd = exec.Command("parted", "-s", device, "set", "1", "boot", "on")
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to set boot flag: %w (output: %s)", err, string(output))
	}
	
	// Create swap partition (2GB)
	cmd = exec.Command("parted", "-s", "-a", "optimal", device, "mkpart", "primary", "linux-swap", "513MiB", "2561MiB")
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to create swap partition: %w (output: %s)", err, string(output))
	}
	
	// Create root partition (rest of disk)
	cmd = exec.Command("parted", "-s", "-a", "optimal", device, "mkpart", "primary", "ext4", "2561MiB", "100%")
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to create root partition: %w (output: %s)", err, string(output))
	}
	
	// Sync and wait
	exec.Command("sync").Run()
	
	// Force kernel to re-read partition table
	if isLoopDevice {
		// For loop devices, use partx
		exec.Command("partx", "-u", device).Run()
		time.Sleep(1 * time.Second)
		
		// Also try losetup to refresh partitions
		exec.Command("losetup", "-P", device).Run()
		time.Sleep(1 * time.Second)
	} else {
		// For regular disks, use partprobe
		exec.Command("partprobe", device).Run()
		time.Sleep(1 * time.Second)
	}
	
	// Wait for partitions to appear in /dev
	maxWait := 10 // seconds
	for i := 0; i < maxWait; i++ {
		part1 := getPartitionPath(device, 1)
		if _, err := os.Stat(part1); err == nil {
			// Partition exists, we're good
			return nil
		}
		time.Sleep(1 * time.Second)
	}
	
	return fmt.Errorf("partitions did not appear after %d seconds", maxWait)
}

// FormatFilesystems formats the partitions
func FormatFilesystems(device string) error {
	bootPart := getPartitionPath(device, 1)
	swapPart := getPartitionPath(device, 2)
	rootPart := getPartitionPath(device, 3)
	
	// Check if partitions exist
	for i, part := range []string{bootPart, swapPart, rootPart} {
		if _, err := os.Stat(part); os.IsNotExist(err) {
			return fmt.Errorf("partition %d does not exist at %s - partitioning may have failed", i+1, part)
		}
	}
	
	// Format boot partition
	cmd := exec.Command("mkfs.ext4", "-F", "-L", "GalacticaBoot", bootPart)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to format boot partition %s: %w (output: %s)", bootPart, err, string(output))
	}
	
	// Format and enable swap
	cmd = exec.Command("mkswap", "-L", "GalacticaSwap", swapPart)
	output, err = cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to format swap %s: %w (output: %s)", swapPart, err, string(output))
	}
	
	cmd = exec.Command("swapon", swapPart)
	_ = cmd.Run() // Don't fail if swap enable fails
	
	// Format root partition
	cmd = exec.Command("mkfs.ext4", "-F", "-L", "GalacticaRoot", rootPart)
	output, err = cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to format root partition %s: %w (output: %s)", rootPart, err, string(output))
	}
	
	return nil
}

// MountFilesystems mounts the partitions
func MountFilesystems(device string) error {
	rootPart := getPartitionPath(device, 3)
	bootPart := getPartitionPath(device, 1)
	
	// Create mount point
	if err := os.MkdirAll(MOUNT_POINT, 0755); err != nil {
		return fmt.Errorf("failed to create mount point: %w", err)
	}
	
	// Mount root
	if err := Mount(rootPart, MOUNT_POINT, "ext4"); err != nil {
		return fmt.Errorf("failed to mount root %s: %w", rootPart, err)
	}
	
	// Create and mount boot
	bootDir := filepath.Join(MOUNT_POINT, "boot")
	if err := os.MkdirAll(bootDir, 0755); err != nil {
		return fmt.Errorf("failed to create boot directory: %w", err)
	}
	
	if err := Mount(bootPart, bootDir, "ext4"); err != nil {
		return fmt.Errorf("failed to mount boot %s: %w", bootPart, err)
	}
	
	return nil
}

// InstallBaseSystem copies the base system files
func InstallBaseSystem() error {
	// Check if source directory exists
	if _, err := os.Stat(SOURCE_DIR); os.IsNotExist(err) {
		return fmt.Errorf("source directory not found: %s (you need to build Galactica first)", SOURCE_DIR)
	}
	
	// Use rsync to copy everything
	cmd := exec.Command("rsync", "-aAXv",
		"--exclude=/boot/*",
		"--exclude=/dev/*",
		"--exclude=/proc/*",
		"--exclude=/sys/*",
		"--exclude=/run/*",
		SOURCE_DIR+"/",
		MOUNT_POINT+"/")
	
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to copy base system: %w (output: %s)", err, string(output))
	}
	
	return nil
}

// InstallKernel copies the kernel to /boot
func InstallKernel() error {
	kernelSrc := filepath.Join(SOURCE_DIR, "boot", "vmlinuz-galactica")
	kernelDst := filepath.Join(MOUNT_POINT, "boot", "vmlinuz-galactica")
	
	// Check if kernel exists
	if _, err := os.Stat(kernelSrc); os.IsNotExist(err) {
		return fmt.Errorf("kernel not found at %s", kernelSrc)
	}
	
	// Copy kernel
	cmd := exec.Command("cp", kernelSrc, kernelDst)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to copy kernel: %w", err)
	}
	
	// Copy kernel modules if they exist
	modulesSrc := filepath.Join(SOURCE_DIR, "lib", "modules")
	if _, err := os.Stat(modulesSrc); err == nil {
		modulesDst := filepath.Join(MOUNT_POINT, "lib", "modules")
		cmd = exec.Command("cp", "-r", modulesSrc, modulesDst)
		_ = cmd.Run() // Don't fail if modules don't exist
	}
	
	return nil
}

// ConfigureSystem sets up basic system configuration
func ConfigureSystem(hostname string) error {
	// Set hostname
	hostnamePath := filepath.Join(MOUNT_POINT, "etc", "hostname")
	if err := os.WriteFile(hostnamePath, []byte(hostname+"\n"), 0644); err != nil {
		return fmt.Errorf("failed to write hostname: %w", err)
	}
	
	// Configure hosts file
	hostsPath := filepath.Join(MOUNT_POINT, "etc", "hosts")
	hosts := fmt.Sprintf(`127.0.0.1   localhost %s
::1         localhost
`, hostname)
	if err := os.WriteFile(hostsPath, []byte(hosts), 0644); err != nil {
		return fmt.Errorf("failed to write hosts: %w", err)
	}
	
	// Configure DNS
	resolvPath := filepath.Join(MOUNT_POINT, "etc", "resolv.conf")
	resolv := "nameserver 8.8.8.8\nnameserver 8.8.4.4\n"
	if err := os.WriteFile(resolvPath, []byte(resolv), 0644); err != nil {
		return fmt.Errorf("failed to write resolv.conf: %w", err)
	}
	
	return nil
}

// InstallBootloader installs and configures extlinux
func InstallBootloader(device string) error {
	bootDir := filepath.Join(MOUNT_POINT, "boot")
	rootPart := getPartitionPath(device, 3)
	
	// Install extlinux
	cmd := exec.Command("extlinux", "--install", bootDir)
	if err := cmd.Run(); err != nil {
		// Try with syslinux if extlinux fails
		cmd = exec.Command("syslinux", "--install", bootDir)
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("failed to install bootloader (tried extlinux and syslinux): %w", err)
		}
	}
	
	// Write MBR
	mbrPaths := []string{
		"/usr/lib/syslinux/mbr/mbr.bin",
		"/usr/share/syslinux/mbr.bin",
		"/usr/lib/syslinux/bios/mbr.bin",
	}
	
	var mbrPath string
	for _, path := range mbrPaths {
		if _, err := os.Stat(path); err == nil {
			mbrPath = path
			break
		}
	}
	
	if mbrPath == "" {
		return fmt.Errorf("MBR boot sector not found (tried: %v)", mbrPaths)
	}
	
	cmd = exec.Command("dd", "if="+mbrPath, "of="+device, "bs=440", "count=1")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to write MBR: %w", err)
	}
	
	// Create extlinux configuration
	configPath := filepath.Join(bootDir, "extlinux.conf")
	config := fmt.Sprintf(`DEFAULT galactica
PROMPT 0
TIMEOUT 50

LABEL galactica
    LINUX /vmlinuz-galactica
    APPEND root=%s rw quiet

LABEL recovery
    LINUX /vmlinuz-galactica
    APPEND root=%s rw init=/bin/sh
`, rootPart, rootPart)
	
	if err := os.WriteFile(configPath, []byte(config), 0644); err != nil {
		return fmt.Errorf("failed to write bootloader config: %w", err)
	}
	
	return nil
}

// SetupUsers creates users and sets passwords
func SetupUsers(rootPassword, username, userPassword string) error {
	// Generate password hashes
	rootHash, err := generatePasswordHash(rootPassword)
	if err != nil {
		return fmt.Errorf("failed to generate root password: %w", err)
	}
	
	userHash, err := generatePasswordHash(userPassword)
	if err != nil {
		return fmt.Errorf("failed to generate user password: %w", err)
	}
	
	// Write passwd file
	passwdPath := filepath.Join(MOUNT_POINT, "etc", "passwd")
	passwd := fmt.Sprintf(`root:x:0:0:root:/root:/bin/sh
%s:x:1000:1000:%s:/home/%s:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
`, username, username, username)
	
	if err := os.WriteFile(passwdPath, []byte(passwd), 0644); err != nil {
		return fmt.Errorf("failed to write passwd: %w", err)
	}
	
	// Write shadow file
	shadowPath := filepath.Join(MOUNT_POINT, "etc", "shadow")
	shadow := fmt.Sprintf(`root:%s:19000:0:99999:7:::
%s:%s:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
`, rootHash, username, userHash)
	
	if err := os.WriteFile(shadowPath, []byte(shadow), 0600); err != nil {
		return fmt.Errorf("failed to write shadow: %w", err)
	}
	
	// Write group file
	groupPath := filepath.Join(MOUNT_POINT, "etc", "group")
	group := fmt.Sprintf(`root:x:0:
tty:x:5:%s
video:x:44:%s
audio:x:29:%s
input:x:104:%s
wheel:x:10:%s
%s:x:1000:
nogroup:x:65534:
`, username, username, username, username, username, username)
	
	if err := os.WriteFile(groupPath, []byte(group), 0644); err != nil {
		return fmt.Errorf("failed to write group: %w", err)
	}
	
	// Create user home directory
	homeDir := filepath.Join(MOUNT_POINT, "home", username)
	if err := os.MkdirAll(homeDir, 0755); err != nil {
		return fmt.Errorf("failed to create home directory: %w", err)
	}
	
	// Set ownership (UID 1000, GID 1000)
	if err := os.Chown(homeDir, 1000, 1000); err != nil {
		return fmt.Errorf("failed to set home ownership: %w", err)
	}
	
	return nil
}

// generatePasswordHash generates a SHA-512 password hash
func generatePasswordHash(password string) (string, error) {
	cmd := exec.Command("openssl", "passwd", "-6", "-salt", "galactica", password)
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

// GenerateFstab creates /etc/fstab
func GenerateFstab(device string) error {
	bootPart := getPartitionPath(device, 1)
	swapPart := getPartitionPath(device, 2)
	rootPart := getPartitionPath(device, 3)
	
	bootUUID, _ := getUUID(bootPart)
	swapUUID, _ := getUUID(swapPart)
	rootUUID, _ := getUUID(rootPart)
	
	fstabPath := filepath.Join(MOUNT_POINT, "etc", "fstab")
	fstab := fmt.Sprintf(`# Galactica fstab
UUID=%s  /      ext4  defaults  0  1
UUID=%s  /boot  ext4  defaults  0  2
UUID=%s  none   swap  sw        0  0
`, rootUUID, bootUUID, swapUUID)
	
	if err := os.WriteFile(fstabPath, []byte(fstab), 0644); err != nil {
		return fmt.Errorf("failed to write fstab: %w", err)
	}
	
	return nil
}

// getUUID gets the UUID of a partition
func getUUID(device string) (string, error) {
	cmd := exec.Command("blkid", "-s", "UUID", "-o", "value", device)
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

// FinalizeInstallation syncs and unmounts
func FinalizeInstallation() error {
	// Sync to ensure all writes are committed
	exec.Command("sync").Run()
	
	// Unmount boot
	bootDir := filepath.Join(MOUNT_POINT, "boot")
	if err := Unmount(bootDir); err != nil {
		return fmt.Errorf("failed to unmount boot: %w", err)
	}
	
	// Unmount root
	if err := Unmount(MOUNT_POINT); err != nil {
		return fmt.Errorf("failed to unmount root: %w", err)
	}
	
	// Turn off swap
	exec.Command("swapoff", "-a").Run()
	
	return nil
}
