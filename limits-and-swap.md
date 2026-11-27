# Limits and swap

## memlock — the one that bites late

RDMA queue pairs and pinned GPU buffers must be lockable in physical memory. The default
`ulimit -l` is typically 64 KiB, which is enough to *start* an engine and not enough to
register real buffers — so you get a failure deep into startup, often after ten minutes of
weight loading, with an error that mentions neither limits nor memory.

`/etc/security/limits.d/99-inference-node.conf`:

```conf
*    soft   memlock   unlimited
*    hard   memlock   unlimited
*    soft   nofile    500000
*    hard   nofile    500000
```

Two things to know:

1. **`limits.d` does not reach containers by default.** A container inherits the *daemon's*
   limits unless overridden. So set it in three places: `limits.d` for login sessions,
   `--ulimit memlock=-1` on every `docker run`, and the systemd slice if you launch via
   systemd. Verify inside the container, not just on the host:
   ```bash
   docker exec <name> sh -c 'ulimit -l'      # must say unlimited
   ```
2. **The platform image already ships this** (`99-nv-spark-limits.conf`, `nv-limits.conf`).
   Our drop-in is redundant but harmless, and it survives a platform package change that
   drops theirs. Check before assuming:
   ```bash
   cat /etc/security/limits.d/*memlock* /etc/security/limits.d/*nofile* 2>/dev/null
   ulimit -l ; ulimit -n
   ```

`nofile 500000`: parallel inference opens a lot of descriptors — one socket per peer per
channel, plus shard files, plus RDMA completion eventfds. The default 1024 is far too low and
produces `Too many open files` at a rank-count-dependent point, which makes it look like a
topology bug.

Also required on the container for `memlock` to actually be usable:

```
--cap-add IPC_LOCK --ulimit memlock=-1 --ulimit stack=67108864
```

## Swap — off at the source

On a unified-memory GB10 there is no meaningful swap target: RAM is the only memory, and it is
already committed to the model. Swapping is not a slow path here, it is a fatal one. When the
kernel tries to page out a buffer the GPU driver holds pinned, the node enters a state where
SSH is unresponsive and only a power cycle recovers it.

So swap is removed rather than managed:

```bash
swapoff -a
rm -f /swap.img
sed -i -E 's|^([^#].*[[:space:]]swap[[:space:]].*)|# \1|' /etc/fstab
```

Verify — empty output is the pass condition:

```bash
swapon --show
cat /proc/swaps
grep -n swap /etc/fstab        # should show only commented lines
```

Notes:

- `/swap.img` on these images is ~17 GiB. Removing it also reclaims that disk.
- Do **not** confuse this with `vm.swappiness`. That governs *how* the kernel swaps; this
  removes the ability to. Both are set, deliberately.

## Transparent huge pages — off

THP sounds like a win for large allocations but for pinned, pre-faulted inference buffers it
causes stalls: khugepaged runs in the background collapsing pages while the engine is working,
and `madvise`-style THP interacts badly with some allocators.

```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

Made persistent with a small oneshot unit (`disable-thp.service`) rather than a sysctl, since
this knob is not exposed via sysctl.

Verify:

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled
# always madvise [never]
```

## Shared memory

Engines use POSIX shared memory between the API process and worker/rank processes. The default
`/dev/shm` is sized at half of RAM, which is usually fine, but Docker caps it at 64 MiB unless
you override. Two options, pick one and be consistent:

```
--shm-size=16g          # explicit, predictable
--ipc host              # simpler on a single-tenant box; shares host /dev/shm
```

Using neither is how you get "shared memory attach failed" from a worker that otherwise looks
healthy.
