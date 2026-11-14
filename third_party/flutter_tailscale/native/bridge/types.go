// Package bridge provides the versioned, application-owned tsnet runtime.
// Its control transport never carries application payloads.
package bridge

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"net"
	"sync"
	"time"

	"tailscale.com/ipn/ipnstate"
)

const ProtocolVersion = 1
const MaxControlBytes = 1 << 20

type PeerRef struct {
	NetworkScope string `json:"networkScope"`
	NodeID       string `json:"nodeId"`
}
type Peer struct {
	PeerRef
	Name      string   `json:"name"`
	Addresses []string `json:"addresses"`
	Online    bool     `json:"online"`
}
type Request struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string   { return e.Code }
func failure(code string) *Error { return &Error{Code: code, Message: code} }

type Response struct {
	ID     json.RawMessage `json:"id"`
	Result any             `json:"result,omitempty"`
	Error  *Error          `json:"error,omitempty"`
}

// Backend is intentionally narrow so transport and authorization tests do not
// require a live account or accidentally contact Tailscale's control plane.
type Backend interface {
	Start() error
	Close() error
	Status(context.Context) (*ipnstate.Status, error)
	Login(context.Context) error
	Logout(context.Context) error
	Dial(context.Context, string) (net.Conn, error)
	Listen(int) (net.Listener, error)
	WhoIs(context.Context, string) (string, error)
	NetworkChanged()
}

type Runtime struct {
	control                    sync.Mutex
	mu                         sync.Mutex
	directory, hostname, epoch string
	cert                       tls.Certificate
	certPEM, keyPEM            string
	stateLock                  *stateLock
	backend                    Backend
	factory                    func(string, string) Backend
	ctx                        context.Context
	cancel                     context.CancelFunc
	owners                     map[string]bool
	forwards                   map[string]*forward
	services                   map[string]*service
	connections                map[net.Conn]connectionOwner
	capacity                   chan struct{}
	loginRequested             bool
	loginOwner                 string
}
type connectionOwner struct{ resource, owner, peer string }
type forward struct {
	id, owner, capability, epoch, authority string
	peer                                    PeerRef
	port                                    int
	listener                                net.Listener
	expires                                 time.Time
}
type service struct {
	id, owner, epoch string
	port, targetPort int
	targetCert       []byte
	allowed          map[PeerRef]bool
	listener         net.Listener
}

func New() *Runtime {
	return &Runtime{factory: newTSBackend, capacity: make(chan struct{}, 64)}
}

type commonParams struct {
	OwnerID      string `json:"ownerId"`
	SessionEpoch string `json:"sessionEpoch"`
}
