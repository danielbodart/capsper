// input_helpers_macos.c — CoreGraphics helpers for macOS keyboard input
//
// Provides CGEventTap creation/management and CGEventPost text injection.
// Called from input_macos.zig. These APIs use CoreFoundation types and
// run loop integration that are simpler to handle in C.

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ──── Callback context ──────────────────────────────────────────────────────

typedef struct {
    CGKeyCode trigger_keycode;  // The remapped key (e.g. F19 = 0x50 = 80)
    void (*on_press)(void);
    void (*on_release)(void);
    CFMachPortRef tap;
    CFRunLoopRef run_loop;
    volatile int shutdown;
} InputContext;

static InputContext *g_ctx = NULL;

// ──── CGEventTap callback ───────────────────────────────────────────────────

static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type,
                               CGEventRef event, void *refcon) {
    (void)proxy;
    InputContext *ctx = (InputContext *)refcon;

    // Handle tap being disabled by the system watchdog
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(ctx->tap, true);
        return event;
    }

    // Only intercept keyDown and keyUp
    if (type != kCGEventKeyDown && type != kCGEventKeyUp) return event;

    CGKeyCode keycode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (keycode != ctx->trigger_keycode) return event;

    // Trigger key — signal PTT state and swallow the event
    if (type == kCGEventKeyDown) {
        // Ignore key repeat (autorepeat flag)
        if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) return NULL;
        if (ctx->on_press) ctx->on_press();
    } else {
        if (ctx->on_release) ctx->on_release();
    }
    return NULL;  // Swallow the event
}

// ──── Public API ────────────────────────────────────────────────────────────

// Create and install a CGEventTap for the trigger key.
// Returns 0 on success, -1 on failure.
int capsper_input_create_tap(int trigger_keycode,
                              void (*on_press)(void),
                              void (*on_release)(void)) {
    if (g_ctx) return -1;  // Already created

    g_ctx = calloc(1, sizeof(InputContext));
    if (!g_ctx) return -1;

    g_ctx->trigger_keycode = (CGKeyCode)trigger_keycode;
    g_ctx->on_press = on_press;
    g_ctx->on_release = on_release;

    // Check accessibility permission
    if (!AXIsProcessTrusted()) {
        fprintf(stderr, "error(input): Accessibility permission required.\n");
        fprintf(stderr, "error(input): Grant in: System Settings → Privacy & Security → Accessibility\n");
        // Don't fail — the tap will silently not work, but we'll detect it
    }

    CGEventMask mask = (1 << kCGEventKeyDown) | (1 << kCGEventKeyUp);
    g_ctx->tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,  // Active tap — can suppress events
        mask,
        tapCallback,
        g_ctx
    );

    if (!g_ctx->tap) {
        fprintf(stderr, "error(input): Failed to create CGEventTap.\n");
        fprintf(stderr, "error(input): Accessibility permission must be granted.\n");
        free(g_ctx);
        g_ctx = NULL;
        return -1;
    }

    return 0;
}

// Run the event tap on the current thread's run loop.
// This blocks until capsper_input_stop_tap() is called.
void capsper_input_run_tap(void) {
    if (!g_ctx || !g_ctx->tap) return;

    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, g_ctx->tap, 0);
    g_ctx->run_loop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(g_ctx->run_loop, source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_ctx->tap, true);
    CFRelease(source);

    // Run until stopped
    CFRunLoopRun();
}

// Stop the event tap run loop (called from another thread).
void capsper_input_stop_tap(void) {
    if (!g_ctx) return;
    g_ctx->shutdown = 1;
    if (g_ctx->run_loop) {
        CFRunLoopStop(g_ctx->run_loop);
    }
}

// Destroy the event tap and free resources.
void capsper_input_destroy_tap(void) {
    if (!g_ctx) return;
    if (g_ctx->tap) {
        CGEventTapEnable(g_ctx->tap, false);
        CFRelease(g_ctx->tap);
    }
    free(g_ctx);
    g_ctx = NULL;
}

// Check if the event tap is still enabled (watchdog may disable it).
int capsper_input_tap_is_enabled(void) {
    if (!g_ctx || !g_ctx->tap) return 0;
    return CGEventTapIsEnabled(g_ctx->tap) ? 1 : 0;
}

// ──── Text injection ────────────────────────────────────────────────────────

// Inject a UTF-8 string as keyboard events via CGEventPost.
// Uses CGEventKeyboardSetUnicodeString which handles Unicode directly —
// no keycode mapping needed. Batches up to 20 chars per event.
void capsper_input_type_text(const char *utf8_text, int len) {
    if (!utf8_text || len <= 0) return;

    CFStringRef str = CFStringCreateWithBytes(NULL, (const UInt8 *)utf8_text,
                                               len, kCFStringEncodingUTF8, false);
    if (!str) return;

    CFIndex total = CFStringGetLength(str);
    for (CFIndex i = 0; i < total; i += 20) {
        CFIndex batch = (total - i > 20) ? 20 : total - i;
        UniChar chars[20];
        CFStringGetCharacters(str, CFRangeMake(i, batch), chars);

        CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, 0, false);
        CGEventKeyboardSetUnicodeString(keyDown, (UniCharCount)batch, chars);
        CGEventKeyboardSetUnicodeString(keyUp, (UniCharCount)batch, chars);
        CGEventPost(kCGSessionEventTap, keyDown);
        CGEventPost(kCGSessionEventTap, keyUp);
        CFRelease(keyDown);
        CFRelease(keyUp);
    }
    CFRelease(str);
}

// ──── hidutil CapsLock remap ────────────────────────────────────────────────

// Remap CapsLock to F19 via hidutil. Returns 0 on success.
// This prevents the OS from seeing CapsLock (no LED toggle, no state change).
// The remap is session-scoped (lost on reboot).
int capsper_input_remap_capslock(void) {
    int r = system("hidutil property --set '{\"UserKeyMapping\":[{"
                   "\"HIDKeyboardModifierMappingSrc\": 0x700000039,"
                   "\"HIDKeyboardModifierMappingDst\": 0x70000006E"
                   "}]}' > /dev/null 2>&1");
    return r == 0 ? 0 : -1;
}

// Remove the CapsLock remap (restore normal CapsLock behavior).
int capsper_input_restore_capslock(void) {
    int r = system("hidutil property --set '{\"UserKeyMapping\":[]}' > /dev/null 2>&1");
    return r == 0 ? 0 : -1;
}
