package bridge

import (
	"context"
	"errors"
	"net"
	"os"
	"runtime"
	"strconv"
	"sync"

	"golang.org/x/net/proxy"
	"tailscale.com/client/local"
	"tailscale.com/envknob"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/logtail"
	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

type tsBackend struct {
	server *tsnet.Server
	client *local.Client
}

var privacyOnce sync.Once

func configurePrivacy() {
	privacyOnce.Do(func() {
		// tsnet's user logger writes to logtail before UserLogf, including login
		// URLs. In the pinned upstream version Disable drops entries before the
		// disk buffer, while NoLogsNoSupport also installs a no-op transport.
		logtail.Disable()
		envknob.SetNoLogsNoSupport()
	})
}

func newTSBackend(dir, hostname string) Backend {
	configurePrivacy()
	if runtime.GOOS == "darwin" {
		if proxy.FromEnvironment() == proxy.Direct {
			// Like userspace tailscaled, this helper installs no system routes.
			// Network maps may reset the capability that controls interface
			// binding. Disable netns so sockets keep following the host route.
			netns.SetEnabled(false)
		} else {
			// netns also applies an explicitly configured SOCKS dialer and its
			// NO_PROXY exclusions. Keep that transport for these launches.
			netns.SetDisableBindConnToInterface(logger.Discard, true)
		}
	}
	return &tsBackend{server: &tsnet.Server{
		Dir: dir, Hostname: hostname, ControlURL: "https://controlplane.tailscale.com",
		Logf: func(string, ...any) {}, UserLogf: func(string, ...any) {},
	}}
}
func (b *tsBackend) Start() error {
	// Authentication is always initiated through this SDK's explicit login.
	// Do not silently inherit CI auth keys or OAuth secrets from a host shell.
	for _, name := range []string{"TS_AUTHKEY", "TS_AUTH_KEY", "TS_CLIENT_SECRET", "TS_CLIENT_ID", "TS_ID_TOKEN", "TS_AUDIENCE"} {
		if os.Getenv(name) != "" {
			return failure("ambientCredentialsUnsupported")
		}
	}
	if err := requireNetworkSnapshot(); err != nil {
		return err
	}
	var err error
	if runtime.GOOS == "android" {
		err = startWithAndroidLogsDir(b.server.Dir, b.server.Start)
	} else {
		err = b.server.Start()
	}
	if err != nil {
		return err
	}
	lc, err := b.server.LocalClient()
	b.client = lc
	return err
}

// Even with uploads disabled, tsnet's synchronous LocalBackend initialization
// calls logpolicy.LogsDir. Android app processes have no usable default there.
// Supply the private node directory only for startup; the runtime serializes
// control calls, and sockstatlog retains the resolved path after Start returns.
func startWithAndroidLogsDir(dir string, start func() error) error {
	if err := os.Mkdir(dir, 0700); err != nil && !os.IsExist(err) {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return failure("storageUnavailable")
	}
	const key = "TS_LOGS_DIR"
	previous, present := os.LookupEnv(key)
	if err := os.Setenv(key, dir); err != nil {
		return err
	}
	defer func() {
		if present {
			os.Setenv(key, previous)
		} else {
			os.Unsetenv(key)
		}
	}()
	return start()
}

func (b *tsBackend) Close() error { return b.server.Close() }
func (b *tsBackend) Status(ctx context.Context) (*ipnstate.Status, error) {
	return b.client.Status(ctx)
}
func (b *tsBackend) Login(ctx context.Context) error  { return b.client.StartLoginInteractive(ctx) }
func (b *tsBackend) Logout(ctx context.Context) error { return b.client.Logout(ctx) }
func (b *tsBackend) Dial(ctx context.Context, address string) (net.Conn, error) {
	return b.server.Dial(ctx, "tcp", address)
}
func (b *tsBackend) Listen(port int) (net.Listener, error) {
	return b.server.Listen("tcp", ":"+strconv.Itoa(port))
}
func (b *tsBackend) WhoIs(ctx context.Context, address string) (string, error) {
	w, err := b.client.WhoIs(ctx, address)
	if err != nil {
		return "", err
	}
	if w.Node == nil || w.Node.StableID == "" {
		return "", errors.New("identityUnavailable")
	}
	return string(w.Node.StableID), nil
}
func (b *tsBackend) NetworkChanged() { b.server.Sys().NetMon.Get().InjectEvent() }
