// Package tscorebind is the gomobile-bindable API of the Tailscale core.
//
// `gomobile bind -target=ios tailscale.com/cmd/tscore/bind` wraps this
// package into Objective-C classes (TsCoreServer, TsCoreExitNode, ...) and
// a static framework; the CI workflow then links the framework archive into
// a dlopen-able dylib (with the load-time initializer stripped, see
// cmd/tscore/tools/stripinits.py) and the host starts the runtime with
// TsEnsureInit() right after dlopen.
//
// Design constraints (gomobile bind): exported functions/methods take only
// bind-supported types (bool/int/float64/string/[]byte/structs); no C
// pointers, no callback function parameters — state is polled instead.
package tscorebind

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/netcheck"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
)

// Version is stamped at build time via
// -ldflags "-X tailscale.com/cmd/tscore/bind.Version=...".
var Version = "dev"

// Server is the singleton tailnet server handle.
type Server struct {
	mu      sync.Mutex
	srv     *tsnet.Server
	cancel  context.CancelFunc
	state   string // "", connecting, running, stopped
	socks5  string
	socks5c string
}

// NewServer creates (but does not connect) the tailnet server with the given
// state directory and hostname. Returns an error if it was already created.
func NewServer(stateDir, hostname string) (*Server, error) {
	s := &Server{state: "idle"}
	if stateDir == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			return nil, fmt.Errorf("state dir: %w", err)
		}
		stateDir = base
	}
	s.srv = &tsnet.Server{
		Dir:      stateDir,
		Hostname: hostname,
		Logf:     func(format string, args ...any) {},
	}
	return s, nil
}

// VersionString reports the build-stamped version.
func VersionString() string { return Version }

// Start connects to the tailnet asynchronously and returns immediately.
// Poll IsRunning / State for progress; Socks5Addr / Socks5Cred are populated
// once the tailnet is up.
func (s *Server) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.srv == nil {
		return errors.New("not initialized")
	}
	if s.state == "running" || s.state == "connecting" {
		return nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.state = "connecting"
	go func() {
		if _, err := s.srv.Up(ctx); err != nil {
			if ctx.Err() == nil {
				s.setState("error")
			}
			return
		}
		addr, cred, _, err := s.srv.Loopback()
		if err != nil {
			s.setState("error")
			return
		}
		s.mu.Lock()
		s.socks5 = addr
		s.socks5c = "tsnet:" + cred
		s.mu.Unlock()
		s.setState("running")
	}()
	return nil
}

func (s *Server) setState(st string) {
	s.mu.Lock()
	s.state = st
	s.mu.Unlock()
}

// Stop tears down the tailnet connection; NewServer must be called again
// before the next Start.
func (s *Server) Stop() error {
	s.mu.Lock()
	srv := s.srv
	cancel := s.cancel
	s.srv = nil
	s.cancel = nil
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if srv != nil {
		if err := srv.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			return err
		}
	}
	s.setState("stopped")
	return nil
}

// State reports idle/connecting/running/error/stopped.
func (s *Server) State() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state
}

// IsRunning reports whether the tailnet is up.
func (s *Server) IsRunning() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state == "running"
}

// Socks5Addr returns the loopback SOCKS5 address ("" until running).
func (s *Server) Socks5Addr() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.socks5
}

// Socks5Cred returns the SOCKS5 password ("tsnet:<pw>") for Socks5Addr.
func (s *Server) Socks5Cred() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.socks5c
}

// Login authenticates with an auth key and blocks until the node is up
// (up to 2 minutes).
func (s *Server) Login(authKey string) error {
	s.mu.Lock()
	srv := s.srv
	s.mu.Unlock()
	if srv == nil {
		return errors.New("not initialized")
	}
	srv.AuthKey = authKey
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	s.setState("connecting")
	if _, err := srv.Up(ctx); err != nil {
		s.setState("error")
		return err
	}
	addr, cred, _, err := srv.Loopback()
	if err != nil {
		s.setState("error")
		return err
	}
	s.mu.Lock()
	s.socks5 = addr
	s.socks5c = "tsnet:" + cred
	s.mu.Unlock()
	s.setState("running")
	return nil
}

