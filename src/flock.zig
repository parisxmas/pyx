//! Thin wrapper around POSIX advisory byte-range locks (fcntl with
//! F_SETLK / F_SETLKW). Used by pyx for cross-process write
//! serialization — same primitive SQLite uses.
//!
//! POSIX semantics gotchas worth knowing:
//!   - Locks are per-process. Closing *any* fd to the file releases
//!     ALL of that process's locks on it. The Pager keeps exactly one
//!     fd to the data file; don't dup it casually.
//!   - Locks are advisory. Other code (or the kernel itself) won't
//!     stop unlocked writes; we trust pyx is the only writer.
//!   - Linux-extra: fcntl record locks coexist OK with `flock(2)` on
//!     modern kernels; we don't use `flock(2)` so no concern.

const std = @import("std");
const builtin = @import("builtin");

pub const LockType = enum { read, write, unlock };

pub const Region = struct {
    /// Byte offset from the start of the file.
    start: u64,
    /// Number of bytes; 0 means "to end of file".
    len: u64,
};

pub const Error = error{
    Conflict, // returned when a non-blocking lock would block
    FcntlFailed,
};

/// Block until the requested lock is acquired (or fail with FcntlFailed
/// on a system error). Implies `LockType.read` or `LockType.write`.
pub fn lock(fd: std.posix.fd_t, kind: LockType, region: Region) !void {
    _ = try setLock(fd, kind, region, true);
}

/// Try to acquire the lock without blocking. Returns false if another
/// process holds a conflicting lock; true on success.
pub fn tryLock(fd: std.posix.fd_t, kind: LockType, region: Region) !bool {
    return setLock(fd, kind, region, false);
}

/// Release any locks this process holds on the region.
pub fn unlock(fd: std.posix.fd_t, region: Region) !void {
    _ = try setLock(fd, .unlock, region, false);
}

fn setLock(
    fd: std.posix.fd_t,
    kind: LockType,
    region: Region,
    blocking: bool,
) !bool {
    const F = std.c.F;
    const lock_type: i16 = switch (kind) {
        .read => @intCast(F.RDLCK),
        .write => @intCast(F.WRLCK),
        .unlock => @intCast(F.UNLCK),
    };
    var fl: std.c.Flock = std.mem.zeroes(std.c.Flock);
    fl.type = lock_type;
    fl.whence = 0; // SEEK_SET
    fl.start = @intCast(region.start);
    fl.len = @intCast(region.len);

    const cmd: c_int = if (blocking) F.SETLKW else F.SETLK;
    const rc = std.c.fcntl(fd, cmd, &fl);
    if (rc < 0) {
        const err = std.posix.errno(rc);
        if (!blocking and (err == .AGAIN or err == .ACCES)) return false;
        return Error.FcntlFailed;
    }
    return true;
}

const testing = std.testing;

test "flock: write lock then unlock on a tmp file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var f = try tmp.dir.createFile(io, "lockme", .{ .read = true });
    defer f.close(io);

    const region: Region = .{ .start = 0, .len = 1 };
    try lock(f.handle, .write, region);
    try unlock(f.handle, region);
}

test "flock: tryLock succeeds on uncontended region" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var f = try tmp.dir.createFile(io, "lockme2", .{ .read = true });
    defer f.close(io);

    const region: Region = .{ .start = 0, .len = 1 };
    try testing.expect(try tryLock(f.handle, .write, region));
    try unlock(f.handle, region);
}
