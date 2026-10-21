package config

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"
)

func TestParseDotEnv(t *testing.T) {
	got := ParseDotEnv("# comment\n\nGREENFIELD_PORT=47821\nexport A=\"quoted value\"\nB='single'\nbad line\n1X=no\nC D=no\r\nE = spaced \r\n")
	want := map[string]string{"GREENFIELD_PORT": "47821", "A": "quoted value", "B": "single", "E": "spaced"}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q want %q", k, got[k], v)
		}
	}
}

func TestPortPrecedence(t *testing.T) {
	env := map[string]string{PortVariable: "5000"}
	dot := map[string]string{PortVariable: "6000"}
	cases := []struct {
		flag     string
		env, dot map[string]string
		want     int
	}{
		{"7000", env, dot, 7000},
		{"", env, dot, 5000},
		{"", nil, dot, 6000},
		{"", nil, nil, DefaultPort},
		{"", map[string]string{PortVariable: ""}, nil, DefaultPort},
	}
	for _, c := range cases {
		if got, err := Port(c.flag, c.env, c.dot); err != nil || got != c.want {
			t.Errorf("%+v: %d %v", c, got, err)
		}
	}
	for _, bad := range []string{"abc", "0", "70000", "-1", "80 80"} {
		if _, err := Port(bad, nil, nil); err == nil {
			t.Errorf("%q must be refused", bad)
		}
	}
}

func TestFindDotEnvWalksUp(t *testing.T) {
	root := t.TempDir()
	deep := filepath.Join(root, "a", "b")
	os.MkdirAll(deep, 0o755)
	if p := FindDotEnv(deep); p != "" && filepath.Dir(p) == root {
		t.Fatalf("found a .env that does not exist: %s", p)
	}
	os.WriteFile(filepath.Join(root, ".env"), []byte("GREENFIELD_PORT=1234\n"), 0o600)
	if p := FindDotEnv(deep); p != filepath.Join(root, ".env") {
		t.Errorf("found %q", p)
	}
	if LoadDotEnv(deep)[PortVariable] != "1234" {
		t.Errorf("load")
	}
}

// The default is the one in .env.example, so the phone and the daemon agree without a .env on either side.
func TestDefaultPortIsTheOneInEnvExample(t *testing.T) {
	data, err := os.ReadFile("../../../.env.example")
	if err != nil {
		t.Skip("no .env.example beside windows/ (a copy of windows/ alone)")
	}
	m := regexp.MustCompile(`(?m)^GREENFIELD_PORT=(\d+)`).FindSubmatch(data)
	if m == nil {
		t.Fatal("no GREENFIELD_PORT in .env.example")
	}
	if n, _ := strconv.Atoi(string(m[1])); n != DefaultPort {
		t.Errorf(".env.example says %d, config.DefaultPort is %d", n, DefaultPort)
	}
}
