// test/macos-audio-helpers.c — CoreAudio helpers for macOS loopback tests
//
// Provides three commands:
//   list-devices    — enumerate audio devices with input channel counts
//   set-output ID   — set default output device by ID
//   get-output      — print current default output device ID and name
//
// Build: clang -framework CoreAudio -framework CoreFoundation test/macos-audio-helpers.c -o test/macos-audio-helpers

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static void get_device_name(AudioDeviceID id, char *buf, size_t buflen) {
    CFStringRef name = NULL;
    UInt32 sz = sizeof(name);
    AudioObjectPropertyAddress addr = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(id, &addr, 0, NULL, &sz, &name) == noErr && name) {
        CFStringGetCString(name, buf, (CFIndex)buflen, kCFStringEncodingUTF8);
        CFRelease(name);
    } else {
        snprintf(buf, buflen, "unknown");
    }
}

static int cmd_list_devices(void) {
    UInt32 sz = 0;
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &sz);
    int count = (int)(sz / sizeof(AudioDeviceID));
    AudioDeviceID devs[64];
    if (count > 64) count = 64;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &sz, devs);

    for (int i = 0; i < count; i++) {
        char name[256];
        get_device_name(devs[i], name, sizeof(name));

        // Count input channels
        UInt32 in_sz = 0;
        AudioObjectPropertyAddress in_addr = {
            kAudioDevicePropertyStreamConfiguration,
            kAudioObjectPropertyScopeInput,
            kAudioObjectPropertyElementMain
        };
        AudioObjectGetPropertyDataSize(devs[i], &in_addr, 0, NULL, &in_sz);
        int in_ch = 0;
        if (in_sz > 0) {
            char buf[1024];
            UInt32 buf_sz = sizeof(buf);
            if (AudioObjectGetPropertyData(devs[i], &in_addr, 0, NULL, &buf_sz, buf) == noErr) {
                AudioBufferList *abl = (AudioBufferList *)buf;
                for (UInt32 b = 0; b < abl->mNumberBuffers; b++)
                    in_ch += (int)abl->mBuffers[b].mNumberChannels;
            }
        }
        printf("%u\t%d\t%s\n", devs[i], in_ch, name);
    }
    return 0;
}

static int cmd_set_output(const char *id_str) {
    AudioDeviceID id = (AudioDeviceID)atoi(id_str);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus r = AudioObjectSetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, sizeof(id), &id);
    return (r == noErr) ? 0 : 1;
}

static int cmd_get_output(void) {
    AudioDeviceID id;
    UInt32 sz = sizeof(id);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &sz, &id);
    char name[256];
    get_device_name(id, name, sizeof(name));
    printf("%u\t%s\n", id, name);
    return 0;
}

// Find device ID by name substring match. Returns 0 if not found.
static int cmd_find_device(const char *search) {
    UInt32 sz = 0;
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &sz);
    int count = (int)(sz / sizeof(AudioDeviceID));
    AudioDeviceID devs[64];
    if (count > 64) count = 64;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &sz, devs);

    for (int i = 0; i < count; i++) {
        char name[256];
        get_device_name(devs[i], name, sizeof(name));
        if (strstr(name, search) != NULL) {
            printf("%u\n", devs[i]);
            return 0;
        }
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <list-devices|set-output ID|get-output|find-device NAME>\n", argv[0]);
        return 1;
    }
    if (strcmp(argv[1], "list-devices") == 0) return cmd_list_devices();
    if (strcmp(argv[1], "set-output") == 0 && argc >= 3) return cmd_set_output(argv[2]);
    if (strcmp(argv[1], "get-output") == 0) return cmd_get_output();
    if (strcmp(argv[1], "find-device") == 0 && argc >= 3) return cmd_find_device(argv[2]);
    fprintf(stderr, "Unknown command: %s\n", argv[1]);
    return 1;
}
