package claudetrust

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// readProjects is a test helper: parses the config and returns the projects map.
func readProjects(t *testing.T, path string) map[string]map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading config: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("parsing config: %v", err)
	}
	raw, _ := doc["projects"].(map[string]any)
	out := make(map[string]map[string]any, len(raw))
	for k, v := range raw {
		entry, _ := v.(map[string]any)
		out[k] = entry
	}
	return out
}

func writeConfig(t *testing.T, dir string, doc map[string]any) string {
	t.Helper()
	path := filepath.Join(dir, ".claude.json")
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		t.Fatalf("marshaling fixture: %v", err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatalf("writing fixture: %v", err)
	}
	return path
}

// The wedge this fixes: a dog worktree registered with hasTrustDialogAccepted
// false blocks its Claude session at the startup trust prompt forever.
func TestEnsureTrustedFlipsFalseToTrue(t *testing.T) {
	dir := t.TempDir()
	path := writeConfig(t, dir, map[string]any{
		"projects": map[string]any{
			"/home/crash/gt/deacon/dogs/alpha": map[string]any{
				"hasTrustDialogAccepted": false,
				"history":                []any{"prior entry"},
			},
		},
	})

	if err := EnsureTrusted(path, "/home/crash/gt/deacon/dogs/alpha"); err != nil {
		t.Fatalf("EnsureTrusted: %v", err)
	}

	entry := readProjects(t, path)["/home/crash/gt/deacon/dogs/alpha"]
	if entry["hasTrustDialogAccepted"] != true {
		t.Errorf("hasTrustDialogAccepted = %v, want true", entry["hasTrustDialogAccepted"])
	}
	// Sibling keys in the same entry must survive — the entry carries session
	// history and onboarding state we must not clobber.
	if entry["history"] == nil {
		t.Error("history key was dropped from the project entry")
	}
}

// Trust is per-directory and NOT inherited, so a brand-new worktree path has no
// entry at all. Creating it is the whole point of pre-registration.
func TestEnsureTrustedCreatesMissingEntry(t *testing.T) {
	dir := t.TempDir()
	path := writeConfig(t, dir, map[string]any{
		"projects": map[string]any{
			"/home/crash/gt": map[string]any{"hasTrustDialogAccepted": true},
		},
	})

	if err := EnsureTrusted(path, "/home/crash/gt/deacon/dogs/echo"); err != nil {
		t.Fatalf("EnsureTrusted: %v", err)
	}

	projects := readProjects(t, path)
	entry, ok := projects["/home/crash/gt/deacon/dogs/echo"]
	if !ok {
		t.Fatal("no project entry created for the new worktree path")
	}
	if entry["hasTrustDialogAccepted"] != true {
		t.Errorf("hasTrustDialogAccepted = %v, want true", entry["hasTrustDialogAccepted"])
	}
	if _, ok := projects["/home/crash/gt"]; !ok {
		t.Error("pre-existing project entry was dropped")
	}
}

// Unrelated top-level config (auth identity, settings) must round-trip intact:
// this file holds the oauthAccount that authenticates every agent.
func TestEnsureTrustedPreservesUnrelatedTopLevelFields(t *testing.T) {
	dir := t.TempDir()
	path := writeConfig(t, dir, map[string]any{
		"oauthAccount": map[string]any{"accountUuid": "abc-123"},
		"numStartups":  float64(42),
		"projects":     map[string]any{},
	})

	if err := EnsureTrusted(path, "/home/crash/gt/deacon/dogs/alpha"); err != nil {
		t.Fatalf("EnsureTrusted: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading config: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("parsing config: %v", err)
	}
	oauth, ok := doc["oauthAccount"].(map[string]any)
	if !ok || oauth["accountUuid"] != "abc-123" {
		t.Errorf("oauthAccount = %v, want it preserved", doc["oauthAccount"])
	}
	if doc["numStartups"] != float64(42) {
		t.Errorf("numStartups = %v, want 42", doc["numStartups"])
	}
}

// Dogs are recreated routinely; granting trust twice must be a no-op, not an error.
func TestEnsureTrustedIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	path := writeConfig(t, dir, map[string]any{
		"projects": map[string]any{
			"/home/crash/gt/deacon/dogs/alpha": map[string]any{"hasTrustDialogAccepted": true},
		},
	})
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading config: %v", err)
	}

	if err := EnsureTrusted(path, "/home/crash/gt/deacon/dogs/alpha"); err != nil {
		t.Fatalf("EnsureTrusted: %v", err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading config: %v", err)
	}
	if string(before) != string(after) {
		t.Errorf("config rewritten on a no-op grant:\nbefore: %s\nafter:  %s", before, after)
	}
}

// No config file means Claude Code has never run as this user. Dog creation must
// not fail on that — the wedge is a nuisance, a hard failure would be worse.
func TestEnsureTrustedMissingConfigIsNotAnError(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".claude.json")

	if err := EnsureTrusted(path, "/home/crash/gt/deacon/dogs/alpha"); err != nil {
		t.Fatalf("EnsureTrusted on missing config: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("EnsureTrusted created a config file where none existed")
	}
}

// The file holds an OAuth token; a widened mode would leak it to other users.
func TestEnsureTrustedKeepsFileMode(t *testing.T) {
	dir := t.TempDir()
	path := writeConfig(t, dir, map[string]any{
		"projects": map[string]any{},
	})

	if err := EnsureTrusted(path, "/home/crash/gt/deacon/dogs/alpha"); err != nil {
		t.Fatalf("EnsureTrusted: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0600 {
		t.Errorf("file mode = %o, want 600", perm)
	}
}
