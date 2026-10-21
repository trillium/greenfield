package mdns

import (
	"encoding/binary"
	"strings"
	"testing"
)

var svc = Service{Instance: "Example PC", Type: DefaultType, Host: "example-pc", Port: 47821, TXT: TXTRecords("Example PC", "pc.tail1234.ts.net", "0.4.0")}

type record struct {
	name  string
	typ   uint16
	class uint16
	ttl   uint32
	data  []byte
	msg   []byte
	off   int // offset of data in msg
}

// decode is an independent reader of a response, so the encoder is not tested against itself.
func decode(t *testing.T, msg []byte) []record {
	t.Helper()
	if binary.BigEndian.Uint16(msg[2:]) != 0x8400 || binary.BigEndian.Uint16(msg[4:]) != 0 {
		t.Fatalf("header %x", msg[:12])
	}
	n := int(binary.BigEndian.Uint16(msg[6:]))
	off := 12
	var out []record
	for i := 0; i < n; i++ {
		name, next, err := readName(msg, off)
		if err != nil {
			t.Fatal(err)
		}
		r := record{name: name, typ: binary.BigEndian.Uint16(msg[next:]), class: binary.BigEndian.Uint16(msg[next+2:]), ttl: binary.BigEndian.Uint32(msg[next+4:])}
		l := int(binary.BigEndian.Uint16(msg[next+8:]))
		r.off = next + 10
		r.data, r.msg = msg[r.off:r.off+l], msg
		out = append(out, r)
		off = r.off + l
	}
	if off != len(msg) {
		t.Fatalf("%d trailing bytes", len(msg)-off)
	}
	return out
}

func find(recs []record, name string, typ uint16) *record {
	for i := range recs {
		if recs[i].name == name && recs[i].typ == typ {
			return &recs[i]
		}
	}
	return nil
}

func TestResponseAdvertisesTheServiceTheWayThePhoneBrowses(t *testing.T) {
	msg, err := svc.Response([4]byte{192, 168, 1, 7}, 4500)
	if err != nil {
		t.Fatal(err)
	}
	recs := decode(t, msg)

	ptr := find(recs, "_greenfield._tcp.local", typePTR)
	if ptr == nil || ptr.class != classIN || ptr.ttl != 4500 {
		t.Fatalf("PTR %+v", ptr)
	}
	if inst, _, _ := readName(msg, ptr.off); inst != "Example PC._greenfield._tcp.local" {
		t.Errorf("PTR points at %q", inst)
	}
	if meta := find(recs, "_services._dns-sd._udp.local", typePTR); meta == nil {
		t.Errorf("the service type must be listed for browsers that enumerate types")
	}

	srv := find(recs, "Example PC._greenfield._tcp.local", typeSRV)
	if srv == nil || srv.class != classIN|cacheFlush || binary.BigEndian.Uint16(srv.data[4:]) != 47821 {
		t.Fatalf("SRV %+v", srv)
	}
	if target, _, _ := readName(msg, srv.off+6); target != "example-pc.local" {
		t.Errorf("SRV target %q", target)
	}

	txt := find(recs, "Example PC._greenfield._tcp.local", typeTXT)
	if txt == nil {
		t.Fatal("TXT")
	}
	var pairs []string
	for d := txt.data; len(d) > 0; d = d[1+int(d[0]):] {
		pairs = append(pairs, string(d[1:1+int(d[0])]))
	}
	want := "name=Example PC,address=pc.tail1234.ts.net,version=0.4.0,path=/status"
	if strings.Join(pairs, ",") != want {
		t.Errorf("TXT %v, want %s (the same four records the Mac daemon advertises)", pairs, want)
	}

	a := find(recs, "example-pc.local", typeA)
	if a == nil || a.class != classIN|cacheFlush || !strings.EqualFold(string(a.data), string([]byte{192, 168, 1, 7})) {
		t.Errorf("A %+v", a)
	}
}

func TestGoodbyeHasTTLZero(t *testing.T) {
	msg, _ := svc.Response([4]byte{10, 0, 0, 1}, 0)
	for _, r := range decode(t, msg) {
		if r.ttl != 0 {
			t.Errorf("%s ttl %d", r.name, r.ttl)
		}
	}
}

func query(names ...any) []byte {
	msg := make([]byte, 12)
	binary.BigEndian.PutUint16(msg[4:], uint16(len(names)/2))
	for i := 0; i < len(names); i += 2 {
		for _, l := range strings.Split(names[i].(string), ".") {
			msg = append(msg, byte(len(l)))
			msg = append(msg, l...)
		}
		msg = append(msg, 0)
		var f [4]byte
		binary.BigEndian.PutUint16(f[0:], names[i+1].(uint16))
		binary.BigEndian.PutUint16(f[2:], 1)
		msg = append(msg, f[:]...)
	}
	return msg
}

