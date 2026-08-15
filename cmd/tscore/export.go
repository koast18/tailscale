package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"strings"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/netcheck"
	"tailscale.com/tailcfg"
)

// jstr marshals v to a JSON C string (caller frees with TsFreeString).
func jstr(v any) *C.char {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return C.CString(fmt.Sprintf(`{"error":%q}`, err.Error()))
	}
	return C.CString(string(b))
}

// lc returns the LocalClient for the singleton server.
func lc() (*local.Client, error) {
	s, err := getSrv()
	if err != nil {
		return nil, err
	}
	return s.LocalClient()
}

// statusCtx returns a bounded context for LocalAPI calls.
func statusCtx() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 15*time.Second)
}

// ---------------------------------------------------------------------------
// 4.2 Exit Node control
// ---------------------------------------------------------------------------

type exitNodeInfo struct {
	ID           tailcfg.StableNodeID `json:"id"`
	Name         string               `json:"name"`
	HostName     string               `json:"hostName"`
	CountryCode  string               `json:"countryCode,omitempty"`
	Online       bool                 `json:"online"`
	ExitNode     bool                 `json:"exitNode"`
	TailscaleIPs []netip.Addr         `json:"tailscaleIPs,omitempty"`
}

//export TsListExitNodes
func TsListExitNodes() *C.char {
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	st, err := c.Status(ctx)
	if err != nil {
		return jstr(err)
	}
	var out []exitNodeInfo
	for _, p := range st.Peer {
		if !p.ExitNodeOption {
			continue
		}
		cc := ""
		if p.Location != nil {
			cc = p.Location.CountryCode
		}
		out = append(out, exitNodeInfo{
			ID:           p.ID,
			Name:         strings.TrimSuffix(p.DNSName, "."),
			HostName:     p.HostName,
			CountryCode:  cc,
			Online:       p.Online,
			ExitNode:     p.ExitNode,
			TailscaleIPs: p.TailscaleIPs,
		})
	}
	return jstr(out)
}

//export TsGetExitNodeStatus
func TsGetExitNodeStatus() *C.char {
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	st, err := c.Status(ctx)
	if err != nil {
		return jstr(err)
	}
	if st.ExitNodeStatus == nil {
		return C.CString(`{"error":"no exit node in use"}`)
	}
	return jstr(st.ExitNodeStatus)
}

//export TsSuggestExitNode
func TsSuggestExitNode() *C.char {
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	res, err := c.SuggestExitNodeWithProbe(ctx)
	if err != nil {
		return jstr(err)
	}
	return jstr(res)
}

// resolveExitNode finds a peer by DNS name, hostname, or 100.x IP.
func resolveExitNode(c *local.Client, ctx context.Context, nameOrIP string) (*ipnstate.PeerStatus, error) {
	st, err := c.Status(ctx)
	if err != nil {
		return nil, err
	}
	needle := strings.ToLower(strings.TrimSuffix(nameOrIP, "."))
	for _, p := range st.Peer {
		if !p.ExitNodeOption {
			continue
		}
		if strings.ToLower(strings.TrimSuffix(p.DNSName, ".")) == needle ||
			strings.EqualFold(p.HostName, needle) {
			return p, nil
		}
		for _, ip := range p.TailscaleIPs {
			if ip.String() == needle {
				return p, nil
			}
		}
	}
	return nil, fmt.Errorf("no exit node option found for %q", nameOrIP)
}

//export TsSetExitNode
func TsSetExitNode(nameOrIP *C.char) C.int {
	if nameOrIP == nil {
		return -1
	}
	c, err := lc()
	if err != nil {
		tslogf("TsSetExitNode: %v", err)
		return -1
	}
	ctx, cancel := statusCtx()
	defer cancel()
	p, err := resolveExitNode(c, ctx, C.GoString(nameOrIP))
	if err != nil {
		tslogf("TsSetExitNode: %v", err)
		return -1
	}
	if _, err := c.EditPrefs(ctx, &ipn.MaskedPrefs{
		Prefs:         ipn.Prefs{ExitNodeID: p.ID},
		ExitNodeIDSet: true,
	}); err != nil {
		tslogf("TsSetExitNode: %v", err)
		return -1
	}
	tslogf("TsSetExitNode: set exit node %s (%s)", p.HostName, p.ID)
	return 0
}

//export TsClearExitNode
func TsClearExitNode() C.int {
	c, err := lc()
	if err != nil {
		tslogf("TsClearExitNode: %v", err)
		return -1
	}
	ctx, cancel := statusCtx()
	defer cancel()
	if _, err := c.EditPrefs(ctx, &ipn.MaskedPrefs{
		ExitNodeIDSet: true,
	}); err != nil {
		tslogf("TsClearExitNode: %v", err)
		return -1
	}
	return 0
}

