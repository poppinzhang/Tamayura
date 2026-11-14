package bridge

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"time"

	"tailscale.com/ipn/ipnstate"
)

var validHostname = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$`)

// Handle serializes control mutations. Data copying and network dials run
// independently; closing a resource interrupts all its pending I/O.
func (r *Runtime) Handle(raw []byte) []byte {
	r.control.Lock()
	defer r.control.Unlock()
	var q Request
	if len(raw) > MaxControlBytes || json.Unmarshal(raw, &q) != nil || len(q.ID) == 0 || q.Method == "" {
		return marshalResponse(Response{ID: json.RawMessage("null"), Error: failure("invalidRequest")})
	}
	value, err := r.dispatch(q)
	response := Response{ID: q.ID, Result: value}
	if err != nil {
		var e *Error
		if !errors.As(err, &e) {
			e = failure("operationFailed")
		}
		response.Result = nil
		response.Error = e
	}
	return marshalResponse(response)
}
func marshalResponse(r Response) []byte {
	b, err := json.Marshal(r)
	if err != nil || len(b) > MaxControlBytes {
		b, _ = json.Marshal(Response{ID: r.ID, Error: failure("resourceExhausted")})
	}
	return b
}
func decode(raw json.RawMessage, p any) error {
	if len(raw) == 0 {
		raw = []byte("{}")
	}
	if json.Unmarshal(raw, p) != nil {
		return failure("invalidArgument")
	}
	return nil
}
func (r *Runtime) dispatch(q Request) (any, error) {
	if q.Method == "initialize" {
		return r.initialize(q.Params)
	}
	if q.Method == "networkChanged" {
		if err := setNetworkSnapshot(q.Params); err != nil {
			return nil, err
		}
		r.mu.Lock()
		b := r.backend
		r.mu.Unlock()
		if b != nil {
			b.NetworkChanged()
		}
		return map[string]any{"updated": true}, nil
	}
	var p commonParams
	if err := decode(q.Params, &p); err != nil {
		return nil, err
	}
	r.mu.Lock()
	valid := r.owners[p.OwnerID]
	epoch := r.epoch
	r.mu.Unlock()
	if !valid {
		return nil, failure("invalidOwner")
	}
	if p.SessionEpoch != "" && p.SessionEpoch != epoch {
		return nil, failure("sessionChanged")
	}
	switch q.Method {
	case "start", "login":
		if err := r.start(q.Method == "login"); err != nil {
			return nil, err
		}
		if q.Method == "login" {
			r.mu.Lock()
			r.loginOwner = p.OwnerID
			r.mu.Unlock()
		}
		out, err := r.snapshot(q.Method == "login")
		if err != nil {
			return nil, err
		}
		r.mu.Lock()
		r.addMaterials(out)
		r.mu.Unlock()
		return out, nil
	case "status":
		r.mu.Lock()
		includeAuth := r.loginOwner == p.OwnerID
		r.mu.Unlock()
		return r.snapshot(includeAuth)
	case "peers":
		return r.peers()
	case "openForward":
		return r.openForward(q.Params, p.OwnerID)
	case "closeForward":
		var v struct {
			ForwardID string `json:"forwardId"`
		}
		if err := decode(q.Params, &v); err != nil {
			return nil, err
		}
		return r.revoke(v.ForwardID, p.OwnerID, false)
	case "publish":
		return r.publish(q.Params, p.OwnerID)
	case "updatePolicy":
		return r.updatePolicy(q.Params, p.OwnerID)
	case "unpublish":
		var v struct {
			ServiceID string `json:"serviceId"`
		}
		if err := decode(q.Params, &v); err != nil {
			return nil, err
		}
		return r.revoke(v.ServiceID, p.OwnerID, true)
	case "stop":
		r.stop()
		if err := r.rotate(); err != nil {
			return nil, err
		}
		return r.snapshot(false)
	case "logout":
		return r.logout()
	case "dispose":
		r.disposeOwner(p.OwnerID)
		return map[string]any{"disposed": true}, nil
	default:
		return nil, failure("unsupportedMethod")
	}
}

func (r *Runtime) initialize(raw json.RawMessage) (any, error) {
	var p struct {
		StateDirectory  string `json:"stateDirectory"`
		Hostname        string `json:"hostname"`
		ProtocolVersion int    `json:"protocolVersion"`
		OwnerID         string `json:"ownerId"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if p.ProtocolVersion != 0 && p.ProtocolVersion != ProtocolVersion {
		return nil, failure("incompatibleProtocol")
	}
	if !filepath.IsAbs(p.StateDirectory) || !validHostname.MatchString(p.Hostname) {
		return nil, failure("invalidArgument")
	}
	dir := filepath.Clean(p.StateDirectory)
	r.mu.Lock()
	if r.directory != "" {
		if r.directory != dir || r.hostname != p.Hostname {
			r.mu.Unlock()
			return nil, failure("stateInUse")
		}
		owner, err := token()
		if err != nil {
			r.mu.Unlock()
			return nil, err
		}
		if p.OwnerID != "" && r.owners[p.OwnerID] {
			owner = p.OwnerID
		}
		r.owners[owner] = true
		out := map[string]any{"ownerId": owner, "protocolVersion": ProtocolVersion}
		r.addMaterials(out)
		r.mu.Unlock()
		return out, nil
	}
	r.mu.Unlock()
	if info, err := os.Lstat(dir); err == nil && (!info.IsDir() || info.Mode()&os.ModeSymlink != 0) {
		return nil, failure("invalidStateDirectory")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, failure("storageUnavailable")
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return nil, failure("storageUnavailable")
	}
	lock, err := lockState(filepath.Join(dir, "bridge.lock"))
	if err != nil {
		return nil, failure("stateInUse")
	}
	owner, err := token()
	if err != nil {
		lock.close()
		return nil, err
	}
	r.mu.Lock()
	r.directory = dir
	r.hostname = p.Hostname
	r.stateLock = lock
	r.owners = map[string]bool{owner: true}
	r.forwards = map[string]*forward{}
	r.services = map[string]*service{}
	r.connections = map[net.Conn]connectionOwner{}
	r.mu.Unlock()
	if err := r.rotate(); err != nil {
		r.shutdown()
		return nil, err
	}
	r.mu.Lock()
	out := map[string]any{"ownerId": owner, "protocolVersion": ProtocolVersion}
	r.addMaterials(out)
	r.mu.Unlock()
	return out, nil
}
func (r *Runtime) addMaterials(out map[string]any) {
	out["sessionEpoch"] = r.epoch
	out["certificatePem"] = r.certPEM
	out["privateKeyPem"] = r.keyPEM
	out["capabilities"] = []string{"tcp", "grpcCleartext", "localMutualTls", "explicitPeerPolicy", "owners"}
}
func (r *Runtime) rotate() error {
	epoch, err := token()
	if err != nil {
		return err
	}
	cert, certPEM, keyPEM, err := certificate()
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.epoch = epoch
	r.cert = cert
	r.certPEM = certPEM
	r.keyPEM = keyPEM
	r.ctx, r.cancel = context.WithCancel(context.Background())
	r.loginRequested = false
	r.loginOwner = ""
	return nil
}

