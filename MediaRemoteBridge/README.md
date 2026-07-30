# MediaRemote bridge

Reads Now Playing state and toggles playback for apps that expose no scripting
interface — browsers, iOS apps running on macOS, most streaming clients.

## Why a helper process

MediaRemote is the private framework behind Control Center's Now Playing tile and
the media keys. Since macOS 15.4 `mediaremoted` verifies an entitlement that no
third-party app can obtain, and answers everyone else with nothing.

It does answer Apple's own binaries. `/usr/bin/perl` is one, so `nowplaying.pl`
loads `nowplaying.m` (built into a dylib by a build phase) and makes the calls
from inside that process. The technique comes from
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
(BSD-3-Clause); the code here is purpose-built and covers only what FineTune needs.

Measured on macOS 26.3: identical code returns the full Now Playing payload under
`/usr/bin/swift` and an empty response from a self-signed binary.

## Why only one app at a time

FineTune can only offer a transport button for the app that currently owns the Now
Playing session. This is a routing decision inside `mediaremoted`, not a gap in the
implementation. What follows is the evidence, recorded so nobody repeats it — plus
one lead that is still open, under "The layer below Now Playing".

### Enumeration works

`MRMediaRemoteGetNowPlayingClients` returns every client at once — on a test
machine Safari (with the media helper resolved to the parent app), Portal, Spotify
and TV simultaneously. `MRClient` exposes `bundleIdentifier`,
`parentApplicationBundleIdentifier` and `processIdentifier` as ordinary
Objective-C properties. Reading the roster is not the problem.

### The call signatures, from disassembly

Guessing these produced either crashes or silent no-ops, so they were read out of
the framework instead (`lldb` against a process that `dlopen`s MediaRemote — perl
itself is SIP-protected and cannot be debugged):

```
MRMediaRemoteSendCommandToClient(command, options, origin, client,
                                 unknown, queue, completion)   // 7 args
MRMediaRemoteSendCommandToPlayer(command, options, playerPath,
                                 unknown, queue, completion)   // 6 args
```

Two details matter. `SendCommandToClient` builds the player path itself and passes
**nil** as the player (`mov x4, #0x0` before `initWithOrigin:client:player:`), so
`+[MRPlayer anyPlayer]` is unnecessary. And both functions end in `mov w0, #0x1`:
**the return value is a hardcoded 1 and carries no information about success.**

With the right signature the call does reach the daemon — unlike the guessed ones,
which did nothing at all.

### The daemon still routes it elsewhere

A path can be constructed and fully resolved, naming the target explicitly:

```
【 LOCL (Mac) ❯ app.portal.ios.v1 (58619) Portal ❯ default 】
```

Sending a toggle to that path leaves Portal untouched and flips **Spotify**, the
app that happened to own the session. Verified twice, using Spotify as the control
because its real state can be read independently through AppleScript. The client
in the path is simply not honoured for callers on this side of the entitlement
boundary.

Corroborating: no open-source project sends per-client commands, including ones
built entirely around MediaRemote (mediaremote-adapter, media-control,
media-remote, mediaremote-rs). They all stop at the global command.

### Redirecting the session was also tried

`MRMediaRemoteSetOverriddenNowPlayingApplication` and
`MRMediaRemoteSetNowPlayingApplicationOverrideEnabled` look like they could point
the active session at a chosen app. They cannot: both operate on
`[[sharedManager] localOriginClient]`, i.e. they change how *the calling process*
advertises itself. Like most `MRMediaRemoteSet*` functions they belong to the
publishing side, for apps declaring their own playback.

`kMRMediaRemoteOptionDestinationAppDisplayID` is the only option key that names a
target app. Passing it to `MRMediaRemoteSendCommand` makes the command vanish: sent
with Spotify as the destination — the app that reliably reacts to the same command
without the option — nothing happened at all. It suppresses delivery rather than
redirecting it.

There is no API that enumerates the players belonging to a client, so a path can
never name anything more specific than `default`.

### The layer below Now Playing — open lead

Everything above goes through the *Now Playing* family, which by design addresses
whatever owns the session: it is the route for the media keys and AirPods.
`_MRMediaRemoteSendCommandToPlayerWithResult` calls
`MRMediaRemoteNowPlayingResolvePlayerPath` unconditionally, and that resolution
happens server-side via `sharedServiceClient`. So the client named in the path
never gets a say.

There is a lower layer that skips it entirely:

```
MRMediaRemoteServiceSendCommand(service, message, queue, completion)
```

It calls only `MRCreateXPCMessage` and `MRAddSendCommandToXPCMessage` — no Now
Playing resolution anywhere in it. The pieces needed to drive it:

- `MRSendCommandMessage` has `-initWithCommand:options:playerPath:`, so the whole
  command including the target path travels inside one object.
- The service is `[[MRMediaRemoteServiceClient sharedServiceClient] service]` —
  an `MRMediaRemoteService`. The client itself does not respond to `connection`.
- `MRMediaRemoteServiceSendCommand` is **not** an exported symbol. On this build
  it sits `0xC1EAC` below the exported `MRMediaRemoteSendCommand` in the same
  image; that offset is specific to one macOS build and would need a sturdier
  lookup before shipping.

This route does reach the daemon: it answered with a real `MRCommandResult`
carrying both a `playerPath` and an `error` — the first genuine diagnostics
obtained anywhere in this investigation.

It is **not** resolved whether it routes per app. In the one measured run the
command arrived as `Unrecognized Command: 4177879401`, i.e. the command argument
was mis-encoded by the probe rather than rejected by the daemon, and the reply
still named the active client. The probe was fixed but not re-run. Anyone picking
this up should start there: send a correctly encoded `kMRTogglePlayPause` (2) and
check whether `MRCommandResult.playerPath` comes back naming the requested app.

Even if it works, shipping it means calling an unexported function through a
hardcoded offset. That is a different risk class from the rest of this bridge.

### Other write paths

`CGEventPostToPid` posts an `NSSystemDefined` media key to a single process and
needs no private framework. Neither Spotify nor Portal reacted: both receive
transport commands through `mediaremoted`, not as key events.

AppleScript remains the only mechanism that addresses apps individually, which is
why it is tried first and MediaRemote only fills in what it cannot reach.

### Why Control Center can do it

Not a trick that is being missed. Control Center runs inside the entitlement
boundary, and `mediaremoted` honours the player paths it sends.

## Files

- `nowplaying.m` — the bridge. Built into `Contents/Resources` by the
  "Build MediaRemote bridge" build phase; deliberately not linked against, since
  only perl ever loads it.
- `nowplaying.pl` — loads the bridge and calls one of its two functions.

## Manual check

```sh
APP=/path/to/FineTune.app/Contents/Resources
/usr/bin/perl "$APP/nowplaying.pl" "$APP/libFineTuneNowPlaying.dylib" get
```