//export TsSetExitNodeAllowLANAccess
func TsSetExitNodeAllowLANAccess(enable C.int) C.int {
	c, err := lc()
	if err != nil {
		tslogf("TsSetExitNodeAllowLANAccess: %v", err)
		return -1
	}
	ctx, cancel := statusCtx()
	defer cancel()
	if _, err := c.EditPrefs(ctx, &ipn.MaskedPrefs{
		Prefs:                     ipn.Prefs{ExitNodeAllowLANAccess: enable != 0},
		ExitNodeAllowLANAccessSet: true,
	}); err != nil {
		tslogf("TsSetExitNodeAllowLANAccess: %v", err)
		return -1
	}
	return 0
}

// ---------------------------------------------------------------------------
// 4.3 Diagnostics & network
// ---------------------------------------------------------------------------

//export TsPing
func TsPing(ip *C.char, pingType *C.char) *C.char {
	if ip == nil {
		return jstr(errors.New("nil ip"))
	}
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	addr, err := netip.ParseAddr(C.GoString(ip))
	if err != nil {
		return jstr(err)
	}
	t := tailcfg.PingDisco
	if pingType != nil {
		pt := C.GoString(pingType)
		switch pt {
		case "disco":
			t = tailcfg.PingDisco
		case "TSMP", "tsmp":
			t = tailcfg.PingTSMP
		case "ICMP", "icmp":
			t = tailcfg.PingICMP
		case "peerapi", "PeerAPI":
			t = tailcfg.PingPeerAPI
		default:
			t = tailcfg.PingType(pt)
		}
	}
	ctx, cancel := statusCtx()
	defer cancel()
	res, err := c.PingWithOpts(ctx, addr, t, local.PingOpts{})
	if err != nil {
		return jstr(err)
	}
	return jstr(res)
}

//export TsNetcheck
func TsNetcheck() *C.char {
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	dm, err := c.CurrentDERPMap(ctx)
	if err != nil {
		return jstr(err)
	}
	nc := &netcheck.Client{Logf: tslogf}
	rpt, err := nc.GetReport(ctx, dm, nil)
	if err != nil {
		return jstr(err)
	}
	return jstr(rpt)
}

//export TsDebugDERPRegion
func TsDebugDERPRegion(regionCode *C.char) *C.char {
	if regionCode == nil {
		return jstr(errors.New("nil region code"))
	}
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	rep, err := c.DebugDERPRegion(ctx, C.GoString(regionCode))
	if err != nil {
		return jstr(err)
	}
	return jstr(rep)
}

//export TsStatusDetailJSON
func TsStatusDetailJSON() *C.char {
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	st, err := c.Status(ctx)
	if err != nil {
		return jstr(err)
	}
	return jstr(st)
}

// ---------------------------------------------------------------------------
// 4.4 Generic Prefs control
// ---------------------------------------------------------------------------

//export TsGetPrefsJSON
func TsGetPrefsJSON() *C.char {
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	p, err := c.GetPrefs(ctx)
	if err != nil {
		return jstr(err)
	}
	return jstr(p)
}

//export TsSetPrefsJSON
func TsSetPrefsJSON(prefsJSON *C.char) C.int {
	if prefsJSON == nil {
		return -1
	}
	c, err := lc()
	if err != nil {
		tslogf("TsSetPrefsJSON: %v", err)
		return -1
	}
	var mp ipn.MaskedPrefs
	if err := json.Unmarshal([]byte(C.GoString(prefsJSON)), &mp); err != nil {
		tslogf("TsSetPrefsJSON: invalid JSON: %v", err)
		return -1
	}
	ctx, cancel := statusCtx()
	defer cancel()
	if _, err := c.EditPrefs(ctx, &mp); err != nil {
		tslogf("TsSetPrefsJSON: %v", err)
		return -1
	}
	return 0
}

//export TsSetHostname
func TsSetHostname(name *C.char) C.int {
	if name == nil {
		return -1
	}
	c, err := lc()
	if err != nil {
		tslogf("TsSetHostname: %v", err)
		return -1
	}
	ctx, cancel := statusCtx()
	defer cancel()
	if _, err := c.EditPrefs(ctx, &ipn.MaskedPrefs{
		Prefs:       ipn.Prefs{Hostname: C.GoString(name)},
		HostnameSet: true,
	}); err != nil {
		tslogf("TsSetHostname: %v", err)
		return -1
	}
	return 0
}

//export TsSetRouteAll
func TsSetRouteAll(enable C.int) C.int {
	c, err := lc()
	if err != nil {
		tslogf("TsSetRouteAll: %v", err)
		return -1
	}
	ctx, cancel := statusCtx()
	defer cancel()
	if _, err := c.EditPrefs(ctx, &ipn.MaskedPrefs{
		Prefs:       ipn.Prefs{RouteAll: enable != 0},
		RouteAllSet: true,
	}); err != nil {
		tslogf("TsSetRouteAll: %v", err)
		return -1
	}
	return 0
}

// ---------------------------------------------------------------------------
// 4.5 Taildrop
// ---------------------------------------------------------------------------

