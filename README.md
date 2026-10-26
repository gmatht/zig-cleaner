# zig-cache-prune

Prune the Zig global cache to a byte ceiling — **8 GiB by default** — by
deleting the least-recently-accessed files first (atime, falling back to
mtime when the filesystem reports no atime). Designed to run before the
gates and tests that compile zig, so `~/.cache/zig` never grows without
bound.

Extracted from the [sh2loop](https://github.com/gmatht/sh2loop) test-harness
workspace, where it runs before every zig-compiling gate.

## Files

| File | Role |
|---|---|
| `zig-cache-prune.zig` | The cleaner itself (std-only, self-contained). |
| `zig-cache-prune.sh` | Wrapper for gates/tests: best-effort, locking, self-building, **always exits 0**. |
| `zig-cache-prune` | Compiled binary — *not* in git; the wrapper builds it on first use. |

## Usage

Direct:

```
zig-cache-prune [-n|--dry-run] [--limit BYTES] [CACHE_DIR]
```

- `CACHE_DIR` defaults to `$XDG_CACHE_HOME/zig`, else `$HOME/.cache/zig`.
- `--limit BYTES` defaults to `8589934592` (8 GiB).
- `-n` prints what *would* be deleted without touching anything.
- Exit 0 on success/no-op; exit 2 on CLI errors (bad flag, bad `--limit`).

Through the wrapper (what gates call):

```
./zig-cache-prune.sh [zig-cache-prune args...]
```

The wrapper:

1. **Compile guard** — if `pgrep -x zig` finds a compile in flight, it skips
   with `a zig compile is in flight — skipping`. Zig has already validated
   its manifest by that point and is about to open outputs we might delete.
2. **Lock** — `flock -n` on `.zig-cache-prune.lock`: only one pruner runs;
   a second caller reports `held by another gate — skipping` and returns.
3. **Self-build** — compiles `zig-cache-prune` on first use, and rebuilds
   when the `.zig` source is newer than the binary (installed atomically
   via `.tmp.$$` + `mv`).
4. **Report** — echoes the cleaner's output to **stderr** prefixed with
   `zig-cache-prune: `, so gate logs are auditable for "the cleaner ran"
   without ever colliding with a gate's stdout protocol.
5. **Never fails its caller** — every path (missing zig, build failure,
   non-zero cleaner exit, lock held) prints a tagged line and exits 0.
   A maintenance step must not read as a test failure.

## Hooking it into your gates

Call the wrapper as the **first action** of anything that compiles zig, and
let it fail open:

```sh
"$ROOT/zig-cache-prune.sh" || true
```

Conditional forms when only some targets compile zig:

```sh
if [ "$lang" = zig ]; then "$ROOT/zig-cache-prune.sh" || true; fi
case " ${TARGETS[*]} " in *" zig "*) "$ROOT/zig-cache-prune.sh" || true ;; esac
```

In sh2loop this hook is wired into six places — the `--backend-gate zig`
entry of `setup_backends.sh`, `harness/corpus-c.sh`,
`harness/frontend-stdout.sh`, `harness/lint.sh`, `zig-baseline.sh`, and
`frontend-js-gate.sh` — each `|| true`, each `bash -n` clean. The backend
gate is the main consumer: it compiles every corpus file with `zig run`,
which is what grows the cache past 8 GiB between runs.

## Design

### The prune policy

1. **Scan** the cache tree (skipping `tmp/` at depth 1 — in-flight build
   artifacts that Zig manages itself), recording every regular file's size
   and atime. Symlinks and special files are never followed or deleted.
   An unreadable subtree is skipped with a warning, not fatal.
2. **Under the limit** → print `under limit, nothing to prune` and stop.
   This is the common case once an earlier run has done the heavy lifting.
3. Sort candidates **oldest atime first** and delete until the total fits
   under the limit. Two mutually exclusive strategies:

   - **Manifests alone suffice** (`total - manifest_bytes <= limit`): delete
     only the oldest `h/*` manifests. No output is touched, so every
     surviving manifest still has its outputs — a dangling hit is
     impossible.
   - **Outputs must be deleted**: then **no manifest may survive the run**
     (see below): wipe `h/` → delete oldest outputs → wipe `h/` a second
     time to catch a manifest a concurrent compile wrote mid-run.
4. Remove emptied directories deepest-first (`DirNotEmpty` ignored — they
   still hold live files).

### Why `h/` manifests get special treatment

`h/<input_digest>` is a **cache manifest** (`std.Build.Cache`,
`manifest_dir`). On a cache *hit*, Zig recomputes the output directory name
(`o/<hit_hash>`) from digests held **in memory in the manifest** — the
mapping is not stored anywhere on disk and cannot be recovered by us. So:

- **Delete an output but keep its manifest** → the next compile is a cache
  "hit" that opens a directory which no longer exists and dies with
  `failed to parse archive: FileNotFound`. This was observed for real after
  an early 4 GiB prune; it is why the manifest-wipe rules exist.
- **Delete a manifest** → always safe: a plain cache miss, Zig just
  recompiles.

Hence the invariant: **no manifest outlives its outputs.** A run that can
get under the ceiling from manifests alone never touches outputs; a run that
deletes outputs invalidates *every* manifest, twice, around the output pass.

### Why atime

atime is the natural LRU signal for a build cache. On a `relatime` mount
(the default almost everywhere) atime advances at most once per file per
day — coarse, but directionally correct: files touched by recent builds
rank newer than cold ones. `mtime` is the fallback when atime is
unavailable.

### Safety properties

- Depth-1 roots (`o/`, `h/`, `z/`, `b/`) are **never removed, only
  emptied** — Zig opens them by handle at startup.
- Unlinking a file a concurrent build has open is safe on Linux, and the
  content-addressed cache rebuilds on a miss; the wrapper's `pgrep` guard
  and `flock` cover the narrower case (a compile that has validated its
  manifest but not yet opened its outputs).
- Best-effort end to end: warnings print, deletions tolerate races
  (`FileNotFound` → skip), and the wrapper never propagates failure.

## Output / auditing a gate run

Every line is tagged `zig-cache-prune:` on **stderr**. A real prune:

```
zig-cache-prune: /root/.cache/zig
zig-cache-prune:   scanned 1916 files, 12.23 GiB (13122775755 bytes)
zig-cache-prune:   pruned 1119 files, 4.23 GiB freed (oldest atime first)
zig-cache-prune:   of which 3 cache manifests invalidated — no manifest outlives its outputs
zig-cache-prune:   remaining 7.99 GiB (limit 8.00 GiB)
```

Other normal messages:

```
zig-cache-prune:   limit 8.00 GiB — under limit, nothing to prune
zig-cache-prune: a zig compile is in flight — skipping
zig-cache-prune: held by another gate — skipping
```

**Check that the cleaner ran** for a given gate:

```sh
grep -F 'zig-cache-prune:' <gate-log>
```

It must appear as the gate's first action (the hook precedes the build and
corpus run). Any of the four messages above — prune, under-limit no-op,
in-flight skip, lock skip — counts as "it ran"; only an *absent* line means
it did not.

## Manual examples

```sh
# Dry run against the real cache
./zig-cache-prune.sh -n

# Prune a scratch cache to 1 GiB
./zig-cache-prune.sh --limit 1073741824 /tmp/fake-zig-cache

# Rebuild the binary after editing the source (or just let the wrapper do it)
zig build-exe zig-cache-prune.zig -OReleaseSafe -femit-bin=zig-cache-prune
```

## Field results

On the sh2loop workload the cache repeatedly regrew to ~12–13 GiB between
gates; fresh gate runs captured a real prune each time (e.g. 12.78 GiB →
7.99 GiB, 477 files, oldest-atime-first, 4 manifests invalidated), an
under-limit no-op once a prior run had done the work, and the in-flight
guard correctly skipping while a concurrent `zig run` was compiling. None
of it ever changed a gate verdict.

## License

[MIT](LICENSE)
