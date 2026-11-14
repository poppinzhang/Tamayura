//go:build !android

package bridge

func requireNetworkSnapshot() error     { return nil }
func updateAndroidRoute(string, string) {}
