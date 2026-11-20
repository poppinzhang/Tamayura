package bridge

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"tailscale.com/logpolicy"
)

func TestAndroidStartupUsesPrivateNodeDirectory(t *testing.T) {
	const key = "TS_LOGS_DIR"
	original := t.TempDir()
	t.Setenv(key, original)
	first := filepath.Join(t.TempDir(), "node")
	second := filepath.Join(t.TempDir(), "node")
	startError := errors.New("start failed")
	for _, step := range []struct {
		dir string
		err error
	}{{first, nil}, {first, startError}, {second, nil}} {
		got := startWithAndroidLogsDir(step.dir, func() error {
			if dir := logpolicy.LogsDir(t.Logf); dir != step.dir {
				t.Fatalf("upstream selected %q during start, want %q", dir, step.dir)
			}
			return step.err
		})
		if !errors.Is(got, step.err) {
			t.Fatalf("start returned %v, want %v", got, step.err)
		}
		if dir := os.Getenv(key); dir != original {
			t.Fatalf("host log directory changed to %q after startup", dir)
		}
	}
	if err := os.Unsetenv(key); err != nil {
		t.Fatal(err)
	}
	if err := startWithAndroidLogsDir(first, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	if _, present := os.LookupEnv(key); present {
		t.Fatal("startup left a log directory in the host environment")
	}
}

func TestAndroidStartupRejectsInvalidNodeDirectory(t *testing.T) {
	const key = "TS_LOGS_DIR"
	original := t.TempDir()
	t.Setenv(key, original)
	blocker := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocker, nil, 0600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{blocker, filepath.Join(blocker, "node")} {
		err := startWithAndroidLogsDir(path, func() error {
			t.Fatal("started tsnet with an unavailable node directory")
			return nil
		})
		if err == nil || os.Getenv(key) != original {
			t.Fatal("invalid node directory did not fail cleanly")
		}
	}
}