//export TsFileTargets
func TsFileTargets() *C.char {
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	targets, err := c.FileTargets(ctx)
	if err != nil {
		return jstr(err)
	}
	return jstr(targets)
}

//export TsPushFile
func TsPushFile(nodeID *C.char, name *C.char, dataBase64 *C.char, size C.int) C.int {
	if nodeID == nil || name == nil || dataBase64 == nil {
		return -1
	}
	c, err := lc()
	if err != nil {
		tslogf("TsPushFile: %v", err)
		return -1
	}
	data, err := base64.StdEncoding.DecodeString(C.GoString(dataBase64))
	if err != nil {
		tslogf("TsPushFile: bad base64: %v", err)
		return -1
	}
	ctx, cancel := statusCtx()
	defer cancel()
	if err := c.PushFile(ctx, tailcfg.StableNodeID(C.GoString(nodeID)), int64(size), C.GoString(name), strings.NewReader(string(data))); err != nil {
		tslogf("TsPushFile: %v", err)
		return -1
	}
	return 0
}

//export TsWaitingFiles
func TsWaitingFiles() *C.char {
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	files, err := c.WaitingFiles(ctx)
	if err != nil {
		return jstr(err)
	}
	return jstr(files)
}

type waitingFileContent struct {
	Name       string `json:"name"`
	Size       int64  `json:"size"`
	DataBase64 string `json:"dataBase64"`
}

//export TsGetWaitingFile
func TsGetWaitingFile(name *C.char) *C.char {
	if name == nil {
		return jstr(errors.New("nil name"))
	}
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	rc, size, err := c.GetWaitingFile(ctx, C.GoString(name))
	if err != nil {
		return jstr(err)
	}
	defer rc.Close()
	data, err := io.ReadAll(rc)
	if err != nil {
		return jstr(err)
	}
	return jstr(waitingFileContent{
		Name:       C.GoString(name),
		Size:       size,
		DataBase64: base64.StdEncoding.EncodeToString(data),
	})
}

//export TsDeleteWaitingFile
func TsDeleteWaitingFile(name *C.char) C.int {
	if name == nil {
		return -1
	}
	c, err := lc()
	if err != nil {
		tslogf("TsDeleteWaitingFile: %v", err)
		return -1
	}
	ctx, cancel := statusCtx()
	defer cancel()
	if err := c.DeleteWaitingFile(ctx, C.GoString(name)); err != nil {
		tslogf("TsDeleteWaitingFile: %v", err)
		return -1
	}
	return 0
}

// ---------------------------------------------------------------------------
// 4.6 Node info
// ---------------------------------------------------------------------------

//export TsTailscaleIPs
func TsTailscaleIPs() *C.char {
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	st, err := c.StatusWithoutPeers(ctx)
	if err != nil {
		return jstr(err)
	}
	return jstr(st.TailscaleIPs)
}

//export TsWhoIs
func TsWhoIs(ipOrAddr *C.char) *C.char {
	if ipOrAddr == nil {
		return jstr(errors.New("nil addr"))
	}
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	resp, err := c.WhoIs(ctx, C.GoString(ipOrAddr))
	if err != nil {
		return jstr(err)
	}
	return jstr(resp)
}

type peerInfo struct {
	ID             tailcfg.StableNodeID `json:"id"`
	DNSName        string               `json:"dnsName"`
	HostName       string               `json:"hostName"`
	OS             string               `json:"os,omitempty"`
	Online         bool                 `json:"online"`
	Active         bool                 `json:"active"`
	TailscaleIPs   []netip.Addr         `json:"tailscaleIPs,omitempty"`
	Relay          string               `json:"relay,omitempty"` // DERP region
	CurAddr        string               `json:"curAddr,omitempty"`
	ExitNode       bool                 `json:"exitNode"`
	ExitNodeOption bool                 `json:"exitNodeOption"`
	LastSeen       time.Time            `json:"lastSeen,omitempty"`
}

//export TsListPeers
func TsListPeers() *C.char {
	c, err := lc()
	if err != nil {
		return jstr(err)
	}
	ctx, cancel := statusCtx()
	defer cancel()
	st, err := c.Status(ctx)
	if err != nil {
		return jstr(err)
	}
	out := make([]peerInfo, 0, len(st.Peer))
	for _, p := range st.Peer {
		out = append(out, peerInfo{
			ID:             p.ID,
			DNSName:        strings.TrimSuffix(p.DNSName, "."),
			HostName:       p.HostName,
			OS:             p.OS,
			Online:         p.Online,
			Active:         p.Active,
			TailscaleIPs:   p.TailscaleIPs,
			Relay:          p.Relay,
			CurAddr:        p.CurAddr,
			ExitNode:       p.ExitNode,
			ExitNodeOption: p.ExitNodeOption,
			LastSeen:       p.LastSeen,
		})
	}
	return jstr(out)
}
