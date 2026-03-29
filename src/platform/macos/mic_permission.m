// mic_permission_macos.m — Microphone permission helper for macOS
//
// CoreAudio silently delivers zero samples when microphone permission
// hasn't been granted. This helper uses AVFoundation (Objective-C) to
// check and request permission before starting capture.

#import <AVFoundation/AVFoundation.h>
// Returns: 0 = not determined, 1 = restricted, 2 = denied, 3 = authorized
int capsper_mic_permission_status(void) {
    return (int)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
}

// Blocks until microphone permission is granted.
// If status is notDetermined, shows the permission dialog and blocks.
// If status is denied, blocks and polls indefinitely — the user may be
// responding to a dialog from a previous launch, or may grant access
// via System Settings. Either way, we wait rather than crash and restart
// (which would spawn duplicate permission dialogs via launchd KeepAlive).
// Returns 1 if granted, 0 only for restricted (system policy, no recovery).
int capsper_mic_request_permission(void) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) return 1;
    if (status == AVAuthorizationStatusRestricted) return 0;

    if (status == AVAuthorizationStatusNotDetermined) {
        __block int granted = 0;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL g) {
            granted = g ? 1 : 0;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        if (granted) return 1;
        // User denied — fall through to polling below
    }

    // Denied: poll every 5s until granted. The user can grant access via
    // System Settings → Privacy & Security → Microphone at any time.
    while (1) {
        [NSThread sleepForTimeInterval:5.0];
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]
                == AVAuthorizationStatusAuthorized) {
            return 1;
        }
    }
}
