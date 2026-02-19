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
	}()

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
	cmd := exec.Command("blkid", "-s", "UUID", "-o", "value", device)
	output, err := cmd.Output()
	if err != nil {
		return "", err
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
	if _, err := os.Stat(getSourceDir()); os.IsNotExist(err) {
		return fmt.Errorf("source directory not found: %s (build Galactica first)", getSourceDir())
	}

	cmd := exec.Command("rsync", "-aAXv",
		"--exclude=/boot/*",
		"--exclude=/dev/*",
		"--exclude=/proc/*",
		"--exclude=/sys/*",
		"--exclude=/run/*",
		getSourceDir()+"/",
		MOUNT_POINT+"/",
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to copy base system: %w (output: %s)", err, string(output))
	}
	return nil
}

func InstallKernel() error {
	kernelSrc := filepath.Join(getSourceDir(), "boot", "vmlinuz-galactica")
	kernelDst := filepath.Join(MOUNT_POINT, "boot", "vmlinuz-galactica")

	if _, err := os.Stat(kernelSrc); os.IsNotExist(err) {
		return fmt.Errorf("kernel not found at %s", kernelSrc)
	}
	if err := exec.Command("cp", kernelSrc, kernelDst).Run(); err != nil {
		return fmt.Errorf("failed to copy kernel: %w", err)
	}

	// Copy kernel modules
	modulesSrc := filepath.Join(getSourceDir(), "lib", "modules")
	if _, err := os.Stat(modulesSrc); err == nil {
		modulesDst := filepath.Join(MOUNT_POINT, "lib", "modules")
		os.MkdirAll(modulesDst, 0755)
		exec.Command("cp", "-r", modulesSrc+"/.", modulesDst+"/").Run()
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

	return nil
}

// ============================================================
// Bootloader
// ============================================================

func InstallBootloader(device string) error {
	rootPart := getPartitionPath(device, 3)

	// Get UUID first — fail fast
	var rootUUID string
	for i := 0; i < 10; i++ {
		uuid, err := getUUID(rootPart)
		if err == nil && uuid != "" {
			rootUUID = uuid
			break
		}
		time.Sleep(1 * time.Second)
	}
	if rootUUID == "" {
		return fmt.Errorf("could not get UUID for %s after 10s", rootPart)
	}

	// Install GRUB
	if isUEFI() {
		if err := installGRUB_UEFI(device); err != nil {
			return err
		}
	} else {
		if err := installGRUB_BIOS(device); err != nil {
			return err
		}
	}

	// Build initramfs via ginitrd inside the target system.
	// writeGRUBConfig is called inside buildInitramfs so it can
	// conditionally include initrd lines based on what was actually built.
	if err := buildInitramfsAndWriteGRUB(rootUUID); err != nil {
		// Non-fatal — write a basic grub.cfg without initrd lines
		fmt.Printf("Warning: %v\n", err)
		fmt.Println("Warning: Writing grub.cfg without initrd. Storage drivers must be built-in (=y).")
		return writeGRUBConfig(rootUUID, false, false)
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
		fmt.Printf("UEFI grub-install failed, falling back to BIOS: %s\n", string(output))
		return installGRUB_BIOS(device)
	}
	return nil
}

// buildInitramfsAndWriteGRUB runs ginitrd inside the target via chroot,
// then writes grub.cfg reflecting what was actually built.
func buildInitramfsAndWriteGRUB(rootUUID string) error {
	ginitrdPath := filepath.Join(MOUNT_POINT, "usr", "sbin", "ginitrd")
	if !fileExists(ginitrdPath) {
		return fmt.Errorf("ginitrd not found at %s — copy it to the rootfs first", ginitrdPath)
	}

	// Find installed kernel version
	modulesDir := filepath.Join(MOUNT_POINT, "lib", "modules")
	entries, err := os.ReadDir(modulesDir)
	if err != nil || len(entries) == 0 {
		return fmt.Errorf("no kernel modules found in %s", modulesDir)
	}
	kernelVer := entries[len(entries)-1].Name()

	// Bind-mount pseudo-filesystems so ginitrd can read /proc/modules, /sys, /dev
	pseudos := []struct{ src, dst, fs string }{
		{"/proc", filepath.Join(MOUNT_POINT, "proc"), "proc"},
		{"/sys", filepath.Join(MOUNT_POINT, "sys"), "sysfs"},
		{"/dev", filepath.Join(MOUNT_POINT, "dev"), "devtmpfs"},
	}
	for _, p := range pseudos {
		exec.Command("mount", "--bind", p.src, p.dst).Run()
	}
	defer func() {
		// Always clean up — unmount in reverse order
		for i := len(pseudos) - 1; i >= 0; i-- {
			exec.Command("umount", pseudos[i].dst).Run()
		}
	}()

	// Build normal initramfs
	normalImg := "/boot/initramfs-galactica.img"
	cmd := exec.Command("chroot", MOUNT_POINT,
		"/usr/sbin/ginitrd",
		"-k", kernelVer,
		"-o", normalImg,
		"-c", "zstd",
	)
	normalOutput, normalErr := cmd.CombinedOutput()
	if normalErr != nil {
		return fmt.Errorf("ginitrd (normal) failed: %w\noutput: %s", normalErr, string(normalOutput))
	}
	fmt.Printf("ginitrd: %s\n", strings.TrimSpace(string(normalOutput)))

	// Build fallback initramfs (includes all storage modules, non-fatal)
	fallbackImg := "/boot/initramfs-galactica-fallback.img"
	fallbackCmd := exec.Command("chroot", MOUNT_POINT,
		"/usr/sbin/ginitrd",
		"-k", kernelVer,
		"-o", fallbackImg,
		"-c", "zstd",
		"-f",
	)
	fallbackOutput, fallbackErr := fallbackCmd.CombinedOutput()
	if fallbackErr != nil {
		fmt.Printf("Warning: ginitrd fallback failed (non-fatal): %v\n%s\n", fallbackErr, string(fallbackOutput))
	}

	hasNormal := fileExists(filepath.Join(MOUNT_POINT, "boot", "initramfs-galactica.img"))
	hasFallback := fileExists(filepath.Join(MOUNT_POINT, "boot", "initramfs-galactica-fallback.img"))

	return writeGRUBConfig(rootUUID, hasNormal, hasFallback)
}

// writeGRUBConfig writes /boot/grub/grub.cfg inside the target.
// hasInitramfs and hasFallback control whether initrd lines are included.
func writeGRUBConfig(rootUUID string, hasInitramfs bool, hasFallback bool) error {
	grubDir := filepath.Join(MOUNT_POINT, "boot", "grub")
	if err := os.MkdirAll(grubDir, 0755); err != nil {
		return fmt.Errorf("failed to create grub dir: %w", err)
	}

	var normalEntry string
	if hasInitramfs {
		normalEntry = fmt.Sprintf(`menuentry "Galactica Linux" {
    linux  /vmlinuz-galactica root=UUID=%s rw quiet
    initrd /initramfs-galactica.img
}`, rootUUID)
	} else {
		normalEntry = fmt.Sprintf(`menuentry "Galactica Linux" {
    linux  /vmlinuz-galactica root=UUID=%s rw quiet
}`, rootUUID)
	}

	var fallbackEntry string
	if hasFallback {
		fallbackEntry = fmt.Sprintf(`
menuentry "Galactica Linux (fallback initramfs)" {
    linux  /vmlinuz-galactica root=UUID=%s rw
    initrd /initramfs-galactica-fallback.img
}`, rootUUID)
	}

	// Recovery entry — never uses initramfs, useful if initramfs itself breaks
	recoveryEntry := fmt.Sprintf(`
menuentry "Galactica Linux (recovery)" {
    linux /vmlinuz-galactica root=UUID=%s rw init=/bin/sh
}`, rootUUID)

	config := fmt.Sprintf("set timeout=5\nset default=0\n\n%s\n%s\n%s\n",
		normalEntry, fallbackEntry, recoveryEntry)

	configPath := filepath.Join(grubDir, "grub.cfg")
	if err := os.WriteFile(configPath, []byte(config), 0644); err != nil {
		return fmt.Errorf("failed to write grub.cfg: %w", err)
	}

	fmt.Printf("grub.cfg written (initramfs=%v fallback=%v uuid=%s)\n", hasInitramfs, hasFallback, rootUUID)
	return nil
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
			os.Chmod(path, 0755|os.ModeSetuid)
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
