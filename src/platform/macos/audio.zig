// src/audio_capture_macos.zig — Core Audio AUHAL capture (macOS)
//
// Captures microphone audio via AUHAL (Audio Unit HAL Output) and delivers
// S16_LE mono 16kHz PCM through a pipe fd, matching the PipeWire capture
// interface on Linux.
//
// AUHAL captures at the device's native sample rate (typically 48kHz) as
// mono S16 — it can do channel mixing and float→int conversion but NOT
// sample rate conversion. An AudioConverter then resamples to 16kHz using
// Apple's high-quality SRC (proper anti-aliasing filter).

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.audio_capture);

const ca = @cImport({
    @cInclude("AudioToolbox/AudioToolbox.h");
    @cInclude("CoreAudio/CoreAudio.h");
});

/// Shared state between main thread and CoreAudio callback thread.
/// Heap-allocated so the pointer remains stable for the unit's lifetime.
const CallbackData = struct {
    au_unit: ca.AudioComponentInstance,
    pipe_write_fd: posix.fd_t,
    gain: std.atomic.Value(f32),
    converter: ca.AudioConverterRef,
    /// Pre-allocated buffer for AudioUnitRender at device rate (S16 mono).
    render_buf: [max_render_frames * 2]u8 = undefined,
    /// Pre-allocated buffer for converter output at 16kHz (S16 mono).
    output_buf: [max_output_frames * 2]u8 = undefined,

    // Device may deliver up to 4096 frames per callback at 48kHz.
    const max_render_frames = 4096;
    // After SRC: 4096 * (16000/48000) ≈ 1366 frames. Over-allocate for safety.
    const max_output_frames = 2048;
};

