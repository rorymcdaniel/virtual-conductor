# Post-upgrade capability verification

Verified 2026-10-29. This supplements the historical [pre-upgrade research](macos-26-2-upgrade.md). The owner's explicit instruction to drop older OS and SDK support supersedes that report's compatibility recommendation.

## Installed baseline

The machine differs from the requested version description. Direct command output:

| Command | Result |
| --- | --- |
| `sw_vers` | macOS **27.2**, build **26B123** |
| `xcodebuild -version` | Xcode **27.1**, build **27A9275** |
| `xcrun --sdk macosx --show-sdk-version` | **27.0** |
| `xcrun swift --version` | Apple Swift **6.4**, target arm64-apple-macosx27.2.0 |

These are local observations, not claims about public release availability. The owner's installed-version policy therefore means macOS 27.2 and SDK 27.0 minimums. OS deployment version and SDK version are distinct.

## Verified opportunities from the earlier report

- **SwiftUI profiling exists locally.** `xcrun xctrace list templates` includes SwiftUI, Audio System Trace, Time Profiler, Allocations, Swift Concurrency, and Processor Trace. Apple's [SwiftUI profiling session](https://developer.apple.com/videos/play/wwdc2025/306/) documents view-update tracking and causal analysis. Template availability does not mean a representative rehearsal has been profiled or prove improved timing.
- **InlineArray and Span run successfully.** A temporary Swift program created `InlineArray<3, Double> = [1, 2, 3]`, read its second element, and read `[1, 2, 3].span.count`; output was `2.0 3`. This verifies compilation and execution on this machine. Apple's [memory performance session](https://developer.apple.com/videos/play/wwdc2025/312/) explains the storage and lifetime benefits. Use only where fixed size or borrowed contiguous storage matches the algorithm; measure allocation and throughput changes before claiming a speedup.
- **Process-tap additions exist and are callable.** Installed `CoreAudio.framework/Headers/CATapDescription.h` marks `bundleIDs` and `processRestoreEnabled` as macOS 26.0. A temporary Swift program constructed `CATapDescription`, assigned a bundle ID, set `isProcessRestoreEnabled = true`, and read back `true`. The header describes bundle targeting and process restoration; [Apple bundle-ID documentation](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids) and [restoration documentation](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled) are the API references. This was a configuration probe, not an authorized audio tap or a real process-relaunch capture test. Adding MuseScore capture remains separate product work.
- **Native appearance changes are documented**, including refreshed controls and custom glass APIs in [Apple's AppKit session](https://developer.apple.com/videos/play/wwdc2025/310/). Their availability does not justify adding translucent decoration to the timing display; visual legibility still needs app-level inspection.
- **Spotlight actions and Shortcuts automations are documented** in [Apple's App Intents session](https://developer.apple.com/videos/play/wwdc2025/260/). They are optional integrations, not replacements for the pedal's timing path.
- **AirPods recording improvement is conditional.** [Apple's announcement](https://www.apple.com/newsroom/2025/06/airpods-now-more-versatile-with-studio-quality-audio-recording-and-camera-remote/) identifies supported H2 devices and firmware/platform requirements. This pass did not verify attached hardware, firmware, or the app's AVAudioEngine recording quality. No lower latency or better pitch accuracy is established.

## Additional engineering opportunities

The highest-value extra opportunity is stronger compiler verification, rather than an additional user-facing framework. [Swift 6.2 release information](https://www.swift.org/blog/swift-6.2-released/) documents opt-in strict memory safety and approachable concurrency. Locally, `swiftc -help` confirms `-strict-memory-safety` and `-strict-concurrency` options. [Apple's Swift overview](https://developer.apple.com/videos/play/wwdc2025/245/) explains these checks.

1. Adopt Swift 6 language checking with explicit isolation and Sendable boundaries. This can detect concurrency mistakes before release. Do not move audio work onto the main actor simply to silence errors; callback lifetimes and real-time execution remain engineering constraints.
2. Audit unsafe memory operations with strict-memory-safety diagnostics, prioritizing input capture and PCM handling. Explicitly acknowledging an unsafe operation documents its boundary but does not prove safety. This is useful follow-up after concurrency checks are clean.
3. Use the available Audio System Trace together with SwiftUI/CPU profiling to distinguish audio scheduling problems from interface work. Establish representative measurements before choosing InlineArray, Span, or algorithm changes.

No evidence in this pass supports changing the playback clock, latency compensation, pitch model, or score alignment purely because the OS changed. Hardware loopback, disconnect/reconnect, permissions, and rehearsal tracing remain necessary to establish real-world reliability; API probes and unit tests cannot substitute for those measurements.

## First implementation batch

- Raised Swift tools minimum to 6.4 and compiler deployment target to 27.0. The installed SDK rejects 27.2 deployment targets; bundle metadata and an executable startup check enforce macOS 27.2. The release script rejects hosts below 27.2 and SDKs below 27.0.
- Enabled Swift 6 language mode for ConductorCore. Full-app migration exposed non-Sendable mutable PCM buffers crossing detached-task boundaries; retain Swift 5 app mode until ownership is migrated deliberately.
- Installed SDK headers additionally expose macOS 27 throwing `connectNode`, `playAudio`, and `installAudioTap` APIs. Adopted these so failures propagate through existing error handling; paired-player start failure stops both players.
- Migrated device access to `withAudioUnit`, and capture to `AVReadOnlyAudioPCMBuffer` with channel Span access. These declarations were verified in the installed AVFAudio Swift interface and headers; no public-release claim is implied.
- Corrected window-title access to explicitly assume main-actor isolation inside the main-queue notification callback.

Next engineering work: migrate prepared audio ownership for app-wide Swift 6 checking, audit unsafe memory boundaries, then collect rehearsal traces and physical loopback timing. No analysis-speed or hardware-accuracy improvement is claimed from this batch.
