// src/audio_capture_macos.zig — Core Audio AUHAL capture (macOS)
//
// Captures microphone audio via AUHAL (Audio Unit HAL Output) and delivers
// S16_LE mono 16kHz PCM through a pipe fd, matching the PipeWire capture
// interface on Linux. AUHAL's internal AudioConverter handles sample rate
// conversion from the device's native rate (typically 48kHz) to 16kHz.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.audio_capture);

const ca = @cImport({
    @cInclude("AudioToolbox/AudioToolbox.h");
    @cInclude("CoreAudio/CoreAudio.h");
});

// Objective-C helper for microphone permission (mic_permission_macos.m)
extern fn capsper_mic_permission_status() c_int;
extern fn capsper_mic_request_permission() c_int;

/// Shared state between main thread and CoreAudio callback thread.
/// Heap-allocated so the pointer remains stable for the unit's lifetime.
const CallbackData = struct {
    au_unit: ca.AudioComponentInstance,
    pipe_write_fd: posix.fd_t,
    gain: std.atomic.Value(f32),
    /// Ratio for integer decimation (e.g. 3 for 48kHz→16kHz). 1 = no SRC.
    src_ratio: u32,
    /// Pre-allocated buffer for AudioUnitRender at device rate (S16 mono).
    render_buf: [max_render_frames * 2]u8 = undefined,
    /// Pre-allocated buffer for decimated output at 16kHz (S16 mono).
    output_buf: [max_output_frames * 2]u8 = undefined,

    // Device may deliver up to 4096 frames per callback at 48kHz.
    const max_render_frames = 4096;
    // After 3:1 decimation: 4096/3 ≈ 1366 frames.
    const max_output_frames = max_render_frames;
};

