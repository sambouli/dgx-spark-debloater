# dgx-spark-debloater — lean inference-node baseline for the DGX Spark

Baseline system configuration applied to NVIDIA DGX Spark (GB10) boxes running large-model
LLM inference.

The goal is simple: on a 121 GiB **unified** memory pool, every resident daemon and
every page of swap is memory and latency taken away from the model. This repo records
exactly what was disabled, tuned and installed — so the setup is reproducible on a
fresh box instead of being re-derived by trial and error.

This is a **headless inference node**, not a workstation. Nothing here is a
recommendation for a desktop.

**Node count is irrelevant.** Every setting here is per-node and applies identically to a
single Spark or a rack of them. Nothing depends on how many nodes you have or how they are
wired together. The one place multi-node changes anything is *operational*, not
configurative: when ranks span machines, killing one rank aborts the job everywhere, so the
value of OOM protection shifts from "the job survives" to "the machine stays reachable so you
can read its logs." See [`oom-protection.md`](oom-protection.md).

## Contents

| File | What it covers |
|---|---|
| [`daemons.md`](daemons.md) | Every unit disabled or masked, with why |
| [`sysctl.md`](sysctl.md) | VM / network sysctls and the reasoning per value |
| [`limits-and-swap.md`](limits-and-swap.md) | memlock, nofile, swap policy |
| [`oom-protection.md`](oom-protection.md) | `earlyoom` + systemd slice: who dies when |
| [`setup.sh`](setup.sh) | Idempotent script applying all of the above |
| [`teardown.sh`](teardown.sh) | Reverses everything in `setup.sh` |

## Why each category matters

**Daemons.** ~85 units are disabled and 16 masked. Most are vendor cruft that costs
RAM and boot time and has no role in inference: cloud-init (four units), the DGX
out-of-box-experience wizards, NVSM telemetry, dashboard, CUPS, Bluetooth, ModemManager,
Samba, OpenVPN, iSCSI/multipath, VM tools, snap helpers. Masking (rather than merely
disabling) is used for units that a package or an update would otherwise re-enable.

**vm.\* sysctls.** The engine wants large, contiguous, *pinned* allocations. Background
compaction and fragmentation are the failure mode: an allocation that succeeds slowly is
worse than one that fails fast. Hence `compaction_proactiveness=0`, a large
`min_free_kbytes` watermark kept primed, and `swappiness=10`.

**Swap off.** Swapping a pinned GPU buffer is not slow, it is fatal — the driver holds
the page, the kernel thrashes around it, and the node becomes unreachable enough that
only a power cycle recovers it. Swap is disabled at the source rather than managed.

**OOM protection.** This is the highest-value item on the list. On a unified-memory box
the kernel OOM killer selects by size, and the largest process is usually `dockerd` or
`containerd` — killing those takes the whole machine down while you are locked out of
SSH. `earlyoom` inverts the policy: kill the *inference engine* first, never the
infrastructure. See [`oom-protection.md`](oom-protection.md).

**memlock unlimited.** RDMA queue pairs must be pinned; without `memlock unlimited` plus
`IPC_LOCK`, registration fails deep into startup with a confusing error. Set via
`limits.d`, and `--ulimit memlock=-1` in the container.

## Scope and honesty

- Applies to Ubuntu 24.04 LTS on arm64/GB10 with the NVIDIA driver stack. Values were
  chosen for a 121 GiB unified-memory single-GPU node; they are not generic tuning.
- `nvidia-system-station*`, `dgxstation-desktop`, `dgx-dashboard` and
  `nvidia-ai-workbench` are **left installed**. They are desktop bundles, not driver or
  firmware packages, and removing them drags in `apt` resolution risk near things like
  `nvidia-system-extra` (which owns `docker-ce`, `git`, `iperf`, `perftest`). Disabling
  the desktop at boot captures the memory without that risk.
- Deliberately **not** touched: the CX7 hot-plug udev handler
  (`/lib/udev/rules.d/90-mtk-hotplug.rules` → `/opt/nvidia/dgx-spark-mlnx-hotplug/`),
  `nvidia-spark-mlnx-firmware-manager`, `nvidia-container-toolkit`, the NVIDIA driver
  and firmware packages, `dgx-release`/`dgx-repo` (OTA/firmware updates), and every
  `nvidia-spark-*` tuning unit. Those are load-bearing.
- Network interface naming, IP addressing and netplan are intentionally absent — they
  belong to your fabric, not to this baseline.

## Usage

```bash
# review first, always
./setup.sh --dry-run

sudo ./setup.sh        # apply
sudo ./teardown.sh     # revert
```

Both scripts are idempotent and print what they change. Run `setup.sh` twice: the second
run should report nothing to do.

## Verifying

```bash
systemctl get-default                                  # multi-user.target
cat /sys/kernel/mm/transparent_hugepage/enabled        # always madvise [never]
swapon --show                                          # empty
systemctl is-active earlyoom                           # active
cat /proc/sys/vm/compaction_proactiveness              # 0
cat /proc/sys/vm/min_free_kbytes                       # 1048576
prlimit -p 1 --memlock 2>/dev/null || ulimit -l        # unlimited
```
