package logsvc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseQuery(t *testing.T) {
	q, err := ParseQuery("")
	if err != nil || q.Tail != 200 || q.Since != 0 || q.PlainText {
		t.Fatalf("defaults: %+v %v", q, err)
	}
	q, err = ParseQuery("tail=50&since=30m&format=text")
	if err != nil || q.Tail != 50 || q.Since != 30*time.Minute || !q.PlainText {
		t.Fatalf("%+v %v", q, err)
	}
	for _, bad := range []string{"tail=0", "tail=2001", "tail=x", "since=8d", "since=0m", "since=5", "since=m", "format=xml", "bogus=1", "tail", "x y=1"} {
		if _, err := ParseQuery(bad); err == nil {
			t.Errorf("%q must be an error", bad)
		}
	}
	if _, err := ParseQuery("tail=2000&since=7d"); err != nil {
		t.Errorf("the limits themselves are fine: %v", err)
	}
	if _, err := ParseQuery("evil-name-that-is-long-enough-to-be-text=1"); err == nil || strings.Contains(err.Error(), "evil-name") {
		t.Errorf("a long parameter name must not be echoed: %v", err)
	}
}

func TestSafeValues(t *testing.T) {
	if ID("6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E") != "6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E" || ID("hello world, this is text") != "(invalid)" || ID(strings.Repeat("a", 65)) != "(invalid)" {
		t.Error("ID")
	}
	if SourceLabel("greenfield") != "greenfield" || SourceLabel("Dictated text here") != "other" || SourceLabel("") != "other" {
		t.Error("SourceLabel")
	}
	if Token("tail") != "tail" || Token("a b") != "?" {
		t.Error("Token")
	}
	if Path("/text", map[string]bool{"/text": true}) != "/text" || Path("/secret words", map[string]bool{"/text": true}) != "(unknown)" {
		t.Error("Path")
	}
}

func TestRateLimiter(t *testing.T) {
	r := NewRateLimiter()
	now := time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 6; i++ {
		if w := r.Admit(now.Add(time.Duration(i) * time.Second)); w != 0 {
			t.Fatalf("request %d refused", i)
		}
	}
	if w := r.Admit(now.Add(10 * time.Second)); w != 50 {
		t.Errorf("seventh request: wait %d, want 50", w)
	}
	if w := r.Admit(now.Add(61 * time.Second)); w != 0 {
		t.Errorf("after the window: %d", w)
	}
}

func writeLog(t *testing.T, lines ...string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "inserter.log")
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestFileSourceTailAndSince(t *testing.T) {
	now := time.Date(2027, 1, 1, 12, 0, 0, 0, time.UTC)
	stamp := func(d time.Duration) string { return now.Add(-d).Format(time.RFC3339) }
	p := writeLog(t, stamp(3*time.Hour)+" old", stamp(20*time.Minute)+" a", "  continuation of a", stamp(5*time.Minute)+" b", stamp(time.Minute)+" c")
	s := NewFileSource(p)
	if !s.Available() {
		t.Fatal("available")
	}
	got := s.Read(Query{Tail: 200, Since: 30 * time.Minute}, now)
	if len(got) != 4 || !strings.HasSuffix(got[0], " a") || got[1] != "  continuation of a" {
		t.Errorf("since: %q", got)
	}
	got = s.Read(Query{Tail: 2}, now)
	if len(got) != 2 || !strings.HasSuffix(got[0], " b") || !strings.HasSuffix(got[1], " c") {
		t.Errorf("tail: %q", got)
	}
	if NewFileSource(filepath.Join(t.TempDir(), "none.log")).Available() {
		t.Error("a missing file is not available")
	}
}

func TestFileSourceReadsTheRotatedFileAndCutsAtTheWindow(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "inserter.log")
	os.WriteFile(p+".1", []byte("t1 older\nt2 older\n"), 0o600)
	os.WriteFile(p, []byte("t3 newer\n"), 0o600)
	got := NewFileSource(p).Read(Query{Tail: 5}, time.Now())
	if strings.Join(got, "|") != "t1 older|t2 older|t3 newer" {
		t.Errorf("%q", got)
	}
	big := strings.Repeat("0123456789abcdef x\n", 100)
	os.Remove(p + ".1")
	os.WriteFile(p, []byte(big), 0o600)
	s := &FileSource{File: p, Window: 100}
	got = s.Read(Query{Tail: 2000}, time.Now())
	if len(got) == 0 || len(got) > 6 {
		t.Errorf("a 100 byte window holds a few lines, got %d", len(got))
	}
}

