//! zig-cache-prune — prune the Zig global cache to a byte ceiling by
//! deleting the least-recently-accessed files first (atime, falling back
//! to mtime when the filesystem reports no atime).
//!
//! Manifest safety (why `h/` is special):
//!  - `h/<input_digest>` is a cache manifest (std.Build.Cache: manifest_dir).
//!    On a hit Zig RECOMPUTES the output dir name (`o/<hit_hash>`) from the
//!    manifest's in-memory digests — it is not stored anywhere on disk and
//!    cannot be recovered from the manifest by us. If we delete the output
//!    but leave the manifest, the next compile is a cache "hit" that opens a
//!    directory which no longer exists and dies with
//!    `failed to parse archive: FileNotFound` (observed after a big prune).
//!  - Deleting a manifest, by contrast, is always safe: plain cache miss.
//!  So: whenever outputs are pruned, EVERY manifest is wiped in the same run
//!  (before and after the output pass, to catch concurrent compiles). A run
//!  that stays under the limit, or one that can get under the limit from
//!  manifests alone, never touches outputs.
//!
//! Usage: zig-cache-prune [-n|--dry-run] [--limit BYTES] [CACHE_DIR]
//!
//! CACHE_DIR defaults to $XDG_CACHE_HOME/zig, else $HOME/.cache/zig.
//! The limit defaults to 8 GiB (8589934592 bytes).
//!
//! Notes:
//!  - atime is the LRU signal. On this box `/` is mounted `relatime`, so
//!    atime advances at most once per file per day — coarse but
//!    directionally correct for a build cache.
//!  - `tmp/` (depth-1) is skipped: it holds in-flight build artifacts and
//!    Zig cleans it itself.
//!  - Depth-1 directories (`o/`, `h/`, `z/`, `b/`) are never removed, only
//!    emptied: Zig opens them by handle at startup.
//!  - Symlinks are never followed and never deleted.
//!  - Unlinking a file a concurrent build has open is safe on Linux, and
//!    Zig's content-addressed cache rebuilds on a miss.

const std = @import("std");
const Io = std.Io;

const default_limit: u64 = 8 * 1024 * 1024 * 1024;

