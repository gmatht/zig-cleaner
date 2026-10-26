#!/usr/bin/env bash
# zig-cache-prune.sh — run the zig cache cleaner before gates and tests that
# compile zig, so ~/.cache/zig never exceeds 8 GiB (oldest atime first; see
# zig-cache-prune.zig).
#
# Contract: BEST-EFFORT, ALWAYS EXITS 0.
#   - A cleaner failure must never turn a gate red — the gate's own verdict
#     decides, not a maintenance step (retriable infrastructure must not read
#     as a test failure).
#   - pgrep guard: skip while a zig compile is in flight (zig has already
#     validated its manifest and is about to open outputs we might delete).
#   - flock -n: if another gate is already pruning, skip (no queueing).
#   - Builds zig-cache-prune from source on first use / when stale.
#   - Output goes to stderr with a zig-cache-prune: prefix so gates can be
#     audited for "the cleaner ran" (grep for 'zig-cache-prune:') without it
#     ever colliding with a gate's stdout protocol.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/zig-cache-prune"
SRC="$DIR/zig-cache-prune.zig"
LOCK="$DIR/.zig-cache-prune.lock"

case "${1:-}" in
  -h|--help)
    echo "usage: zig-cache-prune.sh [zig-cache-prune args...]" >&2
    echo "  (wrapper for zig-cache-prune.zig; always exits 0)" >&2
    exit 0
    ;;
esac

# Never prune while a compile is in flight. The hook runs before a gate's
# own compiles, so this only catches other gates/workers running in parallel.
if command -v pgrep >/dev/null 2>&1 && pgrep -x zig >/dev/null 2>&1; then
  echo "zig-cache-prune: a zig compile is in flight — skipping" >&2
  exit 0
fi

# One pruner at a time; if someone holds the lock, they are already pruning.
# NB: no `2>/dev/null` on this exec — exec redirections persist for the whole
# script, which would silence every later report line.
exec 9>"$LOCK" || exit 0
if ! flock -n 9; then
  echo "zig-cache-prune: held by another gate — skipping" >&2
  exit 0
fi

# Build on demand; rebuild when the source is newer than the binary.
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  if ! command -v zig >/dev/null 2>&1; then
    echo "zig-cache-prune: zig not on PATH — skipping" >&2
    exit 0
  fi
  if ! tmp_out=$(zig build-exe "$SRC" -OReleaseSafe -femit-bin="$BIN.tmp.$$" 2>&1); then
    echo "zig-cache-prune: build failed — skipping" >&2
    rm -f "$BIN.tmp.$$"
    exit 0
  fi
  mv -f "$BIN.tmp.$$" "$BIN" || { echo "zig-cache-prune: install failed — skipping" >&2; exit 0; }
fi

out=$("$BIN" "$@" 2>&1)
rc=$?
if [ $rc -ne 0 ]; then
  printf 'zig-cache-prune: exited %d (ignored) — %s\n' "$rc" "$(printf '%s' "$out" | head -3 | tr '\n' '|')" >&2
  exit 0
fi
# Echo the cleaner's own report, tagged, to stderr: proof-of-run in gate logs.
printf '%s\n' "$out" | sed 's/^/zig-cache-prune: /' >&2
exit 0
