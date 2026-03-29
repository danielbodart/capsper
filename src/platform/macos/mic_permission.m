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

// Blocks until the user responds to the permission dialog.
// Returns 1 if granted, 0 if denied.
// If status is notDetermined, shows the permission dialog and blocks.
// If status is denied, polls for up to 30 seconds in case a permission
// dialog from a previous launch is still visible (launchd restarts can
// race with the user clicking "Allow").
int capsper_mic_request_permission(void) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) return 1;

    if (status == AVAuthorizationStatusNotDetermined) {
        __block int granted = 0;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL g) {
            granted = g ? 1 : 0;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        return granted;
    }

    // Status is denied or restricted. Poll briefly in case the user is
    // responding to a mic dialog from a previous launch attempt — launchd's
    // KeepAlive restarts can overlap with a pending permission prompt.
    for (int i = 0; i < 15; i++) {
        [NSThread sleepForTimeInterval:2.0];
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]
                == AVAuthorizationStatusAuthorized) {
            return 1;
        }
    }
    return 0;
}

