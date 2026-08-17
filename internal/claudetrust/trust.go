// Package claudetrust pre-registers directories as trusted in Claude Code's
// user config.
//
// Claude Code asks "Is this a project you created or one you trust?" on the
// first interactive session in any directory, and blocks until it is answered.
// Trust is stored per-directory in ~/.claude.json under
// .projects[dir].hasTrustDialogAccepted and is NOT inherited from a parent
// directory, so every newly created worktree faces the prompt again.
//
// Agent sessions are spawned unattended into fresh worktrees, where nobody is
// present to answer. --dangerously-skip-permissions does not bypass the prompt
// (only non-interactive -p mode does, which agents do not use), so an
// unregistered worktree wedges its session before it reads a single byte of its
// assignment — while the agent still reports as "working". Granting trust at
// worktree-creation time is what keeps that from happening (hq-ipleo).
package claudetrust

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const trustKey = "hasTrustDialogAccepted"

// DefaultConfigPath returns the path to Claude Code's user config.
func DefaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".claude.json")
}

// EnsureTrusted marks dir as trusted in the Claude Code config at configPath,
// creating the project entry if it does not exist yet.
//
// It is idempotent: when dir is already trusted the file is left byte-for-byte
// untouched. A missing config file is not an error — it means Claude Code has
// never run for this user, and it will create the file (and its own prompt
// state) on first run.
//
// Only the single trust key is modified; every other field, including the
// oauthAccount that authenticates the user, round-trips untouched.
func EnsureTrusted(configPath, dir string) error {
	if configPath == "" || dir == "" {
		return nil
	}

	data, err := os.ReadFile(configPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("reading %s: %w", configPath, err)
	}

	info, err := os.Stat(configPath)
	if err != nil {
		return fmt.Errorf("stat %s: %w", configPath, err)
	}

	// RawMessage everywhere we are not editing: unknown fields survive verbatim
	// rather than being re-encoded through interface{}.
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		return fmt.Errorf("parsing %s: %w", configPath, err)
	}

	projects := map[string]json.RawMessage{}
	if raw, ok := doc["projects"]; ok {
		if err := json.Unmarshal(raw, &projects); err != nil {
			return fmt.Errorf("parsing projects in %s: %w", configPath, err)
		}
	}

	entry := map[string]json.RawMessage{}
	if raw, ok := projects[dir]; ok {
		if err := json.Unmarshal(raw, &entry); err != nil {
			return fmt.Errorf("parsing project entry %s: %w", dir, err)
		}
	}

	// Already granted: do not rewrite. A pointless rewrite races the live Claude
	// Code processes that also write this file wholesale.
	var trusted bool
	if raw, ok := entry[trustKey]; ok {
		if err := json.Unmarshal(raw, &trusted); err == nil && trusted {
			return nil
		}
	}

	entry[trustKey] = json.RawMessage("true")

	encodedEntry, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("encoding project entry %s: %w", dir, err)
	}
	projects[dir] = encodedEntry

	encodedProjects, err := json.Marshal(projects)
	if err != nil {
		return fmt.Errorf("encoding projects: %w", err)
	}
	doc["projects"] = encodedProjects

	out, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding %s: %w", configPath, err)
	}

	// Write via a temp file in the same directory and rename, so a reader never
	// observes a half-written config.
	tmp, err := os.CreateTemp(filepath.Dir(configPath), ".claude.json.tmp-*")
	if err != nil {
		return fmt.Errorf("creating temp file: %w", err)
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()

	if _, err := tmp.Write(out); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("writing temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("closing temp file: %w", err)
	}
	if err := os.Chmod(tmpName, info.Mode().Perm()); err != nil {
		return fmt.Errorf("setting mode on temp file: %w", err)
	}
	if err := os.Rename(tmpName, configPath); err != nil {
		return fmt.Errorf("replacing %s: %w", configPath, err)
	}
	return nil
}
