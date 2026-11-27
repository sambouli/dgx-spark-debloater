#!/usr/bin/env bash
# Apply the DGX Spark inference-node baseline. Idempotent. Needs root.
#
#   ./setup.sh --dry-run    print what would change, change nothing
#   sudo ./setup.sh         apply
#   sudo WITH_EARLYOOM=1 EARLYOOM_PREFER='sglang' ./setup.sh
#                         also configure earlyoom (opt-in, see README)
#
# Reversible with ./teardown.sh
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# Optional, OFF BY DEFAULT. OOM policy kills processes and the right victim
# depends entirely on what you run, so it is not part of the baseline.
#
# EARLYOOM_PREFER is a full ERE passed straight to --prefer.
#
# The default covers the engines this baseline was written against -- vLLM,
# llama.cpp and Ollama -- as their process names ACTUALLY appear in `ps`. comm is
# truncated at 15 chars, so 'VLLM::EngineCore' shows up as 'VLLM::EngineCor'; a
# pattern anchored on the long form silently matches nothing.
#
# It is NOT exhaustive. Other servers (SGLang, TensorRT-LLM, Triton, TGI, ...)
# will not match, and an unmatched pattern degrades earlyoom to kill-the-largest.
# That is why setup.sh verifies the pattern against live processes instead of
# trusting this default. Confirm yours with:
#     docker exec <container> ps -eo comm,rss --sort=-rss | head
# and pass EARLYOOM_PREFER explicitly for anything outside the default.
WITH_EARLYOOM="${WITH_EARLYOOM:-0}"
EARLYOOM_PREFER="${EARLYOOM_PREFER:-^VLLM|^vllm|llama-server|^ollama}"

