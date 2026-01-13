package main

import (
	"fmt"
	"strings"
)

// viewWelcome shows the welcome screen
func (m Model) viewWelcome() string {
	var b strings.Builder

	// Center the logo
	logo := m.renderLogo()
	b.WriteString(logo)
	b.WriteString("\n\n")

	// Subtitle
	subtitle := subtitleStyle.Render("Minimal Linux Distribution - Version 0.2")
	b.WriteString(center(subtitle, m.width))
	b.WriteString("\n\n")

	// Testing mode warning
	if TESTING_MODE {
		testWarning := errorStyle.Render("⚠ TESTING MODE - Only loop devices will be shown")
		b.WriteString(center(testWarning, m.width))
		b.WriteString("\n")
		testInfo := grayStyle.Render("(Set TESTING_MODE=false in disk.go for production)")
		b.WriteString(center(testInfo, m.width))
		b.WriteString("\n\n")
	}

	// Welcome message
	welcome := "Welcome to the Galactica installer!"
	b.WriteString(center(welcome, m.width))
	b.WriteString("\n\n")

	description := "This installer will guide you through setting up Galactica Linux.\n" +
		"Installation takes approximately 10-15 minutes."
	b.WriteString(center(description, m.width))
	b.WriteString("\n\n\n")

	// Options
	options := []string{
		"Install Galactica Linux",
		"Exit",
	}

	for i, option := range options {
		style := normalStyle
		prefix := "  "
		if i == m.cursor {
			style = selectedStyle
			prefix = "> "
		}
		b.WriteString(center(prefix+style.Render(option), m.width))
		b.WriteString("\n")
	}

	// Help text
	b.WriteString("\n\n")
	help := helpStyle.Render("Use ↑/↓ or j/k to move, Enter to select, Esc to go back, q to quit")
	b.WriteString(center(help, m.width))

	return b.String()
}

// viewDiskSelect shows disk selection screen
func (m Model) viewDiskSelect() string {
	var b strings.Builder

	title := titleStyle.Render("Step 1: Select Installation Disk")
	b.WriteString(title)
	b.WriteString("\n\n")

	info := "Choose the disk where Galactica will be installed."
	b.WriteString(info)
	b.WriteString("\n")
	
	warning := errorStyle.Render("⚠ WARNING: All data on the selected disk will be erased!")
	b.WriteString(warning)
	b.WriteString("\n\n")

	b.WriteString("Available disks:\n\n")
	
	if len(m.diskInfo) == 0 {
		b.WriteString(errorStyle.Render("No disks found!"))
	} else {
		for i, disk := range m.diskInfo {
			style := normalStyle
			prefix := "  "
			if i == m.cursor {
				style = selectedStyle
				prefix = "> "
			}
			diskStr := fmt.Sprintf("%s (%s) - %s", disk.Device, disk.SizeHuman, disk.Model)
			b.WriteString(prefix + style.Render(diskStr))
			b.WriteString("\n")
		}
	}

	b.WriteString("\n")
	help := helpStyle.Render("↑/↓: Navigate | Enter: Select | Esc: Back")
	b.WriteString(help)

	return boxStyle.Render(b.String())
}

// viewPartition shows partitioning screen
func (m Model) viewPartition() string {
	var b strings.Builder

	title := titleStyle.Render("Step 2: Partitioning")
	b.WriteString(title)
	b.WriteString("\n\n")

	info := "How would you like to partition the disk?"
	b.WriteString(info)
	b.WriteString("\n\n")

	options := []string{
		"Automatic - Use entire disk (Recommended)",
		"Manual - Custom partitioning (Advanced)",
	}

	for i, option := range options {
		style := normalStyle
		prefix := "  "
		if i == m.cursor {
			style = selectedStyle
			prefix = "> "
		}
		b.WriteString(prefix + style.Render(option))
		b.WriteString("\n")
	}

	b.WriteString("\n")
	
	// Show what automatic partitioning will create
	if m.cursor == 0 {
		b.WriteString("\n")
		b.WriteString(grayStyle.Render("Automatic layout:"))
		b.WriteString("\n")
		b.WriteString("  • /boot (512 MB) - Boot partition\n")
		b.WriteString("  • swap (2 GB) - Swap space\n")
		b.WriteString("  • / (remaining) - Root partition\n")
	}

	b.WriteString("\n")
	help := helpStyle.Render("↑/↓: Navigate | Enter: Select | Esc: Back")
	b.WriteString(help)

	return boxStyle.Render(b.String())
}

