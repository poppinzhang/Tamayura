package bridge

import "tailscale.com/net/netmon"

func init() {
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		networkState.RLock()
		defer networkState.RUnlock()
		if !networkState.ready {
			return nil, failure("networkUnavailable")
		}
		return append([]netmon.Interface(nil), networkState.interfaces...), nil
	})
}
func requireNetworkSnapshot() error {
	networkState.RLock()
	defer networkState.RUnlock()
	if !networkState.ready {
		return failure("networkUnavailable")
	}
	return nil
}
func updateAndroidRoute(iface, gateway string) {
	netmon.UpdateLastKnownDefaultRouteInterface(iface)
	netmon.UpdateLastKnownDefaultGateway(gateway)
}
