# macOS 26.2 upgrade: project implications

Researched 2026-10-29 against the current repository and Apple primary sources. Scope: upgrading this development Mac from macOS 15.6 (24G84) to macOS 26.2; exclude features introduced after 26.2. This is a feasibility assessment, not an implementation change or a measured performance comparison.

## Baseline

Local inspection verified an arm64 Mac running **macOS 15.6**, with **Xcode 26.2 (17C52) and the macOS 26.2 SDK already installed**. [Package.swift](../../Package.swift) uses Swift tools 6.0, Swift 5 language mode, and a macOS 15 deployment minimum. Upgrading macOS therefore changes the runtime available for testing; the 26.2 compiler and SDK are already available. Apple officially supports Xcode 26.2 on macOS 15.6 and later. [Xcode 26.2 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_2-release-notes).

Current dependencies:

| Area | Actual project usage |
| --- | --- |
| Audio-device selection | Core Audio `AudioHardwareSystem.shared.devices`, HAL property reads, Audio Unit `CurrentDevice` binding in [AudioDevices.swift](../../Sources/VirtualConductor/AudioDevices.swift) |
| Playback and capture | Separate `AVAudioEngine` instances, PCM buffers and files, player nodes, host-time scheduling, output `presentationLatency`, input taps and atomic buffering in [PerformanceAudio.swift](../../Sources/VirtualConductor/PerformanceAudio.swift) and [InputCapture.swift](../../Sources/VirtualConductor/InputCapture.swift) |
| Timing and interpretation | Project-owned MIDI-file parser, monophonic pitch analysis and alignment; no current CoreMIDI, SoundAnalysis, Core ML or Foundation Models integration |
| Interface and display | SwiftUI plus AppKit custom `NSView` drawing; display-link updates; local keyboard event monitoring for the pedal; native file panels |
| Build | `swift build`, shell file operations and ad-hoc `codesign` in [build script](../../Scripts/build-virtual-conductor.sh); Node is a fixture-generation tool |

There is no CONTEXT.md or ADR decision to supersede. The existing [MuseScore research](musescore-integration.md) proposes a companion plus native score edits and separate-process exports; that integration is not implemented.

## Most useful changes

### 1. Better visibility into interface stalls and redundant updates

