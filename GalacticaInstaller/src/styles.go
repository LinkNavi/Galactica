
package main

import (
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
	
	inProgressStyle = lipgloss.NewStyle().
			Foreground(blue)

	pendingStyle = lipgloss.NewStyle().
			Foreground(gray)
	
	grayStyle = lipgloss.NewStyle().
			Foreground(gray)
)




