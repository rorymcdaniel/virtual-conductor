# Visual beats from an audio recording

Feasibility inquiry, 2026-11-14. Research only; no application code was changed and no recordings were analyzed for this inquiry.

## Assessment

A useful version is feasible: analyze an imported recording once, retain the estimated times of its beats, and animate a visual pulse or conducting pattern against that recording's playback clock. A full score and live soloist following are unnecessary for that workflow. This is an engineering assessment based on the available offline tools below, not a measured accuracy claim about the owner's repertoire.

The harder requirement is a reliably correct musical interpretation throughout arbitrary classical recordings. The realistic expectation is automatic analysis with occasional correction. Whether the correction burden is small enough must be tested on representative recordings; literature does not establish that for this owner.

## Available methods

[Beat This!](https://github.com/CPJKU/beat_this) provides an official Python API and command-line program that return beat and downbeat timestamps from audio files. It supports CPU inference and publishes pretrained models, so an initial evaluation does not require training a model or a live audio service. Its README lists Python/PyTorch dependencies and approximately 78 MB and 8.1 MB model variants. Native application packaging remains integration work; these facts do not establish import speed on the owner's computer.

The [Beat This! paper](https://arxiv.org/html/2407.21658v1) includes classical music and changing meter in its evaluation/training scope and avoids the common DBN decoder's fixed meter and tempo constraints. It also explicitly reports remaining failures and weaker continuity: isolated good beat detections are not the same as an uninterrupted usable conducting sequence. Some ASAP tracks with rubato annotations were excluded. Its aggregate metrics should therefore not be presented as a success probability for a complete orchestral movement.

[madmom's downbeat tracker](https://madmom.readthedocs.io/en/v0.16.1/modules/features/downbeats.html) accepts expected beats per bar and tempo ranges and returns timestamps with beat positions within the bar. It is a useful comparison when meter is known. Its tempo-change penalty and permitted range require deliberate configuration; the defaults favor continuity rather than arbitrary expressive timing.

[librosa's variable-tempo example](https://librosa.org/doc/latest/auto_tutorials/03-advanced/plot_dynamic_beat.html) documents why a single estimated tempo is inadequate for substantial changes. It supports a time-varying tempo supplied to its beat tracker, making it a useful baseline, but the demonstrated accelerating drum example is not validation on orchestral recordings.

## Where accuracy becomes difficult

[Research on expressive classical piano](https://mir.dei.uc.pt/pdf/Journals/MERGE/TASLP_2023_Chiu.pdf) shows that global tempo assumptions can fail under local expressive changes. It also identifies weak or blurred attacks in non-percussive instruments as a challenge. Rubato, large ritardandos, sparse textures, and long sustained sounds should consequently be included in an orchestral evaluation, rather than testing only clear rhythmic passages.

A [Beethoven sonata downbeat study](https://www.audiolabs-erlangen.de/content/05_fau/professor/00_mueller/06_projects/78_learn/2024_ChiuZAM_DownbeatBeethoven_DAGA.pdf) finds that downbeat interpretation can be ambiguous without the score and requires broader musical context than detecting individual beats. Its piano results do not establish performance for an orchestra; the authors deliberately chose piano because its attacks are clearer than strings or choir.

For this product, these findings imply several distinct errors to review:

- Timing: the pulse lands early or late relative to the audible beat.
- Beat level: the tracker chooses subdivisions or half/double the intended pulse.
- Bar position: the pulse is plausible but the visual beat one is misplaced.
- Continuity: an extra or missed beat shifts the subsequent count.
- Unmetered passages: a cadenza, pause, or fermata may not contain a uniquely
  recoverable sequence of regular conducting beats.

These are evaluation categories and musical inferences, not measured failure rates. A reliable playback clock prevents added synchronization drift; it cannot make an incorrect beat map musically correct.

## What the horn-part PDF contributes

The part supplies useful musical constraints: meter, meter changes, possible beat-unit markings, and a human reference for correcting bar position. It does not by itself say when those measures occur in this particular recording. Extracting notation from a PDF and aligning it to audio are additional tasks; neither is required merely to show the beat.

A minimal workflow could ask the owner to confirm meter and the intended pulse and, if necessary, identify beat one. For example, 6/8 may call for two dotted quarter-note conducting beats rather than six eighth-note flashes; 3/4 can be conducted in three or one. The displayed tempo must name its beat unit. Meter alone cannot settle every such choice. Changing meter needs section boundaries located in recording time, whether detected or corrected by the owner.

These are musical/product conclusions, rather than claims of an existing automatic PDF-import capability. The PDF can remain a reference throughout.

## Engineering implications

A credible workflow would analyze once, preview and correct beat one or the pulse level, then animate from the recording's playback clock. Local tempo is `60 / d` BPM for successive beats `d` seconds apart, with the beat unit named. The numerical display can be smoothed while the animation retains actual beat timestamps. Known future beats permit preparatory motion before each beat. Confirmed holds and unmetered passages need explicit representation.

Repository inspection finds reusable playback and visual foundations, but no existing score-free recording importer or orchestral beat tracker. [PerformanceTiming](../../Sources/ConductorCore/Timing.swift) uses a MIDI-derived timeline and four-beat arithmetic; [Geometry.swift](../../Sources/ConductorCore/Geometry.swift) and [ConductorSurface](../../Sources/VirtualConductor/ConductorSurface.swift) use a four-point pattern. Audio-only timing and other meter patterns therefore require new work. The existing performance-tempo transfer workflow requires a matching full MusicXML score and has linear 4/4 constraints; see [the workflow documentation](../performance-tempo-transfer.md).

## Evidence needed before promising accuracy

A small listening evaluation should cover a steady passage, expressive slow music, compound or changing meter, and a pause or cadenza. Compare estimated beats with independently marked reference beats and assess timing error, continuity, correct beat level, downbeats, import time, and time spent correcting each recording. Also check the visual/audio synchronization during play, pause, seek, and replay. A detector's confidence output alone should not be treated as a calibrated probability that the conducting map is correct.

The decisive product question is whether a brief setup gives the owner a visual guide they can trust for an entire play-through. The feasibility evidence is strong enough to justify that evaluation if requested, but does not justify a promise of flawless, zero-adjustment detection for every classical recording.
