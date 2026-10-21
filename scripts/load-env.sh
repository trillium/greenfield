#!/usr/bin/env bash
# Source this to read the repo's .env into the environment (.env.example lists the variables the
# project defines). Bash 3.2 compatible.
#   . scripts/load-env.sh              exports KEY=VALUE lines of <repo>/.env that are not already set
#   require_env NAME [NAME...]         exit 1 with a hint when a variable is still empty
# The file is parsed, never executed. A variable already set in the environment wins over .env.
# ENV_FILE overrides the file path.

_load_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_load_env_file="${ENV_FILE:-$_load_env_root/.env}"

if [ -f "$_load_env_file" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line#"${_line%%[![:space:]]*}"}"
    case "$_line" in ""|"#"*) continue ;; esac
    _line="${_line#export }"
    _key="${_line%%=*}"; _val="${_line#*=}"
    [ "$_key" != "$_line" ] || continue
    _key="${_key%"${_key##*[![:space:]]}"}"
    case "$_key" in *[!A-Za-z0-9_]*|[0-9]*|"") continue ;; esac
    _val="${_val#"${_val%%[![:space:]]*}"}"; _val="${_val%"${_val##*[![:space:]]}"}"
    case "$_val" in \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;; \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;; esac
    if [ -z "${!_key+x}" ]; then export "$_key=$_val"; fi
  done < "$_load_env_file"
fi

require_env() {
  local name missing=0
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      echo "error: $name is not set; copy .env.example to .env and set it (or export it)" >&2
      missing=1
    fi
  done
  [ "$missing" = 0 ] || exit 1
}
