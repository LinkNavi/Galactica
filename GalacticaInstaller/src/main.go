package main

import (
	"fmt"
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// Colors matching Galactica theme
var (
	pink   = lipgloss.Color("#FF79C6")
	blue   = lipgloss.Color("#8BE9FD")
	green  = lipgloss.Color("#50FA7B")
	yellow = lipgloss.Color("#F1FA8C")
	purple = lipgloss.Color("#BD93F9")
	red    = lipgloss.Color("#FF5555")
	gray   = lipgloss.Color("#6272A4")
	white  = lipgloss.Color("#F8F8F2")
)

// Styles
var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(pink).
			MarginBottom(1)

	logoStyle = lipgloss.NewStyle().
			Foreground(purple).
			Bold(true)

	subtitleStyle = lipgloss.NewStyle().
			Foreground(blue).
			Italic(true)

	selectedStyle = lipgloss.NewStyle().
			Foreground(green).
			Bold(true).
			PaddingLeft(2)

	normalStyle = lipgloss.NewStyle().
			Foreground(white).
			PaddingLeft(2)

	helpStyle = lipgloss.NewStyle().
			Foreground(gray).
			Italic(true).
			MarginTop(1)

	errorStyle = lipgloss.NewStyle().
			Foreground(red).
			Bold(true)

	successStyle = lipgloss.NewStyle().
			Foreground(green).
			Bold(true)

	boxStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(purple).
			Padding(1, 2)
)

// Screen represents different installer screens
type Screen int

const (
	ScreenWelcome Screen = iota
	ScreenDiskSelect
	ScreenPartition
	ScreenUserSetup
	ScreenInstall
	ScreenComplete
)

// Model represents the application state
type Model struct {
	screen       Screen
	width        int
	height       int
	cursor       int
	err          error
	
	// Add your data fields here as you build each screen
	// selectedDisk string
	// username     string
	// etc.
}

// Init initializes the model
func (m Model) Init() tea.Cmd {
	return nil
}

// Update handles messages
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit

		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}

		case "down", "j":
			// Adjust max based on current screen
			m.cursor++

		case "enter", " ":
			return m.handleSelection()

		case "esc":
			// Go back to previous screen
			if m.screen > ScreenWelcome {
				m.screen--
				m.cursor = 0
			}
		}

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	}

	return m, nil
}

// View renders the UI
func (m Model) View() string {
	if m.width == 0 {
		return "Loading..."
	}

	switch m.screen {
	case ScreenWelcome:
		return m.viewWelcome()
	case ScreenDiskSelect:
		return m.viewDiskSelect()
	case ScreenPartition:
		return m.viewPartition()
	case ScreenUserSetup:
		return m.viewUserSetup()
	case ScreenInstall:
		return m.viewInstall()
	case ScreenComplete:
		return m.viewComplete()
	default:
		return "Unknown screen"
	}
}

// handleSelection handles enter key on current screen
func (m Model) handleSelection() (tea.Model, tea.Cmd) {
	switch m.screen {
	case ScreenWelcome:
		if m.cursor == 0 {
			// Start installation
			m.screen = ScreenDiskSelect
			m.cursor = 0
		} else if m.cursor == 1 {
			// Quit
			return m, tea.Quit
		}
	case ScreenDiskSelect:
		// Move to next screen after disk selection
		m.screen = ScreenPartition
		m.cursor = 0
	case ScreenPartition:
		m.screen = ScreenUserSetup
		m.cursor = 0
	case ScreenUserSetup:
		m.screen = ScreenInstall
		m.cursor = 0
	case ScreenInstall:
		m.screen = ScreenComplete
		m.cursor = 0
	case ScreenComplete:
		return m, tea.Quit
	}
	return m, nil
}

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
			prefix = "▶ "
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

	// Placeholder for disk list
	disks := []string{
		"/dev/sda (500 GB) - Samsung SSD 850 EVO",
		"/dev/sdb (1 TB) - WD Blue HDD",
		"/dev/nvme0n1 (256 GB) - Intel NVMe",
	}

	b.WriteString("Available disks:\n\n")
	for i, disk := range disks {
		style := normalStyle
		prefix := "  "
		if i == m.cursor {
			style = selectedStyle
			prefix = "▶ "
		}
		b.WriteString(prefix + style.Render(disk))
		b.WriteString("\n")
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
			prefix = "▶ "
		}
		b.WriteString(prefix + style.Render(option))
		b.WriteString("\n")
	}

	b.WriteString("\n")
	
	// Show what automatic partitioning will create
	if m.cursor == 0 {
		b.WriteString("\n")
		b.WriteString(gray.Render("Automatic layout:"))
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

	// Placeholder - will be replaced with actual forms
	b.WriteString("Root password:      [Not set]\n")
	b.WriteString("Username:           [Not set]\n")
	b.WriteString("User password:      [Not set]\n")
	b.WriteString("\n")

	action := selectedStyle.Render("▶ Continue")
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

	// Placeholder for progress bars
	b.WriteString("Installing Galactica Linux...\n\n")
	
	tasks := []string{
		"✓ Partitioning disk",
		"✓ Formatting filesystems",
		"→ Installing base system...",
		"  Installing bootloader",
		"  Configuring system",
	}

	for _, task := range tasks {
		if strings.HasPrefix(task, "✓") {
			b.WriteString(successStyle.Render(task))
		} else if strings.HasPrefix(task, "→") {
			b.WriteString(blue.Render(task))
		} else {
			b.WriteString(gray.Render(task))
		}
		b.WriteString("\n")
	}

	b.WriteString("\n")
	b.WriteString("Progress: [████████░░░░░░░░░░] 45%\n")

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
		"  • Hostname: galactica\n" +
		"  • User: your-username\n" +
		"  • Disk: /dev/sda\n\n" +
		"Next steps:\n" +
		"  1. Remove installation media\n" +
		"  2. Reboot your computer\n" +
		"  3. Enjoy Galactica Linux!\n"

	b.WriteString(center(message, m.width))
	b.WriteString("\n\n")

	action := selectedStyle.Render("▶ Press Enter to exit")
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

func main() {
	// Check if running as root
	if os.Geteuid() != 0 {
		fmt.Println(errorStyle.Render("Error: Installer must be run as root"))
		fmt.Println("Try: sudo galactica-installer")
		os.Exit(1)
	}

	// Create initial model
	m := Model{
		screen: ScreenWelcome,
		cursor: 0,
	}

	// Run the program
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error: %v\n", err)
		os.Exit(1)
	}
}