func TestWhichQueriesAreAnswered(t *testing.T) {
	cases := []struct {
		name string
		msg  []byte
		want bool
	}{
		{"browse for the service", query("_greenfield._tcp.local", uint16(typePTR)), true},
		{"browse, mixed case", query("_GreenField._TCP.local", uint16(typePTR)), true},
		{"enumerate service types", query("_services._dns-sd._udp.local", uint16(typePTR)), true},
		{"resolve the instance", query("Example PC._greenfield._tcp.local", uint16(typeSRV)), true},
		{"resolve the instance text", query("Example PC._greenfield._tcp.local", uint16(typeTXT)), true},
		{"resolve the host", query("example-pc.local", uint16(typeA)), true},
		{"ANY for the service", query("_greenfield._tcp.local", uint16(typeANY)), true},
		{"another service", query("_http._tcp.local", uint16(typePTR)), false},
		{"another host", query("other.local", uint16(typeA)), false},
		{"the host but asking for something we do not have", query("example-pc.local", uint16(typeSRV)), false},
		{"two questions, one ours", query("_http._tcp.local", uint16(typePTR), "_greenfield._tcp.local", uint16(typePTR)), true},
	}
	for _, c := range cases {
		qs, err := ParseQuestions(c.msg)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got := svc.Wants(qs); got != c.want {
			t.Errorf("%s: %v", c.name, got)
		}
	}
}

func TestStrayPacketsAreIgnored(t *testing.T) {
	good, _ := svc.Response([4]byte{1, 2, 3, 4}, 10)
	if _, err := ParseQuestions(good); err == nil {
		t.Error("a response is not a query (we must not answer our own or other responders' answers)")
	}
	for name, msg := range map[string][]byte{
		"empty":              nil,
		"short":              {0, 0, 0},
		"question runs off":  query("_greenfield._tcp.local", uint16(typePTR))[:20],
		"pointer loop":       append(oneQuestion(), 0xC0, 12, 0, 1, 0, 1),
		"reserved label bit": append(oneQuestion(), 0x80, 1, 0, 1, 0, 1),
	} {
		if _, err := ParseQuestions(msg); err == nil {
			t.Errorf("%s must be an error", name)
		}
	}
	// Compression pointers in a question are followed.
	m := append(query("_greenfield._tcp.local", uint16(typePTR)), 0)
	binary.BigEndian.PutUint16(m[4:], 2)
	m = append(m[:len(m)-1], 0xC0, 12, 0, byte(typePTR), 0, 1)
	qs, err := ParseQuestions(m)
	if err != nil || len(qs) != 2 || qs[1].Name != "_greenfield._tcp.local" {
		t.Errorf("compressed question: %v %v", qs, err)
	}
}

func oneQuestion() []byte {
	h := make([]byte, 12)
	h[5] = 1
	return h
}

func TestHostLabel(t *testing.T) {
	for in, want := range map[string]string{"DESKTOP-ABC123": "desktop-abc123", "Example PC": "example-pc", "  --My_PC!!  ": "my-pc", "": "windows-computer", "日本語": "windows-computer", strings.Repeat("a", 80): strings.Repeat("a", 63)} {
		if got := HostLabel(in); got != want {
			t.Errorf("HostLabel(%q) = %q want %q", in, got, want)
		}
	}
}

func TestBadLabelsAreRefusedNotSent(t *testing.T) {
	bad := svc
	bad.Instance = strings.Repeat("x", 64)
	if _, err := bad.Response([4]byte{}, 1); err == nil {
		t.Error("a 64 byte label is not valid DNS")
	}
	bad = svc
	bad.Instance = ""
	if _, err := bad.Response([4]byte{}, 1); err == nil {
		t.Error("an empty instance name is not valid DNS")
	}
}

func TestInstanceNameWithDotsStaysOneLabel(t *testing.T) {
	s := svc
	s.Instance = "Studio v1.2 PC"
	msg, err := s.Response([4]byte{1, 1, 1, 1}, 1)
	if err != nil {
		t.Fatal(err)
	}
	ptr := find(decode(t, msg), "_greenfield._tcp.local", typePTR)
	labels := []string{}
	for off := ptr.off; msg[off] != 0; off += 1 + int(msg[off]) {
		labels = append(labels, string(msg[off+1:off+1+int(msg[off])]))
	}
	if labels[0] != "Studio v1.2 PC" || len(labels) != 4 {
		t.Errorf("labels %q", labels)
	}
}
