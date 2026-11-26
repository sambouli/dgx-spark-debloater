# sysctl settings

Applied as `/etc/sysctl.d/99-inference-node.conf`, loaded with `sysctl --system`.

The premise: a large-model engine on a GB10 makes **big, contiguous, pinned** allocations
(weights, KV cache, RDMA registration buffers). Two kernel behaviours fight that — background
compaction and swapping. The values below suppress both and keep a reserve of free pages
permanently primed so a big allocation does not have to wait for reclaim.

```conf
vm.swappiness = 10
vm.compaction_proactiveness = 0
vm.extfrag_threshold = 500
vm.min_free_kbytes = 1048576
vm.watermark_scale_factor = 25
```

## Per-value reasoning

### `vm.swappiness = 10`

Not `0`. `0` historically meant "do not swap anonymous pages unless absolutely necessary",
which on a box with no swap is moot anyway; `10` keeps the pageout heuristic strongly biased
toward dropping the **page cache** instead of touching anonymous memory. Page cache here is
model shards being streamed at load time — cheap to re-read from NVMe, expensive if it is a
process's heap.

Combined with swap being off entirely (see `limits-and-swap.md`), this is belt-and-braces:
if swap ever returns (an admin re-enables it), the node still will not thrash.

### `vm.compaction_proactiveness = 0`

**The single most valuable setting.** The proactive compaction kthread wakes periodically and
migrates pages to defragment zones. For normal workloads that helps. Here it means a background
thread rearranging memory *while the engine is allocating tens of gigabytes*, which shows up as
unexplained multi-second stalls during startup and occasionally mid-run.

Setting it to `0` disables proactive compaction. Direct compaction — triggered synchronously by
an allocation that genuinely needs high-order pages — still works, which is what we want: pay
for defragmentation when it is actually needed, never speculatively.

### `vm.min_free_kbytes = 1048576`

1 GiB of free pages kept permanently reserved above the watermark. Without it, the free pool
drifts near zero under load and any large allocation must first wake kswapd and wait on reclaim
— latency spikes that look like model-engine bugs but are allocator behaviour.

1 GiB is roughly 1% of the 121 GiB pool. Sized for high-order (multi-MB contiguous) requests
plus RDMA buffer registration arriving in bursts. If you add more RAM, scale it proportionally
rather than raising it arbitrarily — too large and you simply waste RAM.

### `vm.watermark_scale_factor = 25`

How far above `min` kswapd starts waking, in 1/100ths of a percent of managed pages. Default is
usually 10. Doubling it to 25 makes reclaim start earlier and more gradually, so the free pool
is refilled *before* an allocation hits the low watermark — trading a little constant background
work for removing tail latency at the moment of allocation. Pairs with `min_free_kbytes`.

### `vm.extfrag_threshold = 500`

How much external fragmentation the kernel tolerates before direct compaction gives up and
chooses reclaim instead. Default 500; keeping it explicit documents intent — we want the kernel
to *try* to satisfy a large contiguous request rather than bail early into slow reclaim. Raise
toward 1000 only if you see compaction failures in `vmstat`'s `compact_fail`.

## Verifying

```bash
sysctl vm.swappiness vm.compaction_proactiveness vm.extfrag_threshold \
       vm.min_free_kbytes vm.watermark_scale_factor

# compaction activity should be near-idle once the engine is warm:
grep -E 'compact_|allocstall' /proc/vmstat
```

## Not changed, and why

These exist in the stock image and were left alone deliberately — they are either security
settings or already correct:

| Setting | Value | Note |
|---|---|---|
| `vm.max_map_count` | 1048576 | Already raised in the platform image; engines need many mmaps |
| `vm.mmap_min_addr` | 32768 | Hardening floor, leave it |
| `kernel.kptr_restrict` | 1 | Address-hiding, keep |
| `kernel.yama.ptrace_scope` | 1 | Keep unless your debugger needs cross-process attach |
| `kernel.sysrq` | 176 | **Keep.** On a box prone to hard freezes, SysRq is how you get a crash dump instead of holding the power button |
| `kernel.panic` / `kernel.panic_on_oops` | 10 / 1 | Auto-reboot on panic — right answer for a headless node |
| `net.ipv4.*.rp_filter` | 2 (loose) | Do **not** set strict mode: asymmetric RoCE/multi-interface routing gets dropped |
| `net.core.default_qdisc` | fq_codel | Leave alone; do not swap in BBR blindly on an RDMA-adjacent host |
| `net.ipv4.*.arp_ignore` / `arp_announce` | 1 / 2 | Platform-provided, tuned for multi-homed hosts |

## Things people try that hurt here

- **Disabling NUMA balancing via sysctl.** It is done through the platform's own unit
  (`nvidia-disable-numa-balancing`) and the kernel cmdline, not a sysctl. Duplicating it in
  sysctl creates drift between two sources of truth.
- **`vm.dirty_ratio` heroics.** Streaming 100 GB of weights looks like an I/O tuning problem.
  It usually isn't — the loader is CPU/decompression bound. Measure before touching.
- **Turning off `kernel.sysrq`** "for security". You lose the only graceful response when a
  pinned-buffer deadlock freezes the box.
