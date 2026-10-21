// Package mdns advertises `_greenfield._tcp` on the local network (multicast DNS, "Bonjour"), the way the Mac daemon does, so a
// phone on the same Wi-Fi finds this computer with nothing typed. The service record carries this computer's name and its tailnet
// (MagicDNS) address in TXT records, because the daemon itself listens only on the tailnet and loopback: the phone connects to
// `address`, not to the LAN address the record resolves to. It is a small responder (PTR, SRV, TXT, A) in the standard library.
package mdns

import (
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
)

// Service is what is advertised.
type Service struct {
	Instance string // the computer's name, shown by the phone
	Type     string // "_greenfield._tcp"
	Host     string // a host label, without ".local"
	Port     int
	TXT      [][2]string // key, value pairs in order
}

// DefaultType is the service type the phone browses for.
const DefaultType = "_greenfield._tcp"

// TXTRecords are the records the Mac daemon advertises: name, address (the tailnet name to connect to), version and path.
func TXTRecords(name, address, version string) [][2]string {
	return [][2]string{{"name", name}, {"address", address}, {"version", version}, {"path", "/status"}}
}

// HostLabel makes a DNS host label from a computer name: lowercase letters, digits and dashes.
func HostLabel(name string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			dash = false
		default:
			if b.Len() > 0 && !dash {
				b.WriteByte('-')
				dash = true
			}
		}
	}
	s := strings.Trim(b.String(), "-")
	if len(s) > 63 {
		s = strings.Trim(s[:63], "-")
	}
	if s == "" {
		s = "windows-computer"
	}
	return s
}

// Record types and classes.
const (
	typeA   = 1
	typePTR = 12
	typeTXT = 16
	typeSRV = 33
	typeANY = 255

	classIN    = 1
	cacheFlush = 0x8000
)

const metaQuery = "_services._dns-sd._udp.local"

func (s Service) typeName() string { return s.Type + ".local" }
func (s Service) instanceName() string {
	return s.Instance + "." + s.typeName() // the instance label may hold dots and spaces; it is encoded as one label
}
func (s Service) hostName() string { return s.Host + ".local" }

// encodeName writes a DNS name. The instance label is one label even when it contains dots, so names are built from parts.
func encodeLabels(labels ...string) ([]byte, error) {
	var out []byte
	for _, l := range labels {
		if l == "" || len(l) > 63 {
			return nil, fmt.Errorf("bad DNS label %q", l)
		}
		out = append(out, byte(len(l)))
		out = append(out, l...)
	}
	return append(out, 0), nil
}

func (s Service) labelsOf(name string) []string {
	if name == s.instanceName() {
		return append([]string{s.Instance}, strings.Split(s.typeName(), ".")...)
	}
	return strings.Split(name, ".")
}

func (s Service) nameBytes(name string) ([]byte, error) { return encodeLabels(s.labelsOf(name)...) }

type rr struct {
	name  string
	typ   uint16
	flush bool
	ttl   uint32
	data  []byte
}

func (s Service) txtData() []byte {
	var out []byte
	for _, kv := range s.TXT {
		e := kv[0] + "=" + kv[1]
		if len(e) > 255 {
			e = e[:255]
		}
		out = append(out, byte(len(e)))
		out = append(out, e...)
	}
	if len(out) == 0 {
		out = []byte{0}
	}
	return out
}

func (s Service) records(ip4 [4]byte, ttl uint32) ([]rr, error) {
	inst, err := s.nameBytes(s.instanceName())
	if err != nil {
		return nil, err
	}
	typ, err := s.nameBytes(s.typeName())
	if err != nil {
		return nil, err
	}
	host, err := s.nameBytes(s.hostName())
	if err != nil {
		return nil, err
	}
	srv := make([]byte, 6, 6+len(host))
	binary.BigEndian.PutUint16(srv[4:], uint16(s.Port)) // priority 0, weight 0
	srv = append(srv, host...)
	return []rr{
		{s.typeName(), typePTR, false, ttl, inst},
		{metaQuery, typePTR, false, ttl, typ},
		{s.instanceName(), typeSRV, true, ttl, srv},
		{s.instanceName(), typeTXT, true, ttl, s.txtData()},
		{s.hostName(), typeA, true, ttl, ip4[:]},
	}, nil
}

