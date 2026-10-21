package pairing

import (
	"strings"
	"testing"
	"time"
)

var start = time.Date(2027, 1, 15, 8, 0, 0, 0, time.UTC)

// fixture is a book on a fake clock and a fake random source: bytes that change on every call, so two codes or tokens never collide
// in a test and nothing is truly random.
func fixture() (*Memory, *time.Time) {
	now := start
	var n byte
	m := NewLimited(1000, time.Minute)
	m.Now = func() time.Time { return now }
	m.Random = func(b []byte) {
		for i := range b {
			n += 7
			b[i] = n
		}
	}
	return m, &now
}

func mustPair(t *testing.T, m *Memory, name string) Result {
	t.Helper()
	r := m.Redeem(m.IssueCode().Text, name)
	if r.Outcome != Paired {
		t.Fatalf("not paired: %v", r.Outcome)
	}
	return r
}

func TestCodeIsEightSymbolsFromTheUnambiguousAlphabet(t *testing.T) {
	m, _ := fixture()
	c := m.IssueCode()
	if len(c.Text) != 9 || c.Text[4] != '-' || c.ExpiresIn != 5*time.Minute {
		t.Fatalf("code %q expires in %v", c.Text, c.ExpiresIn)
	}
	for _, r := range strings.ReplaceAll(c.Text, "-", "") {
		if !strings.ContainsRune(alphabet, r) {
			t.Errorf("%q is not in the alphabet", r)
		}
	}
	if strings.ContainsAny(alphabet, "01OIL") {
		t.Error("the alphabet has look-alikes")
	}
}

func TestCodeWorksOnceAndGivesAToken(t *testing.T) {
	m, now := fixture()
	code := m.IssueCode().Text
	r := m.Redeem(code, "Ann's iPhone")
	if r.Outcome != Paired || r.Device.Name != "Ann's iPhone" || r.Device.ExpiresAt.Sub(*now) != 24*time.Hour {
		t.Fatalf("%+v", r)
	}
	if d, ok := m.Verify(r.Token); !ok || d.ID != r.Device.ID {
		t.Fatal("the token should verify")
	}
	if m.Redeem(code, "again").Outcome != Refused {
		t.Error("a code is single use")
	}
}

func TestCodeIsReadForgivingly(t *testing.T) {
	m, _ := fixture()
	code := m.IssueCode().Text
	if m.Redeem(" "+strings.ToLower(strings.ReplaceAll(code, "-", " "))+" ", "x").Outcome != Paired {
		t.Error("case, spaces and the dash do not matter")
	}
}

func TestCodeExpires(t *testing.T) {
	m, now := fixture()
	code := m.IssueCode().Text
	*now = now.Add(CodeTTL + time.Second)
	if m.Redeem(code, "x").Outcome != Refused {
		t.Error("an old code works")
	}
}

func TestANewCodeReplacesTheOldOne(t *testing.T) {
	m, _ := fixture()
	first, second := m.IssueCode().Text, m.IssueCode().Text
	if m.Redeem(first, "x").Outcome != Refused {
		t.Error("the old code still works")
	}
	if m.Redeem(second, "x").Outcome != Paired {
		t.Error("the newest code should work")
	}
}

func TestWrongGuessesBurnTheCode(t *testing.T) {
	m, _ := fixture()
	code := m.IssueCode().Text
	for i := 0; i < MaxWrong; i++ {
		if m.Redeem("AAAA-AAAA", "x").Outcome != Refused {
			t.Fatal("a wrong code was accepted")
		}
	}
	if m.Redeem(code, "x").Outcome != Refused {
		t.Error("even the right code is dead after too many wrong guesses")
	}
}

func TestAttemptsAreRateLimited(t *testing.T) {
	m := NewLimited(3, time.Minute)
	now := start
	m.Now = func() time.Time { return now }
	m.IssueCode()
	for i := 0; i < 3; i++ {
		m.Redeem("AAAA-AAAA", "x")
	}
	if r := m.Redeem("AAAA-AAAA", "x"); r.Outcome != SlowDown || r.Wait < 1 {
		t.Errorf("%+v", r)
	}
	now = now.Add(time.Minute + time.Second)
	if m.Redeem("AAAA-AAAA", "x").Outcome != Refused {
		t.Error("the limit should clear with time")
	}
}

func TestTokenExpiresAndIsPerDevice(t *testing.T) {
	m, now := fixture()
	a, b := mustPair(t, m, "one"), mustPair(t, m, "two")
	if a.Token == b.Token || a.Device.ID == b.Device.ID {
		t.Fatal("tokens and ids must differ per device")
	}
	if d, ok := m.Verify(a.Token); !ok || d.ID != a.Device.ID {
		t.Error("first token")
	}
	if d, ok := m.Verify(b.Token); !ok || d.ID != b.Device.ID {
		t.Error("second token")
	}
	*now = now.Add(TokenTTL + time.Second)
	if _, ok := m.Verify(a.Token); ok {
		t.Error("an expired token works")
	}
	if len(m.Devices()) != 0 {
		t.Error("expired devices are listed")
	}
}

func TestRevokeOneAndAll(t *testing.T) {
	m, _ := fixture()
	a, b := mustPair(t, m, "one"), mustPair(t, m, "two")
	if !m.Revoke(a.Device.ID) {
		t.Fatal("revoke")
	}
	if _, ok := m.Verify(a.Token); ok {
		t.Error("a revoked token works")
	}
	if _, ok := m.Verify(b.Token); !ok {
		t.Error("the other device must keep working")
	}
	if m.Revoke(a.Device.ID) {
		t.Error("revoking twice")
	}
	if n := m.RevokeAll(); n != 1 {
		t.Errorf("revoked %d", n)
	}
	if _, ok := m.Verify(b.Token); ok {
		t.Error("revoke all")
	}
}

func TestOnlyTheHashIsKept(t *testing.T) {
	m, _ := fixture()
	r := mustPair(t, m, "one")
	if len(r.Token) < 43 {
		t.Errorf("token has %d characters, want 256 bits", len(r.Token))
	}
	for _, bad := range []string{"", r.Token[:len(r.Token)-1], r.Token + "x"} {
		if _, ok := m.Verify(bad); ok {
			t.Errorf("%q verified", bad)
		}
	}
}

func TestTheNumberOfDevicesIsCapped(t *testing.T) {
	m, _ := fixture()
	for i := 0; i < MaxDevices+3; i++ {
		mustPair(t, m, "d")
	}
	if n := len(m.Devices()); n != MaxDevices {
		t.Errorf("%d devices", n)
	}
}

func TestDeviceNamesAreOneShortPrintableLine(t *testing.T) {
	for in, want := range map[string]string{"  a\nb\x07c  ": "a b c", "   ": "browser", strings.Repeat("x", 100): strings.Repeat("x", 40)} {
		if got := CleanName(in); got != want {
			t.Errorf("%q -> %q, want %q", in, got, want)
		}
	}
}

func TestProxiedRequests(t *testing.T) {
	for _, h := range []string{"x-forwarded-for", "tailscale-user-login", "forwarded", "x-real-ip", "tailscale-funnel-request"} {
		if !Proxied(map[string]string{h: "1.2.3.4"}) {
			t.Errorf("%s should mark a request as proxied", h)
		}
	}
	if Proxied(map[string]string{"x-greenfield-token": "t", "content-type": "application/json"}) {
		t.Error("an ordinary request is not proxied")
	}
}