pub const AudioCapture = struct {
    au_unit: ca.AudioComponentInstance,
    callback_data: *CallbackData,
    device_id: ca.AudioDeviceID,
    converter: ca.AudioConverterRef,
    pipe_read_fd: posix.fd_t,
    pipe_write_fd: posix.fd_t,
    active: bool,
    has_hardware_gain: bool,

    /// Default channel: 0 = first/mono channel on macOS (zero-indexed).
    pub const default_channel: u32 = 0;

    pub fn init(target: ?[:0]const u8, _channel_position: u32) !AudioCapture {
        _ = _channel_position; // Channel selection deferred — mono only for now

        // Microphone permission is handled automatically by macOS:
        // hardened runtime + com.apple.security.device.audio-input entitlement
        // causes TCC to prompt when CoreAudio accesses the input device.
        // No explicit requestAccessForMediaType: call needed.

        // Create pipe for passing PCM from CoreAudio thread to main thread
        const pipe_fds = try posix.pipe();
        const pipe_read = pipe_fds[0];
        const pipe_write = pipe_fds[1];
        errdefer {
            posix.close(pipe_read);
            posix.close(pipe_write);
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
            if (!findDeviceByName(t, &device_id)) {
                log.err("Input device not found: {s}", .{t});
                return error.AudioInitFailed;
            }
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

        // Get device's native sample rate
        var native_rate: ca.Float64 = 0;
        var rate_size: ca.UInt32 = @sizeOf(ca.Float64);
        var rate_addr = ca.AudioObjectPropertyAddress{
            .mSelector = ca.kAudioDevicePropertyNominalSampleRate,
            .mScope = ca.kAudioObjectPropertyScopeGlobal,
            .mElement = ca.kAudioObjectPropertyElementMain,
        };
        if (ca.AudioObjectGetPropertyData(device_id, &rate_addr, 0, null, &rate_size, @ptrCast(&native_rate)) != ca.noErr) {
            log.err("Failed to get device sample rate", .{});
            return error.AudioInitFailed;
        }

        // Set AUHAL output format: device native rate, mono, S16.
        // AUHAL can do channel mixing (stereo→mono) and float→int, but NOT SRC.
        // We handle SRC separately via AudioConverter.
        var device_format = makePcmFormat(native_rate, 1);
        if (ca.AudioUnitSetProperty(au_unit, ca.kAudioUnitProperty_StreamFormat, ca.kAudioUnitScope_Output, 1, &device_format, @sizeOf(ca.AudioStreamBasicDescription)) != ca.noErr) {
            log.err("Failed to set capture format", .{});
            return error.AudioInitFailed;
        }

        // Create AudioConverter for sample rate conversion: native rate → 16kHz.
        // Uses Apple's high-quality resampler with proper anti-aliasing.
        var output_format = makePcmFormat(16000.0, 1);
        var converter: ca.AudioConverterRef = undefined;
        const needs_src = native_rate != 16000.0;
        if (needs_src) {
            if (ca.AudioConverterNew(&device_format, &output_format, &converter) != ca.noErr) {
                log.err("Failed to create sample rate converter ({d}Hz → 16kHz)", .{native_rate});
                return error.AudioInitFailed;
            }
            // Set highest quality SRC
            var quality: ca.UInt32 = ca.kAudioConverterQuality_Max;
            _ = ca.AudioConverterSetProperty(converter, ca.kAudioConverterSampleRateConverterQuality, @sizeOf(ca.UInt32), &quality);
            log.info("Sample rate conversion: {d}Hz → 16kHz (quality=max)", .{native_rate});
        }

        // Allocate callback data on heap (stable pointer for unit lifetime)
        const callback_data = try std.heap.page_allocator.create(CallbackData);
        callback_data.* = .{
            .au_unit = au_unit,
            .pipe_write_fd = pipe_write,
            .gain = std.atomic.Value(f32).init(1.0),
            .converter = if (needs_src) converter else null,
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

        // Initialize (allocates internal resources)
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
            .converter = if (needs_src) converter else null,
            .pipe_read_fd = pipe_read,
            .pipe_write_fd = pipe_write,
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
        if (self.converter) |conv| _ = ca.AudioConverterDispose(conv);
        posix.close(self.pipe_read_fd);
        if (self.callback_data.pipe_write_fd != -1) {
            posix.close(self.pipe_write_fd);
        }
        std.heap.page_allocator.destroy(self.callback_data);
    }

    /// Parse channel name to zero-based channel index.
    pub fn parseChannelName(name: []const u8) ?u32 {
        if (std.ascii.eqlIgnoreCase(name, "MONO")) return 0;
        if (std.ascii.eqlIgnoreCase(name, "FL")) return 0;
        if (std.ascii.eqlIgnoreCase(name, "FR")) return 1;
        if (name.len >= 4 and std.ascii.eqlIgnoreCase(name[0..3], "AUX")) {
            return std.fmt.parseInt(u32, name[3..], 10) catch return null;
        }
        return null;
    }
};

/// Build a mono S16 packed PCM format descriptor at the given sample rate.
fn makePcmFormat(rate: f64, channels: u32) ca.AudioStreamBasicDescription {
    return .{
        .mSampleRate = rate,
        .mFormatID = ca.kAudioFormatLinearPCM,
        .mFormatFlags = ca.kAudioFormatFlagIsSignedInteger | ca.kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 2 * channels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 2 * channels,
        .mChannelsPerFrame = channels,
        .mBitsPerChannel = 16,
    };
}

/// Find an audio device by name.
fn findDeviceByName(name: [:0]const u8, result: *ca.AudioDeviceID) bool {
    var size: ca.UInt32 = 0;
    var addr = ca.AudioObjectPropertyAddress{
        .mSelector = ca.kAudioHardwarePropertyDevices,
        .mScope = ca.kAudioObjectPropertyScopeGlobal,
        .mElement = ca.kAudioObjectPropertyElementMain,
    };
    if (ca.AudioObjectGetPropertyDataSize(ca.kAudioObjectSystemObject, &addr, 0, null, &size) != ca.noErr) return false;
    const count = size / @sizeOf(ca.AudioDeviceID);
    if (count == 0 or count > 64) return false;

    var devices: [64]ca.AudioDeviceID = undefined;
    if (ca.AudioObjectGetPropertyData(ca.kAudioObjectSystemObject, &addr, 0, null, &size, @ptrCast(&devices)) != ca.noErr) return false;

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
                    result.* = devices[i];
                    ca.CFRelease(@ptrCast(name_ref));
                    return true;
                }
            }
            ca.CFRelease(@ptrCast(name_ref));
        }
    }
    return false;
}

/// State passed to the AudioConverter data supplier callback.
/// Points at the current render buffer so the converter can pull input data.
const ConverterContext = struct {
    data: [*]u8,
    byte_count: u32,
    consumed: bool,
};