func TestBuildPageTruncatesToTheNewestBytes(t *testing.T) {
	line := strings.Repeat("ab cd ", 60) // 360 chars, under the line limit
	var lines []string
	for i := 0; i < 1000; i++ {
		lines = append(lines, line)
	}
	page := BuildPage(lines, Query{Tail: 2000})
	if page.Bytes > MaxBytes || len(page.Lines) >= 1000 || !page.Truncated {
		t.Errorf("bytes=%d lines=%d truncated=%v", page.Bytes, len(page.Lines), page.Truncated)
	}
	page = BuildPage([]string{"one"}, Query{Tail: 200})
	if page.Truncated || len(page.Lines) != 1 {
		t.Errorf("%+v", page)
	}
	if page = BuildPage(nil, Query{Tail: 200}); page.Lines == nil {
		t.Errorf("an empty page has an empty list, not null")
	}
	if page = BuildPage([]string{"a", "b"}, Query{Tail: 2}); !page.Truncated {
		t.Errorf("a full page may have more behind it")
	}
}

func TestLoggerWritesRotatesAndNeverAddsText(t *testing.T) {
	p := filepath.Join(t.TempDir(), "inserter.log")
	l := NewLogger(p, nil)
	l.Now = func() time.Time { return time.Date(2027, 1, 1, 8, 0, 0, 0, time.UTC) }
	l.MaxBytes = 100
	for i := 0; i < 10; i++ {
		l.Log("text id=abc source=greenfield sent chars=41 method=type delivery=unconfirmed")
	}
	data, _ := os.ReadFile(p)
	if !strings.HasPrefix(string(data), "2027-01-01T08:00:00Z text id=abc") {
		t.Errorf("line format: %q", data)
	}
	if _, err := os.Stat(p + ".1"); err != nil {
		t.Errorf("rotated file missing: %v", err)
	}
	var echoed string
	NewLogger("", func(s string) { echoed += s }).Log("hello")
	if !strings.HasSuffix(echoed, " hello\n") {
		t.Errorf("echo: %q", echoed)
	}
}

func TestRedact(t *testing.T) {
	cases := map[string]string{
		"X-Dictation-Key: abc123":                               "X-Dictation-Key: " + Mask,
		"GET https://host/path?token=abc&x=1 failed":            "GET https://host/path failed",
		"dial https://user:pass@host/x":                         "dial https://" + Mask + "@host/x",
		"launched with --api-key s3cret value":                  "launched with --api-key " + Mask + " value",
		`{"password":"hunter2"}`:                                `{"password":"` + Mask + `"}`,
		"Authorization: Bearer abc.def":                         "Authorization: " + Mask,
		"tskey-auth-kABC123-xyz joined":                         Mask + " joined",
		"ghp_abcdefghijklmnopqrstuvwxyz0123":                    Mask,
		"hash 0123456789abcdef0123456789abcdef0123456789abcdef": "hash " + Mask,
		"id 6f1c2e0a-5b7d-4e8b-9c41-0a2d3b4c5d6e stays":         "id 6f1c2e0a-5b7d-4e8b-9c41-0a2d3b4c5d6e stays",
		"two\nlines\r\nand\ttab":                                "two / lines / and tab",
		"text id=abc source=greenfield sent chars=41":           "text id=abc source=greenfield sent chars=41",
	}
	for in, want := range cases {
		if got := Redact(in); got != want {
			t.Errorf("Redact(%q)\n got %q\nwant %q", in, got, want)
		}
	}
	if got := Redact("my value is topsecretvalue here", "topsecretvalue"); got != "my value is "+Mask+" here" {
		t.Errorf("known secrets: %q", got)
	}
	long := Redact(strings.Repeat("word ", 200))
	if n := len([]rune(long)); n != MaxLineLength || !strings.HasSuffix(long, "…") {
		t.Errorf("long line: %d runes", n)
	}
}
