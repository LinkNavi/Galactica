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

const MOUNT_POINT = "/mnt/galactica"

var installError error = nil
func unmountChroot() {
	exec.Command("umount", filepath.Join(MOUNT_POINT, "proc")).Run()
	exec.Command("umount", filepath.Join(MOUNT_POINT, "sys")).Run()
	exec.Command("umount", filepath.Join(MOUNT_POINT, "dev")).Run()
}
func getSourceDir() string {
	if env := os.Getenv("GALACTICA_SOURCE"); env != "" {
		return env
	}
	if _, err := os.Stat("/galactica-build"); err == nil {
		return "/galactica-build"
	}
	if _, err := os.Stat("./galactica-build"); err == nil {
		return "./galactica-build"
	}
	return "/galactica-build"
}
var installLog *os.File

func initLog() {
	os.MkdirAll("/var/log", 0755)
	f, err := os.OpenFile("/var/log/galactica-install.log", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		fmt.Println("Warning: could not open log file:", err)
		return
	}
	installLog = f
}

func logf(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	fmt.Print(msg)
	if installLog != nil {
		installLog.WriteString(msg)
	}
}
// ============================================================
// Tea messages
// ============================================================

type InstallProgressMsg struct {
	step int
	err  error
}

type InstallCompleteMsg struct{}

var currentInstallStep int = 0
var installationRunning bool = false

// ============================================================
// Installation driver
// ============================================================

func (m Model) doInstall() tea.Cmd {
initLog()
	currentInstallStep = 0
	installationRunning = true
	installError = nil

	go func() {
		steps := []struct {
			name string
			fn   func(string, string, string, string, string) error
		}{
			{"Partitioning disk", func(disk, _, _, _, _ string) error {
				if err := UnmountDisk(disk); err != nil {
					return fmt.Errorf("unmount failed: %w", err)
				}
				time.Sleep(500 * time.Millisecond)
				return PartitionDisk(disk)
			}},
			{"Formatting filesystems", func(disk, _, _, _, _ string) error {
				time.Sleep(2 * time.Second)
				exec.Command("partx", "-u", disk).Run()
				time.Sleep(1 * time.Second)
				return FormatFilesystems(disk)
			}},
			{"Mounting filesystems", func(disk, _, _, _, _ string) error {
				return MountFilesystems(disk)
			}},
			{"Installing base system", func(_, _, _, _, _ string) error {
				return InstallBaseSystem()
			}},
			{"Installing kernel", func(_, _, _, _, _ string) error {
				return InstallKernel()
			}},
			{"Configuring system", func(_, hostname, _, _, _ string) error {
				return ConfigureSystem(hostname)
			}},
			{"Installing bootloader", func(disk, _, _, _, _ string) error {
				return InstallBootloader(disk)
			}},
			{"Setting up users", func(_, _, rootPass, user, userPass string) error {
				return SetupUsers(rootPass, user, userPass)
			}},
			{"Generating fstab", func(disk, _, _, _, _ string) error {
				return GenerateFstab(disk)
			}},
			{"Finalizing installation", func(_, _, _, _, _ string) error {
				return FinalizeInstallation()
			}},

		}

		for i, step := range steps {
			currentInstallStep = i
			if err := step.fn(m.selectedDisk, m.hostname, m.rootPassword, m.username, m.userPassword); err != nil {
				installError = fmt.Errorf("step '%s' failed: %w", step.name, err)
				installationRunning = false
				return
			}
		}

		currentInstallStep = len(steps)
		installationRunning = false
 exec.Command("cp", "/var/log/galactica-install.log",
        filepath.Join(MOUNT_POINT, "var", "log", "galactica-install.log")).Run()
	}()
exec.Command("cp", "/var/log/galactica-install.log",
    filepath.Join(MOUNT_POINT, "var", "log", "galactica-install.log")).Run()
	return installProgressTicker()
}

