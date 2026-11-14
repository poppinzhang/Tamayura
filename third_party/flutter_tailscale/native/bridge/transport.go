package bridge

import (
	"bufio"
	"bytes"
	"context"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/textproto"
	"strconv"
	"strings"
	"time"
)

const maxResources = 128

func (r *Runtime) openForward(raw json.RawMessage, owner string) (any, error) {
	var p struct {
		Peer PeerRef `json:"peer"`
		Port int     `json:"port"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	st, _, epoch, err := r.getStatus()
	if err != nil {
		return nil, err
	}
	authority, err := resolvePeer(st, p.Peer, p.Port)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.epoch != epoch {
		return nil, failure("sessionChanged")
	}
	if len(r.forwards) >= maxResources {
		return nil, failure("resourceExhausted")
	}
	id, err := token()
	if err != nil {
		return nil, err
	}
	capability, err := token()
	if err != nil {
		return nil, err
	}
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, failure("listenFailed")
	}
	f := &forward{id: id, owner: owner, capability: capability, epoch: epoch, authority: authority, peer: p.Peer, port: p.Port, listener: ln, expires: time.Now().Add(time.Minute)}
	r.forwards[id] = f
	tlsConfig := &tls.Config{Certificates: []tls.Certificate{r.cert}, MinVersion: tls.VersionTLS12}
	go r.acceptForward(f, tlsConfig)
	time.AfterFunc(time.Minute, func() { _ = ln.Close() })
	return map[string]any{"sessionEpoch": epoch, "forwardId": id, "host": "127.0.0.1", "port": ln.Addr().(*net.TCPAddr).Port,
		"authority": authority, "capability": capability, "certificatePem": r.certPEM, "expiresAt": f.expires.UTC().Format(time.RFC3339Nano)}, nil
}
func (r *Runtime) acceptForward(f *forward, config *tls.Config) {
	for {
		c, err := f.listener.Accept()
		if err != nil {
			return
		}
		if !r.track(c, connectionOwner{resource: f.id, owner: f.owner}, f.epoch) {
			_ = c.Close()
			continue
		}
		go func() { defer r.untrack(c); r.forwardConnection(f, tls.Server(c, config)) }()
	}
}
func (r *Runtime) track(c net.Conn, owner connectionOwner, epoch string) bool {
	select {
	case r.capacity <- struct{}{}:
	default:
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.epoch != epoch || r.backend == nil {
		<-r.capacity
		return false
	}
	if _, ok := r.forwards[owner.resource]; !ok {
		if _, ok := r.services[owner.resource]; !ok {
			<-r.capacity
			return false
		}
	}
	r.connections[c] = owner
	return true
}
func (r *Runtime) untrack(c net.Conn) {
	_ = c.Close()
	r.mu.Lock()
	delete(r.connections, c)
	r.mu.Unlock()
	<-r.capacity
}

func readConnect(reader *bufio.Reader) (string, string, error) {
	total := 0
	readLine := func() (string, error) {
		var all []byte
		for {
			part, err := reader.ReadSlice('\n')
			total += len(part)
			if total > 8192 {
				return "", failure("invalidHandshake")
			}
			all = append(all, part...)
			if err == bufio.ErrBufferFull {
				continue
			}
			if err != nil {
				return "", err
			}
			if len(all) < 2 || all[len(all)-2] != '\r' {
				return "", failure("invalidHandshake")
			}
			return string(all[:len(all)-2]), nil
		}
	}
	first, err := readLine()
	if err != nil {
		return "", "", err
	}
	parts := strings.Split(first, " ")
	if len(parts) != 3 || parts[0] != "CONNECT" || parts[2] != "HTTP/1.1" {
		return "", "", failure("invalidHandshake")
	}
	if _, _, err := net.SplitHostPort(parts[1]); err != nil {
		return "", "", failure("invalidHandshake")
	}
	headers := make(map[string]string)
	for {
		line, err := readLine()
		if err != nil {
			return "", "", err
		}
		if line == "" {
			break
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok || key == "" || strings.ContainsAny(key, " \t\r\n") {
			return "", "", failure("invalidHandshake")
		}
		key = textproto.CanonicalMIMEHeaderKey(key)
		if _, exists := headers[key]; exists {
			return "", "", failure("invalidHandshake")
		}
		headers[key] = strings.TrimSpace(value)
	}
	if headers["Host"] != parts[1] || headers["Transfer-Encoding"] != "" || headers["Content-Length"] != "" {
		return "", "", failure("invalidHandshake")
	}
	auth := headers["Proxy-Authorization"]
	if !strings.HasPrefix(auth, "Basic ") {
		return parts[1], "", nil
	}
	b, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(auth, "Basic "))
	if err != nil {
		return parts[1], "", nil
	}
	return parts[1], string(b), nil
}
func localError(c net.Conn, status int) {
	_, _ = fmt.Fprintf(c, "HTTP/1.1 %d Bridge Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status)
}
func (r *Runtime) forwardConnection(f *forward, c *tls.Conn) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	if err := c.Handshake(); err != nil {
		return
	}
	reader := bufio.NewReaderSize(c, 8192)
	authority, auth, err := readConnect(reader)
	if err != nil {
		localError(c, 400)
		return
	}
	if authority != f.authority || subtle.ConstantTimeCompare([]byte(auth), []byte(f.id+":"+f.capability)) != 1 {
		localError(c, 407)
		return
	}
	r.mu.Lock()
	active := r.forwards[f.id] == f && r.epoch == f.epoch && time.Now().Before(f.expires)
	ctx := r.ctx
	r.mu.Unlock()
	if !active {
		localError(c, 410)
		return
	}
	_ = c.SetDeadline(time.Now().Add(20 * time.Second))
	st, b, epoch, err := r.getStatus()
	if err != nil || epoch != f.epoch {
		localError(c, 502)
		return
	}
	address, err := resolvePeer(st, f.peer, f.port)
	if err != nil {
		localError(c, 502)
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	remote, err := b.Dial(ctx, address)
	if err != nil {
		localError(c, 502)
		return
	}
	defer remote.Close()
	identity, err := b.WhoIs(ctx, remote.RemoteAddr().String())
	if err != nil || identity != f.peer.NodeID {
		localError(c, 403)
		return
	}
	r.mu.Lock()
	active = r.forwards[f.id] == f && r.epoch == f.epoch && r.backend == b
	if active {
		r.connections[remote] = connectionOwner{resource: f.id, owner: f.owner, peer: identity}
	}
	r.mu.Unlock()
	if !active {
		localError(c, 410)
		return
	}
	defer func() { r.mu.Lock(); delete(r.connections, remote); r.mu.Unlock() }()
	if _, err = io.WriteString(c, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	_ = c.SetDeadline(time.Time{})
	copyDuplex(c, remote, reader)
}

func parseCertificate(value string) ([]byte, error) {
	block, rest := pem.Decode([]byte(value))
	if block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, failure("invalidCertificate")
	}
	if _, err := x509.ParseCertificate(block.Bytes); err != nil {
		return nil, failure("invalidCertificate")
	}
	return block.Bytes, nil
}
func (r *Runtime) publish(raw json.RawMessage, owner string) (any, error) {
	var p struct {
		Port                 int        `json:"port"`
		TargetPort           int        `json:"targetPort"`
		TargetCertificatePEM string     `json:"targetCertificatePem"`
		AllowedPeers         *[]PeerRef `json:"allowedPeers"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if p.Port < 1 || p.Port > 65535 || p.TargetPort < 1 || p.TargetPort > 65535 || p.AllowedPeers == nil {
		return nil, failure("invalidArgument")
	}
	cert, err := parseCertificate(p.TargetCertificatePEM)
	if err != nil {
		return nil, err
	}
	st, b, epoch, err := r.getStatus()
	if err != nil {
		return nil, err
	}
	if !ready(st) {
		return nil, failure("loginRequired")
	}
	allowed, err := policy(*p.AllowedPeers, networkScope(st))
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	if len(r.services) >= maxResources {
		r.mu.Unlock()
		return nil, failure("resourceExhausted")
	}
	r.mu.Unlock()
	id, err := token()
	if err != nil {
		return nil, err
	}
	ln, err := b.Listen(p.Port)
	if err != nil {
		return nil, failure("listenFailed")
	}
	s := &service{id: id, owner: owner, epoch: epoch, port: p.Port, targetPort: p.TargetPort, targetCert: cert, allowed: allowed, listener: ln}
	r.mu.Lock()
	r.services[id] = s
	r.mu.Unlock()
	go r.acceptService(s)
	return map[string]any{"sessionEpoch": epoch, "serviceId": id, "port": p.Port}, nil
}
func policy(peers []PeerRef, scope string) (map[PeerRef]bool, error) {
	if len(peers) > 4096 {
		return nil, failure("resourceExhausted")
	}
	out := make(map[PeerRef]bool, len(peers))
	for _, ref := range peers {
		if ref.NetworkScope != scope || ref.NodeID == "" || len(ref.NodeID) > 256 {
			return nil, failure("sessionChanged")
		}
		out[ref] = true
	}
	return out, nil
}
func (r *Runtime) acceptService(s *service) {
	for {
		c, err := s.listener.Accept()
		if err != nil {
			return
		}
		if !r.track(c, connectionOwner{resource: s.id, owner: s.owner}, s.epoch) {
			_ = c.Close()
			continue
		}
		go func() { defer r.untrack(c); r.serviceConnection(s, c) }()
	}
}
func (r *Runtime) serviceConnection(s *service, c net.Conn) {
	st, b, epoch, err := r.getStatus()
	if err != nil || epoch != s.epoch || !ready(st) {
		return
	}
	r.mu.Lock()
	ctx := r.ctx
	clientCert := r.cert
	r.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	id, err := b.WhoIs(ctx, c.RemoteAddr().String())
	if err != nil {
		return
	}
	ref := PeerRef{networkScope(st), id}
	r.mu.Lock()
	allowed := r.services[s.id] == s && s.allowed[ref] && r.epoch == s.epoch
	if allowed {
		r.connections[c] = connectionOwner{resource: s.id, owner: s.owner, peer: id}
	}
	r.mu.Unlock()
	if !allowed {
		return
	}
	pool := x509.NewCertPool()
	cert, err := x509.ParseCertificate(s.targetCert)
	if err != nil {
		return
	}
	pool.AddCert(cert)
	config := &tls.Config{RootCAs: pool, Certificates: []tls.Certificate{clientCert}, ServerName: "127.0.0.1", MinVersion: tls.VersionTLS12,
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) != 1 || !bytes.Equal(state.PeerCertificates[0].Raw, s.targetCert) {
				return failure("targetIdentityMismatch")
			}
			return nil
		},
	}
	dialer := tls.Dialer{NetDialer: &net.Dialer{Timeout: 5 * time.Second}, Config: config}
	local, err := dialer.DialContext(ctx, "tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(s.targetPort)))
	if err != nil {
		return
	}
	defer local.Close()
	r.mu.Lock()
	allowed = r.services[s.id] == s && s.allowed[ref] && r.epoch == s.epoch
	if allowed {
		r.connections[local] = connectionOwner{resource: s.id, owner: s.owner, peer: id}
	}
	r.mu.Unlock()
	if !allowed {
		return
	}
	defer func() { r.mu.Lock(); delete(r.connections, local); r.mu.Unlock() }()
	copyDuplex(c, local, c)
}
func (r *Runtime) updatePolicy(raw json.RawMessage, owner string) (any, error) {
	var p struct {
		ServiceID    string     `json:"serviceId"`
		AllowedPeers *[]PeerRef `json:"allowedPeers"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if p.AllowedPeers == nil {
		return nil, failure("invalidArgument")
	}
	st, _, _, err := r.getStatus()
	if err != nil {
		return nil, err
	}
	allowed, err := policy(*p.AllowedPeers, networkScope(st))
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.services[p.ServiceID]
	if s == nil {
		return nil, failure("unknownService")
	}
	if s.owner != owner {
		return nil, failure("invalidOwner")
	}
	s.allowed = allowed
	for c, o := range r.connections {
		if o.resource == s.id && o.peer != "" && !allowed[PeerRef{networkScope(st), o.peer}] {
			_ = c.Close()
		}
	}
	return map[string]any{"sessionEpoch": r.epoch, "updated": true}, nil
}
func (r *Runtime) revoke(id, owner string, inbound bool) (any, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if inbound {
		if s := r.services[id]; s != nil {
			if s.owner != owner {
				return nil, failure("invalidOwner")
			}
			_ = s.listener.Close()
			delete(r.services, id)
		}
	} else {
		if f := r.forwards[id]; f != nil {
			if f.owner != owner {
				return nil, failure("invalidOwner")
			}
			_ = f.listener.Close()
			delete(r.forwards, id)
		}
	}
	for c, o := range r.connections {
		if o.resource == id {
			_ = c.Close()
		}
	}
	return map[string]any{"sessionEpoch": r.epoch, "revoked": true}, nil
}

// gRPC does not rely on TCP half-close. A clean EOF allows the reverse
// direction up to five seconds to flush. Hard errors close both immediately.
// There is no application idle timeout and no transparent reconnect/replay.
func copyDuplex(a, b net.Conn, aReader io.Reader) {
	defer a.Close()
	defer b.Close()
	done := make(chan error, 2)
	copyOne := func(dst net.Conn, src io.Reader) {
		_, err := io.CopyBuffer(dst, src, make([]byte, 32*1024))
		if err == nil {
			if half, ok := dst.(interface{ CloseWrite() error }); ok {
				_ = half.CloseWrite()
			}
		}
		done <- err
	}
	go copyOne(b, aReader)
	go copyOne(a, b)
	if err := <-done; err != nil {
		_ = a.Close()
		_ = b.Close()
		<-done
		return
	}
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
		_ = a.Close()
		_ = b.Close()
		<-done
	}
}
