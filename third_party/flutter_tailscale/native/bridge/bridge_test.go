package bridge

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/logtail"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
)

type fakeBackend struct {
	mu          sync.Mutex
	status      *ipnstate.Status
	identity    string
	dials       atomic.Int32
	started     atomic.Int32
	closed      atomic.Int32
	listener    net.Listener
	connections []net.Conn
}

func newFake() *fakeBackend {
	return &fakeBackend{identity: "peer-1", status: &ipnstate.Status{
		BackendState: "Running", Self: &ipnstate.PeerStatus{ID: "self-1", UserID: 1},
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{key.NewNode().Public(): {ID: "peer-1", HostName: "example-peer", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.10")}}},
	}}
}
func (f *fakeBackend) Start() error { f.started.Add(1); return nil }
func (f *fakeBackend) Close() error {
	f.closed.Add(1)
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.listener != nil {
		_ = f.listener.Close()
	}
	for _, c := range f.connections {
		_ = c.Close()
	}
	return nil
}
func (f *fakeBackend) Status(context.Context) (*ipnstate.Status, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	// Like LocalClient.Status, hand each caller an immutable snapshot.
	snapshot := *f.status
	return &snapshot, nil
}
func (f *fakeBackend) Login(context.Context) error  { return nil }
func (f *fakeBackend) Logout(context.Context) error { return errors.New("offline") }
func (f *fakeBackend) NetworkChanged()              {}
func (f *fakeBackend) Dial(context.Context, string) (net.Conn, error) {
	f.dials.Add(1)
	a, b := net.Pipe()
	f.mu.Lock()
	f.connections = append(f.connections, a, b)
	f.mu.Unlock()
	go func() { defer b.Close(); _, _ = io.Copy(b, b) }()
	return a, nil
}
func (f *fakeBackend) Listen(int) (net.Listener, error) {
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	f.mu.Lock()
	f.listener = ln
	f.mu.Unlock()
	return ln, err
}
func (f *fakeBackend) WhoIs(context.Context, string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.identity, nil
}

func call(t *testing.T, r *Runtime, method string, p map[string]any) (map[string]any, *Error) {
	t.Helper()
	raw, _ := json.Marshal(map[string]any{"id": 1, "method": method, "params": p})
	var response struct {
		Result map[string]any `json:"result"`
		Error  *Error         `json:"error"`
	}
	if err := json.Unmarshal(r.Handle(raw), &response); err != nil {
		t.Fatal(err)
	}
	return response.Result, response.Error
}
func mustCall(t *testing.T, r *Runtime, method string, p map[string]any) map[string]any {
	t.Helper()
	out, err := call(t, r, method, p)
	if err != nil {
		t.Fatalf("%s: %v", method, err)
	}
	return out
}
func setup(t *testing.T) (*Runtime, *fakeBackend, map[string]any, string) {
	t.Helper()
	f := newFake()
	r := New()
	r.factory = func(string, string) Backend { return f }
	dir := t.TempDir()
	init := mustCall(t, r, "initialize", map[string]any{"stateDirectory": dir, "hostname": "test-node"})
	owner := init["ownerId"].(string)
	mustCall(t, r, "login", map[string]any{"ownerId": owner})
	t.Cleanup(r.Close)
	return r, f, init, owner
}
func peer(f *fakeBackend) PeerRef { return PeerRef{networkScope(f.status), "peer-1"} }
func newForward(t *testing.T, r *Runtime, f *fakeBackend, owner string) map[string]any {
	t.Helper()
	return mustCall(t, r, "openForward", map[string]any{"ownerId": owner, "peer": peer(f), "port": 50728})
}
func connectLocal(t *testing.T, lease map[string]any) (*tls.Conn, *bufio.Reader) {
	t.Helper()
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM([]byte(lease["certificatePem"].(string)))
	c, err := tls.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", int(lease["port"].(float64))), &tls.Config{RootCAs: roots, ServerName: "127.0.0.1", MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	return c, bufio.NewReader(c)
}
func request(lease map[string]any, capability string) string {
	auth := base64.StdEncoding.EncodeToString([]byte(lease["forwardId"].(string) + ":" + capability))
	return fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: Basic %s\r\n\r\n", lease["authority"], lease["authority"], auth)
}
func responseHeader(t *testing.T, r *bufio.Reader) string {
	t.Helper()
	var b strings.Builder
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		b.WriteString(line)
		if line == "\r\n" {
			return b.String()
		}
	}
}

func TestInitializeDoesNotStartAndRestorationRequiresOptIn(t *testing.T) {
	r := New()
	defer r.Close()
	f := newFake()
	r.factory = func(string, string) Backend { return f }
	init := mustCall(t, r, "initialize", map[string]any{"stateDirectory": t.TempDir(), "hostname": "test-node"})
	if f.started.Load() != 0 {
		t.Fatal("initialize started networking")
	}
	_, err := call(t, r, "start", map[string]any{"ownerId": init["ownerId"]})
	if err == nil || err.Code != "loginRequired" {
		t.Fatal(err)
	}
}
func TestStateExclusiveAndOwnerLifetime(t *testing.T) {
	r, f, _, owner := setup(t)
	second := New()
	defer second.Close()
	_, err := call(t, second, "initialize", map[string]any{"stateDirectory": r.directory, "hostname": "test-node"})
	if err == nil || err.Code != "stateInUse" {
		t.Fatal(err)
	}
	attachment := mustCall(t, r, "initialize", map[string]any{"stateDirectory": r.directory, "hostname": "test-node"})
	mustCall(t, r, "dispose", map[string]any{"ownerId": owner})
	if f.closed.Load() != 0 {
		t.Fatal("another owner still holds node")
	}
	mustCall(t, r, "status", map[string]any{"ownerId": attachment["ownerId"]})
	mustCall(t, r, "dispose", map[string]any{"ownerId": attachment["ownerId"]})
	if f.closed.Load() != 1 {
		t.Fatal("last owner did not stop")
	}
}
func TestForwardHandshakeFragmentedAndPreservesCoalescedPayload(t *testing.T) {
	r, f, _, owner := setup(t)
	lease := newForward(t, r, f, owner)
	c, reader := connectLocal(t, lease)
	header := request(lease, lease["capability"].(string))
	for _, part := range []string{header[:4], header[4:31], header[31:] + "payload-before-response"} {
		if _, err := io.WriteString(c, part); err != nil {
			t.Fatal(err)
		}
	}
	if !strings.HasPrefix(responseHeader(t, reader), "HTTP/1.1 200") {
		t.Fatal("handshake failed")
	}
	got := make([]byte, len("payload-before-response"))
	if _, err := io.ReadFull(reader, got); err != nil {
		t.Fatal(err)
	}
	if string(got) != "payload-before-response" {
		t.Fatalf("lost prebuffer: %q", got)
	}
}
func TestInvalidCapabilityAndWrongTargetNeverDial(t *testing.T) {
	r, f, _, owner := setup(t)
	lease := newForward(t, r, f, owner)
	for _, req := range []string{request(lease, "wrong"), strings.ReplaceAll(request(lease, lease["capability"].(string)), ":50728", ":50729")} {
		c, reader := connectLocal(t, lease)
		_, _ = io.WriteString(c, req)
		if !strings.HasPrefix(responseHeader(t, reader), "HTTP/1.1 407") {
			t.Fatal("accepted invalid capability")
		}
		_ = c.Close()
	}
	if f.dials.Load() != 0 {
		t.Fatal("dialed before authorization")
	}
}
func TestLeaseExpiryAndRevocationCloseExistingStreams(t *testing.T) {
	r, f, _, owner := setup(t)
	lease := newForward(t, r, f, owner)
	c, reader := connectLocal(t, lease)
	_, _ = io.WriteString(c, request(lease, lease["capability"].(string)))
	responseHeader(t, reader)
	mustCall(t, r, "closeForward", map[string]any{"ownerId": owner, "forwardId": lease["forwardId"]})
	if _, err := reader.ReadByte(); err == nil {
		t.Fatal("revoked stream still open")
	}
	expired := newForward(t, r, f, owner)
	r.mu.Lock()
	r.forwards[expired["forwardId"].(string)].expires = time.Now().Add(-time.Second)
	r.mu.Unlock()
	c2, rd2 := connectLocal(t, expired)
	_, _ = io.WriteString(c2, request(expired, expired["capability"].(string)))
	if !strings.HasPrefix(responseHeader(t, rd2), "HTTP/1.1 410") {
		t.Fatal("expired lease accepted")
	}
}
func TestWrongRemoteIdentityIsRejected(t *testing.T) {
	r, f, _, owner := setup(t)
	lease := newForward(t, r, f, owner)
	f.mu.Lock()
	f.identity = "other-node"
	f.mu.Unlock()
	c, reader := connectLocal(t, lease)
	_, _ = io.WriteString(c, request(lease, lease["capability"].(string)))
	if !strings.HasPrefix(responseHeader(t, reader), "HTTP/1.1 403") {
		t.Fatal("identity mismatch not rejected")
	}
}
func TestWrongLocalCertificateIsRejected(t *testing.T) {
	r, f, _, owner := setup(t)
	lease := newForward(t, r, f, owner)
	_, wrong, _, err := certificate()
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM([]byte(wrong))
	c, err := tls.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", int(lease["port"].(float64))), &tls.Config{RootCAs: pool, ServerName: "127.0.0.1"})
	if err == nil {
		c.Close()
		t.Fatal("wrong local identity accepted")
	}
	if f.dials.Load() != 0 {
		t.Fatal("remote dial on failed TLS")
	}
}
func TestPublishRequiresExplicitPolicyAndPinnedMutualTLS(t *testing.T) {
	r, f, init, owner := setup(t)
	cert, err := tls.X509KeyPair([]byte(init["certificatePem"].(string)), []byte(init["privateKeyPem"].(string)))
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM([]byte(init["certificatePem"].(string)))
	ln, err := tls.Listen("tcp4", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}, ClientCAs: pool, ClientAuth: tls.RequireAndVerifyClientCert})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, e := ln.Accept()
			if e != nil {
				return
			}
			go func() { defer c.Close(); _, _ = io.Copy(c, c) }()
		}
	}()
	params := map[string]any{"ownerId": owner, "port": 50728, "targetPort": ln.Addr().(*net.TCPAddr).Port, "targetCertificatePem": init["certificatePem"]}
	if _, e := call(t, r, "publish", params); e == nil {
		t.Fatal("missing policy accepted")
	}
	params["allowedPeers"] = []PeerRef{}
	svc := mustCall(t, r, "publish", params)
	c, err := net.Dial("tcp", f.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = c.SetDeadline(time.Now().Add(time.Second))
	_, _ = c.Write([]byte("denied"))
	if _, e := c.Read(make([]byte, 1)); e == nil {
		t.Fatal("empty policy accepted")
	}
	c.Close()
	mustCall(t, r, "updatePolicy", map[string]any{"ownerId": owner, "serviceId": svc["serviceId"], "allowedPeers": []PeerRef{peer(f)}})
	c, err = net.Dial("tcp", f.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	_, _ = c.Write([]byte("secure"))
	buf := make([]byte, 6)
	if _, err = io.ReadFull(c, buf); err != nil {
		t.Fatal(err)
	}
	if string(buf) != "secure" {
		t.Fatal(string(buf))
	}
	mustCall(t, r, "updatePolicy", map[string]any{"ownerId": owner, "serviceId": svc["serviceId"], "allowedPeers": []PeerRef{}})
	if _, err = c.Read(buf); err == nil {
		t.Fatal("policy revocation kept existing stream")
	}
}
func TestLogoutOfflineClearsOnlyNodeStateAndChangesEpoch(t *testing.T) {
	r, _, init, owner := setup(t)
	dir := r.directory
	if err := os.MkdirAll(filepath.Join(dir, "node"), 0700); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "node", "identity"), []byte("test-secret"), 0600)
	os.WriteFile(filepath.Join(dir, "host-data"), []byte("keep"), 0600)
	out := mustCall(t, r, "logout", map[string]any{"ownerId": owner})
	if out["remoteLogoutNotified"] != false || out["localCredentialsCleared"] != true {
		t.Fatal(out)
	}
	if out["sessionEpoch"] == init["sessionEpoch"] {
		t.Fatal("old epoch survived")
	}
	if _, err := os.Stat(filepath.Join(dir, "node")); !os.IsNotExist(err) {
		t.Fatal("node state survived")
	}
	if _, err := os.Stat(filepath.Join(dir, "host-data")); err != nil {
		t.Fatal("host data lost")
	}
	if _, err := call(t, r, "start", map[string]any{"ownerId": owner}); err == nil || err.Code != "loginRequired" {
		t.Fatal(err)
	}
}
func TestScopeChangesForReregistration(t *testing.T) {
	f := newFake()
	ref := peer(f)
	f.status.Self.ID = tailcfg.StableNodeID("new-self")
	if _, err := resolvePeer(f.status, ref, 50728); err == nil {
		t.Fatal("old registration scope reused")
	}
}