func installProgressTicker() tea.Cmd {
	return tea.Tick(time.Millisecond*500, func(time.Time) tea.Msg {
		if !installationRunning && currentInstallStep >= 10 {
			return InstallCompleteMsg{}
		}
		return InstallProgressMsg{step: currentInstallStep, err: installError}
	})
}

// ============================================================
// Helpers
// ============================================================

func getPartitionPath(device string, partNum int) string {
	if strings.Contains(device, "loop") || strings.Contains(device, "nvme") {
		return fmt.Sprintf("%sp%d", device, partNum)
	}
	return fmt.Sprintf("%s%d", device, partNum)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func getUUID(device string) (string, error) {
	cmd := exec.Command("blkid", "-p", "-s", "UUID", "-o", "value", device)
	output, err := cmd.Output()
	if err != nil {
		// fallback without -p
		cmd = exec.Command("blkid", "-s", "UUID", "-o", "value", device)
		output, err = cmd.Output()
		if err != nil {
			return "", err
		}
	}
	return strings.TrimSpace(string(output)), nil
}

// isUEFI returns true if the installer is running on a UEFI system.
func isUEFI() bool {
	_, err := os.Stat("/sys/firmware/efi")
	return err == nil
}

// ============================================================
// Partitioning
// ============================================================

func PartitionDisk(device string) error {
	isLoop := strings.Contains(device, "loop")
	uefi := isUEFI()

	// Wipe existing partition table
	cmd := exec.Command("dd", "if=/dev/zero", "of="+device, "bs=512", "count=1")
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to wipe disk: %w (output: %s)", err, string(output))
	}
	exec.Command("sync").Run()
	time.Sleep(500 * time.Millisecond)

	if uefi {
		// GPT layout:
		//   1 — EFI  (FAT32, 512 MB)
		//   2 — swap (2 GB)
		//   3 — root (rest)
		cmds := [][]string{
			{"parted", "-s", device, "mklabel", "gpt"},
			{"parted", "-s", "-a", "optimal", device, "mkpart", "EFI", "fat32", "1MiB", "513MiB"},
			{"parted", "-s", device, "set", "1", "esp", "on"},
			{"parted", "-s", "-a", "optimal", device, "mkpart", "swap", "linux-swap", "513MiB", "2561MiB"},
			{"parted", "-s", "-a", "optimal", device, "mkpart", "root", "ext4", "2561MiB", "100%"},
		}
		for _, args := range cmds {
			if output, err := exec.Command(args[0], args[1:]...).CombinedOutput(); err != nil {
				return fmt.Errorf("parted %v failed: %w (output: %s)", args, err, string(output))
			}
		}
	} else {
		// MBR layout:
		//   1 — boot (ext4, 512 MB)
		//   2 — swap (2 GB)
		//   3 — root (rest)
		cmds := [][]string{
			{"parted", "-s", device, "mklabel", "msdos"},
			{"parted", "-s", "-a", "optimal", device, "mkpart", "primary", "ext4", "1MiB", "513MiB"},
			{"parted", "-s", device, "set", "1", "boot", "on"},
			{"parted", "-s", "-a", "optimal", device, "mkpart", "primary", "linux-swap", "513MiB", "2561MiB"},
			{"parted", "-s", "-a", "optimal", device, "mkpart", "primary", "ext4", "2561MiB", "100%"},
		}
		for _, args := range cmds {
			if output, err := exec.Command(args[0], args[1:]...).CombinedOutput(); err != nil {
				return fmt.Errorf("parted %v failed: %w (output: %s)", args, err, string(output))
			}
		}
	}

	exec.Command("sync").Run()

	if isLoop {
		exec.Command("partx", "-u", device).Run()
		time.Sleep(1 * time.Second)
		exec.Command("losetup", "-P", device).Run()
		time.Sleep(1 * time.Second)
	} else {
		exec.Command("partx", "-u", device).Run()
		time.Sleep(1 * time.Second)
	}

	// Wait for partitions to appear
	for i := 0; i < 10; i++ {
		if _, err := os.Stat(getPartitionPath(device, 1)); err == nil {
			return nil
		}
		time.Sleep(1 * time.Second)
	}
	return fmt.Errorf("partitions did not appear after 10 seconds")
}