func (r *Runtime) start(interactive bool) error {
	r.mu.Lock()
	if r.backend != nil {
		b := r.backend
		requested := r.loginRequested
		r.mu.Unlock()
		if interactive && !requested {
			return r.requestLogin(b)
		}
		return nil
	}
	dir, hostname := r.directory, r.hostname
	canceled := r.ctx != nil && r.ctx.Err() != nil
	r.mu.Unlock()
	if canceled {
		if err := r.rotate(); err != nil {
			return err
		}
	}
	// A durable marker, separate from upstream files, prevents an interrupted
	// offline logout from silently resurrecting a prior node on restart.
	marker := filepath.Join(dir, "resume-enabled")
	pending := filepath.Join(dir, "logout-pending")
	if _, err := os.Stat(pending); err == nil {
		if !interactive {
			return failure("loginRequired")
		}
		if err := os.RemoveAll(filepath.Join(dir, "node")); err != nil {
			return failure("credentialCleanupFailed")
		}
		if err := os.Remove(pending); err != nil {
			return failure("credentialCleanupFailed")
		}
	} else if !os.IsNotExist(err) {
		return failure("storageUnavailable")
	}
	if !interactive {
		if _, err := os.Stat(marker); err != nil {
			return failure("loginRequired")
		}
	}
	if interactive {
		if err := writeMarker(marker); err != nil {
			return failure("storageUnavailable")
		}
	}
	b := r.factory(filepath.Join(dir, "node"), hostname)
	if err := b.Start(); err != nil {
		_ = b.Close()
		return failure("startFailed")
	}
	r.mu.Lock()
	r.backend = b
	r.mu.Unlock()
	if interactive {
		return r.requestLogin(b)
	}
	return nil
}
func (r *Runtime) requestLogin(b Backend) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := b.Login(ctx); err != nil {
		return failure("loginFailed")
	}
	r.mu.Lock()
	r.loginRequested = true
	r.mu.Unlock()
	return nil
}

