# Multi-output reliability

## Accepted behavior

Selecting the owner's existing Blackhole & Headphones multi-output device must
complete without freezing the menu or app. Audio must reach both headphones and
BlackHole. Switching back to a normal output must continue working. Preserve
preparation, immediate cadenza returns, tempo following, independent microphone
selection, take playback, and output interruption checks. Do not change system
audio defaults, device sample rates, aggregate membership, music, or recordings.
Notify the owner before updating or restarting the installed app.

## Cause and implementation

The frozen app and an opt-in test of PerformanceAudio both blocked in
AVAudioEngine.prepare. The audio-unit thread looped in hardware-format discovery
(`_GetHWFormat` / `GetSubDevices`). A fresh one-player engine reproduced the hang
with 2-channel headphones plus BlackHole 16ch. Two equal-width outputs worked.
Changing source sample rate, explicit output channel count, and binding order
did not fix it. This identifies the affected Apple audio-engine path on this Mac;
it does not establish which other OS/device combinations exhibit the defect.

Mixed-width aggregates now use the existing player/mixer/time-pitch graph in
realtime manual-rendering mode, driven by a separate HAL output unit. Other
devices keep the existing engine output. The adapter reads the device's current
sample rate and checks its route, rate, subdevices, running state, and render errors.
Shutdown stops the output callback before releasing graph resources.

Manual-rendering players ignore host timestamps, and their sample clocks advance
at the time-stretch rate. Reusing the hardware sample count to schedule a future
start therefore drifts after tempo changes. Instead the adapter holds rendering
until the requested hardware host time; both players are started while held.
This preserves the 200 ms startup lead independently of tempo. Immediate returns
have no extra lead. Starts are quantized to an output buffer, with output and
time-pitch latency included in the transport clock.

## Reproducible checks

```sh
python3 Scripts/check-multi-output.py 'Blackhole & Headphones'
python3 Scripts/check-multi-output.py 'Blackhole & Headphones' --loopback 'BlackHole 16ch'
```

The script builds with warnings as errors, then runs the actual production path
under a separate 20-second process watchdog. A main-thread freeze cannot be caught
by an ordinary XCTest elapsed-time assertion. Device switching is silent. The
optional loopback check plays short quiet synthesized tones and requires existing
capture authorization. It stores no audio. Run it only when the owner is stopped.
Names are explicit parameters; no audio-device settings are modified.

The original switching test hung before the fix. The regression switches normal
headphones -> aggregate -> headphones -> aggregate and checks the actual bound
output and readiness. Loopback checks normal and immediate starts, repeated starts
after time stretching at 80% and 120%, audible origin, and stretched duration using
a 44.1 kHz source on the 48 kHz device. Capture must be receiving before measuring.
These checks establish routing and timing, not musical quality of live following
with the owner's horn; that remains a rehearsal check.

The loopback also appends ten buffers and updates the tempo every 15 ms during
playback, including unchanged-rate updates. It checks audible completion against
the transport and counts frames deferred by realtime engine contention. This
catches gaps/clock drift that a route-only test or pre-start rate change misses.

## Verification on November 17, 2026

The warnings-as-errors suite passed 153 tests with four opt-in hardware checks
skipped. Nine release audio checks passed with hardware enabled. Final release
route/timing checks also passed after review: six starts were within 21 ms of
their predicted origin, continuous rate updates deferred zero frames, and the
completion error was 13 ms. Standards review's duplicate cleanup was removed;
specification review cleared after continuous-rate coverage was added.

The signed app was installed and reopened with the owner's score, two preparation
measures, solo staff, and cadenza. The native output menu selected the formerly
freezing device, Test output ran, and switching back and forth remained responsive.
The app was left Ready on Blackhole & Headphones. The owner had already confirmed
the prototype tone in headphones, with simultaneous BlackHole loopback detection.
The rehearsal report was saved before restart and the prior app was backed up.