// ============================================================
// Formatting
// ============================================================

func FormatFilesystems(device string) error {
	bootPart := getPartitionPath(device, 1)
	swapPart := getPartitionPath(device, 2)
	rootPart := getPartitionPath(device, 3)

	for i, part := range []string{bootPart, swapPart, rootPart} {
		if _, err := os.Stat(part); os.IsNotExist(err) {
			return fmt.Errorf("partition %d does not exist at %s", i+1, part)
		}
	}

	if isUEFI() {
		cmd := exec.Command("mkfs.fat", "-F32", "-n", "GALACTICAEFI", bootPart)
		if output, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to format EFI partition %s: %w (output: %s)", bootPart, err, string(output))
		}
	} else {
		cmd := exec.Command("mkfs.ext4", "-F", "-L", "GalacticaBoot", bootPart)
		if output, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to format boot partition %s: %w (output: %s)", bootPart, err, string(output))
		}
	}

	if output, err := exec.Command("mkswap", "-L", "GalacticaSwap", swapPart).CombinedOutput(); err != nil {
		return fmt.Errorf("failed to format swap %s: %w (output: %s)", swapPart, err, string(output))
	}
	exec.Command("swapon", swapPart).Run()

	if output, err := exec.Command("mkfs.ext4", "-F", "-L", "GalacticaRoot", rootPart).CombinedOutput(); err != nil {
		return fmt.Errorf("failed to format root partition %s: %w (output: %s)", rootPart, err, string(output))
	}

	return nil
}

// ============================================================
// Mounting
// ============================================================

func MountFilesystems(device string) error {
	rootPart := getPartitionPath(device, 3)
	bootPart := getPartitionPath(device, 1)

	if err := os.MkdirAll(MOUNT_POINT, 0755); err != nil {
		return fmt.Errorf("failed to create mount point: %w", err)
	}
	if err := Mount(rootPart, MOUNT_POINT, "ext4"); err != nil {
		return fmt.Errorf("failed to mount root %s: %w", rootPart, err)
	}

	if isUEFI() {
		efiDir := filepath.Join(MOUNT_POINT, "boot", "efi")
		if err := os.MkdirAll(efiDir, 0755); err != nil {
			return fmt.Errorf("failed to create EFI dir: %w", err)
		}
		if err := Mount(bootPart, efiDir, "vfat"); err != nil {
			return fmt.Errorf("failed to mount EFI partition %s: %w", bootPart, err)
		}
	} else {
		bootDir := filepath.Join(MOUNT_POINT, "boot")
		if err := os.MkdirAll(bootDir, 0755); err != nil {
			return fmt.Errorf("failed to create boot dir: %w", err)
		}
		if err := Mount(bootPart, bootDir, "ext4"); err != nil {
			return fmt.Errorf("failed to mount boot %s: %w", bootPart, err)
		}
	}

	return nil
}

// ============================================================
// Base system + kernel
// ============================================================

