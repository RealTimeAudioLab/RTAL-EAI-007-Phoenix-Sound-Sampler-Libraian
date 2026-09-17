# Development History

Phoenix Librarian v1.1.0 is the result of an iterative development process in which functionality and audio reliability were measured and refined rather than being treated as a single monolithic implementation.

The v1.1.0 release builds directly on the stable v1.0.0 architecture and adds synchronization with **Project Phoenix firmware v1.1.0 FINAL**.

## Early editor stages

The first stages concentrated on Phoenix bank parsing, four-slot sample management and editing the sampler's configuration files. The UI was progressively expanded with waveform visualization, loop points, routing parameters, pattern/song data and backup workflows.

## Waveform and loop editing

The waveform editor evolved into a dedicated sample-preparation environment with S.START, L.START, L.END and S.END, zero-crossing assistance, normalization/DC workflows and FORWARD/ALTERNATE loop audition.

A final v1.0.0 UI rule was frozen:

- One Shot playhead begins at S.START.
- Loop Hold playhead begins at L.START.

This behavior remains unchanged in v1.1.0.

## Pattern / song preview

Early WPF `MediaPlayer` step playback produced clicks and unreliable timing. Pattern and song preview therefore moved to offline rendering. This gave deterministic timing and eliminated the discontinuities caused by repeatedly starting independent player instances.

The offline pattern/song architecture remains unchanged in v1.1.0.

## Live preview and pitch

The live preview first used temporary WAV files and WPF MediaPlayer. Pitch through `SpeedRatio` proved unsuitable, so pitched sample caches were generated. This worked but became memory-heavy when long HOLD files were pre-rendered for many notes.

The architecture was replaced with a native pitch engine: one original source sample is held in RAM and the playback step is varied in the mixer. This removed the need for per-note pitch files.

This native pitch architecture remains the v1.1.0 preview core.

## WASAPI work

Shared-mode WASAPI improved control of the audio path but the Windows endpoint still exposed a relatively large effective buffer. Exclusive/Event mode was then developed and the endpoint was probed for supported formats.

The tested device accepted PCM16 stereo at 48 kHz. Very small 3 ms buffers were achievable, but long-run tests demonstrated scheduling sensitivity. The stable release therefore uses:

- LIVE: 480 frames / 10 ms
- EDITOR: 960 frames / 20 ms

These validated profiles remain unchanged in v1.1.0.

## Dropout investigation

A sequence of diagnostic builds measured event wakeups, mixer time, write time and complete render-loop time. The mixer itself was consistently very fast, while managed runtime stalls could cause much larger timing excursions.

The final solution was not simply to keep increasing the buffer. Instead, the audio core was redesigned to reduce managed-runtime interference:

- fixed voice pool
- preallocated command ring buffer
- no dynamic voice creation in the render loop
- preallocated output buffers
- deferred diagnostics
- GC-isolated render architecture

This eliminated the audible dropouts in the validated v1.0.0 test path and remains the frozen real-time basis for v1.1.0.

## Audio endpoint ownership

Keeping an Exclusive WASAPI endpoint open from application startup prevented other Windows applications from playing sound. The v1.0.0 architecture therefore acquires Exclusive audio only when Phoenix actually needs playback and releases it again after use.

This remains unchanged in v1.1.0.

## From v1.0.0 to v1.1.0

After the Windows audio/MIDI core had reached a stable v1.0.0 state, Project Phoenix itself evolved to firmware v1.1.0.

The Librarian therefore required a **data-format synchronization release**, not a new PC audio engine.

The main v1.1.0 development goals were:

- support Phoenix `BANK_VERSION=16`
- retain safe BANK15 read compatibility
- add global Reverb parameters
- add per-slot Reverb Send
- synchronize Echo limits with the final hardware implementation
- add Reverb-aware `INIT_SOUND.CFG` support
- retain the v1.0 Windows audio/MIDI core unchanged

## BANK16 and Reverb synchronization

Phoenix v1.1.0 added persistent Reverb data to the bank format.

Phoenix Librarian was extended with:

```text
REVERB_SIZE
REVERB_DECAY
REVERB_DAMP
REVERB_MIX
```

and per slot:

```text
REVERB_SEND
```

for S1 through S4.

The release also synchronizes the effective Echo ranges with the hardware:

```text
ECHO_DELAY_MS    50..2000
ECHO_FEEDBACK    0..90
ECHO_MIX         0..100
```

## Controlled BANK15 migration

An important compatibility decision was **not** to rewrite every BANK15 bank merely because it had been scanned or opened.

Phoenix Librarian v1.1.0 therefore follows this rule:

```text
Read / browse BANK15
        -> leave file unchanged

Explicitly save v1.1.0 Reverb/effects
        -> write Reverb fields
        -> promote header to BANK_VERSION=16
```

This keeps migration intentional and traceable.

## INIT_SOUND synchronization

The optional Phoenix v1.1.0 file:

```text
/PHOENIX/INIT_SOUND.CFG
```

was integrated into the Librarian workflow.

The v1.1.0 template path supports Reverb globals and per-slot Reverb sends while remaining a sound/mapping template rather than a complete bank/sample-path container.

## DEV2 Reverb synchronization branch

The existing `Phoenix_Librarian_v1_1_0_DEV2_REVERB_SYNC` branch provided the development basis for the v1.1.0 release.

Before FINAL promotion, the release work included:

- final BANK16 new-bank creation
- Reverb-aware effect save path
- final Echo validation ranges
- Reverb-aware INIT_SOUND workflow
- correction of the DEV2 Reverb validation path under PowerShell `Set-StrictMode`
- release/version cleanup

## Why the hardware Reverb is not emulated on the PC

Phoenix Librarian already contains useful PC-side previews for established processing.

For v1.1.0, the new ESP32-S3 Reverb was deliberately **not** recreated as a merely similar desktop effect.

The Librarian stores the hardware parameters exactly, while the Phoenix hardware remains the reference for final Reverb sound.

This avoids presenting two different algorithms as if they were equivalent.

## v1.1.0 FINAL

The resulting release can be summarized as:

```text
v1.0.0
Stable Windows audio / MIDI / editor core
        |
        v
v1.1.0 development
BANK16 + Reverb + INIT_SOUND synchronization
        |
        v
v1.1.0 FINAL
Stable Phoenix v1.1.0 companion release
```

The main engineering principle remained the same throughout development: change the subsystem that actually needs change, and avoid destabilizing a measured, validated real-time path without a reproducible reason.
