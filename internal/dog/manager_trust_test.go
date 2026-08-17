package dog

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// trustedPaths returns the set of directories marked trusted in a Claude Code config.
func trustedPaths(t *testing.T, configPath string) map[string]bool {
	t.Helper()
	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("reading claude config: %v", err)
	}
	var doc struct {
		Projects map[string]struct {
			HasTrustDialogAccepted bool `json:"hasTrustDialogAccepted"`
		} `json:"projects"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("parsing claude config: %v", err)
	}
	out := map[string]bool{}
	for dir, entry := range doc.Projects {
		out[dir] = entry.HasTrustDialogAccepted
	}
	return out
}

func writeEmptyClaudeConfig(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".claude.json")
	if err := os.WriteFile(path, []byte(`{"projects":{}}`), 0600); err != nil {
		t.Fatalf("writing claude config: %v", err)
	}
	return path
}

// A dog whose directory is not pre-registered wedges at Claude Code's startup
// trust prompt with nobody there to answer it, and reports as "working" the
// whole time (hq-ipleo). Registering at creation is what prevents it.
func TestManager_Add_GrantsTrustForDogDirectory(t *testing.T) {
	m, tmpDir := testTownWithGitRigs(t)
	configPath := writeEmptyClaudeConfig(t)
	m.claudeConfigPath = configPath

	if _, err := m.Add("alpha"); err != nil {
		t.Fatalf("Add() error = %v", err)
	}

	dogPath := filepath.Join(tmpDir, "deacon", "dogs", "alpha")
	trusted := trustedPaths(t, configPath)
	if !trusted[dogPath] {
		t.Errorf("dog directory %s not trusted; trusted set = %v", dogPath, trusted)
	}
}

// The dog also works from its per-rig worktrees, each a distinct directory and
// therefore a distinct trust prompt — trust is not inherited from the dog root.
func TestManager_Add_GrantsTrustForRigWorktrees(t *testing.T) {
	m, _ := testTownWithGitRigs(t)
	configPath := writeEmptyClaudeConfig(t)
	m.claudeConfigPath = configPath

	d, err := m.Add("alpha")
	if err != nil {
		t.Fatalf("Add() error = %v", err)
	}

	trusted := trustedPaths(t, configPath)
	for rigName, worktree := range d.Worktrees {
		if !trusted[worktree] {
			t.Errorf("worktree for rig %s (%s) not trusted; trusted set = %v", rigName, worktree, trusted)
		}
	}
}

// A missing or unwritable Claude config must not fail dog creation: an
// un-granted dog is a nuisance, a dog that cannot be created at all is worse.
func TestManager_Add_SucceedsWhenClaudeConfigMissing(t *testing.T) {
	m, _ := testTownWithGitRigs(t)
	m.claudeConfigPath = filepath.Join(t.TempDir(), "does-not-exist.json")

	if _, err := m.Add("alpha"); err != nil {
		t.Fatalf("Add() error = %v, want nil when the claude config is absent", err)
	}
}
