package daemon

import (
	"os"
	"strings"
	"testing"
)

// The bug this guards (hq-ylg4w, 2026-08-07): reapWisps has two paths. The
// inline fallback closed plugin receipt and dispatch beads; the Dog path did
// not, because the mol-dog-reaper formula has no step for it. Every tick took
// the Dog path, so those beads were never closed by anything — AutoClose is a
// different function with a 7-day rule. 63 dispatch beads accumulated before
// anyone noticed, and the only visible signal was their absence from a log.
//
// The call is one line and trivially deleted during a refactor, so these tests
// assert the wiring at the source level rather than the behaviour. A behavioural
// test would need a live Dolt server, which is exactly the dependency that made
// the original failure invisible.

func wispReaperSource(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("wisp_reaper.go")
	if err != nil {
		t.Fatalf("read wisp_reaper.go: %v", err)
	}
	return string(b)
}

// funcBody returns the text of the named function, from its declaration to its
// closing brace at column 0.
//
// It must stop at the brace, NOT at the next "\nfunc ". Stopping at the next
// func swallows that function's doc comment, and the comment above
// dispatchReaperDog happens to read "dispatches the mol-dog-reaper formula to a
// Dog via gt sling" — every forbidden token below, in prose. The first version
// of this test failed on exactly that.
func funcBody(t *testing.T, src, decl string) string {
	t.Helper()
	start := strings.Index(src, decl)
	if start < 0 {
		t.Fatalf("%q not found — test needs updating", decl)
	}
	rest := src[start:]
	end := strings.Index(rest, "\n}\n")
	if end < 0 {
		t.Fatalf("could not find closing brace of %q", decl)
	}
	return rest[:end]
}

func TestDogPathClosesPluginBeads(t *testing.T) {
	body := funcBody(t, wispReaperSource(t), "func (d *Daemon) reapWisps() {")

	if !strings.Contains(body, "closePluginBeadsForConfig") {
		t.Fatal("reapWisps does not call closePluginBeadsForConfig — the Dog path " +
			"will silently stop closing plugin dispatch/receipt beads (hq-ylg4w)")
	}

	// It must run on the path taken when dispatch SUCCEEDS. If the only call
	// sat inside the `if err := d.dispatchReaperDog(...)` failure branch we
	// would be back to the original bug, which is why presence alone is not
	// enough. The failure branch ends at its `return`.
	failStart := strings.Index(body, "if err := d.dispatchReaperDog(vars); err != nil {")
	if failStart < 0 {
		t.Fatal("dispatchReaperDog error branch not found — test needs updating")
	}
	failEnd := strings.Index(body[failStart:], "\t\treturn\n\t}")
	if failEnd < 0 {
		t.Fatal("could not delimit the dispatch failure branch")
	}
	afterFailure := body[failStart+failEnd:]

	if !strings.Contains(afterFailure, "closePluginBeadsForConfig") {
		t.Error("closePluginBeadsForConfig is only called inside the dispatch-failure " +
			"branch; it must also run when the Dog dispatch succeeds, which is the " +
			"path taken on essentially every tick")
	}
}

// The cleanup must not become a formula step. The whole failure was that the
// work disappeared when execution was delegated, so reintroducing a dependency
// on a Dog being available would reintroduce the bug in a new costume.
func TestPluginCleanupDoesNotDependOnDog(t *testing.T) {
	body := funcBody(t, wispReaperSource(t),
		"func (d *Daemon) closePluginBeads(databases []string, port int, dryRun bool)")

	for _, forbidden := range []string{"dispatchReaperDog", "MolDogReaper", "gt sling"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("closePluginBeads references %q — cleanup must run in-process, "+
				"not via a Dog (that dependency IS the bug this fixes)", forbidden)
		}
	}
}

func TestBothReceiptsAndDispatchesAreClosed(t *testing.T) {
	src := wispReaperSource(t)

	// Both were lost together on the Dog path; a fix that restores only the
	// dispatch half would leave receipts accumulating with no visible signal.
	for _, fn := range []string{"reaper.ClosePluginReceipts", "reaper.ClosePluginDispatches"} {
		if !strings.Contains(src, fn) {
			t.Errorf("%s is never called — that class of plugin bead will accumulate", fn)
		}
	}
}