log()  { printf '%s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then printf '  [dry] %s\n' "$*"; else "$@"; fi; }

if [ "$(id -u)" != 0 ] && [ "$DRY" = 0 ]; then
  echo "must run as root (or use --dry-run)" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# Units disabled: not needed on a headless inference node.
# `disable` only — these can come back via an apt postinst, so the ones that
# demonstrably do are also in MASKED below.
# ---------------------------------------------------------------------------
DISABLED=(
  # --- vendor out-of-box / dashboards / telemetry -------------------------
  dgx-oobe.service
  dgx-oobe-admin.service
  dgx-oobe-hostname.service
  dgx-oobe-hotspot.service
  dgx-oobe-hotspot-watchdog.service
  dgx-oobe-ubuntu-pro-activate.service
  setup-oem-config-override.service
  dgx-dashboard.service
  dgx-dashboard-admin.service
  nvidia-dgx-telemetry.service
  nvidia-dgx-sol.service
  nvidia-remove-gnome-software-once.service
  nvidia-spark-remove-once.service
  nvidia-spark-run-apt-upgrade-once.service
  nvidia-desktop-default-snaps.service
  ubuntu-advantage.service
  pollinate.service

  # --- cloud provisioning (this is not a cloud instance) ------------------
  cloud-init.service
  cloud-init-local.service
  cloud-config.service
  cloud-final.service

  # --- VM / hypervisor guest tooling --------------------------------------
  open-vm-tools.service
  vgauth.service

  # --- printing ------------------------------------------------------------
  cups.service
  cups-browsed.service

  # --- radio / cellular / serial console ----------------------------------
  bluetooth.service
  ModemManager.service
  brltty.service
  speech-dispatcherd.service

  # --- file sharing --------------------------------------------------------
  smbd.service
  nmbd.service
  samba-ad-dc.service
  rpcbind.service
  quotarpc.service
  quota.service

  # --- VPN / tunnel daemons (started on demand instead) --------------------
  openvpn.service
  'openvpn-client@.service'
  'openvpn-server@.service'
  'openvpn@.service'

  # --- storage we do not use ----------------------------------------------
  open-iscsi.service
  iscsid.service
  multipathd.service
  lvm2-monitor.service
  nvmf-autoconnect.service
  nvmefc-boot-connections.service
  srp_daemon.service
  'srp_daemon_port@.service'

  # --- IPMI / watchdog sidecars (keep ipmitool usable, drop the daemons) --
  ipmievd.service

  # --- crash reporting / debug --------------------------------------------
  apport.service
  kdump-tools.service
  debug-shell.service

  # --- desktop / session plumbing -----------------------------------------
  upower.service
  rtkit-daemon.service
  udisks2.service
  switcheroo-control.service
  accounts-daemon.service
  gnome-remote-desktop.service

  # --- mDNS / discovery (not needed; also a boot-time stall source) -------
  avahi-daemon.service
  avahi-daemon.socket

  # --- networkd + wait-online (NetworkManager owns the config here) -------
  systemd-networkd.service
  systemd-network-generator.service
  systemd-networkd-wait-online.service
  'systemd-networkd-wait-online@.service'
  NetworkManager-wait-online.service

  # --- misc one-shot or unused --------------------------------------------
  nftables.service          # no host firewall policy in use; iptables/nft rules stay loaded
  rsync.service             # socket-activated on demand
  dnsmasq.service
  'dnsmasq@.service'
  wpa_supplicant.service
  'wpa_supplicant-nl80211@.service'
  'wpa_supplicant-wired@.service'
  'wpa_supplicant@.service'
  systemd-boot-check-no-failures.service
  systemd-confext.service
  systemd-sysext.service
  systemd-time-wait-sync.service
  'systemd-pcrlock-file-system.service'
  'systemd-pcrlock-firmware-code.service'
  'systemd-pcrlock-firmware-config.service'
  'systemd-pcrlock-machine-id.service'
  'systemd-pcrlock-make-policy.service'
  'systemd-pcrlock-secureboot-authority.service'
  'systemd-pcrlock-secureboot-policy.service'
  console-getty.service     # headless: no local console login
)

# ---------------------------------------------------------------------------
# Units masked: disabling alone did not stick (an apt postinst or another unit
# re-enabled them), so they are masked to `/dev/null`.
# ---------------------------------------------------------------------------
MASKED=(
  # NVIDIA System Management stack — pulls many resident processes, unused here
  nvsm.service
  nvsm-api-gateway.service
  nvsm-core.service
  nvsm-exporter.service
  nvsm-mqtt.service
  nvsm-notifier.service

  # NFS client (no NFS mounts)
  nfs-common.service

  # multipath boot path (multipathd is disabled above; this is the boot hook)
  multipath-tools-boot.service

  # desktop leftovers that survive a gdm removal
  x11-common.service
  alsa-utils.service
  saned.service
  screen-cleanup.service

  # disk encryption / RTC paths irrelevant to this platform image
  cryptdisks.service
  cryptdisks-early.service
  hwclock.service
)

# ---------------------------------------------------------------------------
log "== 1/6  disabling units =="
for u in "${DISABLED[@]}"; do
  state=$(systemctl is-enabled "$u" 2>&1 || true)
  # 'not-found' / 'bad' / 'error' mean the unit does not exist on this box
  # (image or package-version drift). Skip rather than act on nothing.
  case "$state" in not-found|bad|error|unknown) continue ;; esac
  case "$state" in
    enabled|static|generated|indirect)
      log "  disable $u ($state)"
      run systemctl disable "$u"
      ;;
  esac
done

log "== 2/6  masking units =="
for u in "${MASKED[@]}"; do
  state=$(systemctl is-enabled "$u" 2>&1 || true)
  case "$state" in not-found|bad|error|unknown) continue ;; esac
  [ "$state" = "masked" ] && continue
  log "  mask $u ($state)"
  run systemctl mask "$u"
done

log "== 3/6  headless boot target =="
cur=$(systemctl get-default)
if [ "$cur" != "multi-user.target" ]; then
  log "  get-default: $cur -> multi-user.target"
  run systemctl set-default multi-user.target
  run systemctl stop gdm sddm lightdm 2>/dev/null || true
else
  log "  already multi-user.target"
fi

log "== 4/6  swap off =="
if [ -e /swap.img ]; then
  log "  swapoff + remove /swap.img"
  run swapoff -a
  run rm -f /swap.img
else
  log "  no /swap.img"