func InstallBaseSystem() error {
	// Create minimal directory structure
	dirs := []string{
		"bin", "sbin", "usr/bin", "usr/sbin", "etc", "lib", "lib64",
		"proc", "sys", "dev", "run", "tmp", "root", "home",
		"var/log", "var/run", "boot",
	}
	for _, d := range dirs {
		os.MkdirAll(filepath.Join(MOUNT_POINT, d), 0755)
	}
	os.Chmod(filepath.Join(MOUNT_POINT, "tmp"), 0o1777)
	os.Chmod(filepath.Join(MOUNT_POINT, "root"), 0o700)

	// Copy dreamland and its libs into the new root
	dreamlandSrc := "/sbin/dreamland"
	if !fileExists(dreamlandSrc) {
		dreamlandSrc = "/usr/bin/dreamland"
	}
	if !fileExists(dreamlandSrc) {
		return fmt.Errorf("dreamland not found in initrd")
	}
	dreamlandDst := filepath.Join(MOUNT_POINT, "usr/bin/dreamland")
	if err := exec.Command("cp", dreamlandSrc, dreamlandDst).Run(); err != nil {
		return fmt.Errorf("failed to copy dreamland: %w", err)
	}
	os.Chmod(dreamlandDst, 0755)
	exec.Command("ln", "-sf", "dreamland", filepath.Join(MOUNT_POINT, "usr/bin/dl")).Run()

	// Copy libs needed by dreamland

	if err := exec.Command("cp", "-a", "/lib/.", filepath.Join(MOUNT_POINT, "lib")+"/").Run(); err != nil {
		logf("WARNING: lib copy failed: %v\n", err)
	}
	if fileExists("/lib64") {
		exec.Command("cp", "-a", "/lib64/.", filepath.Join(MOUNT_POINT, "lib64")+"/").Run()
	}
	if fileExists("/usr/lib") {
		os.MkdirAll(filepath.Join(MOUNT_POINT, "usr/lib"), 0755)
		exec.Command("cp", "-a", "/usr/lib/.", filepath.Join(MOUNT_POINT, "usr/lib")+"/").Run()
	}
	if fileExists("/usr/lib64") {
		os.MkdirAll(filepath.Join(MOUNT_POINT, "usr/lib64"), 0755)
		exec.Command("cp", "-a", "/usr/lib64/.", filepath.Join(MOUNT_POINT, "usr/lib64")+"/").Run()
	}
	// Copy curl
	for _, curlPath := range []string{"/usr/bin/curl", "/bin/curl", "/sbin/curl"} {
		if fileExists(curlPath) {
			exec.Command("cp", curlPath, filepath.Join(MOUNT_POINT, "usr/bin/curl")).Run()
			break
		}
	}

	// Copy CA certs
	for _, cert := range []string{
		"/etc/ssl/certs/ca-certificates.crt",
		"/etc/pki/tls/certs/ca-bundle.crt",
		"/etc/ca-certificates/extracted/tls-ca-bundle.pem",
	} {
		if fileExists(cert) {
			os.MkdirAll(filepath.Join(MOUNT_POINT, "etc/ssl/certs"), 0755)
			exec.Command("cp", cert, filepath.Join(MOUNT_POINT, "etc/ssl/certs/ca-certificates.crt")).Run()
			break
		}
	}

	// Copy busybox and create symlinks
	if fileExists("/bin/busybox") {
		exec.Command("cp", "/bin/busybox", filepath.Join(MOUNT_POINT, "bin/busybox")).Run()
		for _, cmd := range []string{"sh", "ash", "ls", "cat", "echo", "cp", "mv", "rm",
			"mkdir", "mount", "umount", "sleep", "grep", "sed", "awk", "ps",
			"kill", "ln", "chmod", "chown", "ip", "ping", "hostname", "uname",
			"tar", "gzip", "gunzip", "udhcpc", "dmesg", "touch", "date"} {
			os.Symlink("busybox", filepath.Join(MOUNT_POINT, "bin", cmd))
		}
	}

	// Copy resolv.conf so dreamland can reach the internet
	exec.Command("cp", "/etc/resolv.conf", filepath.Join(MOUNT_POINT, "etc/resolv.conf")).Run()

	// Bind mount proc/sys/dev for chroot
	exec.Command("mount", "--bind", "/proc", filepath.Join(MOUNT_POINT, "proc")).Run()
	exec.Command("mount", "--bind", "/sys", filepath.Join(MOUNT_POINT, "sys")).Run()
	exec.Command("mount", "--bind", "/dev", filepath.Join(MOUNT_POINT, "dev")).Run()

	// Find chroot binary
	chroot := "/sbin/chroot"
	if !fileExists(chroot) {
		chroot = "/usr/sbin/chroot"
	}
	if !fileExists(chroot) {
		if p, err := exec.LookPath("chroot"); err == nil {
			chroot = p
		} else {
			return fmt.Errorf("chroot not found in initrd")
		}
	}
	logf("Using chroot: %s\n", chroot)

	chrootEnv := []string{
		"PATH=/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME=/root",
		"TERM=linux",
	}

	logf("Running dreamland sync...\n")
	syncCmd := exec.Command(chroot, MOUNT_POINT, "/usr/bin/dreamland", "sync")
	syncCmd.Env = chrootEnv
	out, err := syncCmd.CombinedOutput()
	logf("dreamland sync: %s\n", string(out))
	if err != nil {
		return fmt.Errorf("dreamland sync failed: %w", err)
	}

	logf("Running dreamland install base...\n")
	installCmd := exec.Command(chroot, MOUNT_POINT, "/usr/bin/dreamland", "install", "base")
	installCmd.Env = chrootEnv
	out, err = installCmd.CombinedOutput()
	logf("dreamland install base: %s\n", string(out))
	if err != nil {
		return fmt.Errorf("dreamland install base failed: %w", err)
	}

	return nil
}


