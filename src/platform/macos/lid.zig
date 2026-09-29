// src/platform/macos/lid.zig — no lid to watch.
//
// The room latch is Linux-only (see `macos/input.zig`), so there is never a
// room session here for the lid to stop. This is the shape the room loop
// compiles against, and it always says there is no lid.

const std = @import("std");

pub const Lid = struct {
    fd: std.posix.fd_t,

    pub fn open() ?Lid {
        return null;
    }

    pub fn close(_: *Lid) void {}

    pub fn shut(_: *Lid) bool {
        return false;
    }
};
