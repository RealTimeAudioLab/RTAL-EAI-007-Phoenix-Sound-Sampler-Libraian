# Phoenix Librarian Architecture

Phoenix Librarian v1.1.0 combines a PowerShell/WPF application layer with embedded C# components for the parts that require deterministic native Windows access.

Version 1.1.0 retains the proven v1.0 audio/MIDI architecture and extends the file/editor layer for **Project Phoenix v1.1.0 FINAL**, including **BANK16**, Reverb parameters and `INIT_SOUND.CFG`.

## High-level structure

```text
WPF UI
  |
  +-- PowerShell application state
  |     +-- bank scanning
  |     +-- BANK15 / BANK16 configuration parsing
  |     +-- metadata
  |     +-- import/export
  |     +-- backup/restore
  |     +-- pattern/song workflows
  |     +-- Echo / Reverb / effects workflows
  |     +-- INIT_SOUND template handling
  |
  +-- Embedded C# modules
        +-- WinMM MIDI input
        +-- WASAPI audio engine
        +-- native pitch / loop mixer
        +-- timing and health counters
```

## Why PowerShell + WPF

The Librarian was intentionally kept inspectable and portable. PowerShell 5.1 provides the file-system and automation layer while WPF provides a native Windows desktop UI. Time-critical work is moved out of PowerShell and into embedded C#.

This separation remains unchanged in v1.1.0.

## File-format architecture in v1.1.0

The Librarian works directly with the Phoenix files instead of maintaining a proprietary PC project database.

The current Phoenix compatibility baseline is:

```text
Project Phoenix firmware   v1.1.0 FINAL
BANK_VERSION               16
Legacy BANK_VERSION        15 (read-compatible)
MULTISAMPLE_VERSION        10
PATTERNS.CFG               VERSION=1
SONG.CFG                   VERSION=2
INIT_SOUND.CFG             VERSION=1
```

### BANK15 compatibility

Existing BANK15 banks remain readable.

Opening, scanning or previewing a BANK15 bank does **not** automatically rewrite it.

When the user explicitly saves v1.1.0 Echo/Reverb/effect parameters, Phoenix Librarian writes the new Reverb fields and promotes the bank header to:

```text
BANK_VERSION=16
```

This avoids uncontrolled bulk migration of an existing Phoenix library.

### BANK16 Reverb data

Phoenix Librarian v1.1.0 supports the following global BANK16 values:

```text
REVERB_SIZE
REVERB_DECAY
REVERB_DAMP
REVERB_MIX
```

Each slot additionally supports:

```text
REVERB_SEND
```

for S1 through S4.

The Echo fields remain part of the same bank workflow:

```text
ECHO_DELAY_MS
ECHO_FEEDBACK
ECHO_MIX
ECHO_SEND
```

The effective v1.1.0 validation ranges are:

```text
Echo Delay       50..2000 ms
Echo Feedback    0..90 %
Echo Mix         0..100 %
Reverb globals   0..100 %
Reverb Send      0..100 %
```

## INIT_SOUND architecture

Phoenix v1.1.0 can use:

```text
/PHOENIX/INIT_SOUND.CFG
```

as an optional sound/mapping template for new banks.

Phoenix Librarian v1.1.0 reads and writes the corresponding v1.1.0 sound parameters, including Echo/Reverb settings and per-slot sends.

`INIT_SOUND.CFG` is intentionally a **sound and mapping template**, not a container for sample paths or current song/pattern data.

## Audio design evolution

The preview system evolved through several architectures:

1. WPF `MediaPlayer` for simple preview.
2. Pre-rendered pitched WAV caches to obtain correct pitch.
3. Segmented attack/hold/release preview experiments.
4. Native WASAPI shared-mode playback.
5. WASAPI Exclusive/Event playback with lower latency.
6. Native pitch from a single source sample in RAM.
7. Stable dual audio profiles: LIVE 10 ms and EDITOR 20 ms.
8. Fixed voice pool and preallocated command ring buffer to remove managed allocation pressure from the real-time path.
9. On-demand Exclusive mode so Phoenix does not hold the Windows audio endpoint while idle.

The final v1.0.0 design prioritized repeatable stability over the smallest technically possible buffer size. Phoenix Librarian v1.1.0 deliberately keeps this validated real-time architecture unchanged.

## Real-time audio core

The audio engine uses:

- 48 kHz output
- PCM16 stereo
- WASAPI Event mode
- Exclusive mode when available
- Shared mode fallback
- MMCSS `Pro Audio`
- a fixed 16-voice pool
- a preallocated command ring buffer
- a preallocated PCM work buffer
- interpolation and pitch stepping in the native mixer
- no disk reads during Note On after the source sample has been cached

### Profiles

`LIVE-10ms` is optimized for MIDI and screen-keyboard responsiveness.

`EDITOR-20ms` provides additional scheduling margin for continuous waveform audition and looping.

## Effects preview architecture

The PC preview remains intentionally separated from the exact embedded DSP implementation.

Phoenix Librarian v1.1.0 can approximate or preview established Filter, Echo and Vintage processing where applicable.

The new Phoenix v1.1.0 hardware Reverb is **not** reimplemented as a PC approximation. The Librarian edits and stores the exact BANK16 Reverb parameters while the Phoenix hardware remains the sonic reference.

This prevents a superficially similar but technically different PC Reverb from being mistaken for the actual ESP32-S3 DSP.

## On-demand endpoint ownership

Exclusive WASAPI is not opened merely because the application or a Phoenix SD card is present. The endpoint is acquired only when Phoenix actually needs to produce sound. It is released again after preview stops or after the live engine has been idle for a short period.

This prevents Phoenix Librarian from unnecessarily blocking Windows Media Player, a DAW or another application while the Librarian is being used only for file editing.

## v1.1.0 architecture principle

The v1.1.0 release intentionally separates two concerns:

```text
Stable v1.0 real-time PC core
        +
Phoenix v1.1.0 file / BANK16 / Reverb synchronization
        =
Phoenix Librarian v1.1.0 FINAL
```

The real-time audio path was not rewritten merely to accompany a bank-format update.