pub const AudioCapture = struct {
    au_unit: ca.AudioComponentInstance,
    callback_data: *CallbackData,
    device_id: ca.AudioDeviceID,
    pipe_read_fd: posix.fd_t,
    pipe_write_fd: posix.fd_t,
    active: bool,
    has_hardware_gain: bool,

    /// Default channel: 0 = first/mono channel on macOS (zero-indexed).
    pub const default_channel: u32 = 0;

    pub fn init(target: ?[:0]const u8, _channel_position: u32) !AudioCapture {
        _ = _channel_position; // Channel selection deferred — mono only for now

        // Check and request microphone permission before anything else.
        // CoreAudio silently delivers zero samples without permission.
        // Skip for virtual devices (e.g. BlackHole) which don't need mic permission.
        if (target == null) {
            const mic_status = capsper_mic_permission_status();
            if (mic_status == 0) {
                log.info("Requesting microphone permission...", .{});
                if (capsper_mic_request_permission() == 0) {
                    log.err("Microphone permission denied.", .{});
                    log.err("Grant access in: System Settings → Privacy & Security → Microphone", .{});
                    return error.AudioInitFailed;
                }
            } else if (mic_status == 2) {
                log.err("Microphone permission denied.", .{});
                log.err("Grant access in: System Settings → Privacy & Security → Microphone", .{});
                return error.AudioInitFailed;
            } else if (mic_status == 1) {
                log.err("Microphone access is restricted by system policy.", .{});
                return error.AudioInitFailed;
            }
        }

        // Create pipe for passing PCM from CoreAudio thread to main thread
        const pipe_fds = try posix.pipe();
        errdefer {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
        }

        // Find AUHAL audio unit
        var desc = ca.AudioComponentDescription{
            .componentType = ca.kAudioUnitType_Output,
            .componentSubType = ca.kAudioUnitSubType_HALOutput,
            .componentManufacturer = ca.kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };
        const component = ca.AudioComponentFindNext(null, &desc) orelse {
            log.err("Failed to find AUHAL audio component", .{});
            return error.AudioInitFailed;
        };

        var au_unit: ca.AudioComponentInstance = undefined;
        if (ca.AudioComponentInstanceNew(component, &au_unit) != ca.noErr) {
            log.err("Failed to create AUHAL instance", .{});
            return error.AudioInitFailed;
        }
        errdefer _ = ca.AudioComponentInstanceDispose(au_unit);

        // Enable input on bus 1
        var enable_io: ca.UInt32 = 1;
        if (ca.AudioUnitSetProperty(au_unit, ca.kAudioOutputUnitProperty_EnableIO, ca.kAudioUnitScope_Input, 1, &enable_io, @sizeOf(ca.UInt32)) != ca.noErr) {
            log.err("Failed to enable input IO", .{});
            return error.AudioInitFailed;
        }

        // Disable output on bus 0 (input-only)
        var disable_io: ca.UInt32 = 0;
        if (ca.AudioUnitSetProperty(au_unit, ca.kAudioOutputUnitProperty_EnableIO, ca.kAudioUnitScope_Output, 0, &disable_io, @sizeOf(ca.UInt32)) != ca.noErr) {
            log.err("Failed to disable output IO", .{});
            return error.AudioInitFailed;
        }

        // Find input device — by name if target specified, otherwise system default
        var device_id: ca.AudioDeviceID = ca.kAudioObjectUnknown;
        if (target) |t| {
            device_id = findDeviceByName(t) orelse {
                log.err("Input device not found: {s}", .{t});
                return error.AudioInitFailed;
            };
        } else {
            var device_size: ca.UInt32 = @sizeOf(ca.AudioDeviceID);
            var device_addr = ca.AudioObjectPropertyAddress{
                .mSelector = ca.kAudioHardwarePropertyDefaultInputDevice,
                .mScope = ca.kAudioObjectPropertyScopeGlobal,
                .mElement = ca.kAudioObjectPropertyElementMain,
            };
            if (ca.AudioObjectGetPropertyData(ca.kAudioObjectSystemObject, &device_addr, 0, null, &device_size, @ptrCast(&device_id)) != ca.noErr) {
                log.err("Failed to get default input device", .{});
                return error.AudioInitFailed;
            }
        }
        if (device_id == ca.kAudioObjectUnknown) {
            log.err("No input device available. Microphone permission may be needed.", .{});
            log.err("Grant access in: System Settings → Privacy & Security → Microphone", .{});
            return error.AudioInitFailed;
        }

        if (ca.AudioUnitSetProperty(au_unit, ca.kAudioOutputUnitProperty_CurrentDevice, ca.kAudioUnitScope_Global, 0, &device_id, @sizeOf(ca.AudioDeviceID)) != ca.noErr) {
            log.err("Failed to set input device on AUHAL", .{});
            return error.AudioInitFailed;
        }

        // Log device name
        var name_ref: ca.CFStringRef = undefined;
        var name_size: ca.UInt32 = @sizeOf(ca.CFStringRef);
        var name_addr = ca.AudioObjectPropertyAddress{
            .mSelector = ca.kAudioObjectPropertyName,
            .mScope = ca.kAudioObjectPropertyScopeGlobal,
            .mElement = ca.kAudioObjectPropertyElementMain,
        };
        if (ca.AudioObjectGetPropertyData(device_id, &name_addr, 0, null, &name_size, @ptrCast(&name_ref)) == ca.noErr) {
            var name_buf: [256]u8 = undefined;
            if (ca.CFStringGetCString(name_ref, &name_buf, name_buf.len, ca.kCFStringEncodingUTF8) != 0) {
                log.info("Input device: {s}", .{std.mem.sliceTo(&name_buf, 0)});
            }
            ca.CFRelease(@ptrCast(name_ref));
        }

        // Set desired output format: 16kHz mono S16_LE on output scope, bus 1.
        // AUHAL's internal AudioConverter handles resampling from device native rate.
        var format = ca.AudioStreamBasicDescription{
            .mSampleRate = 16000.0,
            .mFormatID = ca.kAudioFormatLinearPCM,
            .mFormatFlags = ca.kAudioFormatFlagIsSignedInteger | ca.kAudioFormatFlagIsPacked,
            .mBytesPerPacket = 2,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 2,
            .mChannelsPerFrame = 1,
            .mBitsPerChannel = 16,
        };
        if (ca.AudioUnitSetProperty(au_unit, ca.kAudioUnitProperty_StreamFormat, ca.kAudioUnitScope_Output, 1, &format, @sizeOf(ca.AudioStreamBasicDescription)) != ca.noErr) {
            log.err("Failed to set 16kHz mono S16 format", .{});
            return error.AudioInitFailed;
        }

        // Allocate callback data on heap (stable pointer for unit lifetime)
        const callback_data = try std.heap.page_allocator.create(CallbackData);
        callback_data.* = .{
            .au_unit = au_unit,
            .pipe_write_fd = pipe_fds[1],
            .gain = std.atomic.Value(f32).init(1.0),
        };
        errdefer std.heap.page_allocator.destroy(callback_data);

        // Register input callback
        var cb = ca.AURenderCallbackStruct{
            .inputProc = onCapture,
            .inputProcRefCon = callback_data,
        };
        if (ca.AudioUnitSetProperty(au_unit, ca.kAudioOutputUnitProperty_SetInputCallback, ca.kAudioUnitScope_Global, 0, &cb, @sizeOf(ca.AURenderCallbackStruct)) != ca.noErr) {
            log.err("Failed to set input callback", .{});
            return error.AudioInitFailed;
        }

        // Initialize (allocates internal resources, creates internal converter)
        const init_result = ca.AudioUnitInitialize(au_unit);
        if (init_result != ca.noErr) {
            log.err("Failed to initialize AUHAL (error {d}). Microphone permission may be denied.", .{init_result});
            log.err("Grant microphone access in: System Settings → Privacy & Security → Microphone", .{});
            return error.AudioInitFailed;
        }

        // Check if hardware input gain is available
        var gain_addr = ca.AudioObjectPropertyAddress{
            .mSelector = ca.kAudioDevicePropertyVolumeScalar,
            .mScope = ca.kAudioObjectPropertyScopeInput,
            .mElement = 0,
        };
        const has_hw_gain = ca.AudioObjectHasProperty(device_id, &gain_addr) != 0;
        if (has_hw_gain) {
            log.info("CoreAudio capture ready (16kHz mono S16, hardware gain available)", .{});
        } else {
            log.info("CoreAudio capture ready (16kHz mono S16, software gain only)", .{});
        }

        return .{
            .au_unit = au_unit,
            .callback_data = callback_data,
            .device_id = device_id,
            .pipe_read_fd = pipe_fds[0],
            .pipe_write_fd = pipe_fds[1],
            .active = false,
            .has_hardware_gain = has_hw_gain,
        };
    }

    /// Start or stop audio capture. Maps to AudioOutputUnitStart/Stop.
    /// On macOS, start/stop is fast (sub-millisecond) — no connect/disconnect
    /// overhead like PipeWire, so this handles both normal and low-latency modes.
    pub fn setActive(self: *AudioCapture, active: bool) void {
        if (active and !self.active) {
            if (ca.AudioOutputUnitStart(self.au_unit) != ca.noErr) {
                log.err("Failed to start audio capture", .{});
                return;
            }
            self.active = true;
            log.info("Audio capture started", .{});
        } else if (!active and self.active) {
            if (ca.AudioOutputUnitStop(self.au_unit) != ca.noErr) {
                log.err("Failed to stop audio capture", .{});
                return;
            }
            self.active = false;
        }
    }

    /// Cork/uncork — on macOS, start/stop is already fast, so this is
    /// identical to setActive. The --low-latency flag is a no-op on macOS.
    pub fn setCork(self: *AudioCapture, corked: bool) void {
        self.setActive(!corked);
    }

    /// Set input gain. Prefers hardware gain via CoreAudio device volume
    /// (kAudioDevicePropertyVolumeScalar on input scope). Falls back to
    /// software gain in the capture callback if hardware is unavailable.
    ///
    /// gain is a linear multiplier: 1.0 = unity, 10.0 = +20 dB.
    pub fn setGain(self: *AudioCapture, gain: f32) void {
        // Always store for software fallback
        self.callback_data.gain.store(gain, .monotonic);

        if (!self.has_hardware_gain) return;

        // Convert linear gain to dB: dB = 20 * log10(gain)
        const gain_db: f32 = 20.0 * @log10(gain);

        // Use the device's dB-to-scalar conversion for accurate mapping.
        // This accounts for the device's actual dB range and transfer function.
        var scalar: ca.Float32 = gain_db;
        var scalar_size: ca.UInt32 = @sizeOf(ca.Float32);
        var convert_addr = ca.AudioObjectPropertyAddress{
            .mSelector = ca.kAudioDevicePropertyVolumeDecibelsToScalar,
            .mScope = ca.kAudioObjectPropertyScopeInput,
            .mElement = 0,
        };
        if (ca.AudioObjectGetPropertyData(self.device_id, &convert_addr, 0, null, &scalar_size, @ptrCast(&scalar)) != ca.noErr) {
            // Conversion failed — fall back to linear approximation (0-1 scalar ≈ linear)
            scalar = std.math.clamp(gain / 10.0, 0.0, 1.0);
        }

        var set_addr = ca.AudioObjectPropertyAddress{
            .mSelector = ca.kAudioDevicePropertyVolumeScalar,
            .mScope = ca.kAudioObjectPropertyScopeInput,
            .mElement = 0,
        };
        if (ca.AudioObjectSetPropertyData(self.device_id, &set_addr, 0, null, @sizeOf(ca.Float32), @ptrCast(&scalar)) == ca.noErr) {
            // Hardware gain applied — disable software gain so we don't double-amplify
            self.callback_data.gain.store(1.0, .monotonic);
        }
    }

    pub fn getFd(self: *const AudioCapture) posix.fd_t {
        return self.pipe_read_fd;
    }

    pub fn deinit(self: *AudioCapture) void {
        if (self.active) {
            _ = ca.AudioOutputUnitStop(self.au_unit);
        }
        _ = ca.AudioUnitUninitialize(self.au_unit);
        _ = ca.AudioComponentInstanceDispose(self.au_unit);
        posix.close(self.pipe_read_fd);
        if (self.callback_data.pipe_write_fd != -1) {
            posix.close(self.pipe_write_fd);
        }
        std.heap.page_allocator.destroy(self.callback_data);
    }

    /// Parse channel name to zero-based channel index.
    /// macOS uses simple integer indices, not SPA position constants.
    pub fn parseChannelName(name: []const u8) ?u32 {
        if (std.ascii.eqlIgnoreCase(name, "MONO")) return 0;
        if (std.ascii.eqlIgnoreCase(name, "FL")) return 0;
        if (std.ascii.eqlIgnoreCase(name, "FR")) return 1;
        // Parse AUXn → channel index n
        if (name.len >= 4 and std.ascii.eqlIgnoreCase(name[0..3], "AUX")) {
            return std.fmt.parseInt(u32, name[3..], 10) catch return null;
        }
        return null;
    }
};

