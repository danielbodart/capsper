// src/platform/macos/output_duck.zig — not implemented here.
//
// Lowering the output while the trigger is held is Linux only today. The
// setting is accepted and does nothing, which is what a setting for a feature
// a platform lacks does everywhere else in capsper.

pub const OutputDuck = struct {
    pub fn init() !OutputDuck {
        return error.OutputDuckUnavailable;
    }

    pub fn deinit(_: *OutputDuck) void {}

    pub fn hold(_: *OutputDuck, _: f32) bool {
        return false;
    }

    pub fn release(_: *OutputDuck) void {}
};
