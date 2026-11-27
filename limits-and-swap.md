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

### Two mechanisms — writing only one is the classic silent failure

| File | Read by | Covers |
|---|---|---|
| `/etc/security/limits.d/*.conf` | `pam_limits` | **login sessions only** |
| `/etc/systemd/system/<svc>.service.d/*.conf` | systemd | **services** (dockerd, containerd) |

A container inherits the **daemon's** limits, and a systemd-started daemon never reads
`limits.d`. So `memlock unlimited` in `limits.d` looks configured, passes `ulimit -l` in your
SSH session, and does absolutely nothing for containers. This is the single most common way the
setting gets "applied" without ever taking effect. Set both:

```bash
# services -- what actually matters for RDMA from containers
systemctl show docker -p LimitMEMLOCK          # want: infinity
tr '\0' '\n' < /proc/$(pgrep -x dockerd)/limits | grep -i 'locked memory'
```

### The drop-in name is load-bearing — last writer wins

systemd merges drop-ins in **lexicographic order and the last writer of a key wins**. So a
high-sorting name does **not** override anything; it gets overridden. Platform images commonly
ship `docker.service.d/docker-override.conf` pinning `LimitMEMLOCK=8388608` (8 MiB), and because
`d` sorts after `9`, a file called `99-inference-node-limits.conf` loses to it — silently, while
`ls` shows your file sitting right there looking applied.

Measured on this platform, not inferred:

| file | value | effective |
|---|---|---|
| `docker-override.conf` | 111111 | **111111** |
| `99-inference-node-limits.conf` | 222222 | ← ignored |

This baseline therefore writes **`zz-inference-node-limits.conf`**, which sorts after the usual
vendor names (`docker-override.conf`, `10-*`, `50-*`, `99-*`). If you write your own, use a
low-sorting name and verify the *effective* value — never the file:

```bash
cat /etc/systemd/system/docker.service.d/*.conf   # see all contributors
systemctl show docker -p LimitMEMLOCK              # the only answer that counts
```

To check the precedence rule yourself on a harmless unit:

```bash
d=/etc/systemd/system/cron.service.d; mkdir -p $d
printf '[Service]\nLimitNOFILE=111111\n' > $d/docker-override.conf
printf '[Service]\nLimitNOFILE=222222\n' > $d/zz-test.conf
systemctl daemon-reload; systemctl show cron -p LimitNOFILE   # want 222222
rm -f $d/*; rmdir $d; systemctl daemon-reload
```

```bash
cat /etc/systemd/system/docker.service.d/*.conf   # see all contributors
systemctl show docker -p LimitMEMLOCK              # the one answer that counts
```

Then restart the daemon — `LimitMEMLOCK` is read at process start, so a reload alone leaves the
running daemon capped. Restarting docker stops running containers, so do it deliberately.

Also required on the container itself for memlock to be usable:

```
--cap-add IPC_LOCK --ulimit memlock=-1 --ulimit stack=67108864
```

Verify inside the container, not just on the host:

```bash
docker exec <name> sh -c 'ulimit -l'      # must say unlimited
```

Note the platform image may already ship `99-nv-spark-limits.conf` / `nv-limits.conf` in
`limits.d`. Those cover login sessions only — they do not exempt you from the systemd drop-in.

`nofile 500000`: parallel inference opens a lot of descriptors — one socket per peer per
channel, plus shard files, plus RDMA completion eventfds. The default 1024 is far too low and
produces `Too many open files` at a rank-count-dependent point, which makes it look like a
topology bug.

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
