package logsvc

import (
	"regexp"
	"strings"
)

// The last gate before a log line leaves the computer (GET /logs, `logs`). Loggers already write only ids, counts, lengths, timings,
// states and error text; this also masks anything that looks like a credential, so a mistake in a log call cannot leak one, and
// keeps every line short and on one line. Dictated text has no pattern to match, so it is kept out by construction: nothing hands
// it to a logger.

// Mask replaces a secret.
const Mask = "<redacted>"

// MaxLineLength is the longest a served line gets.
const MaxLineLength = 400

const secretName = `(?:x-[a-z-]*key|authorization|proxy-authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd|passphrase|bearer|key)`

type rule struct {
	re   *regexp.Regexp
	with string
}

var rules = []rule{
	// a query string or fragment of a URL can carry a token; the host and path are enough to debug
	{regexp.MustCompile(`(?i)([a-z][a-z0-9+.-]*://[^\s?#"']*)[?#][^\s"']*`), "${1}"},
	// credentials in a URL: scheme://user:pass@host
	{regexp.MustCompile(`(?i)(://)[^/\s@"']+@`), "${1}" + Mask + "@"},
	// a launch argument that carries a secret: `-some-key VALUE`
	{regexp.MustCompile(`(?i)(^|\s)(--?[a-z][a-z-]*(?:key|token|secret|password))(\s+)\S+`), "${1}${2}${3}" + Mask},
	// header or field with a value: `X-Example-Key: abc`, `key=abc`, `"token":"abc"`
	{regexp.MustCompile(`(?i)\b(` + secretName + `)(["']?\s*[:=]\s*["']?)(?:(?:bearer|basic)\s+)?[^\s,;"'}&]+`), "${1}${2}" + Mask},
	{regexp.MustCompile(`(?i)\bbearer\s+[^\s,;"']+`), "Bearer " + Mask},
	{regexp.MustCompile(`(?i)\btskey-[a-z0-9-]+`), Mask},
	{regexp.MustCompile(`(?i)\bsk-[a-z0-9_-]{16,}`), Mask},
	{regexp.MustCompile(`(?i)\bgh[pousr]_[a-z0-9]{20,}`), Mask},
	{regexp.MustCompile(`(?i)\bxox[abprs]-[a-z0-9-]{10,}`), Mask},
	{regexp.MustCompile(`\bAKIA[0-9A-Z]{16}\b`), Mask},
	{regexp.MustCompile(`(?i)\beyJ[a-z0-9_-]{8,}\.[a-z0-9_-]+\.[a-z0-9_-]*`), Mask},
}

var (
	opaque = regexp.MustCompile(`(?i)[a-z0-9+/_-]{32,}`)
	uuid   = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

// Redact makes one line safe: values in secrets are masked wherever they appear, line breaks become " / " (one entry per line, so
// `tail` means something), other control characters become spaces, credentials are masked, long opaque strings (hashes, keys) are
// masked, and the result is cut to MaxLineLength characters.
func Redact(line string, secrets ...string) string {
	text := line
	for _, s := range secrets {
		if s != "" {
			text = strings.ReplaceAll(text, s, Mask)
		}
	}
	text = strings.NewReplacer("\r\n", " / ", "\n", " / ", "\r", " / ").Replace(text)
	text = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, text)
	for _, r := range rules {
		text = r.re.ReplaceAllString(text, r.with)
	}
	text = opaque.ReplaceAllStringFunc(text, func(m string) string {
		if uuid.MatchString(m) || strings.Contains(m, Mask) {
			return m
		}
		return Mask
	})
	if rs := []rune(text); len(rs) > MaxLineLength {
		text = string(rs[:MaxLineLength-1]) + "…"
	}
	return text
}

// RedactLines redacts every line.
func RedactLines(lines []string) []string {
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		out = append(out, Redact(l))
	}
	return out
}