// NeedsLogin reports whether the node has no valid state yet.
func (s *Server) NeedsLogin() bool {
	c, err := s.local()
	if err != nil {
		return true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	st, err := c.StatusWithoutPeers(ctx)
	if err != nil {
		return true
	}
	switch st.BackendState {
	case "NoState", "NeedsLogin", "NeedsMachineAuth":
		return true
	}
	return false
}

// LoginURL returns the interactive login URL ("" if not needed).
func (s *Server) LoginURL() string {
	c, err := s.local()
	if err != nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	st, err := c.StatusWithoutPeers(ctx)
	if err != nil {
		return ""
	}
	return st.AuthURL
}

// SetHTTPProxy sets HTTPS_PROXY for the control plane / DERP connections.
func (s *Server) SetHTTPProxy(proxyURL string) error {
	if proxyURL == "" {
		os.Unsetenv("HTTPS_PROXY")
		return nil
	}
	return os.Setenv("HTTPS_PROXY", proxyURL)
}

// HTTPProxy returns the current HTTPS_PROXY value.
func (s *Server) HTTPProxy() string { return os.Getenv("HTTPS_PROXY") }

// StatusJSON returns the full backend status as JSON.
func (s *Server) StatusJSON() string {
	c, err := s.local()
	if err != nil {
		return jerr(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	st, err := c.Status(ctx)
	if err != nil {
		return jerr(err)
	}
	return mustJSON(st)
}

// Peer is a trimmed view of a tailnet peer.
type Peer struct {
	ID             string   `json:"id"`
	DNSName        string   `json:"dnsName"`
	HostName       string   `json:"hostName"`
	OS             string   `json:"os,omitempty"`
	Online         bool     `json:"online"`
	Active         bool     `json:"active"`
	TailscaleIPs   []string `json:"tailscaleIPs,omitempty"`
	Relay          string   `json:"relay,omitempty"`
	ExitNode       bool     `json:"exitNode"`
	ExitNodeOption bool     `json:"exitNodeOption"`
}

// ListPeers returns the current peers.
func (s *Server) ListPeers() []*Peer {
	c, err := s.local()
	if err != nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	st, err := c.Status(ctx)
	if err != nil {
		return nil
	}
	var out []*Peer
	for _, p := range st.Peer {
		var ips []string
		for _, ip := range p.TailscaleIPs {
			ips = append(ips, ip.String())
		}
		out = append(out, &Peer{
			ID:             string(p.ID),
			DNSName:        strings.TrimSuffix(p.DNSName, "."),
			HostName:       p.HostName,
			OS:             p.OS,
			Online:         p.Online,
			Active:         p.Active,
			TailscaleIPs:   ips,
			Relay:          p.Relay,
			ExitNode:       p.ExitNode,
			ExitNodeOption: p.ExitNodeOption,
		})
	}
	return out
}

// TailscaleIPs returns this node's 100.x addresses.
func (s *Server) TailscaleIPs() []string {
	c, err := s.local()
	if err != nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	st, err := c.StatusWithoutPeers(ctx)
	if err != nil {
		return nil
	}
	var out []string
	for _, ip := range st.TailscaleIPs {
		out = append(out, ip.String())
	}
	return out
}

// ExitNode is a selectable exit node.
type ExitNode struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	CountryCode string `json:"countryCode,omitempty"`
	Online      bool   `json:"online"`
	InUse       bool   `json:"inUse"`
}

// ListExitNodes returns peers that offer exit-node service.
func (s *Server) ListExitNodes() []*ExitNode {
	c, err := s.local()
	if err != nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	st, err := c.Status(ctx)
	if err != nil {
		return nil
	}
	var out []*ExitNode
	for _, p := range st.Peer {
		if !p.ExitNodeOption {
			continue
		}
		cc := ""
		if p.Location != nil {
			cc = p.Location.CountryCode
		}
		out = append(out, &ExitNode{
			ID:          string(p.ID),
			Name:        strings.TrimSuffix(p.DNSName, "."),
			CountryCode: cc,
			Online:      p.Online,
			InUse:       p.ExitNode,
		})
	}
	return out
}

// SetExitNode routes traffic through the named exit node ("" clears).
func (s *Server) SetExitNode(nameOrIP string) error {
	c, err := s.local()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if nameOrIP == "" {
		_, err = c.EditPrefs(ctx, &ipn.MaskedPrefs{ExitNodeIDSet: true})
		return err
	}
	st, err := c.Status(ctx)
	if err != nil {
		return err
	}
	needle := strings.ToLower(strings.TrimSuffix(nameOrIP, "."))
	for _, p := range st.Peer {
		if !p.ExitNodeOption {
			continue
		}
		if strings.ToLower(strings.TrimSuffix(p.DNSName, ".")) == needle ||
			strings.EqualFold(p.HostName, needle) {
			_, err = c.EditPrefs(ctx, &ipn.MaskedPrefs{
				Prefs:         ipn.Prefs{ExitNodeID: p.ID},
				ExitNodeIDSet: true,
			})
			return err
		}
		for _, ip := range p.TailscaleIPs {
			if ip.String() == needle {
				_, err = c.EditPrefs(ctx, &ipn.MaskedPrefs{
					Prefs:         ipn.Prefs{ExitNodeID: p.ID},
					ExitNodeIDSet: true,
				})
				return err
			}
		}
	}
	return fmt.Errorf("no exit node found for %q", nameOrIP)
}

// SetRouteAll routes all traffic through the exit node when enabled.
func (s *Server) SetRouteAll(enable bool) error {
	c, err := s.local()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_, err = c.EditPrefs(ctx, &ipn.MaskedPrefs{
		Prefs:                 ipn.Prefs{RouteAll: enable},
		RouteAllSet:           true,
	})
	return err
}

// Ping returns the ping result JSON for an IP or hostname.
func (s *Server) Ping(ip, pingType string) string {
	c, err := s.local()
	if err != nil {
		return jerr(err)
	}
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return jerr(err)
	}
	t := tailcfg.PingDisco
	switch pingType {
	case "TSMP", "tsmp":
		t = tailcfg.PingTSMP
	case "ICMP", "icmp":
		t = tailcfg.PingICMP
	case "peerapi", "PeerAPI":
		t = tailcfg.PingPeerAPI
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	res, err := c.PingWithOpts(ctx, addr, t, local.PingOpts{})
	if err != nil {
		return jerr(err)
	}
	return mustJSON(res)
}

// Netcheck returns the NAT traversal report as JSON.
func (s *Server) Netcheck() string {
	c, err := s.local()
	if err != nil {
		return jerr(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	dm, err := c.CurrentDERPMap(ctx)
	if err != nil {
		return jerr(err)
	}
	nc := &netcheck.Client{Logf: func(string, ...any) {}}
	rpt, err := nc.GetReport(ctx, dm, nil)
	if err != nil {
		return jerr(err)
	}
	return mustJSON(rpt)
}

// WaitingFiles lists incoming taildrop files.
func (s *Server) WaitingFiles() string {
	c, err := s.local()
	if err != nil {
		return jerr(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	files, err := c.WaitingFiles(ctx)
	if err != nil {
		return jerr(err)
	}
	return mustJSON(files)
}

// FileTargets lists taildrop targets.
func (s *Server) FileTargets() string {
	c, err := s.local()
	if err != nil {
		return jerr(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	t, err := c.FileTargets(ctx)
	if err != nil {
		return jerr(err)
	}
	return mustJSON(t)
}

// PushFile sends a base64-encoded file to a peer (nodeID = stable ID).
func (s *Server) PushFile(nodeID, name string, dataBase64 string) error {
	c, err := s.local()
	if err != nil {
		return err
	}
	data, err := base64.StdEncoding.DecodeString(dataBase64)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return c.PushFile(ctx, tailcfg.StableNodeID(nodeID), int64(len(data)), name, strings.NewReader(string(data)))
}

// GetWaitingFile returns a received file as base64.
func (s *Server) GetWaitingFile(name string) string {
	c, err := s.local()
	if err != nil {
		return jerr(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	rc, size, err := c.GetWaitingFile(ctx, name)
	if err != nil {
		return jerr(err)
	}
	defer rc.Close()
	data, err := io.ReadAll(rc)
	if err != nil {
		return jerr(err)
	}
	return mustJSON(map[string]any{"name": name, "size": size, "dataBase64": base64.StdEncoding.EncodeToString(data)})
}

// DeleteWaitingFile removes a received file.
func (s *Server) DeleteWaitingFile(name string) error {
	c, err := s.local()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return c.DeleteWaitingFile(ctx, name)
}

// CurrentUser returns the logged-in user as JSON.
func (s *Server) CurrentUser() string {
	c, err := s.local()
	if err != nil {
		return jerr(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	st, err := c.StatusWithoutPeers(ctx)
	if err != nil {
		return jerr(err)
	}
	if st.Self == nil {
		return "{}"
	}
	out := map[string]any{"userId": st.Self.UserID}
	if up, ok := st.User[st.Self.UserID]; ok {
		out["loginName"] = up.LoginName
		out["displayName"] = up.DisplayName
	}
	return mustJSON(out)
}

// local returns the LocalClient for the singleton server.
func (s *Server) local() (*local.Client, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.srv == nil {
		return nil, errors.New("not initialized")
	}
	return s.srv.LocalClient()
}

func jerr(err error) string {
	b, _ := json.Marshal(map[string]string{"error": err.Error()})
	return string(b)
}

func mustJSON(v any) string {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return jerr(err)
	}
	return string(b)
}

// Keep ipnstate referenced (used indirectly through Status calls).
var _ = ipnstate.Status{}