fi
if grep -qE '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
  log "  commenting out active swap entries in /etc/fstab"
  if [ "$DRY" = 0 ]; then
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
    sed -i -E 's|^([^#].*[[:space:]]swap[[:space:]].*)|# \1|' /etc/fstab
  else
    echo "  [dry] sed -i -E 's|^([^#].* swap .*)|# \\1|' /etc/fstab"
  fi
fi

log "== 5/6  transparent huge pages: never =="
if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi
if [ ! -f /etc/systemd/system/disable-thp.service ] && [ "$DRY" = 0 ]; then
  cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable transparent huge pages for pinned inference allocations
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now disable-thp.service
fi
log "  THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"

log "== 6/6  kernel tuning: sysctls + resource limits =="
if [ ! -f /etc/sysctl.d/99-inference-node.conf ] || [ "$DRY" = 0 ]; then
  run tee /etc/sysctl.d/99-inference-node.conf >/dev/null <<'EOF'
# Inference node: large pinned allocations, no background compaction churn.
# See sysctl.md for the reasoning per value.
vm.swappiness = 10
vm.compaction_proactiveness = 0
vm.extfrag_threshold = 500
vm.min_free_kbytes = 1048576
vm.watermark_scale_factor = 25
EOF
fi
if [ "$DRY" = 0 ]; then
  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-inference-node.conf
fi
log "  compaction_proactiveness=$(cat /proc/sys/vm/compaction_proactiveness 2>/dev/null)"
log "  min_free_kbytes=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)"

# Two DIFFERENT mechanisms, because they cover different things -- writing only
# the first is a classic silent failure.
#
#   limits.d  -> read by pam_limits, so it applies to LOGIN sessions only.
#                It does nothing for anything systemd starts.
#   drop-in   -> read by systemd, required for services (dockerd, containerd)
#                and therefore for containers doing RDMA / pinned allocations.
if [ ! -f /etc/security/limits.d/99-inference-node.conf ] || [ "$DRY" = 0 ]; then
  run tee /etc/security/limits.d/99-inference-node.conf >/dev/null <<'EOF'
# Applies to login (PAM) sessions only -- see the systemd drop-in below for
# services. RDMA queue pairs and pinned GPU buffers must be lockable.
*    soft   memlock   unlimited
*    hard   memlock   unlimited
*    soft   nofile    500000
*    hard   nofile    500000
EOF
fi

# Service-side memlock. Vendor images frequently ship their own docker override
# pinning LimitMEMLOCK (e.g. 8388608), so this file is named to sort AFTER any
# such override: systemd applies drop-ins in lexicographic order, and a name
# like 10-*.conf would lose to docker-override.conf and change nothing.
log "  service limits (systemd drop-in)"
for svc in docker containerd; do
  if ! systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q .; then
    continue
  fi
  dir="/etc/systemd/system/${svc}.service.d"
  # 99- sorts after typical vendor names (docker-override.conf, 10-*, 50-*)
  target="$dir/99-inference-node-limits.conf"
  if [ ! -f "$target" ] || [ "$DRY" = 0 ]; then
    log "    write $target"
    if [ "$DRY" = 0 ]; then
      mkdir -p "$dir"
      cat > "$target" <<'EOF'
# Must sort after vendor overrides: systemd applies drop-ins in lexicographic
# order, so a lower-sorting name would be overridden rather than override.
[Service]
LimitMEMLOCK=infinity
LimitNOFILE=524288
EOF
    else
      echo "  [dry] write $target (LimitMEMLOCK=infinity)"
    fi
  fi
done

# A drop-in is inert until systemd reloads AND the daemon restarts -- LimitMEMLOCK
# is read at process start. Warn rather than silently restart a running engine.
if [ "$DRY" = 0 ]; then
  if systemctl daemon-reload; then :; fi
  for svc in docker containerd; do
    tgt="/etc/systemd/system/${svc}.service.d/99-inference-node-limits.conf"
    [ -f "$tgt" ] || continue
    cur=$(systemctl show "$svc.service" -p LimitMEMLOCK --value 2>/dev/null)
    if [ "$cur" != "infinity" ]; then
      log "    NOTE: $svc still reports LimitMEMLOCK=$cur."
      log "          The drop-in is written but takes effect only after"
      log "            systemctl restart $svc"
      log "          which stops running containers -- do it deliberately."
    else
      log "    $svc: LimitMEMLOCK=infinity (live)"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Optional, OFF BY DEFAULT.
