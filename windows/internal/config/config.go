// Package config reads the port (and nothing else) the way the Mac daemon does: --port wins, then the environment, then the nearest
// .env, then the default in .env.example, so a fresh checkout needs no .env and no port number is a surprise.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// PortVariable is the variable .env.example defines.
const PortVariable = "GREENFIELD_PORT"

// DefaultPort is the default in .env.example (a test keeps the two equal).
const DefaultPort = 47821

// ParseDotEnv reads KEY=VALUE lines; blank lines and `#` comments are skipped, `export ` and one pair of quotes are removed. The
// file is only parsed, never executed.
func ParseDotEnv(text string) map[string]string {
	out := map[string]string{}
	for _, raw := range strings.FieldsFunc(text, func(r rune) bool { return r == '\n' || r == '\r' }) {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		if k == "" || (k[0] >= '0' && k[0] <= '9') || strings.IndexFunc(k, func(r rune) bool {
			return !(r == '_' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9')
		}) >= 0 {
			continue
		}
		v = strings.TrimSpace(v)
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
			v = v[1 : len(v)-1]
		}
		out[k] = v
	}
	return out
}

// FindDotEnv is the nearest .env at or above dir ("" when there is none).
func FindDotEnv(dir string) string {
	dir, err := filepath.Abs(dir)
	if err != nil {
		return ""
	}
	for {
		candidate := filepath.Join(dir, ".env")
		if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// LoadDotEnv reads the nearest .env at or above dir.
func LoadDotEnv(dir string) map[string]string {
	p := FindDotEnv(dir)
	if p == "" {
		return map[string]string{}
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return map[string]string{}
	}
	return ParseDotEnv(string(data))
}

// Port is the port to use: the flag wins, then the environment, then .env, else DefaultPort.
func Port(flag string, environment, dotEnv map[string]string) (int, error) {
	text := flag
	if text == "" {
		text = environment[PortVariable]
	}
	if text == "" {
		text = dotEnv[PortVariable]
	}
	if text == "" {
		return DefaultPort, nil
	}
	n, err := strconv.Atoi(text)
	if err != nil || n < 1 || n > 65535 {
		return 0, fmt.Errorf("bad port '%s': expected a number from 1 to 65535", text)
	}
	return n, nil
}