func networkScope(st *ipnstate.Status) string {
	if st.Self == nil || st.Self.ID == "" {
		return ""
	}
	// Local registration scope, intentionally opaque. Re-registering this node
	// or changing accounts invalidates all remembered peer references.
	sum := sha256.Sum256([]byte(fmt.Sprintf("official:%s:%d", st.Self.ID, st.Self.UserID)))
	return hex.EncodeToString(sum[:])
}
func (r *Runtime) getStatus() (*ipnstate.Status, Backend, string, error) {
	r.mu.Lock()
	b, epoch := r.backend, r.epoch
	ctx := r.ctx
	r.mu.Unlock()
	if b == nil {
		return nil, nil, epoch, failure("notRunning")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	st, err := b.Status(ctx)
	if err != nil {
		return nil, b, epoch, failure("statusUnavailable")
	}
	return st, b, epoch, nil
}
func (r *Runtime) snapshot(includeAuth bool) (map[string]any, error) {
	r.mu.Lock()
	epoch := r.epoch
	running := r.backend != nil
	requested := r.loginRequested
	r.mu.Unlock()
	out := map[string]any{"sessionEpoch": epoch, "state": "stopped", "controlState": "unknown"}
	if !running {
		return out, nil
	}
	st, _, _, err := r.getStatus()
	if err != nil {
		return nil, err
	}
	state := "connecting"
	switch st.BackendState {
	case "NeedsLogin":
		state = "signedOut"
		if requested {
			state = "authorizing"
		}
	case "NeedsMachineAuth":
		state = "awaitingApproval"
	case "Running":
		state = "connected"
	case "Stopped":
		state = "stopped"
	}
	out["state"] = state
	if st.Self != nil {
		out["selfNodeId"] = string(st.Self.ID)
		out["controlState"] = "disconnected"
		if st.Self.Online {
			out["controlState"] = "connected"
		}
	}
	if scope := networkScope(st); scope != "" {
		out["networkScope"] = scope
	}
	if includeAuth && requested && st.AuthURL != "" {
		u, err := url.Parse(st.AuthURL)
		if err == nil && u.Scheme == "https" && u.Hostname() == "login.tailscale.com" && u.User == nil && u.Port() == "" {
			out["authUrl"] = st.AuthURL
		}
	}
	return out, nil
}
func (r *Runtime) peers() (any, error) {
	st, _, epoch, err := r.getStatus()
	if err != nil {
		return nil, err
	}
	if !ready(st) {
		return nil, failure("loginRequired")
	}
	scope := networkScope(st)
	peers := make([]Peer, 0, len(st.Peer))
	for _, p := range st.Peer {
		if p.ID == "" || p.ID == st.Self.ID {
			continue
		}
		addresses := make([]string, 0, len(p.TailscaleIPs))
		for _, ip := range p.TailscaleIPs {
			addresses = append(addresses, ip.String())
		}
		peers = append(peers, Peer{PeerRef: PeerRef{scope, string(p.ID)}, Name: p.HostName, Addresses: addresses, Online: p.Online})
	}
	sort.Slice(peers, func(i, j int) bool { return peers[i].NodeID < peers[j].NodeID })
	return map[string]any{"sessionEpoch": epoch, "peers": peers}, nil
}
func ready(st *ipnstate.Status) bool {
	return st != nil && st.Self != nil && st.Self.ID != "" && st.BackendState == "Running"
}
func resolvePeer(st *ipnstate.Status, ref PeerRef, port int) (string, error) {
	if !ready(st) || ref.NetworkScope == "" || ref.NetworkScope != networkScope(st) {
		return "", failure("sessionChanged")
	}
	if port < 1 || port > 65535 {
		return "", failure("invalidArgument")
	}
	for _, p := range st.Peer {
		if string(p.ID) == ref.NodeID && len(p.TailscaleIPs) > 0 {
			return net.JoinHostPort(p.TailscaleIPs[0].String(), strconv.Itoa(port)), nil
		}
	}
	return "", failure("peerUnavailable")
}

func (r *Runtime) stop() {
	r.mu.Lock()
	b := r.backend
	r.backend = nil
	if r.cancel != nil {
		r.cancel()
	}
	for _, f := range r.forwards {
		_ = f.listener.Close()
	}
	r.forwards = map[string]*forward{}
	for _, s := range r.services {
		_ = s.listener.Close()
	}
	r.services = map[string]*service{}
	for c := range r.connections {
		_ = c.Close()
	}
	r.connections = map[net.Conn]connectionOwner{}
	r.mu.Unlock()
	if b != nil {
		_ = b.Close()
	}
}
func (r *Runtime) logout() (any, error) {
	r.mu.Lock()
	dir := r.directory
	b := r.backend
	r.mu.Unlock()
	if err := writeMarker(filepath.Join(dir, "logout-pending")); err != nil {
		return nil, failure("storageUnavailable")
	}
	if err := os.Remove(filepath.Join(dir, "resume-enabled")); err != nil && !os.IsNotExist(err) {
		return nil, failure("storageUnavailable")
	}
	// Resources are invalidated before attempting a bounded cloud notification.
	r.mu.Lock()
	if r.cancel != nil {
		r.cancel()
	}
	for _, f := range r.forwards {
		_ = f.listener.Close()
	}
	for _, s := range r.services {
		_ = s.listener.Close()
	}
	for c := range r.connections {
		_ = c.Close()
	}
	r.mu.Unlock()
	remote := false
	if b != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		remote = b.Logout(ctx) == nil
		cancel()
	}
	r.stop()
	// Delete only this SDK's dedicated identity subdirectory, never the host
	// application directory. Failed cleanup is reported and resume stays off.
	if err := os.RemoveAll(filepath.Join(dir, "node")); err != nil {
		return nil, failure("credentialCleanupFailed")
	}
	if err := os.Remove(filepath.Join(dir, "logout-pending")); err != nil {
		return nil, failure("credentialCleanupFailed")
	}
	if err := r.rotate(); err != nil {
		return nil, err
	}
	return map[string]any{"localCredentialsCleared": true, "remoteLogoutNotified": remote, "sessionEpoch": r.epoch, "state": "signedOut"}, nil
}

func writeMarker(path string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	if _, err = f.WriteString("1\n"); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}
func (r *Runtime) disposeOwner(owner string) {
	r.mu.Lock()
	for id, f := range r.forwards {
		if f.owner == owner {
			_ = f.listener.Close()
			delete(r.forwards, id)
		}
	}
	for id, s := range r.services {
		if s.owner == owner {
			_ = s.listener.Close()
			delete(r.services, id)
		}
	}
	for c, entry := range r.connections {
		if entry.owner == owner {
			_ = c.Close()
			delete(r.connections, c)
		}
	}
	delete(r.owners, owner)
	empty := len(r.owners) == 0
	r.mu.Unlock()
	if empty {
		r.shutdown()
	}
}
func (r *Runtime) shutdown() {
	r.stop()
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.stateLock != nil {
		r.stateLock.close()
	}
	r.stateLock = nil
	r.directory = ""
	r.hostname = ""
	r.epoch = ""
	r.certPEM = ""
	r.keyPEM = ""
	r.owners = nil
}

// Close is for process EOF or host termination. It retains node credentials.
func (r *Runtime) Close() { r.control.Lock(); defer r.control.Unlock(); r.shutdown() }
