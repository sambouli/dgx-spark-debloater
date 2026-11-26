# Disabled and masked units

Two tiers:

- **disabled** — `systemctl disable`. A package postinst or a dependency can re-enable it.
- **masked** — symlinked to `/dev/null`. Nothing can start it, including an apt hook. Used
  where disabling alone did not survive updates, and for stacks with many resident processes.

Verified against live state on both nodes (`systemctl list-unit-files --state=disabled` /
`--state=masked`).

## Tier 1 — disabled (85 units)

### Vendor out-of-box experience, dashboards, telemetry

These are the DGX Station/PGX desktop conveniences. They cost RAM at boot and phone home.

| Unit | Role |
|---|---|
| `dgx-oobe.service` | First-boot setup wizard |
| `dgx-oobe-admin.service` | OOBE admin page |
| `dgx-oobe-hostname.service` | OOBE hostname prompt |
| `dgx-oobe-hotspot.service` | OOBE Wi-Fi hotspot |
| `dgx-oobe-hotspot-watchdog.service` | Keeps the hotspot alive |
| `dgx-oobe-ubuntu-pro-activate.service` | Ubuntu Pro enrolment prompt |
| `setup-oem-config-override.service` | OEM configuration pass |
| `dgx-dashboard.service` | Browser dashboard |
| `dgx-dashboard-admin.service` | Dashboard admin backend |
| `nvidia-dgx-telemetry.service` | Telemetry upload |
| `nvidia-dgx-sol.service` | Serial-over-LAN console |
| `nvidia-remove-gnome-software-once.service` | One-shot cleanup |
| `nvidia-spark-remove-once.service` | One-shot cleanup |
| `nvidia-spark-run-apt-upgrade-once.service` | Unattended first upgrade |
| `nvidia-desktop-default-snaps.service` | Installs desktop snaps |
| `ubuntu-advantage.service` | Pro attach / livepatch client |
| `pollinate.service` | Seeds entropy to a remote service at boot |

### Cloud provisioning

Not a cloud instance; four units that add boot latency and contact an metadata endpoint.

`cloud-init.service`, `cloud-init-local.service`, `cloud-config.service`, `cloud-final.service`

### Hypervisor guest tooling

`open-vm-tools.service`, `vgauth.service`

### Printing

`cups.service`, `cups-browsed.service`

### Radio, cellular, accessibility console

`bluetooth.service`, `ModemManager.service`, `brltty.service`, `speech-dispatcherd.service`

### File sharing

`smbd.service`, `nmbd.service`, `samba-ad-dc.service`, `rpcbind.service`, `quota.service`,
`quotarpc.service`

### VPN daemons

Started on demand instead of resident.

`openvpn.service`, `openvpn-client@.service`, `openvpn-server@.service`, `openvpn@.service`

### Storage subsystems not in use

iSCSI initiator, multipath, LVM monitoring, NVMe-oF/FC autoconnect, RDMA session daemon.

`open-iscsi.service`, `iscsid.service`, `multipathd.service`, `lvm2-monitor.service`,
`nvmf-autoconnect.service`, `nvmefc-boot-connections.service`, `srp_daemon.service`,
`srp_daemon_port@.service`

> Note: `srp_daemon` is the iSER/RDMA *session* daemon, unrelated to the CX7 RoCE data path
> used for inter-node collectives. NCCL/RDMA still works with it disabled.

### IPMI sidecar

`ipmievd.service` — the event daemon only. `ipmitool` itself remains usable.

### Crash reporting and debug

`apport.service`, `kdump-tools.service`, `debug-shell.service`

`kdump-tools` is worth calling out: it reserves a crashkernel memory region at boot. On a
121 GiB unified pool that reservation competes with weights, and there is no plan to collect
vmcores from a headless node.

### Desktop and session plumbing

The single biggest win after the OOM work, since these hold real RSS rather than just idle
mmap.

| Unit | Why |
|---|---|
| `gdm` / `graphical.target` → `multi-user.target` | The display manager itself |
| `gnome-remote-desktop.service` | RDP/VNC server — was also `enabled` |
| `accounts-daemon.service` | D-Bus user-account service for the control centre |
| `udisks2.service` | Removable-media automation |
| `upower.service` | Battery/UPS polling — no battery |
| `rtkit-daemon.service` | Realtime scheduling for *audio* |
| `switcheroo-control.service` | GPU-switching for laptops |
| `avahi-daemon.service` | mDNS advertisement |
| **`avahi-daemon.socket`** | See note below |
| `wpa_supplicant.service` (+3 templates) | Wired-only node |

> **`avahi-daemon.socket` matters.** Disabling only the `.service` leaves the socket
> activated: the first mDNS lookup on the network *resurrects the daemon*. Both units must be
> disabled together. Check with:
> ```bash
> systemctl is-active avahi-daemon.socket avahi-daemon.service   # both inactive
> ```

