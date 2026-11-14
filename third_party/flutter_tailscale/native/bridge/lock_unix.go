//go:build !windows

package bridge

import (
	"golang.org/x/sys/unix"
	"os"
)

type stateLock struct{ file *os.File }

func lockState(path string) (*stateLock, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		f.Close()
		return nil, err
	}
	return &stateLock{f}, nil
}
func (l *stateLock) close() { _ = unix.Flock(int(l.file.Fd()), unix.LOCK_UN); _ = l.file.Close() }
