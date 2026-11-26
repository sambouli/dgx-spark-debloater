#!/usr/bin/env bash
# Reverse the DGX Spark inference-node baseline applied by setup.sh.
#
#   ./teardown.sh --dry-run
#   sudo ./teardown.sh
#
# Note: units that were MASKED come back to `static`/`disabled`, not `enabled`.
# Re-enabling them is usually wrong on an inference node; do it per unit if you
# genuinely need one (e.g. `systemctl unmask nfs-common && systemctl enable nfs-client.target`).
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
if [ "$(id -u)" != 0 ] && [ "$DRY" = 0 ]; then
  echo "must run as root (or use --dry-run)" >&2; exit 1
fi
log() { printf '%s\n' "$*"; }
run() { if [ "$DRY" = 1 ]; then printf '  [dry] %s\n' "$*"; else "$@"; fi; }

source <(sed -n '/^DISABLED=(/,/^)/p;/^MASKED=(/,/^)/p' "$(dirname "$0")/setup.sh")

log "== unmasking =="
for u in "${MASKED[@]}"; do
  [ "$(systemctl is-enabled "$u" 2>&1)" = "masked" ] || continue
  log "  unmask $u"
  run systemctl unmask "$u"
done

log "== restoring desktop boot target =="
cur=$(systemctl get-default)
if [ "$cur" = "multi-user.target" ]; then
  log "  get-default -> graphical.target"
  run systemctl set-default graphical.target
fi

log "== restoring THP =="
if [ -f /etc/systemd/system/disable-thp.service ]; then
  run systemctl disable --now disable-thp.service
  run rm -f /etc/systemd/system/disable-thp.service
  run systemctl daemon-reload
fi
[ -w /sys/kernel/mm/transparent_hugepage/enabled ] && \
  run sh -c 'echo always > /sys/kernel/mm/transparent_hugepage/enabled'

log "== removing tuning drop-ins =="
for f in /etc/sysctl.d/99-inference-node.conf /etc/security/limits.d/99-inference-node.conf; do
  if [ -f "$f" ]; then
    log "  rm $f"
    run rm -f "$f"
  fi
done
run sysctl --system

log "== swap =="
if grep -qE '^#[[:space:]]*/swap\.img' /etc/fstab 2>/dev/null; then
  log "  NOTE: /etc/fstab swap entries were commented out by setup.sh."
  log "        Restore from /etc/fstab.bak.<timestamp>, or uncomment manually:"
  grep -nE '^#[[:space:]]*/swap\.img' /etc/fstab | sed 's/^/          /'
fi

log ""
log "Disabled units are left disabled — review daemons.md and re-enable individually with"
log "'systemctl enable <unit>' only for what you actually need."
