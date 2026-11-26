# OOM protection

The highest-value item in this repo. If you adopt only one thing, adopt this.

## The problem

On a GB10 the 121 GiB pool is **unified** — CPU and GPU allocate from the same RAM. A large
model engine legitimately runs near full capacity. So an OOM event is not a hypothetical; it
is a matter of when you load one model too many.

When the kernel OOM killer fires, its scoring function heavily favours **resident size**. The
biggest process on the box is your inference engine — which is exactly the process you would
*want* sacrificed. But the killer does not always pick it first, and the runner-up candidates
are `dockerd`, `containerd`, `sshd`. Killing the container daemon orphans every running
container; killing SSH leaves you staring at a machine you cannot log into while it thrashes.

Observed failure shape: you start a second container to test something. Twenty seconds later
SSH dies mid-command. `docker ps` never answers again. The box needs a power cycle.

## The fix: earlyoom

A tiny daemon that watches free memory and kills *your chosen victim* long before the kernel
gets involved.

`/etc/default/earlyoom` (replace `INFERENCE_ENGINE` with a regex matching your engine's
process name — see "choosing `--prefer`" below):

```sh
EARLYOOM_ARGS="-r 3600 -p -M 1048576,524288 -s 100,100 \
  --prefer ^INFERENCE_ENGINE \
  --avoid ^(systemd|sshd|dockerd|containerd|dbus-daemon|NetworkManager|gdm|Xorg|nvidia)"
```

| Flag | Meaning |
|---|---|
| `-M 1048576,524288` | Act when free RAM < **1 GiB**; consider the crisis over above **512 MiB** |
| `-s 100,100` | Same thresholds for free swap (inert with swap off, protective if it returns) |
| `--prefer ^INFERENCE_ENGINE` | Kill processes whose name matches this **first** |
| `--avoid ^(...)` | **Never** kill these, regardless of size |
| `-p` | Send `SIGTERM`, not `SIGKILL` — let the engine shut down cleanly and release pinned memory |
| `-r 3600` | Rate limit: at most one kill per hour, so it cannot cascade through your process table |

### Choosing `--prefer`

Match what actually appears in `ps`, not what you think the engine is called. Launch the
engine once and inspect — the process you care about often has a mangled name:

```bash
ps -eo comm,rss --sort=-rss | head -15
```

Common surprises: a Python engine shows up as `VLLM::EngineCor` (truncated at 15 chars) or
`vllm`, a rank process may be named after its role, and a launcher wrapper can exit while the
real worker survives. Anchor your regex to the *worker*, and prefer an anchor that survives
truncation (`^VLLM` rather than `^VLLM::EngineCore`).

Verify it is alive and configured as intended:

```bash
systemctl is-enabled earlyoom      # enabled
systemctl is-active  earlyoom      # active
ps -o args= -C earlyoom            # shows the live EARLYOOM_ARGS
journalctl -u earlyoom --since -1d # any past kills are logged here
```

### Why `--avoid` lists things that are already small

Because the point is not "kill the biggest" — it is "kill the *rightest*". Listing `systemd`,
`sshd`, `dockerd`, `containerd`, `dbus-daemon`, `NetworkManager` makes the policy explicit and
immune to those processes ever growing large (`dockerd` absolutely can). `gdm`/`Xorg` are listed
defensively even though the desktop is disabled, in case someone re-enables it.

## Second layer: a systemd slice with no swap

Even with swappiness tuned, a swapped-out engine page faulting back in during a decode step is
a latency cliff. Pinning the policy structurally is better than tuning it:

`/etc/systemd/system/inference.slice`:

```ini
[Unit]
Description=Inference rank containers (no swap)

[Slice]
MemorySwapMax=0
```

Launch ranks under it (`systemd-run --slice=... `, or the engine's own launcher), then confirm
the kernel really refuses to swap them:

```bash
cat /sys/fs/cgroup/system.slice/inference.slice/memory.swap.max   # 0
systemctl show <container>.service -p MemorySwapCurrent 2>/dev/null
```

`MemorySwapMax=0` means an OOM happens *inside the cgroup*, immediately and visibly, instead of
slowly across the whole machine. Fast and local beats slow and global.

## Third layer: make sure you get told

An OOM protection system that alerts nobody just changes which service died silently. Pipe the
kill events somewhere you actually look — the unit's journal, a webhook, a message to your
phone. Do not rely on noticing later.

## What this does NOT protect against

- **Hard freezes from driver-level deadlocks.** If the GPU driver wedges on a pinned-buffer
  conflict, no userspace daemon runs to save you. Keep `kernel.sysrq = 176` so SysRq still
  works, and accept that some failures need a power cycle.
- **Slow leaks.** earlyoom fires at 1 GiB free; a leak that takes three days to arrive will
  first show up as degraded performance. Watch KV-cache headroom over time separately.
- **Both nodes at once.** In a two-node tensor-parallel setup, earlyoom killing rank 1 aborts
  the job on rank 0 anyway. Its value there is keeping the *machine* reachable so you can read
  the logs — which is still worth a lot compared to a power cycle.