/// Find an audio device by name. Searches all devices with input channels.
fn findDeviceByName(name: [:0]const u8) ?ca.AudioDeviceID {
    var size: ca.UInt32 = 0;
    var addr = ca.AudioObjectPropertyAddress{
        .mSelector = ca.kAudioHardwarePropertyDevices,
        .mScope = ca.kAudioObjectPropertyScopeGlobal,
        .mElement = ca.kAudioObjectPropertyElementMain,
    };
    if (ca.AudioObjectGetPropertyDataSize(ca.kAudioObjectSystemObject, &addr, 0, null, &size) != ca.noErr) return null;
    const count = size / @sizeOf(ca.AudioDeviceID);
    if (count == 0) return null;

    var devices: [64]ca.AudioDeviceID = undefined;
    if (count > 64) return null;
    if (ca.AudioObjectGetPropertyData(ca.kAudioObjectSystemObject, &addr, 0, null, &size, @ptrCast(&devices)) != ca.noErr) return null;

    for (0..count) |i| {
        var name_ref: ca.CFStringRef = undefined;
        var name_size: ca.UInt32 = @sizeOf(ca.CFStringRef);
        var name_addr = ca.AudioObjectPropertyAddress{
            .mSelector = ca.kAudioObjectPropertyName,
            .mScope = ca.kAudioObjectPropertyScopeGlobal,
            .mElement = ca.kAudioObjectPropertyElementMain,
        };
        if (ca.AudioObjectGetPropertyData(devices[i], &name_addr, 0, null, &name_size, @ptrCast(&name_ref)) == ca.noErr) {
            var name_buf: [256]u8 = undefined;
            if (ca.CFStringGetCString(name_ref, &name_buf, name_buf.len, ca.kCFStringEncodingUTF8) != 0) {
                const dev_name = std.mem.sliceTo(&name_buf, 0);
                if (std.mem.eql(u8, dev_name, name)) {
                    ca.CFRelease(@ptrCast(name_ref));
                    return devices[i];
                }
            }
            ca.CFRelease(@ptrCast(name_ref));
        }
    }
    return null;
}