func TestAnotherOwnerCannotRevokeForward(t *testing.T) {
	r, f, _, owner := setup(t)
	lease := newForward(t, r, f, owner)
	other := mustCall(t, r, "initialize", map[string]any{"stateDirectory": r.directory, "hostname": "test-node"})
	_, err := call(t, r, "closeForward", map[string]any{"ownerId": other["ownerId"], "forwardId": lease["forwardId"]})
	if err == nil || err.Code != "invalidOwner" {
		t.Fatal(err)
	}
	c, reader := connectLocal(t, lease)
	_, _ = io.WriteString(c, request(lease, lease["capability"].(string)))
	if !strings.HasPrefix(responseHeader(t, reader), "HTTP/1.1 200") {
		t.Fatal("other owner revoked forward")
	}
}

func TestInboundTargetPortTakeoverCannotReceivePayload(t *testing.T) {
	r, f, init, owner := setup(t)
	original, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := original.Addr().(*net.TCPAddr).Port
	mustCall(t, r, "publish", map[string]any{"ownerId": owner, "port": 50728, "targetPort": port, "targetCertificatePem": init["certificatePem"], "allowedPeers": []PeerRef{peer(f)}})
	_ = original.Close()
	wrongCert, _, _, err := certificate()
	if err != nil {
		t.Fatal(err)
	}
	imposter, err := tls.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", port), &tls.Config{Certificates: []tls.Certificate{wrongCert}})
	if err != nil {
		t.Fatal(err)
	}
	defer imposter.Close()
	readResult := make(chan int, 1)
	go func() {
		c, e := imposter.Accept()
		if e != nil {
			readResult <- 0
			return
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(2 * time.Second))
		buf := make([]byte, 64)
		n, _ := c.Read(buf)
		readResult <- n
	}()
	c, err := net.Dial("tcp", f.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	_, _ = c.Write([]byte("private payload"))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("target takeover accepted")
	}
	select {
	case n := <-readResult:
		if n != 0 {
			t.Fatal("payload sent to imposter")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("target handshake did not end")
	}
}

func TestInterruptedLogoutCannotRestoreOldIdentity(t *testing.T) {
	r, f, _, owner := setup(t)
	if err := writeMarker(filepath.Join(r.directory, "logout-pending")); err != nil {
		t.Fatal(err)
	}
	r.stop()
	if err := r.rotate(); err != nil {
		t.Fatal(err)
	}
	_, err := call(t, r, "start", map[string]any{"ownerId": owner})
	if err == nil || err.Code != "loginRequired" {
		t.Fatal(err)
	}
	if f.started.Load() != 1 {
		t.Fatal("interrupted logout restarted old node")
	}
}
func TestConnectRejectsAmbiguousFraming(t *testing.T) {
	base := "CONNECT 100.64.0.10:50728 HTTP/1.1\r\nHost: 100.64.0.10:50728\r\n"
	for _, extra := range []string{"Content-Length: 0\r\n", "Transfer-Encoding: chunked\r\n", "Host: 100.64.0.10:50728\r\n", strings.Repeat("x", 9000) + ": y\r\n"} {
		if _, _, err := readConnect(bufio.NewReader(strings.NewReader(base + extra + "\r\n"))); err == nil {
			t.Fatal("ambiguous framing accepted")
		}
	}
}

func TestAuthenticationURLIsPrivateToLoginOwner(t *testing.T) {
	r, f, _, owner := setup(t)
	f.status.AuthURL = "https://login.tailscale.com/a/example"
	other := mustCall(t, r, "initialize", map[string]any{"stateDirectory": r.directory, "hostname": "test-node"})
	status := mustCall(t, r, "status", map[string]any{"ownerId": owner})
	if status["authUrl"] != f.status.AuthURL {
		t.Fatal("login owner lost URL")
	}
	status = mustCall(t, r, "status", map[string]any{"ownerId": other["ownerId"]})
	if _, ok := status["authUrl"]; ok {
		t.Fatal("authentication URL leaked to another owner")
	}
}

type countingLogBuffer struct{ writes atomic.Int32 }

func (b *countingLogBuffer) Write(p []byte) (int, error)  { b.writes.Add(1); return len(p), nil }
func (b *countingLogBuffer) TryReadLine() ([]byte, error) { return nil, nil }

type rejectLogTransport struct{ attempts atomic.Int32 }

func (r *rejectLogTransport) RoundTrip(*http.Request) (*http.Response, error) {
	r.attempts.Add(1)
	return nil, errors.New("logging forbidden")
}

func TestPrivacyDropsUpstreamLogsBeforeBufferAndUpload(t *testing.T) {
	configurePrivacy()
	if !envknob.NoLogsNoSupport() {
		t.Fatal("upstream logging opt-out missing")
	}
	buffer := &countingLogBuffer{}
	transport := &rejectLogTransport{}
	logger := logtail.NewLogger(logtail.Config{BaseURL: "http://invalid.test", Buffer: buffer, Stderr: io.Discard, HTTPC: &http.Client{Transport: transport}}, func(string, ...any) {})
	logger.Logf("login URL %s", "https://login.tailscale.com/a/synthetic-test-value")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_ = logger.Shutdown(ctx)
	if buffer.writes.Load() != 0 || transport.attempts.Load() != 0 {
		t.Fatal("upstream login log was buffered or uploaded")
	}
}

func TestExpiredRegistrationRejectsNewInboundStreams(t *testing.T) {
	r, f, init, owner := setup(t)
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	mustCall(t, r, "publish", map[string]any{"ownerId": owner, "port": 50728, "targetPort": listener.Addr().(*net.TCPAddr).Port, "targetCertificatePem": init["certificatePem"], "allowedPeers": []PeerRef{peer(f)}})
	f.mu.Lock()
	f.status.BackendState = "NeedsLogin"
	f.mu.Unlock()
	remote, err := net.Dial("tcp", f.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer remote.Close()
	_ = remote.SetDeadline(time.Now().Add(time.Second))
	if _, err = remote.Read(make([]byte, 1)); err == nil {
		t.Fatal("expired registration accepted inbound")
	}
	_ = listener.(*net.TCPListener).SetDeadline(time.Now().Add(50 * time.Millisecond))
	if c, err := listener.Accept(); err == nil {
		c.Close()
		t.Fatal("expired registration connected to local target")
	}
}
