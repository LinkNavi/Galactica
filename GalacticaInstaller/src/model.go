package main

import (
	tea "github.com/charmbracelet/bubbletea"
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
	
	// Installation data
	selectedDisk      string
	diskInfo          []DiskInfo
	partitionMode     string  // "auto" or "manual"
	rootPassword      string
	username          string
	userPassword      string
	hostname          string
	
	// Installation progress
	installing        bool
	installStep       int
	installSteps      []string
	installError      error
}

// NewModel creates a new model with defaults
func NewModel() Model {
	return Model{
		screen:   ScreenWelcome,
		cursor:   0,
		hostname: "galactica",
		installSteps: []string{
			"Partitioning disk",
			"Formatting filesystems",
			"Mounting filesystems",
			"Installing base system",
			"Installing kernel",
			"Configuring system",
			"Installing bootloader",
			"Setting up users",
			"Generating fstab",
			"Finalizing installation",
		},
	}
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
			if m.screen != ScreenInstall || !m.installing {
				return m, tea.Quit
			}

		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}

		case "down", "j":
			// Adjust max based on current screen
			maxCursor := m.getMaxCursor()
			if m.cursor < maxCursor {
				m.cursor++
			}

		case "enter", " ":
			return m.handleSelection()

		case "esc":
			// Go back to previous screen
			if m.screen > ScreenWelcome && !m.installing {
				m.screen--
				m.cursor = 0
			}
		}

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		
	case InstallProgressMsg:
		m.installStep = msg.step
		if msg.err != nil {
			m.installError = msg.err
			m.installing = false
			return m, nil
		}
		// Keep ticking to get updates
		if m.installing {
			return m, installProgressTicker()
		}
		return m, nil
		
	case InstallCompleteMsg:
		m.screen = ScreenComplete
		m.installing = false
		return m, nil
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
			// Start installation - scan disks
			disks, err := ScanDisks()
			if err != nil {
				m.err = err
				return m, nil
			}
			m.diskInfo = disks
			m.screen = ScreenDiskSelect
			m.cursor = 0
		} else if m.cursor == 1 {
			// Quit
			return m, tea.Quit
		}
		
	case ScreenDiskSelect:
		// Select disk
		if m.cursor < len(m.diskInfo) {
			m.selectedDisk = m.diskInfo[m.cursor].Device
			m.screen = ScreenPartition
			m.cursor = 0
		}
		
	case ScreenPartition:
		// Select partition mode
		if m.cursor == 0 {
			m.partitionMode = "auto"
		} else {
			m.partitionMode = "manual"
		}
		m.screen = ScreenUserSetup
		m.cursor = 0
		
	case ScreenUserSetup:
		// For now, use defaults - we'll add input fields later
		m.rootPassword = "galactica"
		m.username = "user"
		m.userPassword = "user"
		m.screen = ScreenInstall
		m.cursor = 0
		m.installing = true
		
		// Start installation
		return m, m.doInstall()
		
	case ScreenInstall:
		// Installation in progress - no action
		return m, nil
		
	case ScreenComplete:
		return m, tea.Quit
	}
	
	return m, nil
}

func (m Model) getMaxCursor() int {
	switch m.screen {
	case ScreenWelcome:
		return 1
	case ScreenDiskSelect:
		return len(m.diskInfo) - 1
	case ScreenPartition:
		return 1
	case ScreenUserSetup:
		return 0
	default:
		return 0
	}
}