/// CoreAudio input callback — runs on a real-time I/O thread.
/// Pulls audio via AudioUnitRender and writes S16_LE PCM to the pipe.
fn onCapture(
    in_ref_con: ?*anyopaque,
    io_action_flags: [*c]ca.AudioUnitRenderActionFlags,
    in_time_stamp: [*c]const ca.AudioTimeStamp,
    in_bus_number: ca.UInt32,
    in_number_frames: ca.UInt32,
    _: [*c]ca.AudioBufferList, // NULL for input — must call AudioUnitRender
) callconv(.c) ca.OSStatus {
    const data: *CallbackData = @ptrCast(@alignCast(in_ref_con orelse return ca.noErr));
    if (data.pipe_write_fd == -1) return ca.noErr;

    // Clamp frames to our buffer size
    const frames: u32 = @min(in_number_frames, CallbackData.max_frames_per_callback);
    const byte_count = frames * 2; // S16 = 2 bytes per frame

    // Set up AudioBufferList pointing to our pre-allocated buffer
    var buf_list = ca.AudioBufferList{
        .mNumberBuffers = 1,
        .mBuffers = [1]ca.AudioBuffer{.{
            .mNumberChannels = 1,
            .mDataByteSize = byte_count,
            .mData = &data.render_buf,
        }},
    };

    // Pull audio from the AUHAL — fills buf_list with S16_LE PCM
    const render_result = ca.AudioUnitRender(
        data.au_unit,
        io_action_flags,
        in_time_stamp,
        in_bus_number,
        frames,
        &buf_list,
    );
    if (render_result != ca.noErr) return ca.noErr; // skip this callback on error

    const actual_bytes = buf_list.mBuffers[0].mDataByteSize;
    if (actual_bytes == 0) return ca.noErr;

    // Apply software gain if > 1.0 (hardware gain is preferred but may not be available)
    const gain = data.gain.load(.monotonic);
    if (gain > 1.01) {
        const samples: [*]i16 = @ptrCast(@alignCast(&data.render_buf));
        const sample_count = actual_bytes / 2;
        for (0..sample_count) |i| {
            const amplified: i32 = @as(i32, samples[i]) * @as(i32, @intFromFloat(gain));
            samples[i] = @intCast(std.math.clamp(amplified, -32768, 32767));
        }
    }

    // Write to pipe — non-blocking best-effort (same as PipeWire's onProcess)
    _ = posix.write(data.pipe_write_fd, data.render_buf[0..actual_bytes]) catch {};

    return ca.noErr;
}
