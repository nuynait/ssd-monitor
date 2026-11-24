#!/bin/bash
# Install the helper scripts the app runs (helpers/, into ~/Local/bin and ~/Local/ssd on the Mac's own disk),
# build the app, install it into /Applications (also the Mac's own disk, so it runs while the SSD is gone), and
# (re)start it. Edit the setup block at the top of helpers/ssd-volumes.sh for your Mac first.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPTS=helpers
for f in ssd-resume ssd-off ssd-volumes.sh ssd.zsh; do
  [ -f "$SCRIPTS/$f" ] || { echo "missing $SCRIPTS/$f" >&2; exit 1; }
done
for f in ssd-resume ssd-off; do
  grep -q 'ssd-monitor-protocol: 2' "$SCRIPTS/$f" || { echo "$SCRIPTS/$f is too old for this app" >&2; exit 1; }
done

scripts/build.sh

mkdir -p "$HOME/Local/bin" "$HOME/Local/ssd"
install -m 755 "$SCRIPTS/ssd-resume" "$SCRIPTS/ssd-off" "$HOME/Local/bin/"
install -m 644 "$SCRIPTS/ssd-volumes.sh" "$HOME/Local/bin/"
install -m 644 "$SCRIPTS/ssd.zsh" "$HOME/Local/ssd/"
[ "$("$HOME/Local/bin/ssd-resume" --step list | grep -c '^VOLUME')" -gt 0 ] \
  || { echo "~/Local/bin/ssd-resume --step list gave no volumes" >&2; exit 1; }
echo "installed the helper scripts into ~/Local/bin and ~/Local/ssd/ssd.zsh"
# A line that loads it as a command: `source`/`.` at the start or after &&, ||, ; or `then` (not in a comment).
grep -qsE '^([^#]*(&&|\|\||;|then))?[[:space:]]*(source|\.)[[:space:]]+[^#]*Local/ssd/ssd\.zsh' "$HOME/.zshrc" \
  || echo "note: ~/.zshrc does not source ~/Local/ssd/ssd.zsh yet (see AGENTS.md, section 8)"

# Quit the running app. It treats SIGTERM as a normal quit: it stops any command it is running first.
# If it does not go within 10 s, stop here rather than kill it (a command of its could keep running).
if pgrep -x SSDMonitor >/dev/null; then
  pkill -TERM -x SSDMonitor || true
  for _ in $(seq 1 40); do pgrep -x SSDMonitor >/dev/null || break; sleep 0.25; done
  if pgrep -x SSDMonitor >/dev/null; then
    echo "SSD Monitor did not quit. Quit it from its menu, then run this again." >&2; exit 1
  fi
fi
rm -rf "/Applications/SSD Monitor.app"
ditto "build/SSD Monitor.app" "/Applications/SSD Monitor.app"
open "/Applications/SSD Monitor.app"
echo "installed and started /Applications/SSD Monitor.app"
