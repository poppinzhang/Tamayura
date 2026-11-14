package bridge

import (
	"golang.org/x/sys/windows"
	"os"
)

type stateLock struct {
	file       *os.File
	overlapped windows.Overlapped
}

func lockState(path string) (*stateLock, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	l := &stateLock{file: f}
	err = windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &l.overlapped)
	if err != nil {
		f.Close()
		return nil, err
	}
	return l, nil
}
func (l *stateLock) close() {
	_ = windows.UnlockFileEx(windows.Handle(l.file.Fd()), 0, 1, 0, &l.overlapped)
	_ = l.file.Close()
}
