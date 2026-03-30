// mic_permission_macos.m — Microphone permission helper for macOS
//
// CoreAudio silently delivers zero samples when microphone permission
// hasn't been granted. This helper uses AVFoundation (Objective-C) to
// request permission before starting capture.

#import <AVFoundation/AVFoundation.h>

// Blocks until microphone permission is granted.
// Makes exactly ONE permission request to avoid duplicate TCC dialogs,
// then polls if denied. Never returns — the process stays alive waiting
// for the user to grant access (via dialog or System Settings), so
// launchd doesn't restart and spawn duplicate prompts.
// Returns 1 when granted. Only returns 0 for restricted (system policy).
int capsper_mic_request_permission(void) {
    // Single requestAccess call — handles all states:
    //   authorized:     completion fires immediately with YES
    //   notDetermined:  shows dialog, blocks until user responds
    //   denied:         completion fires immediately with NO
    //   restricted:     completion fires immediately with NO
    __block int granted = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL g) {
        granted = g ? 1 : 0;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (granted) return 1;

    // Denied or restricted. Poll until granted — the user may grant
    // access via System Settings at any time.
    while (1) {
        [NSThread sleepForTimeInterval:5.0];
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]
                == AVAuthorizationStatusAuthorized) {
            return 1;
        }
    }
}
