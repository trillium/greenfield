package mdns

import (
	"fmt"
	"net"
	"sync"
	"time"

	"greenfield-inserter/internal/tailnet"
)

var group = &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251), Port: 5353}

// Responder answers mDNS queries for a service on every usable network interface.
type Responder struct {
	Service Service
	Log     func(string)

	mu    sync.Mutex
	conns []*ifaceConn
	done  chan struct{}
}

type ifaceConn struct {
	conn *net.UDPConn
	ip   [4]byte
	name string
}

// usable interfaces are up, multicast-capable, not loopback and have a LAN IPv4 address (not Tailscale's).
func usable() []ifaceAddr {
	var out []ifaceAddr
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagMulticast == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			v4 := ipn.IP.To4()
			if v4 == nil || v4.IsLinkLocalUnicast() || tailnet.InTailnetRange(v4) {
				continue
			}
			out = append(out, ifaceAddr{ifc, [4]byte(v4)})
			break
		}
	}
	return out
}

type ifaceAddr struct {
	iface net.Interface
	ip    [4]byte
}

// Start announces the service and answers queries until Stop. Failing to use one interface is logged and does not stop the others;
// it returns an error only when no interface could be used.
func (r *Responder) Start() error {
	r.done = make(chan struct{})
	var firstErr error
	for _, ia := range usable() {
		ifc := ia.iface
		conn, err := net.ListenMulticastUDP("udp4", &ifc, group)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			r.log(fmt.Sprintf("mdns: cannot listen on %s: %v", ifc.Name, err))
			continue
		}
		if err := setMulticastInterface(conn, ia.ip); err != nil {
			r.log(fmt.Sprintf("mdns: cannot select %s for sending: %v", ifc.Name, err))
		}
		ic := &ifaceConn{conn: conn, ip: ia.ip, name: ifc.Name}
		r.mu.Lock()
		r.conns = append(r.conns, ic)
		r.mu.Unlock()
		go r.serve(ic)
		go r.announce(ic)
	}
	r.mu.Lock()
	n := len(r.conns)
	r.mu.Unlock()
	if n == 0 {
		if firstErr == nil {
			firstErr = fmt.Errorf("no network interface can do multicast")
		}
		return firstErr
	}
	r.log(fmt.Sprintf("advertising %s as %q (address %s) on %d interface(s)", r.Service.Type, r.Service.Instance, r.addressText(), n))
	return nil
}

func (r *Responder) addressText() string {
	for _, kv := range r.Service.TXT {
		if kv[0] == "address" {
			return kv[1]
		}
	}
	return "?"
}

func (r *Responder) log(m string) {
	if r.Log != nil {
		r.Log(m)
	}
}

func (r *Responder) announce(ic *ifaceConn) {
	for i := 0; i < 2; i++ {
		select {
		case <-r.done:
			return
		case <-time.After(time.Duration(i) * time.Second):
		}
		r.send(ic, 4500)
	}
}

func (r *Responder) send(ic *ifaceConn, ttl uint32) {
	msg, err := r.Service.Response(ic.ip, ttl)
	if err != nil {
		r.log("mdns: " + err.Error())
		return
	}
	_, _ = ic.conn.WriteToUDP(msg, group)
}

func (r *Responder) serve(ic *ifaceConn) {
	buf := make([]byte, 9000)
	var last time.Time
	for {
		n, _, err := ic.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		qs, err := ParseQuestions(buf[:n])
		if err != nil || !r.Service.Wants(qs) {
			continue
		}
		if time.Since(last) < time.Second { // one answer a second per interface is plenty
			continue
		}
		last = time.Now()
		r.send(ic, 4500)
	}
}

// Stop says goodbye (TTL 0) and closes the sockets.
func (r *Responder) Stop() {
	if r.done == nil {
		return
	}
	select {
	case <-r.done:
		return
	default:
		close(r.done)
	}
	r.mu.Lock()
	conns := r.conns
	r.conns = nil
	r.mu.Unlock()
	for _, ic := range conns {
		r.send(ic, 0)
		ic.conn.Close()
	}
}