func InstallKernel() error {
	chroot := "/sbin/chroot"
	if !fileExists(chroot) {
		chroot = "/usr/sbin/chroot"
	}

	logf("Running dreamland install linux...\n")
	cmd := exec.Command(chroot, MOUNT_POINT, "/usr/bin/dreamland", "install", "linux")
	cmd.Env = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/root"}
	out, err := cmd.CombinedOutput()
	logf("dreamland install linux: %s\n", string(out))
	if err != nil {
		logf("WARNING: dreamland kernel install failed, trying fallback...\n")
		for _, src := range []string{"/boot/vmlinuz-galactica", "/vmlinuz-galactica"} {
			if fileExists(src) {
				exec.Command("cp", src, filepath.Join(MOUNT_POINT, "boot/vmlinuz-galactica")).Run()
				logf("Copied kernel from %s\n", src)
				return nil
			}
		}
		return fmt.Errorf("kernel install failed and no fallback kernel found")
	}
	return nil
}

// ============================================================
// System configuration
// ============================================================

func ConfigureSystem(hostname string) error {
	if err := os.WriteFile(filepath.Join(MOUNT_POINT, "etc", "hostname"), []byte(hostname+"\n"), 0644); err != nil {
		return fmt.Errorf("failed to write hostname: %w", err)
	}

	hosts := fmt.Sprintf("127.0.0.1   localhost %s\n::1         localhost\n", hostname)
	if err := os.WriteFile(filepath.Join(MOUNT_POINT, "etc", "hosts"), []byte(hosts), 0644); err != nil {
		return fmt.Errorf("failed to write hosts: %w", err)
	}

	if err := os.WriteFile(filepath.Join(MOUNT_POINT, "etc", "resolv.conf"), []byte("nameserver 8.8.8.8\nnameserver 8.8.4.4\n"), 0644); err != nil {
		return fmt.Errorf("failed to write resolv.conf: %w", err)
	}

	// Pre-create udhcpc script so network-setup works on first boot
	udhcpcDir := filepath.Join(MOUNT_POINT, "usr", "share", "udhcpc")
	if err := os.MkdirAll(udhcpcDir, 0755); err != nil {
		return fmt.Errorf("failed to create udhcpc dir: %w", err)
	}
	udhcpcScript := `#!/bin/sh
case "$1" in
    deconfig)
        ip addr flush dev "$interface" 2>/dev/null
        ip link set "$interface" up
        ;;
    bound|renew)
        ip addr flush dev "$interface" 2>/dev/null
        mask2prefix() {
            local mask="$1" bits=0 IFS=.
            for octet in $mask; do
                case "$octet" in
                    255) bits=$((bits+8));; 254) bits=$((bits+7));;
                    252) bits=$((bits+6));; 248) bits=$((bits+5));;
                    240) bits=$((bits+4));; 224) bits=$((bits+3));;
                    192) bits=$((bits+2));; 128) bits=$((bits+1));;
                esac
            done
            echo $bits
        }
        PREFIX=$(mask2prefix "${subnet:-255.255.255.0}")
        ip addr add "$ip/$PREFIX" dev "$interface"
        [ -n "$router" ] && {
            while ip route del default 2>/dev/null; do :; done
            for gw in $router; do ip route add default via "$gw" dev "$interface" && break; done
        }
        { echo "# DHCP $(date)"; for ns in $dns 8.8.8.8 8.8.4.4; do echo "nameserver $ns"; done; } > /etc/resolv.conf
        ;;
esac
exit 0
`
	scriptPath := filepath.Join(udhcpcDir, "default.script")
	if err := os.WriteFile(scriptPath, []byte(udhcpcScript), 0755); err != nil {
		return fmt.Errorf("failed to write udhcpc script: %w", err)
	}

	return nil
}