The new SwiftUI instrument in Instruments 26 records long view-body and representable updates and shows a Cause & Effect Graph explaining what triggered updates. Apple requires both Xcode 26 and the new target OS releases for the new tracing support. With Xcode already installed, updating this Mac supplies the missing runtime side. [Apple's SwiftUI profiling session](https://developer.apple.com/videos/play/wwdc2025/306/).

**Project application, inferred from the code:** profile a representative session containing conducting playback, recording, and waveform review. This can distinguish SwiftUI update work from drawing or analysis costs. It helps us find and correct glitches; it does not itself make playback or the pedal more accurate. The custom AppKit surface still needs Time Profiler/System Trace alongside SwiftUI profiling.

The macOS 26.2 notes also list a fix for missing native Swift reference-counting events in Allocations. The same fix appears in the Xcode 26.2 notes, so it should not be represented as a wholly new capability that only the OS upgrade unlocks. [macOS 26.2 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-26_2-release-notes), [Xcode 26.2 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_2-release-notes).

### 2. A useful optimization option for the custom analysis code

Swift 6.2 adds `InlineArray`, a fixed-size collection that stores its elements inline, avoiding a separate heap allocation. It is appropriate for fixed-size scratch storage rather than arrays that grow or need cheap shared copies. Apple also introduces span-based access to contiguous memory to reduce reference-counting work safely. [InlineArray documentation](https://developer.apple.com/documentation/swift/inlinearray), [Apple's memory-performance session](https://developer.apple.com/videos/play/wwdc2025/312/).

Local SDK inspection and a Swift 5-mode type-check probe confirmed that `InlineArray<3, Double>` and `Array.span` require macOS 26; they fail a macOS 15 deployment target and pass a macOS 26 target. The existing compiler is sufficient, but these particular standard-library surfaces need the newer runtime. Some span types have older availability, so it would be inaccurate to say every use of Span requires macOS 26.

**Project application, inferred from the code:** [Interpretation.swift](../../Sources/ConductorCore/Interpretation.swift) repeatedly creates pitch-analysis scratch arrays and three-candidate alignment arrays. Fixed-size storage is worth benchmarking there. The user benefit would be faster analysis or less allocation churn on longer takes; there is no measured speedup yet. Reusing buffers or replacing small temporary arrays with scalars can provide similar benefits while retaining macOS 15 support. Profile first, then choose the smallest useful change.

### 3. More robust capture of another app's audio, if we add that feature

The installed 26.2 SDK's `CATapDescription.h` marks `bundleIDs` and `processRestoreEnabled` as macOS 26.0 additions. They let a tap identify included/excluded processes by bundle ID and restore tapped processes after they quit and relaunch. Apple's documentation confirms those semantics. [Bundle-ID targeting](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids), [process restoration](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled).

**Possible product benefit, not implemented:** an optional “capture MuseScore playback” connection could survive MuseScore relaunches without asking the musician to find a new process. This is a genuine OS 26 addition, but the project has no process taps today.

Basic process-audio capture was already available in macOS 14.2. It uses a tap plus a HAL aggregate device and requires `NSAudioCaptureUsageDescription` and system audio-recording permission. The upgrade improves process targeting/lifecycle handling; it does not first enable system-audio recording. [Apple's tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

This would not replace the planned native MuseScore score-editing connection or matching MIDI/WAV exports without further investigation. A captured playback stream alone does not provide native score identity, repeat mapping, tempo-edit transactions or verified export timing.

### 4. The current native controls can adopt the new system appearance

Apple says apps rebuilt with Xcode 26 render standard controls using the new design when running on OS 26. Since this project already builds with that toolchain, the upgrade makes the actual new-runtime appearance available for review. Custom views require deliberate adoption of glass effects. [Platforms State of the Union, design adoption](https://developer.apple.com/videos/play/wwdc2025/102/?time=1098), [AppKit design guidance](https://developer.apple.com/videos/play/wwdc2025/310/).

**Project recommendation:** check control spacing, dark appearance, menus and file panels after upgrading; preserve clear contrast on the conductor display and waveform. Treat the new styling as visual polish. There is no reason to rebuild the custom conductor surface around Liquid Glass for this project's musical goals.

Apple also reports SwiftUI runtime performance improvements, including faster List updates. The conductor's main animated display is custom AppKit drawing, so those improvements do not establish a corresponding speedup for this app. [Apple's Xcode performance overview](https://developer.apple.com/videos/play/wwdc2025/247/?time=402).

### 5. Optional system-level rehearsal actions

macOS 26 brings runnable app actions to Spotlight and personal Shortcuts automations, such as reacting to Bluetooth connections or folder changes. Rich app actions require adopting App Intents; ordinary menu actions can also surface automatically in Spotlight. [Apple's App Intents session](https://developer.apple.com/videos/play/wwdc2025/260/), [WWDC25 macOS guide](https://developer.apple.com/news/?id=uf3qdaoe).

**Possible product benefit:** eventually expose “Open rehearsal,” “Start take,” or “Play take” to system shortcuts. The app currently has no custom menu-command or App Intents implementation, so this is future work. It offers convenient access rather than a replacement for the latency-sensitive pedal event path.

### 6. Conditional AirPods recording improvement

Apple introduced higher-quality audio recording with H2 AirPods, including AirPods 4 and AirPods Pro 2, through firmware updates used with macOS 26. [Apple's AirPods announcement](https://www.apple.com/newsroom/2025/06/airpods-now-more-versatile-with-studio-quality-audio-recording-and-camera-remote/).

This may matter for a singer using supported AirPods as a microphone. It is not evidence of improved instrumental pitch tracking or lower Bluetooth latency. Apple's WWDC recording examples enable high-quality Bluetooth through `AVAudioSession` or `AVCaptureSession`; the current native Mac `AVAudioEngine` path needs its own validation. Do not copy the iOS-only `AVAudioSession` solution into this app. [Apple's recording session](https://developer.apple.com/videos/play/wwdc2025/251/).

## Changes not to count as upgrade benefits

- **No established latency or alignment improvement.** Apple's 26/26.2 material examined here does not establish lower latency for the app's existing separate audio engines, more accurate `presentationLatency`, better WAV/MIDI alignment, or a new built-in musical score follower. Measure actual timing before claiming improvement.
- **Existing Core Audio Swift APIs are not newly unlocked.** The project already enumerates devices with the Swift Core Audio layer on macOS 15.6. Further cleanup using that layer does not require macOS 26.
- **Processor Trace already works on suitable macOS 15 hardware.** Apple's requirements are Instruments 16.3+, macOS 15.4+ and M4-or-later Mac hardware. It can help analyze the pitch detector, but upgrading from 15.6 is not the enabling condition. [Processor Trace requirements](https://developer.apple.com/documentation/xcode/analyzing-cpu-usage-with-processor-trace).
- **Compiler improvements are already installed.** Xcode 26.2 includes Swift 6.2.3. Changing Swift language mode, isolation settings or adopting newer memory-management tools is separate engineering work, not an automatic result of the OS upgrade. [Xcode 26.2 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_2-release-notes).
- **Foundation Models does not replace audio analysis.** The new framework exposes an on-device language model for text understanding/generation. It could support textual practice notes, but does not supply audio-to-MIDI or real-time score following. Availability depends on Apple Intelligence eligibility, settings and model readiness. [Apple model capabilities](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models).
- **The 26.2 Thunderbolt RDMA feature is unrelated to this design.** Apple describes low-latency communication between Thunderbolt 5 hosts for distributed workloads; this app is a single-Mac audio tool. [macOS 26.2 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-26_2-release-notes).

## Compatibility and next steps

Apple stopped publishing the old `AppleUSBAudioEngine`, `AppleUSBAudioDevice` and `AppleUSBAudioStream` IORegistry services in macOS 26. This code accesses Core Audio rather than directly relying on those services, so the identified removal does not itself call for an app rewrite. Test the actual USB interface and its vendor software on the new OS. [Apple USB audio technote TN3190](https://developer.apple.com/documentation/technotes/tn3190-usb-audio-device-design-considerations).

Recommended engineering follow-up after the upgrade:

1. Rebuild and run the existing tests, then check microphone permission, input/output selection, sample-rate changes, disconnect/reconnect and playback interruption with the real devices.
2. Measure recording-to-playback alignment and pedal/cadenza behavior; retain the current timing model until measurements justify changes.
3. Profile one representative rehearsal/recording session with the new SwiftUI instrument and existing CPU/audio tools.
4. Keep the macOS 15 minimum unless a selected OS-26-only feature earns the compatibility tradeoff. Isolate optional process-tap additions behind availability checks if supporting macOS 15 remains useful.

The strongest immediate project benefit is better runtime validation and interface profiling. New fixed-size storage offers a focused analysis-optimization option. The most concrete new audio integration opportunity is persistent process-tap targeting for a future MuseScore capture feature. These opportunities support the existing priority of a reliable play → listen → keep workflow.
