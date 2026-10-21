#!/usr/bin/env bash
# Validate a commit message against Conventional Commits (docs/commits.md). Bash 3.2 compatible.
# Usage: check-commit-msg.sh FILE      a commit message file (what the commit-msg hook passes)
#        check-commit-msg.sh -         read the message from stdin
#        check-commit-msg.sh -m TEXT   check TEXT
# Exit 0 when valid (or exempt: merge commits), 1 with the reasons on stderr when not.
set -euo pipefail

TYPES="feat fix docs chore refactor test perf build ci revert"
MAX_SUBJECT=72
# Imperative check: these first words look like verbs but are fine.
OK_ED=" embed speed feed seed need proceed exceed succeed shed shred bleed breed bed red wed "
OK_ING=" bring string ring spring swing sing sting cling fling sling wring king thing ping "
OK_S=" alias canvas bias gas atlas lens ios macos tvos watchos ops "

case "${1:-}" in
  -m) [ $# -ge 2 ] || { echo "usage: $0 FILE | - | -m TEXT" >&2; exit 2; }; msg="$2" ;;
  -)  msg="$(cat)" ;;
  "") echo "usage: $0 FILE | - | -m TEXT" >&2; exit 2 ;;
  *)  [ -f "$1" ] || { echo "$0: no such file: $1" >&2; exit 2; }
      # a file is what git wrote: drop its comment lines and everything under the scissors line
      msg="$(awk '/^# -+ >8 -+$/{exit} !/^#/{print}' "$1")" ;;
esac

# Leading blank lines are not part of the message.
msg="$(printf '%s\n' "$msg" | awk 'NF || seen {seen=1; print}')"
subject="$(printf '%s\n' "$msg" | head -n 1 | sed -E 's/[[:space:]]+$//')"
second="$(printf '%s\n' "$msg" | sed -n 2p)"

case "$subject" in "Merge "*) exit 0 ;; esac

errors=()
err() { errors+=("$1"); }

if [ -z "$subject" ]; then
  err "empty commit message"
else
  re='^([a-z]+)(\(([^)]*)\))?(!)?: (.*)$'
  acronym='^[A-Z0-9][A-Z0-9_-]+[,.:;]?$'
  scope_re='^[a-z0-9][a-z0-9._/-]*$'
  if [[ "$subject" =~ $re ]]; then
    type="${BASH_REMATCH[1]}"; scope="${BASH_REMATCH[3]}"; desc="${BASH_REMATCH[5]}"
    has_scope=0; [ -z "${BASH_REMATCH[2]}" ] || has_scope=1
    case " $TYPES " in *" $type "*) ;; *) err "unknown type '$type' (use one of: $TYPES)" ;; esac
    if [ "$has_scope" = 1 ] && ! [[ "$scope" =~ $scope_re ]]; then
      err "scope '($scope)' must be lowercase letters, digits, '.', '_', '/' or '-' (for example feat(mac): ...)"
    fi
    if [ -z "$desc" ] || [ -z "${desc//[[:space:]]/}" ]; then
      err "the subject after ': ' is empty"
    else
      first="${desc%% *}"
      if [[ "$desc" =~ ^[A-Z] ]] && ! [[ "$first" =~ $acronym ]]; then
        err "subject must start lowercase (an all-caps acronym like HTTP is fine): '$desc'"
      fi
      case "$desc" in *.) err "subject must not end with a period" ;; esac
      w="$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z]*$//')"
      bad=""
      case "$w" in
        *ed)  case "$OK_ED" in *" $w "*) ;; *) bad="past tense" ;; esac ;;
        *ing) case "$OK_ING" in *" $w "*) ;; *) bad="-ing form" ;; esac ;;
        *ss|*us|*is) ;;
        ???*s) case "$OK_S" in *" $w "*) ;; *) bad="third person" ;; esac ;;
      esac
      [ -z "$bad" ] || err "use the imperative mood ('add', not 'added'/'adds'/'adding'); '$w' reads as $bad"
    fi
  else
    err "subject must look like 'type(scope)!: description', e.g. 'fix(mac): reject empty text' (types: $TYPES)"
  fi
  if [ "${#subject}" -gt "$MAX_SUBJECT" ]; then
    err "subject is ${#subject} characters; the limit is $MAX_SUBJECT"
  fi
fi

if [ -n "$second" ]; then err "put a blank line between the subject and the body"; fi

breaking_re='^BREAKING[ -]CHANGE: .*[^[:space:]]'
# A breaking-change footer needs the exact form 'BREAKING CHANGE: description'.
while IFS= read -r line; do
  case "$line" in
    "BREAKING CHANGE"*|"BREAKING-CHANGE"*)
      [[ "$line" =~ $breaking_re ]] \
        || err "breaking-change footer must read 'BREAKING CHANGE: what breaks and what to do' (got '$line')" ;;
  esac
done <<EOT
$(printf '%s\n' "$msg" | tail -n +2)
EOT

if [ "${#errors[@]}" -gt 0 ]; then
  {
    echo "commit message rejected: $subject"
    for e in "${errors[@]}"; do echo "  - $e"; done
    echo "  format: type(scope)!: lowercase imperative subject, at most $MAX_SUBJECT characters. See docs/commits.md."
  } >&2
  exit 1
fi
