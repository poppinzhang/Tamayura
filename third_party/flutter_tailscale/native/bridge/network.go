package bridge

import (
	"encoding/json"
	"net"
	"net/netip"
	"sync"

	"tailscale.com/net/netmon"
)

var networkState struct {
	sync.RWMutex
	ready      bool
	interfaces []netmon.Interface
}

type networkSnapshot struct {
	Interfaces []struct {
		Index     int      `json:"index"`
		Name      string   `json:"name"`
		MTU       int      `json:"mtu"`
		Flags     uint     `json:"flags"`
		Addresses []string `json:"addresses"`
	} `json:"interfaces"`
	DefaultInterface string `json:"defaultInterface"`
	Gateway          string `json:"gateway"`
}

func setNetworkSnapshot(raw json.RawMessage) error {
	var p networkSnapshot
	if err := json.Unmarshal(raw, &p); err != nil {
		return failure("invalidArgument")
	}
	if len(p.Interfaces) > 128 {
		return failure("invalidArgument")
	}
	ifs := make([]netmon.Interface, 0, len(p.Interfaces))
	for _, i := range p.Interfaces {
		if i.Index <= 0 || len(i.Name) > 128 || len(i.Addresses) > 64 {
			return failure("invalidArgument")
		}
		addrs := make([]net.Addr, 0, len(i.Addresses))
		for _, a := range i.Addresses {
			prefix, err := netip.ParsePrefix(a)
			if err != nil {
				return failure("invalidArgument")
			}
			addrs = append(addrs, &net.IPNet{IP: net.IP(prefix.Addr().AsSlice()), Mask: net.CIDRMask(prefix.Bits(), prefix.Addr().BitLen())})
		}
		ifs = append(ifs, netmon.Interface{Interface: &net.Interface{Index: i.Index, Name: i.Name, MTU: i.MTU, Flags: net.Flags(i.Flags)}, AltAddrs: addrs})
	}
	networkState.Lock()
	networkState.ready = true
	networkState.interfaces = ifs
	networkState.Unlock()
	updateAndroidRoute(p.DefaultInterface, p.Gateway)
	return nil
}
