# Cadenza handoff through a rubato lead-in

## Written cadenza following

With live following enabled, **Follow written cadenzas** reads the selected horn
staff and all the orchestral staves. In the Strauss export it finds the release
at measure 7 beat 1½ and the shared attack at measure 13 beat 1. A saved pedal
passage for that handoff can be used again by selecting **Use pedal passages**.

A local release-build check loaded the matching MIDI, WAV and MusicXML and fed
the Baborák recording through the live microphone-processing path in 40 ms
blocks. Starting at the orchestral release, the conductor commanded measure 13
at recording time 44.08 seconds. The reference alignment places the entrance
at 44.04 seconds. This replay measured the playback command with simulated
output. Audible timing through the player’s microphone and headphones still
needs a rehearsal.

## Pedal-controlled behavior

The performer reported that rubato in measure 7 led to lost tracking before a
configured cadenza beginning in measure 8. The agreed change is to begin manual
free time at the orchestral release within measure 7, let the orchestra's last
sound ring, and remain in the cadenza until the right-arrow pedal cues measure 13.
The cadenza indicator must remain stable despite microphone analysis recovery.

## Native app behavior

- Cadenza starts and returns accept fractional beats, such as 1.5 (halfway
  through beat 1) or 4.75. Measures remain whole numbers; beats must be at least
  1 and less than 5. Existing whole-beat settings still load unchanged.
- Ordinary accompanied playback reaches the configured cadenza even if the
  solo tracker has lost its place. At that boundary, the conducting clock stops
  and the indicator remains **Cadenza** until the pedal cue.
- Microphone samples during manual free time cannot steer playback. Buffered
  samples and pending analysis from before the cadenza or pedal cue are discarded.
  The input meter remains available. A disconnected microphone still interrupts
  live following, as before.
- In both fixed playback and live following, the recorded release can continue
  after the boundary while clicks stop there. It ends after 50 milliseconds below
  the quiet threshold on every channel, at the configured return, or after three
  seconds of source audio, whichever comes first. A short end fade avoids an abrupt
  cutoff if the limit is reached. An early pedal cue stops any remaining tail. Space or application
  suspension also silences a fixed-playback tail while preserving the pedal wait.
- This is a bounded release allowance, not source separation. New orchestral
  notes before the first quiet gap could also sound. The existing audio warning
  remains, with wording explaining this behavior. Place starts at actual releases.
- The return starts at the configured measure and beat at the planned tempo,
  without a count-in. Pausing/resuming the lead-in preserves the same release.
- These changes apply to the native app. Older browser versions still require
  whole-beat cadenza settings; a fractional-beat native export is not compatible
  with those versions.

## This rehearsal

Read-only inspection of the owner's MusicXML found the final orchestral notes
in measure 7 ending at beat 1.5, with no further orchestral notes through measure
12. In the corresponding WAV/MIDI export, that release is at 14.5806255 seconds.
The recorded decay reaches the release detector's quiet threshold at roughly
16.554 seconds, about 1.974 seconds later. The configured start can therefore
move from measure 8 beat 1 to measure 7 beat 1.5 while preserving the recorded
decay. The return remains measure 13 beat 1. These settings belong only to this
exact MIDI export; the owner's music is not stored in the repository.

## Verification

The original regression test failed with `lost` where `cadenza` was expected
following a 300-millisecond microphone delivery. Tests cover that recovery path,
analysis launched on the entry tick and completed after entry or the pedal,
fractional setting persistence and legacy integer imports, exact return position,
planned return tempo, release preservation, quiet-gap termination, a continuously
sounding recording's three-second cap, and resumed lead-in buffers. Synthetic
checks cannot replace a fresh horn rehearsal of the musical handoff.

An opt-in output-device regression (`VC_DEVICE_CHECK=1 swift test --filter
DeviceBindingTests/testPausingCadenzaReleasePreservesPedalReturnOnThisMac`) uses
muted output to verify pause, Space, and suspension silence an actively scheduled
release while retaining the correct pedal return. It reproduced all three
failures before the transport fix.
