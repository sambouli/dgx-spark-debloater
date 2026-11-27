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
wired together — interface naming, IP addressing and fabric configuration are deliberately
out of scope, since they belong to your network rather than to this baseline.

## Contents

| File | What it covers |
|---|---|
| [`daemons.md`](daemons.md) | Every unit disabled or masked, with why |
| [`sysctl.md`](sysctl.md) | VM / network sysctls and the reasoning per value |
| [`limits-and-swap.md`](limits-and-swap.md) | memlock, nofile, swap policy, THP |
| [`setup.sh`](setup.sh) | Idempotent script applying all of the above |
| [`teardown.sh`](teardown.sh) | Reverses everything in `setup.sh` |

Out of scope on purpose: monitoring and alerting, model serving, and anything
engine-specific. OOM policy is available but **opt-in and off by default** — see below.

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

## Optional: earlyoom (off by default)

OOM policy is **not** part of the baseline. It kills processes, and the correct victim depends
entirely on what you serve — so unlike everything else here, it is a deployment decision rather
than a debloating one. Enable it explicitly:

```bash
# find out what your engine's process is REALLY called before trusting any default
docker exec <container> ps -eo comm,rss --sort=-rss | head

sudo WITH_EARLYOOM=1 ./setup.sh                                   # shipped default
sudo WITH_EARLYOOM=1 EARLYOOM_PREFER='sglang' ./setup.sh          # your own
```

### Scope of the shipped default

It is `'^VLLM|^vllm|llama-server|^ollama'` — verified against live containers, covering
**vLLM, llama.cpp and Ollama**. It is deliberately narrow, and it is **not** a general-purpose
inference pattern. Servers such as SGLang, TensorRT-LLM, Triton or TGI will not match it; pass
`EARLYOOM_PREFER` for those.

Two reasons for the narrowness:

- A pattern that matches nothing is worse than no earlyoom at all (see the guard below), so a
  broad guess-the-name default would be actively harmful.
- The obvious widening — adding `python3` — is a trap. Most Python inference servers *also* show
  a `python3` process, so matching it would let earlyoom kill unrelated host Python: monitoring,
  cron jobs, your own shells. Match the worker's real name, never the interpreter.

`^VLLM` is anchored on the truncated form on purpose: `comm` cuts off at 15 characters, so
`VLLM::EngineCore` appears as `VLLM::EngineCor`.

### Why it exists

On a unified-memory box the kernel OOM killer scores candidates by resident size, so the largest
process — usually your inference engine — is the prime candidate, with `dockerd` and `sshd` next.
Killing the container daemon orphans every running container; killing SSH leaves you locked out
of a machine that still needs a power cycle. `earlyoom` watches free memory and kills a process
*you* designate, before the kernel gets involved.

### The liveness guard, and why it exists

A `--prefer` pattern that matches nothing is **worse than not installing earlyoom**: it looks like
protection and silently degrades to kill-the-largest-process. This is by far the most common way
the feature gets misconfigured — an engine gets renamed or restructured, the pattern goes stale,
and nobody notices until the OOM killer takes `dockerd` anyway.

So `setup.sh` runs `pgrep -f "$EARLYOOM_PREFER"` and refuses to install if it matches zero running
processes, printing the commands to find the real name. If your engine legitimately isn't started
yet on that node, pass `EARLYOOM_ALLOW_NO_MATCH=1` to proceed.

The trap this catches: `comm` is truncated at **15 characters**, so `VLLM::EngineCore` appears as
`VLLM::EngineCor`. A pattern anchored on the long form matches nothing forever, and every other
aspect of the setup still looks correct. Verify after enabling:

```bash
systemctl is-active earlyoom       # active
ps -o args= -C earlyoom            # shows the live EARLYOOM_ARGS
journalctl -u earlyoom --since -1d # past kills are logged here
```

The shipped policy: act under 1 GiB free, `SIGTERM` not `SIGKILL` (so pinned memory is released
cleanly), rate-limited to one kill per hour, and `--avoid` on `systemd`, `sshd`, `dockerd`,
`containerd`, `dbus-daemon`, `NetworkManager`, `gdm`, `Xorg`, `nvidia`.

If the workload spans processes or nodes, match **every** worker rather than one role — killing a
single rank aborts the job everywhere anyway, so a partial teardown buys nothing.

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
cat /proc/sys/vm/compaction_proactiveness              # 0
cat /proc/sys/vm/min_free_kbytes                       # 1048576
prlimit -p 1 --memlock 2>/dev/null || ulimit -l        # unlimited
```