const FileRec = struct {
    path: []const u8, // relative to the cache root, arena-owned
    size: u64,
    atime_ns: i96,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_out = &stderr_writer.interface;

    // ---- CLI ----
    var dry_run = false;
    var limit: u64 = default_limit;
    var cache_dir_arg: ?[]const u8 = null;

    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.skip(); // argv[0]
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(out);
            try out.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const v = arg_it.next() orelse {
                try err_out.print("zig-cache-prune: --limit needs a byte count\n", .{});
                try err_out.flush();
                std.process.exit(2);
            };
            limit = std.fmt.parseInt(u64, v, 10) catch {
                try err_out.print("zig-cache-prune: bad --limit '{s}'\n", .{v});
                try err_out.flush();
                std.process.exit(2);
            };
        } else if (arg.len > 0 and arg[0] == '-') {
            try err_out.print("zig-cache-prune: unknown flag '{s}'\n", .{arg});
            try err_out.flush();
            try printUsage(err_out);
            try err_out.flush();
            std.process.exit(2);
        } else if (cache_dir_arg == null) {
            cache_dir_arg = arg;
        } else {
            try err_out.print("zig-cache-prune: unexpected extra argument '{s}'\n", .{arg});
            try err_out.flush();
            std.process.exit(2);
        }
    }

    // Arena, not gpa: gpa leak-checks in Debug/ReleaseSafe and this string
    // lives for the whole run.
    const cache_dir: []const u8 = cache_dir_arg orelse blk: {
        const dir_alloc = init.arena.allocator();
        if (init.environ_map.get("XDG_CACHE_HOME")) |xdg| {
            if (xdg.len > 0) break :blk try std.fmt.allocPrint(dir_alloc, "{s}/zig", .{xdg});
        }
        if (init.environ_map.get("HOME")) |home| {
            break :blk try std.fmt.allocPrint(dir_alloc, "{s}/.cache/zig", .{home});
        }
        try err_out.print("zig-cache-prune: neither XDG_CACHE_HOME nor HOME is set; pass the cache dir\n", .{});
        try err_out.flush();
        std.process.exit(2);
    };

    // ---- scan ----
    var root = Io.Dir.cwd().openDir(io, cache_dir, .{ .iterate = true }) catch |scan_err| {
        switch (scan_err) {
            error.FileNotFound => {
                try out.print("zig-cache-prune: no cache at {s}; nothing to prune\n", .{cache_dir});
                try out.flush();
                return;
            },
            else => {
                try err_out.print("zig-cache-prune: cannot open {s}: {s}\n", .{ cache_dir, @errorName(scan_err) });
                try err_out.flush();
                return scan_err;
            },
        }
    };
    defer root.close(io);

    const alloc = init.arena.allocator();
    var files: std.ArrayList(FileRec) = .empty; // prunable outputs
    var manifests: std.ArrayList(FileRec) = .empty; // h/*: see header
    var dirs: std.ArrayList([]const u8) = .empty;
    var total: u64 = 0;
    var file_count: u64 = 0;

    var walker = try root.walkSelectively(alloc);
    defer walker.deinit();

    walk_loop: while (true) {
        const entry = walker.next(io) catch |walk_err| {
            // The walker pops the failing directory, so continuing makes
            // progress; an unreadable subtree is skipped, not fatal.
            try out.print("zig-cache-prune: warning: {s} while scanning; skipping subtree\n", .{@errorName(walk_err)});
            continue :walk_loop;
        } orelse break;

        switch (entry.kind) {
            .directory => {
                // `tmp/` holds in-flight build artifacts; Zig manages it.
                if (entry.depth() == 1 and std.mem.eql(u8, entry.basename, "tmp")) continue;
                // Depth-1 roots (o/, h/, z/, b/) are never removed, only
                // emptied deeper dirs: Zig opens them by handle at startup.
                if (entry.depth() > 1) try dirs.append(alloc, try alloc.dupe(u8, entry.path));
                try walker.enter(io, entry);
            },
            .file => {
                const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
                if (st.kind != .file) continue; // symlinks etc: never touched
                const atime_ns: i96 = if (st.atime) |t| t.nanoseconds else st.mtime.nanoseconds;
                const rec = FileRec{
                    .path = try alloc.dupe(u8, entry.path),
                    .size = st.size,
                    .atime_ns = atime_ns,
                };
                if (isManifestPath(entry.path)) {
                    try manifests.append(alloc, rec);
                } else {
                    try files.append(alloc, rec);
                }
                total += st.size;
                file_count += 1;
            },
            else => continue, // symlinks and specials: never followed, never deleted
        }
    }

    // ---- report + prune ----
    var total_buf: [32]u8 = undefined;
    var limit_buf: [32]u8 = undefined;
    try out.print("zig-cache-prune: {s}\n", .{cache_dir});
    try out.print("  scanned {d} files, {s} ({d} bytes)\n", .{ file_count, fmtSize(&total_buf, total), total });

    if (total <= limit) {
        try out.print("  limit {s} — under limit, nothing to prune\n", .{fmtSize(&limit_buf, limit)});
        try out.flush();
        return;
    }

    // Oldest atime first.
    const lessFn = struct {
        fn less(_: void, a: FileRec, b: FileRec) bool {
            return a.atime_ns < b.atime_ns;
        }
    }.less;
    std.sort.pdq(FileRec, files.items, {}, lessFn);
    std.sort.pdq(FileRec, manifests.items, {}, lessFn);

    var man_total: u64 = 0;
    for (manifests.items) |m| man_total += m.size;

    var remaining = total;
    var freed: u64 = 0;
    var pruned: u64 = 0;
    var mpruned: u64 = 0;
    var mfreed: u64 = 0;

    if (total - man_total <= limit) {
        // Manifests alone can get us under the ceiling: delete only the
        // oldest manifests. No output is touched, so every manifest we KEEP
        // still has its outputs — a dangling hit is impossible.
        for (manifests.items) |f| {
            if (remaining <= limit) break;
            if (!dry_run) {
                root.deleteFile(io, f.path) catch |del_err| switch (del_err) {
                    error.FileNotFound => continue, // raced with another cleaner
                    else => {
                        try out.print("  warning: could not delete {s}: {s}\n", .{ f.path, @errorName(del_err) });
                        continue;
                    },
                };
            }
            remaining -= f.size;
            mfreed += f.size;
            mpruned += 1;
        }
    } else {
        // Outputs must be deleted, so NO manifest may survive this run:
        // Zig recomputes an output's path from the manifest's in-memory
        // digests, so a live manifest whose output we deleted makes the next
        // compile a "hit" that opens a directory which no longer exists —
        // `failed to parse archive: FileNotFound` (seen for real after a
        // 4 GiB prune). A deleted manifest, by contrast, is a plain miss.
        // 1) wipe the manifests that existed at scan time...
        const first = try wipeManifestDir(io, &root, alloc, dry_run);
        mpruned += first.count;
        mfreed += first.bytes;
        remaining -= first.bytes;
        // 2) ...then the outputs, oldest atime first...
        for (files.items) |f| {
            if (remaining <= limit) break;
            if (dry_run) {
                remaining -= f.size;
                freed += f.size;
                pruned += 1;
                continue;
            }
            root.deleteFile(io, f.path) catch |del_err| switch (del_err) {
                error.FileNotFound => continue, // raced with another cleaner
                else => {
                    try out.print("  warning: could not delete {s}: {s}\n", .{ f.path, @errorName(del_err) });
                    continue;
                },
            };
            remaining -= f.size;
            freed += f.size;
            pruned += 1;
        }
        // 3) ...and sweep manifests once more, for one a concurrent compile
        //    wrote while we were deleting (dry-run: step 1 already counted
        //    everything that is there now).
        if (!dry_run) {
            const second = try wipeManifestDir(io, &root, alloc, false);
            mpruned += second.count;
            mfreed += second.bytes;
            remaining -= second.bytes;
        }
    }

    // Remove emptied directories, deepest first. Non-empty ones fail with
    // DirNotEmpty, which is exactly what we want to ignore.
    if (!dry_run) {
        std.sort.pdq([]const u8, dirs.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.countScalar(u8, a, Io.Dir.path.sep) > std.mem.countScalar(u8, b, Io.Dir.path.sep);
            }
        }.less);
        for (dirs.items) |d| {
            root.deleteDir(io, d) catch {};
        }
    }

    var freed_buf: [32]u8 = undefined;
    var remain_buf: [32]u8 = undefined;
    var mbuf: [32]u8 = undefined;
    try out.print("  {s}pruned {d} files, {s} freed (oldest atime first)\n", .{ if (dry_run) "(dry-run) " else "", pruned + mpruned, fmtSize(&freed_buf, freed + mfreed) });
    if (mpruned > 0) {
        try out.print("  of which {d} cache manifests ({s}) invalidated — no manifest outlives its outputs (zig misses and recompiles)\n", .{ mpruned, fmtSize(&mbuf, mfreed) });
    }
    try out.print("  remaining {s} (limit {s})\n", .{ fmtSize(&remain_buf, remaining), fmtSize(&limit_buf, limit) });
    try out.flush();
}