// viewUserSetup shows user creation screen
func (m Model) viewUserSetup() string {
	var b strings.Builder

	title := titleStyle.Render("Step 3: User Setup")
	b.WriteString(title)
	b.WriteString("\n\n")

	info := "Set up your user account and passwords."
	b.WriteString(info)
	b.WriteString("\n\n")

	// For now, show defaults (we'll add input fields later)
	b.WriteString(fmt.Sprintf("Hostname:           %s\n", m.hostname))
	b.WriteString("Root password:      galactica (default)\n")
	b.WriteString("Username:           user\n")
	b.WriteString("User password:      user\n")
	b.WriteString("\n")
	b.WriteString(grayStyle.Render("(Customization will be added in a future version)"))
	b.WriteString("\n\n")

	action := selectedStyle.Render("> Continue with installation")
	b.WriteString(action)

	b.WriteString("\n\n")
	help := helpStyle.Render("Enter: Continue | Esc: Back")
	b.WriteString(help)

	return boxStyle.Render(b.String())
}

// viewInstall shows installation progress
func (m Model) viewInstall() string {
	var b strings.Builder

	title := titleStyle.Render("Step 4: Installing")
	b.WriteString(title)
	b.WriteString("\n\n")

	if m.installError != nil {
		b.WriteString(errorStyle.Render("Installation failed!"))
		b.WriteString("\n\n")
		b.WriteString(errorStyle.Render(m.installError.Error()))
		b.WriteString("\n\n")
		b.WriteString(helpStyle.Render("Press Esc to go back"))
		return boxStyle.Render(b.String())
	}

	b.WriteString("Installing Galactica Linux...\n\n")
	
	for i, task := range m.installSteps {
		var status string
		if i < m.installStep {
			status = successStyle.Render("✓ " + task)
		} else if i == m.installStep {
			status = inProgressStyle.Render("→ " + task + "...")
		} else {
			status = pendingStyle.Render("  " + task)
		}
		b.WriteString(status)
		b.WriteString("\n")
	}

	b.WriteString("\n")
	
	// Progress bar with ASCII characters
	totalSteps := len(m.installSteps)
	progress := float64(m.installStep) / float64(totalSteps)
	barWidth := 30
	filled := int(progress * float64(barWidth))
	
	// Use simple ASCII characters
	bar := "[" + strings.Repeat("=", filled) + strings.Repeat("-", barWidth-filled) + "]"
	percentage := int(progress * 100)
	
	b.WriteString(fmt.Sprintf("Progress: %s %d%%\n", bar, percentage))

	b.WriteString("\n")
	help := helpStyle.Render("Please wait...")
	b.WriteString(help)

	return boxStyle.Render(b.String())
}

// viewComplete shows completion screen
func (m Model) viewComplete() string {
	var b strings.Builder

	// Success message
	success := successStyle.Render("✓ Installation Complete!")
	b.WriteString(center(success, m.width))
	b.WriteString("\n\n\n")

	message := "Galactica Linux has been successfully installed!\n\n" +
		"System configuration:\n" +
		fmt.Sprintf("  • Hostname: %s\n", m.hostname) +
		fmt.Sprintf("  • User: %s\n", m.username) +
		fmt.Sprintf("  • Disk: %s\n\n", m.selectedDisk) +
		"Default credentials:\n" +
		"  • root / galactica\n" +
		"  • user / user\n\n" +
		"Next steps:\n" +
		"  1. Remove installation media\n" +
		"  2. Reboot your computer\n" +
		"  3. Enjoy Galactica Linux!\n"

	b.WriteString(center(message, m.width))
	b.WriteString("\n\n")

	action := selectedStyle.Render("> Press Enter to exit")
	b.WriteString(center(action, m.width))

	return b.String()
}

// renderLogo returns the Galactica ASCII logo
func (m Model) renderLogo() string {
	logo := `
  ________       .__                 __  .__               
 /  _____/_____  |  | _____    _____/  |_|__| ____ _____   
/   \  ___\__  \ |  | \__  \ _/ ___\   __\  |/ ___\\__  \  
\    \_\  \/ __ \|  |__/ __ \\  \___|  | |  \  \___ / __ \_
 \______  (____  /____(____  /\___  >__| |__|\___  >____  /
        \/     \/          \/     \/             \/     \/ 
`
	styledLogo := logoStyle.Render(logo)
	return center(styledLogo, m.width)
}

// center centers text in the terminal
func center(s string, width int) string {
	lines := strings.Split(s, "\n")
	var centered strings.Builder
	
	for _, line := range lines {
		// Remove ANSI codes for length calculation
		cleanLine := stripAnsi(line)
		padding := (width - len(cleanLine)) / 2
		if padding > 0 {
			centered.WriteString(strings.Repeat(" ", padding))
		}
		centered.WriteString(line)
		centered.WriteString("\n")
	}
	
	return strings.TrimRight(centered.String(), "\n")
}

// stripAnsi removes ANSI escape codes for length calculation
func stripAnsi(s string) string {
	// Simple ANSI stripper (good enough for centering)
	inEscape := false
	var result strings.Builder
	
	for _, r := range s {
		if r == '\x1b' {
			inEscape = true
			continue
		}
		if inEscape {
			if r == 'm' {
				inEscape = false
			}
			continue
		}
		result.WriteRune(r)
	}
	
	return result.String()
}
