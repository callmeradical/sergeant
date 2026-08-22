package config

import (
	"os"
	"path/filepath"
	"strings"
)

// ListProjects scans ~/.config/sergeant for all available project yaml files.
func ListProjects() ([]*Project, error) {
	configDir := os.Getenv("SERGEANT_CONFIG")
	if configDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		configDir = filepath.Join(home, ".config", "sergeant")
	}

	if _, err := os.Stat(configDir); os.IsNotExist(err) {
		return []*Project{}, nil
	}

	entries, err := os.ReadDir(configDir)
	if err != nil {
		return nil, err
	}

	var list []*Project
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if strings.HasSuffix(name, ".yaml") || strings.HasSuffix(name, ".yml") {
			fullPath := filepath.Join(configDir, name)
			p, err := LoadProject(fullPath)
			if err == nil {
				list = append(list, p)
			}
		}
	}

	return list, nil
}
