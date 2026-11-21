//go:build darwin && !ios

package bridge

import (
	"net"
	"os"
	"os/exec"
	"testing"

	"tailscale.com/net/netmon"
	"tailscale.com/net/netns"
	"tailscale.com/types/logger"
)

func TestMacOSControlDialFollowsHostRouteAfterNetworkMap(t *testing.T) {
	const modeVar = "FLUTTER_TAILSCALE_TEST_MACOS_ROUTE"
	mode := os.Getenv(modeVar)
	if mode == "" {
		// x/net/proxy reads its environment once, as it would on helper launch.
		for _, tc := range []struct{ name, allProxy, mode string }{
			{"system_route", "", "direct"},
			{"unsupported_all_proxy", "http://127.0.0.1:1", "direct"},
			{"explicit_socks", "socks5://127.0.0.1:1", "socks"},
		} {
			t.Run(tc.name, func(t *testing.T) {
				cmd := exec.Command(os.Args[0], "-test.run=^TestMacOSControlDialFollowsHostRouteAfterNetworkMap$")
				cmd.Env = append(os.Environ(), modeVar+"="+tc.mode,
					"ALL_PROXY="+tc.allProxy, "all_proxy=", "NO_PROXY=localhost", "no_proxy=")
				if out, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("route check: %v\n%s", err, out)
				}
			})
		}
		return
	}

	newTSBackend(t.TempDir(), "test-node")

	// LocalBackend updates this capability when it applies a network map.
	// An ordinary node has no debug capability that disables interface binding.
	netns.SetDisableBindConnToInterface(logger.Discard, false)
	dialer := new(net.Dialer)
	transport := netns.FromDialer(logger.Discard, netmon.NewStatic(), dialer)
	if mode == "socks" {
		if !netns.IsSOCKSDialer(transport) {
			t.Fatal("the helper bypassed its explicit SOCKS proxy")
		}
	} else if transport != dialer || dialer.Control != nil {
		t.Fatal("the network map restored interface binding or proxying on the host dialer")
	}
}
