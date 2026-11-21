package bridge

import (
	"net/netip"
	"reflect"
	"testing"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/types/key"
)

func TestStartRestoresAfterRuntimeRestartWithoutInteractiveLogin(t *testing.T) {
	original, _, first, _ := setup(t)
	dir := original.directory
	original.Close()

	backend := newFake()
	restored := New()
	restored.factory = func(string, string) Backend { return backend }
	t.Cleanup(restored.Close)
	init := mustCall(t, restored, "initialize", map[string]any{"stateDirectory": dir, "hostname": "test-node"})
	owner := init["ownerId"]
	if init["sessionEpoch"] == first["sessionEpoch"] || init["certificatePem"] == first["certificatePem"] {
		t.Fatal("fresh runtime reused previous session material")
	}
	if backend.started.Load() != 0 {
		t.Fatal("initialization started the saved node before start")
	}
	_, err := call(t, restored, "start", map[string]any{"ownerId": owner, "sessionEpoch": first["sessionEpoch"]})
	if err == nil || err.Code != "sessionChanged" || backend.started.Load() != 0 {
		t.Fatal("stale session was allowed to start the node")
	}
	for range 2 {
		status := mustCall(t, restored, "start", map[string]any{"ownerId": owner, "sessionEpoch": init["sessionEpoch"]})
		if status["state"] != "connected" || status["sessionEpoch"] != init["sessionEpoch"] {
			t.Fatal("restored node did not report a connected, stable session")
		}
	}
	if backend.started.Load() != 1 || backend.logins.Load() != 0 {
		t.Fatalf("restore called Start %d times and Login %d times", backend.started.Load(), backend.logins.Load())
	}
}

func TestPeersReturnsSortedScopedCandidatesIncludingOfflinePeers(t *testing.T) {
	r, f, init, owner := setup(t)
	f.status.Peer = map[key.NodePublic]*ipnstate.PeerStatus{
		key.NewNode().Public(): {ID: "peer-b", HostName: "offline-peer"},
		key.NewNode().Public(): {ID: "peer-a", HostName: "online-peer", Online: true,
			TailscaleIPs: []netip.Addr{netip.MustParseAddr("192.0.2.42"), netip.MustParseAddr("2001:db8::2")}},
		key.NewNode().Public(): f.status.Self,
		key.NewNode().Public(): {HostName: "unregistered"},
	}
	params := map[string]any{"ownerId": owner}
	scope := mustCall(t, r, "status", params)["networkScope"]
	got := mustCall(t, r, "peers", params)
	want := []any{
		map[string]any{"networkScope": scope, "nodeId": "peer-a", "name": "online-peer", "addresses": []any{"192.0.2.42", "2001:db8::2"}, "online": true},
		map[string]any{"networkScope": scope, "nodeId": "peer-b", "name": "offline-peer", "addresses": []any{}, "online": false},
	}
	if got["sessionEpoch"] != init["sessionEpoch"] || !reflect.DeepEqual(got["peers"], want) {
		t.Fatalf("unexpected peer snapshot: %#v", got["peers"])
	}
	f.status.Peer = nil
	if peers := mustCall(t, r, "peers", params)["peers"]; !reflect.DeepEqual(peers, []any{}) {
		t.Fatalf("empty list encoded as %#v", peers)
	}
	f.status.BackendState = "NeedsLogin"
	if _, err := call(t, r, "peers", params); err == nil || err.Code != "loginRequired" {
		t.Fatalf("unregistered node returned %v, want loginRequired", err)
	}
}