/// AudioConverter data supplier — called by FillComplexBuffer to get input data.
/// Simply points at the render buffer from the current AUHAL callback. Called once
/// per FillComplexBuffer invocation since we provide all input in a single chunk.
fn converterSupplier(
    _: ca.AudioConverterRef,
    io_number_data_packets: [*c]ca.UInt32,
    io_data: [*c]ca.AudioBufferList,
    _: [*c][*c]ca.AudioStreamPacketDescription,
    in_user_data: ?*anyopaque,
) callconv(.c) ca.OSStatus {
    const ctx: *ConverterContext = @ptrCast(@alignCast(in_user_data orelse return -50));
    if (ctx.consumed) {
        // No more data — signal end of input
        io_number_data_packets.* = 0;
        return ca.noErr;
    }
    io_number_data_packets.* = ctx.byte_count / 2; // S16 mono: 1 frame = 2 bytes = 1 packet
    io_data.*.mBuffers[0].mData = ctx.data;
    io_data.*.mBuffers[0].mDataByteSize = ctx.byte_count;
    io_data.*.mBuffers[0].mNumberChannels = 1;
    ctx.consumed = true;
    return ca.noErr;
}

/// CoreAudio input callback — runs on a real-time I/O thread.
/// Pulls audio via AudioUnitRender at device native rate, converts to 16kHz
/// via AudioConverter (FillComplexBuffer with proper SRC), applies gain,
/// and writes S16_LE PCM to the pipe.
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
    const frames: u32 = @min(in_number_frames, CallbackData.max_render_frames);
    const render_bytes = frames * 2; // S16 mono = 2 bytes per frame

    // Set up AudioBufferList pointing to our pre-allocated render buffer
    var buf_list = ca.AudioBufferList{
        .mNumberBuffers = 1,
        .mBuffers = [1]ca.AudioBuffer{.{
            .mNumberChannels = 1,
            .mDataByteSize = render_bytes,
            .mData = &data.render_buf,
        }},
    };

    // Pull audio from AUHAL at device native rate, mono S16
    const render_result = ca.AudioUnitRender(
        data.au_unit,
        io_action_flags,
        in_time_stamp,
        in_bus_number,
        frames,
        &buf_list,
    );
    if (render_result != ca.noErr) {
        // Log first error only to avoid spamming
        const count = struct {
            var n: u32 = 0;
        };
        if (count.n == 0) log.warn("AudioUnitRender error: {d}", .{render_result});
        count.n += 1;
        return ca.noErr;
    }

    const rendered_bytes = buf_list.mBuffers[0].mDataByteSize;
    if (rendered_bytes == 0) return ca.noErr;

    // Apply software gain before SRC (if hardware gain unavailable)
    const gain = data.gain.load(.monotonic);
    if (gain > 1.01) {
        const samples: [*]i16 = @ptrCast(@alignCast(&data.render_buf));
        const sample_count = rendered_bytes / 2;
        for (0..sample_count) |i| {
            const amplified: i32 = @as(i32, samples[i]) * @as(i32, @intFromFloat(gain));
            samples[i] = @intCast(std.math.clamp(amplified, -32768, 32767));
        }
    }

    if (data.converter) |conv| {
        // Sample rate conversion via AudioConverterFillComplexBuffer.
        // The supplier callback points at our render buffer.
        var ctx = ConverterContext{
            .data = &data.render_buf,
            .byte_count = rendered_bytes,
            .consumed = false,
        };

        // Estimate output frames: input_frames * (16000 / device_rate) + 1
        var output_frames: ca.UInt32 = frames / 3 + 1; // 48kHz→16kHz = 3:1
        if (output_frames > CallbackData.max_output_frames)
            output_frames = CallbackData.max_output_frames;

        var out_list = ca.AudioBufferList{
            .mNumberBuffers = 1,
            .mBuffers = [1]ca.AudioBuffer{.{
                .mNumberChannels = 1,
                .mDataByteSize = output_frames * 2,
                .mData = &data.output_buf,
            }},
        };

        const conv_result = ca.AudioConverterFillComplexBuffer(
            conv,
            converterSupplier,
            &ctx,
            &output_frames,
            &out_list,
            null,
        );
        if (conv_result != ca.noErr and conv_result != 100) return ca.noErr; // 100 = underflow (OK at end)

        const output_bytes = out_list.mBuffers[0].mDataByteSize;
        if (output_bytes > 0) {
            _ = posix.write(data.pipe_write_fd, data.output_buf[0..output_bytes]) catch {};
        }
    } else {
        // No SRC needed — device is already at 16kHz
        _ = posix.write(data.pipe_write_fd, data.render_buf[0..rendered_bytes]) catch {};
    }

    return ca.noErr;
}
