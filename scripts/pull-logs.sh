#!/usr/bin/env bash
# Pull recent, redacted logs from the phone app and the Macs, with no cable and no hand-copying. Read-only everywhere.
# Usage: scripts/pull-logs.sh [--target NAME[,NAME...]|all] [--since 30m] [--tail N] [--out DIR] [--list]
#   --target  what to pull; the names come from Config/logs.conf (--list prints them). Default: all
#   --since   only lines newer than this: a number and s, m, h or d (default 30m, at most 7d)
#   --tail    at most N lines per source (default 500, at most 2000)
#   --out     the folder to write into (default: the private folder named in Config/logs.conf, under ~/Library/Logs);
#             it must be outside every git repository, and the files are readable by you only
# Each source is written to its own file and also redacted a second time here (keys, tokens, long opaque strings): the apps and the
# daemons log only ids, counts, lengths, timings, states and error text, and this is the last gate, not the first.
# Config/logs.conf says where each source is; kinds: device (an app container on the phone, through devicectl), daemon (GET /logs on a
# Mac's daemon), file (a log file on this Mac) and ssh (some lines of a log file on another Mac, read-only). See docs/logs.md.
# Exit 0 only when every requested source was pulled; the others are named, with what to do.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONF="${LOGS_CONF:-$ROOT/Config/logs.conf}"
[ -f "$CONF" ] || die "no $CONF: it lists where this project's logs are (see docs/logs.md)"
# shellcheck disable=SC1090
. "$CONF"
: "${LOGS_TARGETS:?Config/logs.conf must set LOGS_TARGETS}"
: "${LOGS_DEFAULT_OUT:?Config/logs.conf must set LOGS_DEFAULT_OUT}"

targets="all"; since="30m"; tail_n=500; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) targets="${2:?--target needs a name}"; shift 2 ;;
    --since) since="${2:?--since needs a duration like 30m}"; shift 2 ;;
    --tail) tail_n="${2:?--tail needs a number}"; shift 2 ;;
    --out) out="${2:?--out needs a folder}"; shift 2 ;;
    --list) printf '%s\n' "$LOGS_TARGETS" | tr ' ' '\n'; exit 0 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

duration_seconds() { # 90s, 30m, 2h, 1d -> seconds, or nothing
  local n unit
  n="${1%?}"; unit="${1#"$n"}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ] || return 1
  case "$unit" in s) echo "$n" ;; m) echo $((n * 60)) ;; h) echo $((n * 3600)) ;; d) echo $((n * 86400)) ;; *) return 1 ;; esac
}
since_s="$(duration_seconds "$since")" || die "--since must look like 90s, 30m, 2h or 1d, got: $since"
[ "$since_s" -le 604800 ] || die "--since can be at most 7d"
case "$tail_n" in ''|*[!0-9]*) die "--tail needs a whole number, got: $tail_n" ;; esac
{ [ "$tail_n" -ge 1 ] && [ "$tail_n" -le 2000 ]; } || die "--tail must be 1 to 2000"

[ "$targets" != "all" ] || targets="${LOGS_TARGETS// /,}"
for name in ${targets//,/ }; do
  case " $LOGS_TARGETS " in *" $name "*) ;; *) die "unknown target: $name (this project has: $LOGS_TARGETS)" ;; esac
done

