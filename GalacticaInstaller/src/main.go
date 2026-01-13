package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"

)

func main() {
	// Check if running as root
	if os.Geteuid() != 0 {
		fmt.Println(errorStyle.Render("Error: Installer must be run as root"))
		fmt.Println("Try: sudo galactica-installer")
		os.Exit(1)
	}

	// Create initial model
	m := NewModel()

	// Run the program
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error: %v\n", err)
		os.Exit(1)
	}
}