#
# OOM policy is deliberately excluded from the baseline: it kills processes, and
# the correct victim depends on what you actually serve. Enabling it without a
# --prefer pattern makes earlyoom fall back to killing the LARGEST process, which
# is strictly worse than leaving it alone -- you lose the kernel's predictability
# and keep the surprise. So this refuses to install until you name your engine.
# ---------------------------------------------------------------------------
if [ "$WITH_EARLYOOM" = "1" ]; then
  log "== optional: earlyoom (WITH_EARLYOOM=1) =="
  if [ -z "$EARLYOOM_PREFER" ]; then
    log "  ERROR: EARLYOOM_PREFER must not be empty."
    log "         With no --prefer pattern earlyoom kills the LARGEST process,"
    log "         which is the behaviour this feature exists to avoid."
    exit 1
  fi

  # A pattern that matches nothing is worse than no earlyoom at all: it looks
  # like protection and silently degrades to kill-the-largest. This is the most
  # common way the feature is misconfigured, so verify against live processes.
  matched=$(pgrep -f "$EARLYOOM_PREFER" 2>/dev/null | wc -l)
  if [ "$matched" -eq 0 ]; then
    log "  WARNING: pattern '$EARLYOOM_PREFER' matches NO running process."
    log "           earlyoom would fall back to killing the largest process."
    log ""
    log "           Check what your engine is really called (comm truncates at"
    log "           15 chars -- anchor on what ps shows, not on the cmdline):"
    log "             ps -eo comm,rss --sort=-rss | head"
    log "             pgrep -fa '$EARLYOOM_PREFER'"
    log ""
    log "           Override once confirmed:"
    log "             sudo WITH_EARLYOOM=1 EARLYOOM_PREFER='<regex>' ./setup.sh"
    log ""
    log "           Pass EARLYOOM_ALLOW_NO_MATCH=1 to install anyway (e.g. the"
    log "           engine is not started yet on this node)."
    [ "${EARLYOOM_ALLOW_NO_MATCH:-0}" = "1" ] || exit 1
    log "  proceeding despite no match (EARLYOOM_ALLOW_NO_MATCH=1)"
  else
    log "  pattern matches $matched running process(es) -- ok"
  fi
  if ! command -v earlyoom >/dev/null 2>&1; then
    log "  installing earlyoom"
    run apt-get install -y earlyoom
  fi
  log "  writing /etc/default/earlyoom (prefer=$EARLYOOM_PREFER)"
  if [ "$DRY" = 0 ]; then
    tee /etc/default/earlyoom >/dev/null <<EOF
# Kill the inference engine first; never the infrastructure.
# -M <free MB>,<min MB>: act when free RAM drops under 1 GiB, stop at 512 MiB
# -s <free>,<min>:        same for swap (inert with swap off, protective if it returns)
# --prefer:               kill processes matching this regex first
# --avoid:                never touch these, regardless of size
EARLYOOM_ARGS="-r 3600 -p -M 1048576,524288 -s 100,100 --prefer $EARLYOOM_PREFER --avoid ^(systemd|sshd|dockerd|containerd|dbus-daemon|NetworkManager|gdm|Xorg|nvidia)"
EOF
  else
    echo "  [dry] write /etc/default/earlyoom with --prefer $EARLYOOM_PREFER"
  fi
  run systemctl enable --now earlyoom
  log "  earlyoom: $(systemctl is-active earlyoom 2>/dev/null)"
else
  log ""
  log "skipped (optional): earlyoom OOM protection."
  log "  The kernel OOM killer scores by resident size, so on a unified-memory"
  log "  box it may take dockerd or sshd rather than the engine. Consider"
  log "  WITH_EARLYOOM=1 if you run close to full memory."
fi

log ""
log "done. Verify with:"
log "  systemctl get-default"
log "  swapon --show"
log "  cat /proc/sys/vm/compaction_proactiveness"