// ============================================================
// Bootloader
// ============================================================
func InstallBootloader(device string) error {
	rootPart := getPartitionPath(device, 3)
	bootPart := getPartitionPath(device, 1)

	if isUEFI() {
		if err := installGRUB_UEFI(device); err != nil {
			return err
		}
	} else {
		if err := installGRUB_BIOS(device); err != nil {
			return err
		}
	}

	if err := buildInitramfsAndWriteGRUB(rootPart, bootPart); err != nil {
		logf("WARNING: initramfs build failed: %v\n", err)
		logf("DEBUG: rootPart=%s bootPart=%s\n", rootPart, bootPart)
		fmt.Println("Falling back to device path (no initramfs)...")
		return writeGRUBConfig(false, false, rootPart, bootPart)
	}
	return nil
}

func installGRUB_BIOS(device string) error {
	cmd := exec.Command("grub-install",
		"--target=i386-pc",
		"--boot-directory="+filepath.Join(MOUNT_POINT, "boot"),
		"--recheck",
		device,
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("grub-install (BIOS) failed: %w\noutput: %s", err, string(output))
	}
	return nil
}

func installGRUB_UEFI(device string) error {
	efiDir := filepath.Join(MOUNT_POINT, "boot", "efi")
	os.MkdirAll(efiDir, 0755)

	cmd := exec.Command("grub-install",
		"--target=x86_64-efi",
		"--efi-directory="+efiDir,
		"--boot-directory="+filepath.Join(MOUNT_POINT, "boot"),
		"--bootloader-id=Galactica",
		"--recheck",
		device,
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		// UEFI install failed — fall back to BIOS
		logf("UEFI grub-install failed, falling back to BIOS: %s\n", string(output))
		return installGRUB_BIOS(device)
	}
	return nil
}

