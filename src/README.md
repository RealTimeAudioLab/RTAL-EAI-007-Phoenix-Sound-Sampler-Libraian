# Phoenix Librarian v1.1.0 FINAL — BANK16 & Reverb Sync Release

Phoenix Librarian v1.1.0 FINAL is the current stable Windows companion release for the **RTAL Project Phoenix hardware sampler v1.1.0 FINAL**.

The Librarian provides a visual PC environment for preparing, organizing, validating and auditioning Phoenix content while keeping the hardware sampler completely standalone during normal use.

Version 1.1.0 retains the proven v1.0.0 Windows audio/MIDI architecture and synchronizes the editor and file workflow with the Phoenix v1.1.0 firmware format.

## Highlights

### Complete Phoenix bank workflow
- Scan and manage Phoenix banks directly from the SD card / USB mass-storage structure.
- Edit four-slot bank content and metadata.
- Work with `BANK.CFG`, `BANK.INFO`, sample WAV files, patterns and song data.
- Search and organize a Factory Library.
- Create backups and perform controlled restores.
- Create new banks directly as **BANK_VERSION=16**.
- Read existing **BANK15** banks without forcing an automatic conversion.
- Promote BANK15 → BANK16 only when v1.1.0 Reverb/effect data are explicitly saved.

### BANK16 and Reverb synchronization
Phoenix Librarian v1.1.0 is synchronized with the persistent Reverb data used by Phoenix firmware v1.1.0 FINAL.

Global Reverb parameters:
- `REVERB_SIZE`
- `REVERB_DECAY`
- `REVERB_DAMP`
- `REVERB_MIX`

Per-slot Reverb parameter:
- `REVERB_SEND` for S1–S4

Phoenix v1.1.0 default effect values:

```text
ECHO_DELAY_MS=250
ECHO_FEEDBACK=35
ECHO_MIX=20

REVERB_SIZE=55
REVERB_DECAY=55
REVERB_DAMP=45
REVERB_MIX=20
```

New banks start with:

```text
ECHO_SEND=0
REVERB_SEND=0
```

for all four slots.

### INIT_SOUND compatibility
- Supports the optional `/PHOENIX/INIT_SOUND.CFG`.
- Reverb globals and per-slot Reverb sends are preserved in the template workflow.
- `INIT_SOUND.CFG` remains a sound/mapping template rather than a sample-path container.
- Factory Defaults remain available if no custom init template is present.

### Final Echo ranges
The Librarian validation now follows the effective Phoenix v1.1.0 hardware limits:

- Echo Delay: **50–2000 ms**
- Echo Feedback: **0–90 %**
- Echo Mix: **0–100 %**

### Graphical waveform and loop editor
- Edit `S.START`, `L.START`, `L.END` and `S.END` visually.
- One Shot audition from S.START to S.END.
- Dedicated Loop Hold audition beginning at L.START.
- FORWARD and ALTERNATE loops.
- Crossfade, zero-crossing assistance, trim, DC removal and normalization workflows.

### Quattro routing
- KEYZONE and MULTI workflows.
- Low / Root / High key mapping.
- Per-slot MIDI channel configuration.
- Routing-aware validation.

### Sequencer, song and effects editing
- Pattern editor.
- Song editor.
- Offline pattern/song preview rendering.
- Echo, Reverb and effect parameter editing.
- Per-slot Echo Send and Reverb Send.
- Filter and Vintage DSP parameter editing.

The PC effect preview remains an editing aid. Filter, Echo and Vintage processing are approximated where applicable.

The new Phoenix v1.1.0 hardware Reverb is deliberately **not reimplemented as a PC approximation**. The Librarian edits and stores the exact Reverb parameters; the Phoenix hardware remains the sonic reference.

### MIDI and live audition
- Windows MIDI input through WinMM.
- On-screen keyboard.
- Polyphonic live preview.
- Sustain pedal and pitch bend.
- Native real-time pitch playback from a single cached source sample.

## Audio engine

The validated v1.0.0 PC audio architecture remains unchanged in v1.1.0.

The engine uses:

- WASAPI Event mode
- Exclusive mode with Shared fallback
- 48 kHz / PCM16 stereo
- `LIVE-10ms`: 480-frame buffer for MIDI and screen-keyboard audition
- `EDITOR-20ms`: 960-frame buffer for waveform preview
- MMCSS `Pro Audio`
- fixed 16-voice pool
- preallocated command ring buffer
- GC-isolated render path
- single-source-sample RAM cache
- native pitch and loop processing

The audio endpoint is acquired **on demand**. Phoenix Librarian does not hold the Windows sound device merely because the application is open. After playback becomes idle or the waveform preview is stopped, the endpoint is released again so other Windows applications can use it.

## Relationship to the Phoenix hardware

Phoenix Librarian is deliberately a **companion editor**, not part of the sampler's required real-time playback chain.

```text
Phoenix hardware sampler
        ↕
SD card / USB mass storage
        ↕
Phoenix Librarian on Windows
```

Banks are prepared and managed on the PC, then used autonomously by Phoenix. The hardware remains a standalone musical instrument.

## File-format compatibility

```text
Project Phoenix firmware   v1.1.0 FINAL
Phoenix bank format        BANK_VERSION=16
Legacy bank read support   BANK_VERSION=15
Multisample format         10
PATTERNS.CFG               VERSION=1
SONG.CFG                   VERSION=2
INIT_SOUND.CFG             VERSION=1
```

Opening or browsing a BANK15 bank does not rewrite it. When the user explicitly saves v1.1.0 Echo/Reverb/effect data, the Librarian writes the new Reverb fields and promotes the bank header to BANK16.

## Platform

- Windows 10 or later
- Windows PowerShell 5.1
- WPF
- Native WinMM MIDI
- Native WASAPI audio components embedded through C#

## Starting the Librarian

Extract the release archive and run:

`Start_Phoenix_Librarian.cmd`

Alternatively, start `PhoenixLibrarian.ps1` from Windows PowerShell 5.1 if your local execution policy permits it.

## Release status

**v1.1.0 FINAL is the current stable Phoenix Librarian release.**

It is promoted from the existing v1.1.0 Reverb-synchronization development line and is intended to be used together with **Project Phoenix firmware v1.1.0 FINAL**.

The release deliberately preserves the proven v1.0 audio/MIDI core and limits functional changes to Phoenix v1.1.0 data-format and Reverb synchronization.

Future development should branch from v1.1.0 FINAL rather than modify the archived release source directly.

## Notes

Phoenix Librarian can request Exclusive access to the Windows audio endpoint while it is actively producing sound. The on-demand architecture releases the endpoint again after use instead of occupying it for the entire application session.

Phoenix v1.1.0 Reverb parameters are stored exactly for the hardware, but the hardware Reverb itself is not emulated in the PC preview.

Please report reproducible issues together with:
- the relevant Phoenix bank configuration,
- the action that triggered the problem,
- the Phoenix firmware version,
- and the Librarian log where possible.

---

**RealTimeAudioLab / RTAL**  
Phoenix Librarian v1.1.0 FINAL  
September 2026