### Network wait-online and networkd

NetworkManager owns configuration here; `networkd` is unused and the `-wait-online` units
only add boot latency (and have been observed to stall boot for minutes).

`systemd-networkd.service`, `systemd-network-generator.service`,
`systemd-networkd-wait-online.service`, `systemd-networkd-wait-online@.service`,
`NetworkManager-wait-online.service`

### Misc one-shots and unused machinery

`nftables.service` (no host firewall policy in use — loaded rules are unaffected),
`rsync.service` (socket-activated on demand), `dnsmasq.service`, `dnsmasq@.service`,
`console-getty.service` (headless: no local login prompt),
`systemd-boot-check-no-failures.service`, `systemd-confext.service`, `systemd-sysext.service`,
`systemd-time-wait-sync.service`, and all seven `systemd-pcrlock-*` units.

## Tier 2 — masked (16 units)

| Unit | Reason |
|---|---|
| `nvsm.service` | NVIDIA System Management suite umbrella |
| `nvsm-api-gateway.service` | NVSM REST gateway |
| `nvsm-core.service` | NVSM collector |
| `nvsm-exporter.service` | NVSM Prometheus exporter |
| `nvsm-mqtt.service` | NVSM MQTT broker bridge |
| `nvsm-notifier.service` | NVSM alert notifier |
| `nfs-common.service` | No NFS mounts; pulls `statd`/`idmapd` |
| `multipath-tools-boot.service` | Boot-time multipath hook |
| `x11-common.service` | X infrastructure left behind by the desktop stack |
| `alsa-utils.service` | No audio on an inference node |
| `saned.service` | Scanner daemon |
| `screen-cleanup.service` | Console blanking helper |
| `cryptdisks.service` | No encrypted root |
| `cryptdisks-early.service` | Same |
| `hwclock.service` | RTC sync handled by chrony/systemd-timesyncd |
| `sudo.service` | Not a service; masked defensively so nothing can trigger it |

The NVSM family is the important one: six services plus their D-Bus activation, all resident,
none needed when you monitor the box with `nvidia-smi` and your own probes.

## What was deliberately NOT touched

Load-bearing on this platform. If a script disables any of these, fix the script:

```
nvidia-persistenced              nvidia-container-toolkit (package + its systemd units)
nvidia-spark-limits              nvidia-spark-mlnx-firmware-manager
nvidia-disable-numa-balancing    nvidia-relaxed-ordering-gpu / -nvme
nvidia-earlycon                  nv-grubmenu  nv-grubserial  nv-iommu  nv-limits
dgx-release                      dgx-repo  cuda-compute-repo  hpc-sdk-repo
nvidia-spark-ota-check           nvidia-crashdump (the tool, not kdump-tools)
```

Also left alone: the **CX7 hot-plug path**. There is no systemd unit for it — it is a udev
rule, `/lib/udev/rules.d/90-mtk-hotplug.rules`, invoking
`/opt/nvidia/dgx-spark-mlnx-hotplug/mtk-hotplug-handler.sh` on `add` / `plugin` / `removal`
events for the `cx7-pcie-hotplug` driver bound to `MTKP0001:00`. Do not "clean up" that
directory or the rule; it is what makes the ConnectX-7 ports appear when you seat a cable.

Also left installed on purpose: `nvidia-system-station{,-core,-apps,-common,-utils,-games,
-localization}`, `dgxstation-desktop`, `dgx-dashboard`, `nvidia-ai-workbench`,
`nvidia-system-{core,extra,utils}`. These are desktop *bundles*, not drivers. Removing them
risks `apt` pulling neighbours like `nvidia-system-extra`, which owns `docker-ce`, `git`,
`iperf` and `perftest`. Disabling the desktop target captures the memory without that risk.

### The autoremove trap (measured, not theoretical)

Removing the obvious-looking desktop apps reports a reassuringly small transaction — **19
packages, 11.8 MB freed** — and then the "automatically installed and no longer required" list
it prints contains things you did not consent to losing:

```
nvidia-update-manager    nvidia-plymouth    dgxstation-grub
dgxstation-desktop       nv-yaru-theme-all  samba
avahi-utils              kpartx-boot        vino
```

`nvidia-update-manager` is the platform firmware/OTA front-end. It appears only because the
bundle you removed was its last reverse dependency; running the suggested `apt autoremove`
takes it with it. On a box whose ConnectX-7 firmware is managed through LVFS/fwupd, that is a
bad trade for eleven megabytes.

The rule this establishes: **the removal plan is not the transaction.** Always read the
"no longer required" block as part of what you are approving, and treat any `nvidia-*`,
`dgx*`, `mlnx*`, `fwupd*`, `cuda*` or `linux-*` name appearing there as a reason to abort.
Disk space on these boxes is essentially never the binding constraint — RAM is. Debloat by
disabling units, not by removing packages.