// buildInitramfsAndWriteGRUB runs ginitrd inside the target via chroot,
// then writes grub.cfg reflecting what was actually built.
func buildInitramfsAndWriteGRUB(rootPart, bootPart string) error {
	ginitrdPath, err := exec.LookPath("ginitrd")
	if err != nil {
		logf("DEBUG: ginitrd not on PATH: %v\n", err)
		ginitrdPath = filepath.Join(MOUNT_POINT, "usr", "sbin", "ginitrd")
		if !fileExists(ginitrdPath) {
			return fmt.Errorf("ginitrd not found on PATH or at %s", ginitrdPath)
		}
		logf("DEBUG: using ginitrd from rootfs: %s\n", ginitrdPath)
	} else {
		logf("DEBUG: found ginitrd at %s\n", ginitrdPath)
	}

	modulesDir := filepath.Join(MOUNT_POINT, "lib", "modules")
	entries, err := os.ReadDir(modulesDir)
	if err != nil || len(entries) == 0 {
		return fmt.Errorf("no kernel modules found in %s: %v", modulesDir, err)
	}
	kernelVer := entries[len(entries)-1].Name()
	logf("DEBUG: kernelVer=%s\n", kernelVer)

	normalImg := filepath.Join(MOUNT_POINT, "boot", "initramfs-galactica.img")
	cmd := exec.Command(ginitrdPath,
		"-k", kernelVer,
		"-d", filepath.Join(MOUNT_POINT, "lib", "modules", kernelVer),
		"-o", normalImg,
		"-c", "zstd",
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ginitrd failed: %w\noutput: %s", err, string(output))
	}

	fallbackImg := filepath.Join(MOUNT_POINT, "boot", "initramfs-galactica-fallback.img")
	exec.Command(ginitrdPath,
		"-k", kernelVer,
		"-d", filepath.Join(MOUNT_POINT, "lib", "modules", kernelVer),
		"-o", fallbackImg,
		"-c", "zstd",
		"-f",
	).CombinedOutput()

	hasNormal := fileExists(normalImg)
	hasFallback := fileExists(fallbackImg)
	return writeGRUBConfig(hasNormal, hasFallback, rootPart, bootPart)
}// writeGRUBConfig writes /boot/grub/grub.cfg inside the target.
// hasInitramfs and hasFallback control whether initrd lines are included.
func writeGRUBConfig(hasInitramfs bool, hasFallback bool, rootPart string, bootPart string) error {
grubDir := filepath.Join(MOUNT_POINT, "boot", "grub")
	if err := os.MkdirAll(grubDir, 0755); err != nil {
		return fmt.Errorf("failed to create grub dir: %w", err)
	}

	var rootArg string
	if hasInitramfs {
		// initramfs can resolve UUID via blkid/findfs
		rootUUID, err := getUUID(rootPart)
		if err == nil && rootUUID != "" {
			rootArg = "UUID=" + rootUUID
		} else {
			rootArg = rootPart
		}
	} else {
		// no initramfs — kernel needs a direct device path
		rootArg = rootPart
	}

	bootLabel := "GalacticaBoot"
	if isUEFI() {
		bootLabel = "GalacticaRoot"
	}

	kernelArgs := fmt.Sprintf("root=%s rootwait rw quiet console=ttyS0,115200 console=tty0", rootArg)

	normalEntry := fmt.Sprintf(`menuentry "Galactica Linux" {
    search --no-floppy --label --set=root %s
    linux  /vmlinuz-galactica %s`, bootLabel, kernelArgs)
	if hasInitramfs {
		normalEntry += "\n    initrd /initramfs-galactica.img"
	}
	normalEntry += "\n}"

	fallbackEntry := ""
	if hasFallback {
		fallbackEntry = fmt.Sprintf(`
menuentry "Galactica Linux (fallback)" {
    search --no-floppy --label --set=root %s
    linux  /vmlinuz-galactica %s
    initrd /initramfs-galactica-fallback.img
}`, bootLabel, kernelArgs)
	}

	recoveryEntry := fmt.Sprintf(`
menuentry "Galactica Linux (recovery)" {
    search --no-floppy --label --set=root %s
    linux /vmlinuz-galactica root=%s rootwait rw init=/bin/sh console=ttyS0,115200 console=tty0
}`, bootLabel, rootArg)

	config := fmt.Sprintf("set timeout=5\nset default=0\n\n%s\n%s\n%s\n",
		normalEntry, fallbackEntry, recoveryEntry)

	return os.WriteFile(filepath.Join(grubDir, "grub.cfg"), []byte(config), 0644)
}
// ============================================================
// Users
// ============================================================

