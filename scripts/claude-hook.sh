#!/usr/bin/env bash
# Claude Code hook: tells hisashi what a session does. Point every hook event at it.
# Sends "tty pid" of the claude process, then the hook's JSON, to hisashi's socket.
# Exits at once and quietly when hisashi is not running.
sock="$HOME/Library/Application Support/Hisashi/claude.sock"
payload="$(cat)"
[ -S "$sock" ] || exit 0
pid=$PPID
while [ "$pid" -gt 1 ]; do
  read -r tty ppid comm <<<"$(ps -o tty=,ppid=,comm= -p "$pid")"
  [ "${comm##*/}" = "claude" ] && break
  pid=$ppid
done
[ "$pid" -gt 1 ] || { tty=-; pid=-; }
printf '%s %s\n%s\n' "$tty" "$pid" "$payload" | nc -U -w 2 "$sock" >/dev/null 2>&1
exit 0
