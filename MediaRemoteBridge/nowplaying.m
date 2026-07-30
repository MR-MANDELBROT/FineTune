// Minimal MediaRemote bridge for FineTune.
//
// Since macOS 15.4 the MediaRemote framework refuses to answer a process that
// lacks a private entitlement, which no third-party app can obtain. It does
// answer Apple's own binaries, so this file is built as a plain dylib and is
// loaded into /usr/bin/perl, which is entitled. The technique is the one used
// by ungive/mediaremote-adapter (BSD-3-Clause); the implementation here is
// purpose-built and covers only what FineTune needs.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(pid_t));
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*SendCommandFn)(int, NSDictionary *);

static const int kTogglePlayPause = 2;

static void *media_remote(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                        RTLD_LAZY);
    });
    return handle;
}

/// Apple's private "who is really responsible for this process" API — the same
/// one Activity Monitor uses to attribute XPC helpers to their host app. The now
/// playing client is often a helper (a browser's media process), and the caller
/// needs the app the user actually sees.
static pid_t responsible_pid(pid_t pid) {
    static pid_t (*fn)(pid_t);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    });
    if (!fn) return 0;
    pid_t responsible = fn(pid);
    return (responsible > 0 && responsible != pid) ? responsible : 0;
}

static NSString *bundle_id_for_pid(pid_t pid) {
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (app && [app.bundleURL.pathExtension isEqualToString:@"app"]) {
        return app.bundleIdentifier;
    }
    pid_t responsible = responsible_pid(pid);
    if (responsible) {
        NSRunningApplication *parent =
            [NSRunningApplication runningApplicationWithProcessIdentifier:responsible];
        if (parent.bundleIdentifier) return parent.bundleIdentifier;
    }
    return app.bundleIdentifier;
}

/// Callbacks are taken on a global queue on purpose: perl runs no run loop, so
/// anything dispatched to the main queue would never be delivered.
static BOOL wait_for(dispatch_semaphore_t sem) {
    return dispatch_semaphore_wait(
               sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
}

/// Prints {"bundleIdentifier":"…","playing":true} or "null".
void finetune_nowplaying_get(void) {
    void *handle = media_remote();
    GetPIDFn get_pid = handle ? dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
    GetIsPlayingFn get_playing =
        handle ? dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
    if (!get_pid || !get_playing) {
        printf("null\n");
        return;
    }

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    __block pid_t pid = 0;
    dispatch_semaphore_t pid_sem = dispatch_semaphore_create(0);
    get_pid(queue, ^(pid_t value) {
        pid = value;
        dispatch_semaphore_signal(pid_sem);
    });
    if (!wait_for(pid_sem) || pid <= 0) {
        printf("null\n");
        return;
    }

    __block BOOL playing = NO;
    dispatch_semaphore_t playing_sem = dispatch_semaphore_create(0);
    get_playing(queue, ^(Boolean value) {
        playing = value;
        dispatch_semaphore_signal(playing_sem);
    });
    if (!wait_for(playing_sem)) {
        printf("null\n");
        return;
    }

    NSString *bundleID = bundle_id_for_pid(pid);
    if (!bundleID) {
        printf("null\n");
        return;
    }

    NSDictionary *payload = @{
        @"bundleIdentifier" : bundleID,
        @"playing" : @(playing),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (!json) {
        printf("null\n");
        return;
    }
    fwrite(json.bytes, 1, json.length, stdout);
    printf("\n");
}

/// Toggles playback in the app that owns the now playing session.
///
/// Commands can only be addressed at that one session. MediaRemote does expose
/// per-client entry points (MRMediaRemoteSendCommandToClient), but they build an
/// MRPlayerPath from an origin, a client and a player, and the shape of that call
/// could not be established without guessing at private signatures — the upstream
/// mediaremote-adapter does not attempt it either. So the caller passes the bundle
/// identifier it believes is current, and the command is dropped if the session
/// moved on in the meantime. Better to do nothing than to pause the wrong app.
///
/// Sending is asynchronous over XPC, and this process exits the moment the call
/// returns — far too early for the command to have gone out. Issuing a follow-up
/// request and waiting for its reply proves the send completed, because the
/// connection delivers serially.
void finetune_nowplaying_toggle(void) {
    void *handle = media_remote();
    SendCommandFn send = handle ? dlsym(handle, "MRMediaRemoteSendCommand") : NULL;
    GetPIDFn get_pid = handle ? dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
    if (!send || !get_pid) return;

    const char *expected = getenv("FINETUNE_EXPECTED_BUNDLE");
    if (expected && *expected) {
        __block pid_t pid = 0;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        get_pid(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(pid_t value) {
            pid = value;
            dispatch_semaphore_signal(sem);
        });
        if (!wait_for(sem) || pid <= 0) return;

        NSString *current = bundle_id_for_pid(pid);
        if (![current isEqualToString:[NSString stringWithUTF8String:expected]]) {
            fprintf(stderr, "now playing moved to %s, dropping command\n",
                    current.UTF8String ?: "nothing");
            return;
        }
    }

    send(kTogglePlayPause, nil);

    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    get_pid(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(pid_t pid) {
        dispatch_semaphore_signal(completion);
    });
    wait_for(completion);
}