# Where the files go: private, and never inside a repository.
[ -n "$out" ] || out="$LOGS_DEFAULT_OUT/$(date +%Y%m%d-%H%M%S)"
case "$out" in \~/*) out="$HOME/${out#\~/}" ;; esac
mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
chmod 700 "$out"
if git -C "$out" rev-parse --is-inside-work-tree >/dev/null 2>&1 || case "$out/" in "$ROOT"/*) true ;; *) false ;; esac; then
  rmdir "$out" 2>/dev/null || true
  die "refusing to write logs inside a git repository ($out): pick a folder outside it (the default is under ~/Library/Logs)"
fi
umask 077

# redact: keys, tokens, credentials in URLs, long opaque strings; one short line per entry. Reads stdin, writes stdout.
redact() {
  perl -CSD -pe '
    s/[\x00-\x08\x0b-\x1f\x7f]/ /g;
    s/\b((?:x-[a-z-]*key|authorization|proxy-authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd|passphrase|bearer|key)["\x27]?\s*[:=]\s*["\x27]?)(?:(?:bearer|basic)\s+)?[^\s,;"\x27}&]+/$1<redacted>/gi;
    s/\bbearer\s+[^\s,;"\x27]+/Bearer <redacted>/gi;
    s/\b(?:tskey-[a-z0-9-]+|sk-[a-z0-9_-]{16,}|gh[pousr]_[a-z0-9]{20,}|xox[abprs]-[a-z0-9-]{10,}|AKIA[0-9A-Z]{16}\b)/<redacted>/gi;
    s/\beyJ[a-z0-9_-]{8,}\.[a-z0-9_-]+\.[a-z0-9_-]*/<redacted>/gi;
    s/(:\/\/)[^\/\s:@]+:[^\/\s@]+@/$1<redacted>@/g;
    s/([a-z0-9+\/_-]{32,})/ my $t = $1; $t =~ m{^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$}i ? $t : "<redacted>" /gie;
    s/^(.{399}).+$/$1\x{2026}\n/s;
  '
}

# keep_recent SECONDS TAIL: lines newer than SECONDS ago, at most TAIL of them. Header lines (#) stay. A line without a time
# belongs to the line before it. Understands "2026-10-20T10:00:00Z" (UTC) and "2026-10-20 10:00:00" (local time).
keep_recent() {
  perl -CSD -MTime::Local -e '
    my ($since, $tail) = @ARGV; my $cutoff = time - $since; my $keep = 1; my (@head, @body);
    while (my $line = <STDIN>) {
      if ($line =~ /^#/) { push @head, $line; next }
      if ($line =~ /^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(Z?)/) {
        my @t = ($6, $5, $4, $3, $2 - 1, $1);
        my $at = eval { $7 eq "Z" ? timegm(@t) : timelocal(@t) } // $cutoff;
        $keep = $at >= $cutoff;
      }
      push @body, $line if $keep;
    }
    @body = @body[-$tail .. -1] if @body > $tail;
    print @head, @body;
  ' "$since_s" "$tail_n"
}

failed=0
say() { printf '%s\n' "$*"; }
fail_target() { say "$1: $2"; failed=$((failed + 1)); }
conf_of() { local var="LOGS_T_$1"; printf '%s' "${!var:-}"; }

finish() { # finish NAME RAWFILE -> redacted, filtered file in $out
  local name="$1" raw="$2" dest="$out/$1.log" lines
  redact <"$raw" | keep_recent "$since_s" "$tail_n" >"$dest"
  lines="$(grep -vc '^#' "$dest" || true)"
  say "$name: $lines lines -> $dest"
}

pull_device() { # device|NAME FRAGMENT|CONTAINER PATH
  local name="$1" fragment="$2" source="$3" id status=0 text raw="$work/$1.raw"
  require_tool xcrun "Xcode command line tools"
  [ -n "$BUNDLE_ID" ] || { fail_target "$name" "no bundle id in Config/Base.xcconfig"; return; }
  id="${LOGS_DEVICE:-}"
  if [ -z "$id" ]; then
    id="$(xcrun devicectl list devices 2>/dev/null | grep -i -- "$fragment" | grep -i 'connected\|available' \
          | grep -oE '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' | head -1 || true)"
  fi
  if [ -z "$id" ]; then
    fail_target "$name" "no connected device with \"$fragment\" in its name. Wake the phone on the same network (or plug it in) and check 'xcrun devicectl list devices'."
    return
  fi
  rm -f "$raw"
  text="$(xcrun devicectl device copy from --device "$id" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
          --source "$source" --destination "$raw" --timeout 30 2>&1)" || status=$?
  if [ "$status" -eq 0 ] && [ -f "$raw" ]; then finish "$name" "$raw"; return; fi
  if printf '%s' "$text" | grep -qiE 'locked|passcode|device is not unlocked'; then
    fail_target "$name" "the phone is locked. Unlock it, keep it awake, and run this again."
  elif printf '%s' "$text" | grep -qiE 'no such file|does not exist|failed to retrieve the file node|not found|NSPOSIXErrorDomain error 2'; then
    fail_target "$name" "no support log on the phone yet. Open the app once; if this build predates the log, install the newer build."
  else
    fail_target "$name" "devicectl failed: $(printf '%s' "$text" | redact | tail -3 | tr '\n' ' ')"
  fi
}