func SetupUsers(rootPassword, username, userPassword string) error {
	rootHash, err := generatePasswordHash(rootPassword)
	if err != nil {
		return fmt.Errorf("failed to generate root password: %w", err)
	}
	userHash, err := generatePasswordHash(userPassword)
	if err != nil {
		return fmt.Errorf("failed to generate user password: %w", err)
	}

	passwd := fmt.Sprintf("root:x:0:0:root:/root:/bin/sh\n%s:x:1000:1000:%s:/home/%s:/bin/sh\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n",
		username, username, username)
	if err := os.WriteFile(filepath.Join(MOUNT_POINT, "etc", "passwd"), []byte(passwd), 0644); err != nil {
		return fmt.Errorf("failed to write passwd: %w", err)
	}

	shadow := fmt.Sprintf("root:%s:19000:0:99999:7:::\n%s:%s:19000:0:99999:7:::\nnobody:*:19000:0:99999:7:::\n",
		rootHash, username, userHash)
	if err := os.WriteFile(filepath.Join(MOUNT_POINT, "etc", "shadow"), []byte(shadow), 0600); err != nil {
		return fmt.Errorf("failed to write shadow: %w", err)
	}

	group := fmt.Sprintf("root:x:0:\ntty:x:5:%s\nvideo:x:44:%s\naudio:x:29:%s\ninput:x:104:%s\nwheel:x:10:%s\n%s:x:1000:\nnogroup:x:65534:\n",
		username, username, username, username, username, username)
	if err := os.WriteFile(filepath.Join(MOUNT_POINT, "etc", "group"), []byte(group), 0644); err != nil {
		return fmt.Errorf("failed to write group: %w", err)
	}

	homeDir := filepath.Join(MOUNT_POINT, "home", username)
	if err := os.MkdirAll(homeDir, 0755); err != nil {
		return fmt.Errorf("failed to create home dir: %w", err)
	}
	os.Chown(homeDir, 1000, 1000)

	sudoers := fmt.Sprintf("root ALL=(ALL:ALL) ALL\n%s ALL=(ALL:ALL) ALL\n%%wheel ALL=(ALL:ALL) ALL\n", username)
	os.MkdirAll(filepath.Join(MOUNT_POINT, "etc", "sudoers.d"), 0750)
	if err := os.WriteFile(filepath.Join(MOUNT_POINT, "etc", "sudoers"), []byte(sudoers), 0440); err != nil {
		return fmt.Errorf("failed to write sudoers: %w", err)
	}

for _, bin := range []string{"/bin/su", "/usr/bin/sudo", "/bin/mount", "/bin/umount"} {
    path := filepath.Join(MOUNT_POINT, bin)
    if _, err := os.Stat(path); err == nil {
        os.Lchown(path, 0, 0)
        os.Chmod(path, 0o4755)
    }
}

	return nil
}

func generatePasswordHash(password string) (string, error) {
	cmd := exec.Command("openssl", "passwd", "-6", "-salt", "galactica", password)
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

// ============================================================
// fstab
// ============================================================

func GenerateFstab(device string) error {
	bootPart := getPartitionPath(device, 1)
	swapPart := getPartitionPath(device, 2)
	rootPart := getPartitionPath(device, 3)

	bootUUID, _ := getUUID(bootPart)
	swapUUID, _ := getUUID(swapPart)
	rootUUID, _ := getUUID(rootPart)

	var bootEntry string
	if isUEFI() {
		bootEntry = fmt.Sprintf("UUID=%s  /boot/efi  vfat  defaults  0  2\n", bootUUID)
	} else {
		bootEntry = fmt.Sprintf("UUID=%s  /boot  ext4  defaults  0  2\n", bootUUID)
	}

	fstab := fmt.Sprintf("# Galactica fstab\nUUID=%s  /      ext4  defaults  0  1\n%sUUID=%s  none   swap  sw        0  0\n",
		rootUUID, bootEntry, swapUUID)

	if err := os.WriteFile(filepath.Join(MOUNT_POINT, "etc", "fstab"), []byte(fstab), 0644); err != nil {
		return fmt.Errorf("failed to write fstab: %w", err)
	}
	return nil
}

// ============================================================
// Finalize
// ============================================================

func FinalizeInstallation() error {
unmountChroot()
	exec.Command("sync").Run()


	if isUEFI() {
		exec.Command("umount", filepath.Join(MOUNT_POINT, "boot", "efi")).Run()
	} else {
		exec.Command("umount", filepath.Join(MOUNT_POINT, "boot")).Run()
	}

	if err := Unmount(MOUNT_POINT); err != nil {
		return fmt.Errorf("failed to unmount root: %w", err)
	}

	exec.Command("swapoff", "-a").Run()
	return nil
}