// Response builds an authoritative mDNS response with every record. ttl 0 is a goodbye.
func (s Service) Response(ip4 [4]byte, ttl uint32) ([]byte, error) {
	recs, err := s.records(ip4, ttl)
	if err != nil {
		return nil, err
	}
	return pack(s, recs)
}

func pack(s Service, recs []rr) ([]byte, error) {
	msg := make([]byte, 12)
	binary.BigEndian.PutUint16(msg[2:], 0x8400) // response, authoritative
	binary.BigEndian.PutUint16(msg[6:], uint16(len(recs)))
	for _, r := range recs {
		name, err := s.nameBytes(r.name)
		if err != nil {
			return nil, err
		}
		msg = append(msg, name...)
		class := uint16(classIN)
		if r.flush {
			class |= cacheFlush
		}
		var fixed [10]byte
		binary.BigEndian.PutUint16(fixed[0:], r.typ)
		binary.BigEndian.PutUint16(fixed[2:], class)
		binary.BigEndian.PutUint32(fixed[4:], r.ttl)
		binary.BigEndian.PutUint16(fixed[8:], uint16(len(r.data)))
		msg = append(msg, fixed[:]...)
		msg = append(msg, r.data...)
	}
	return msg, nil
}

// Question is one question of a query.
type Question struct {
	Name string // dot-joined labels, lowercase
	Type uint16
}

// ParseQuestions reads the questions of a query message (flags without the response bit). Responses and malformed packets give an
// error, so a stray packet is ignored.
func ParseQuestions(msg []byte) ([]Question, error) {
	if len(msg) < 12 {
		return nil, errors.New("short packet")
	}
	if binary.BigEndian.Uint16(msg[2:])&0x8000 != 0 {
		return nil, errors.New("not a query")
	}
	n := int(binary.BigEndian.Uint16(msg[4:]))
	off := 12
	var out []Question
	for i := 0; i < n; i++ {
		name, next, err := readName(msg, off)
		if err != nil {
			return nil, err
		}
		if next+4 > len(msg) {
			return nil, errors.New("short question")
		}
		out = append(out, Question{Name: strings.ToLower(name), Type: binary.BigEndian.Uint16(msg[next:])})
		off = next + 4
	}
	return out, nil
}

func readName(msg []byte, off int) (string, int, error) {
	var labels []string
	end, jumped := -1, false
	for hops := 0; hops < 32; hops++ {
		if off >= len(msg) {
			return "", 0, errors.New("name runs off the packet")
		}
		l := int(msg[off])
		switch {
		case l == 0:
			if !jumped {
				end = off + 1
			}
			return strings.Join(labels, "."), end, nil
		case l&0xC0 == 0xC0:
			if off+1 >= len(msg) {
				return "", 0, errors.New("bad pointer")
			}
			if !jumped {
				end = off + 2
			}
			off, jumped = (l&0x3F)<<8|int(msg[off+1]), true
		case l&0xC0 != 0:
			return "", 0, errors.New("bad label")
		default:
			if off+1+l > len(msg) {
				return "", 0, errors.New("label runs off the packet")
			}
			labels = append(labels, string(msg[off+1:off+1+l]))
			off += 1 + l
		}
	}
	return "", 0, errors.New("too many pointers")
}

// Wants says whether a query is asking for something this service answers.
func (s Service) Wants(questions []Question) bool {
	typ, inst, host := strings.ToLower(s.typeName()), strings.ToLower(s.Instance+"."+s.typeName()), strings.ToLower(s.hostName())
	for _, q := range questions {
		switch q.Name {
		case typ:
			if q.Type == typePTR || q.Type == typeANY {
				return true
			}
		case metaQuery:
			if q.Type == typePTR || q.Type == typeANY {
				return true
			}
		case inst:
			if q.Type == typeSRV || q.Type == typeTXT || q.Type == typeANY {
				return true
			}
		case host:
			if q.Type == typeA || q.Type == typeANY {
				return true
			}
		}
	}
	return false
}