/// `h/<digest>` files are cache manifests (`std.Build.Cache` manifest_dir).
fn isManifestPath(rel: []const u8) bool {
    return rel.len > 2 and rel[0] == 'h' and rel[1] == Io.Dir.path.sep;
}

const WipeResult = struct { count: u64 = 0, bytes: u64 = 0 };

/// Delete every regular file directly under `h/` (or, with `dry_run`, just
/// count them). Only `h/` is descended into; the directory itself is left in
/// place — Zig holds manifest_dir by handle at startup.
fn wipeManifestDir(io: Io, root: *Io.Dir, alloc: std.mem.Allocator, dry_run: bool) !WipeResult {
    var res: WipeResult = .{};
    var walker = try root.walkSelectively(alloc);
    defer walker.deinit();
    walk_loop: while (true) {
        const entry = walker.next(io) catch {
            continue :walk_loop; // unreadable subtree: skip, not fatal
        } orelse break;
        switch (entry.kind) {
            .directory => {
                if (entry.depth() == 1 and std.mem.eql(u8, entry.basename, "h")) {
                    try walker.enter(io, entry);
                }
            },
            .file => {
                if (!isManifestPath(entry.path)) continue;
                const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
                if (st.kind != .file) continue;
                res.count += 1;
                res.bytes += st.size;
                if (dry_run) continue;
                root.deleteFile(io, entry.path) catch continue;
            },
            else => {},
        }
    }
    return res;
}

fn printUsage(out: *Io.Writer) !void {
    try out.print(
        \\usage: zig-cache-prune [-n|--dry-run] [--limit BYTES] [CACHE_DIR]
        \\
        \\Prune the Zig global cache to at most BYTES (default 8589934592 =
        \\8 GiB), deleting the least-recently-accessed files first (atime;
        \\mtime when atime is unavailable). CACHE_DIR defaults to
        \\$XDG_CACHE_HOME/zig, else $HOME/.cache/zig. `tmp/` and symlinks
        \\are left alone, and whenever outputs are pruned every cache
        \\manifest in `h/` is invalidated in the same run so no manifest
        \\can outlive the outputs it points at.
        \\
    , .{});
}

fn fmtSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) : (unit += 1) {
        value /= 1024.0;
    }
    if (unit == 0) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d:.2} {s}", .{ value, units[unit] }) catch unreachable;
}