pull_daemon() { # daemon|HOST|PORT
  local name="$1" host="$2" port="$3" code body="$work/$1.raw" url
  require_tool curl "curl"
  url="http://$host:$port/logs?format=text&tail=$tail_n&since=${since_s}s"
  code="$(curl -sS --max-time 20 -o "$body" -w '%{http_code}' "$url" 2>"$work/curl.err")" || {
    fail_target "$name" "$host did not answer ($(redact <"$work/curl.err" | tail -1)). Is the Mac awake and on the tailnet?"; return; }
  case "$code" in
    200) finish "$name" "$body" ;;
    404) fail_target "$name" "its daemon predates GET /logs (or has no log yet). Update it, then pull again." ;;
    401) fail_target "$name" "refused: this computer is not on the same tailnet user as that Mac." ;;
    403) fail_target "$name" "refused: logs are shown only to devices of that Mac's tailnet user." ;;
    429) fail_target "$name" "rate limited by that daemon (a few pulls a minute). Wait a minute and run this again." ;;
    503) fail_target "$name" "that Mac cannot verify who is calling (its Tailscale is not answering)." ;;
    *) fail_target "$name" "HTTP $code: $(sed -n 's/.*"message":"\([^"]*\)".*/\1/p' "$body" | redact | head -1)" ;;
  esac
}

pull_file() { # file|PATH
  local name="$1" path="$2"
  case "$path" in \~/*) path="$HOME/${path#\~/}" ;; esac
  if [ ! -r "$path" ]; then fail_target "$name" "no readable log at $path"; return; fi
  tail -n 20000 -- "$path" >"$work/$name.raw"
  finish "$name" "$work/$name.raw"
}

pull_ssh() { # ssh|HOST|REMOTE PATH|FILTER   (read-only: one tail piped through grep -F, nothing else is ever run)
  local name="$1" host="$2" path="$3" filter="${4:-}" remote
  case "$path$filter$host" in *[\'\"\`\$\;\&\|\<\>\\]*) fail_target "$name" "Config/logs.conf: the path, host and filter may not contain quotes or shell characters"; return ;; esac
  case "$path" in \~/*) path="\$HOME/${path#\~/}" ;; esac
  remote="tail -n 20000 \"$path\""
  [ -z "$filter" ] || remote="$remote | grep -F -- '$filter'"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "$remote" >"$work/$name.raw" 2>"$work/ssh.err" && [ ! -s "$work/$name.raw" ]; then
    if grep -q . "$work/ssh.err"; then
      fail_target "$name" "ssh to $host failed ($(redact <"$work/ssh.err" | tail -1)). Check 'ssh $host true' works without a password."; return
    fi
  fi
  finish "$name" "$work/$name.raw"
}

work="$(mktemp -d "${TMPDIR:-/tmp}/pull-logs.XXXXXX")"
trap 'rm -rf "$work"' EXIT

say "pulling ${targets//,/ } (last $since, up to $tail_n lines each) into $out"
for name in ${targets//,/ }; do
  spec="$(conf_of "$name")"
  [ -n "$spec" ] || { fail_target "$name" "Config/logs.conf has no LOGS_T_$name"; continue; }
  IFS='|' read -r kind a b c <<EOT
$spec
EOT
  case "$kind" in
    device) pull_device "$name" "$a" "$b" ;;
    daemon) pull_daemon "$name" "$a" "$b" ;;
    file) pull_file "$name" "$a" ;;
    ssh) pull_ssh "$name" "$a" "$b" "$c" ;;
    *) fail_target "$name" "Config/logs.conf: unknown kind \"$kind\" (device, daemon, file or ssh)" ;;
  esac
done

if [ "$failed" -gt 0 ]; then say "$failed of $(printf '%s\n' "${targets//,/ }" | wc -w | tr -d ' ') sources could not be pulled."; exit 1; fi
say "done. These files hold no dictated text, keys or recordings. Delete the folder when you no longer need it."
