// src/platform/linux/output_duck.zig — the speakers, turned down while the
// trigger is held.
//
// A thin handle over `pw_out_duck` in pw_helpers.c, which follows the
// desktop's default output and sets its level where the desktop sets it. Held
// open for the life of the process, because the press is when it is wanted and
// a PipeWire connection built on the press would land after the first word.

const pw = @import("pipewire_c.zig");

pub const OutputDuck = struct {
    handle: *pw.pw_out_duck,

    pub fn init() !OutputDuck {
        const handle = pw.pw_out_duck_create() orelse return error.OutputDuckUnavailable;
        return .{ .handle = handle };
    }

    /// Gives back a level still lowered, so a clean exit mid-hold does not
    /// leave the speakers down.
    pub fn deinit(self: *OutputDuck) void {
        pw.pw_out_duck_destroy(self.handle);
    }

    /// Lower the output to `factor` of its level, linear. False when there is
    /// no output to lower yet, which leaves it as it is.
    pub fn hold(self: *OutputDuck, factor: f32) bool {
        return pw.pw_out_duck_hold(self.handle, factor) == 0;
    }

    /// Back to the level it had when `hold` lowered it.
    pub fn release(self: *OutputDuck) void {
        pw.pw_out_duck_release(self.handle);
    }
};
