package main

import (
	"strings"

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

// InputField tracks which field is focused in user setup
type InputField int

const (
	FieldHostname InputField = iota
	FieldUsername
	FieldRootPassword
	FieldRootPasswordConfirm
	FieldUserPassword
	FieldUserPasswordConfirm
	FieldCount // sentinel
)

// Model represents the application state
type Model struct {
	screen  Screen
	width   int
	height  int
	cursor  int
	err     error

	// Installation data
	selectedDisk  string
	diskInfo      []DiskInfo
	partitionMode string

	// User setup fields
	hostname            string
	username            string
	rootPassword        string
	rootPasswordConfirm string
	userPassword        string
	userPasswordConfirm string

	// User setup state
	activeField   InputField
	fieldValues   [FieldCount]string
	fieldMasked   [FieldCount]bool
	userSetupErr  string

	// Installation progress
	installing   bool
	installStep  int
	installSteps []string
	installError error
}

var fieldLabels = [FieldCount]string{
	"Hostname",
	"Username",
	"Root Password",
	"Confirm Root Password",
	"User Password",
	"Confirm User Password",
}

// NewModel creates a new model with defaults
func NewModel() Model {
	m := Model{
		screen: ScreenWelcome,
		cursor: 0,
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
	// Defaults
	m.fieldValues[FieldHostname] = "galactica"
	m.fieldValues[FieldUsername] = ""
	m.fieldMasked[FieldRootPassword] = true
	m.fieldMasked[FieldRootPasswordConfirm] = true
	m.fieldMasked[FieldUserPassword] = true
	m.fieldMasked[FieldUserPasswordConfirm] = true
	return m
}

func (m Model) Init() tea.Cmd {
	return nil
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		// User setup screen handles keys specially
		if m.screen == ScreenUserSetup {
			return m.handleUserSetupKey(msg)
		}

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
			if m.cursor < m.getMaxCursor() {
				m.cursor++
			}
		case "enter", " ", "ctrl+m":
    			return m.handleSelection()

		case "esc":
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

func (m Model) handleUserSetupKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit

	case "esc":
		m.screen = ScreenPartition
		m.cursor = 0
		m.userSetupErr = ""
		return m, nil

	case "tab", "down":
		m.activeField = (m.activeField + 1) % FieldCount
		return m, nil

	case "shift+tab", "up":
		if m.activeField == 0 {
			m.activeField = FieldCount - 1
		} else {
			m.activeField--
		}
		return m, nil

	case "enter", "ctrl+m":
		if m.activeField < FieldCount-1 {
			m.activeField++
			return m, nil
		}
		// Last field — try to proceed
		return m.validateAndProceed()

	case "backspace":
		f := m.activeField
		if len(m.fieldValues[f]) > 0 {
			m.fieldValues[f] = m.fieldValues[f][:len(m.fieldValues[f])-1]
		}
		return m, nil
	}

	// Printable characters
	if len(msg.String()) == 1 {
		ch := msg.String()[0]
		if ch >= 32 && ch <= 126 {
			m.fieldValues[m.activeField] += msg.String()
		}
	}

	return m, nil
}

func (m Model) validateAndProceed() (tea.Model, tea.Cmd) {
	hostname := strings.TrimSpace(m.fieldValues[FieldHostname])
	username := strings.TrimSpace(m.fieldValues[FieldUsername])
	rootPass := m.fieldValues[FieldRootPassword]
	rootConfirm := m.fieldValues[FieldRootPasswordConfirm]
	userPass := m.fieldValues[FieldUserPassword]
	userConfirm := m.fieldValues[FieldUserPasswordConfirm]

	if hostname == "" {
		m.userSetupErr = "Hostname cannot be empty"
		return m, nil
	}
	if username == "" {
		m.userSetupErr = "Username cannot be empty"
		return m, nil
	}
	if rootPass == "" {
		m.userSetupErr = "Root password cannot be empty"
		return m, nil
	}
	if rootPass != rootConfirm {
		m.userSetupErr = "Root passwords do not match"
		return m, nil
	}
	if userPass == "" {
		m.userSetupErr = "User password cannot be empty"
		return m, nil
	}
	if userPass != userConfirm {
		m.userSetupErr = "User passwords do not match"
		return m, nil
	}

	// All good
	m.hostname = hostname
	m.username = username
	m.rootPassword = rootPass
	m.userPassword = userPass
	m.userSetupErr = ""
	m.screen = ScreenInstall
	m.installing = true

	return m, m.doInstall()
}

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

func (m Model) handleSelection() (tea.Model, tea.Cmd) {
	switch m.screen {
	case ScreenWelcome:
		if m.cursor == 0 {
			disks, err := ScanDisks()
			if err != nil {
				m.err = err
				return m, nil
			}
			m.diskInfo = disks
			m.screen = ScreenDiskSelect
			m.cursor = 0
		} else if m.cursor == 1 {
			return m, tea.Quit
		}

	case ScreenDiskSelect:
		if m.cursor < len(m.diskInfo) {
			m.selectedDisk = m.diskInfo[m.cursor].Device
			m.screen = ScreenPartition
			m.cursor = 0
		}

	case ScreenPartition:
		if m.cursor == 0 {
			m.partitionMode = "auto"
		} else {
			m.partitionMode = "manual"
		}
		m.screen = ScreenUserSetup
		m.activeField = FieldHostname
		m.cursor = 0

	case ScreenInstall:
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
	default:
		return 0
	}
}
