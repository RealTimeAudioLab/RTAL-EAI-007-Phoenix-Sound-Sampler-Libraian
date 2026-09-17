# RTAL-EAI-006-Phoenix-Sound-Sampler-Librarian
**Windows Bank Manager, Sample Editor, Sequencer Editor, Backup Center and Low-Latency Preview System for the RTAL Project Phoenix Sampler**

![Version](https://img.shields.io/badge/version-1.1.0-blue)
![Platform](https://img.shields.io/badge/platform-Windows-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![Audio](https://img.shields.io/badge/audio-WASAPI%20Exclusive%20%2F%20Shared-brightgreen)
![MIDI](https://img.shields.io/badge/MIDI-WinMM-orange)

Phoenix Librarian is the companion Windows application for the **RTAL Project Phoenix** hardware sampler. It was developed to make the complete Phoenix bank structure accessible from a PC without turning the sampler into a computer-dependent instrument.

Phoenix itself remains the autonomous embedded sampler. The Librarian is the workstation around it: it manages banks, edits sample and loop parameters, creates routing setups, programs patterns and songs, previews samples and MIDI mappings, manages metadata, performs backups and restores, validates bank contents and provides a low-latency PC audition engine.

Version **1.1.0 FINAL** is the current stable companion release for **Project Phoenix firmware v1.1.0 FINAL**. It retains the proven v1.0 Windows audio/MIDI architecture and adds full **BANK16, Reverb and INIT_SOUND compatibility**.

> The central design goal was not to replace Phoenix, but to make editing, library maintenance and preparation of Phoenix content faster, safer and more visual while keeping the hardware sampler fully independent.

<p align="center">
<img src="images/RTAL_Wellenbad_Waveform-Editor.JPG" width="900">  
---

## Contents

- [Project overview](#project-overview)
- [What's new in v1.1.0](#whats-new-in-v110)
- [Phoenix + Librarian workflow](#phoenix--librarian-workflow)
- [How the Librarian was built](#how-the-librarian-was-built)
- [Software architecture](#software-architecture)
- [Installation and start](#installation-and-start)
- [Phoenix v1.1.0 compatibility](#phoenix-v110-compatibility)
- [Phoenix storage structure](#phoenix-storage-structure)
- [Feature tour](#feature-tour)
- [Waveform editor](#waveform-editor)
- [Quattro routing](#quattro-routing)
- [Sequencer and pattern editor](#sequencer-and-pattern-editor)
- [Song editor](#song-editor)
- [Echo, Reverb and effects editor](#echo-reverb-and-effects-editor)
- [MIDI and screen keyboard](#midi-and-screen-keyboard)
- [PC audio engine](#pc-audio-engine)
- [Factory Library](#factory-library)
- [Backup and Restore](#backup-and-restore)
- [Validation and Self Test](#validation-and-self-test)
- [Data safety](#data-safety)
- [Development history](#development-history)
- [Known limitations](#known-limitations)
- [Suggested GitHub repository structure](#suggested-github-repository-structure)
- [Screenshots and media](#screenshots-and-media)
- [Project status](#project-status)

---

# Project overview

Project Phoenix is an embedded sampler project developed by **RealTimeAudioLab / RTAL**. The hardware sampler stores its samples, bank configuration, patterns, songs and related data on removable storage. Phoenix Librarian works directly with this data structure and therefore acts as a bridge between the Windows editing environment and the embedded sampler.

The Librarian combines several normally separate tools in one application:

- Phoenix bank manager
- four-slot sample librarian
- graphical waveform and loop editor
- KEYZONE / MULTI routing editor
- pattern and sequencer editor
- song editor
- BANK16-compatible Echo / Reverb / effect parameter editor
- MIDI monitor and live keyboard
- low-latency sample audition engine
- Factory Library builder
- backup and restore center
- bank validator
- system diagnostics and self test
- configuration-file inspector

No database is required. The Phoenix files on the SD card / USB mass-storage volume remain the authoritative project data.

---

# What's new in v1.1.0

Phoenix Librarian v1.1.0 is synchronized with the persistent bank format used by **Project Phoenix v1.1.0 FINAL**.

The release adds:

- **BANK_VERSION 16** support
- read compatibility with existing **BANK15** libraries
- controlled BANK15 → BANK16 promotion when Reverb/effect parameters are explicitly saved
- global Reverb parameters:
  - `REVERB_SIZE`
  - `REVERB_DECAY`
  - `REVERB_DAMP`
  - `REVERB_MIX`
- independent `REVERB_SEND` for slots **S1–S4**
- Reverb-aware **INIT_SOUND.CFG** handling
- synchronized Phoenix v1.1.0 factory FX defaults
- final hardware-effective Echo validation:
  - Delay **50–2000 ms**
  - Feedback **0–90 %**
  - Mix **0–100 %**
- a corrected Reverb validation path for Windows PowerShell `Set-StrictMode`
- preservation of the established v1.0 low-latency WASAPI / MIDI preview core

Phoenix v1.1.0 hardware Reverb is deliberately **not** replaced by an approximate PC Reverb algorithm in this release. The Librarian edits and stores the exact hardware parameters; the Phoenix hardware remains the sonic reference for Reverb.

A legacy BANK15 bank is not rewritten merely because it is opened. When Reverb/effect data are explicitly saved with v1.1.0, the file is updated with the new fields and promoted to `BANK_VERSION=16`.

<!-- IMAGE PLACEHOLDER: Main Phoenix Librarian window -->
<!-- Suggested file: images/phoenix-librarian-main.png -->

---

# Phoenix + Librarian workflow

The intended workflow is deliberately simple:

```text
                 ┌─────────────────────┐
                 │   Project Phoenix   │
                 │   Hardware Sampler  │
                 └─────────┬───────────┘
                           │
                 USB Mass Storage / SD
                           │
                           ▼
                 ┌─────────────────────┐
                 │  Phoenix Librarian  │
                 │      Windows        │
                 └─────────┬───────────┘
                           │
       ┌───────────────────┼────────────────────┐
       ▼                   ▼                    ▼
 Bank / Sample Edit   Pattern / Song Edit   Backup / Library
       │                   │                    │
       └───────────────────┴────────────────────┘
                           │
                           ▼
                  Save to Phoenix media
                           │
                           ▼
                 Phoenix plays standalone
```

A typical session looks like this:

1. Phoenix exposes its storage to Windows through USB mass storage, or the SD card is mounted directly.
2. Phoenix Librarian locates the `PHOENIX` structure automatically or the user selects it manually.
3. The application scans all available banks.
4. Samples, markers, metadata, routing, patterns, songs and effects can be inspected and edited.
5. Samples can be auditioned directly on the PC without transferring them into another audio application.
6. The edited bank is saved back into the Phoenix file structure.
7. Phoenix then uses the edited data autonomously on the hardware.

This separation is important: **the PC is an editor and librarian, not part of the real-time signal path of the hardware sampler.**

---

# How the Librarian was built

Phoenix Librarian is unusual in that the complete application was developed around **Windows PowerShell 5.1**, WPF and small embedded C# modules instead of a traditional Visual Studio project.

This approach made it possible to keep the application portable and easy to inspect while still using native Windows APIs where PowerShell alone would not have been suitable.

## PowerShell as application framework

The main application logic is implemented in `PhoenixLibrarian.ps1`.

PowerShell handles:

- application state
- bank scanning
- file operations
- Phoenix configuration parsing
- metadata management
- validation
- import/export
- pattern and song data
- backup/restore workflows
- WPF event handling
- UI state synchronization
- logging and diagnostics

The application can therefore be inspected and modified without requiring a compiled executable project.

## WPF user interface

The graphical interface is built with **Windows Presentation Foundation (WPF)**.

The Librarian loads the standard Windows assemblies:

- `PresentationFramework`
- `PresentationCore`
- `WindowsBase`
- `System.Windows.Forms`
- `System.Drawing`

The interface is defined from XAML and connected to PowerShell event handlers. This allowed the project to evolve rapidly while still providing a native Windows desktop interface with tabs, grids, dialogs, progress bars, waveform canvases and editable data tables.

## Embedded C# where real-time performance matters

Several performance-critical or low-level subsystems are compiled at runtime with PowerShell `Add-Type`.

These C# modules provide direct access to native Windows APIs for:

- MIDI input
- MIDI output
- WASAPI audio
- COM audio interfaces
- event-driven audio rendering
- high-priority multimedia scheduling

This hybrid design became one of the key architectural decisions of the project:

```text
PowerShell / WPF
    │
    ├── Bank management
    ├── Editors
    ├── File I/O
    ├── UI
    ├── Validation
    └── Workflow
            │
            ▼
Embedded C# runtime modules
    │
    ├── WinMM MIDI
    ├── WASAPI audio
    ├── Native pitch playback
    ├── Voice engine
    └── Real-time scheduling
```

## MIDI implementation

Phoenix Librarian accesses the Windows multimedia MIDI API directly through `winmm.dll`.

The embedded C# wrappers provide:

- enumeration of MIDI input devices
- enumeration of MIDI output devices
- opening and closing ports
- short MIDI messages
- Note On / Note Off
- controller processing
- sustain handling
- pitch bend

No external MIDI framework is required for the basic MIDI functionality.

## Audio implementation

The audio subsystem went through extensive development during the v0.9 and v1.0 release-candidate phases.

Early builds used WPF `MediaPlayer`. That was sufficient for simple preview playback but introduced several limitations:

- noticeable first-note latency
- unreliable pitch control for sampler-style transposition
- difficulty chaining attack and loop sections seamlessly
- incompatibility with the later WASAPI Exclusive live-audio path

The final solution is a dedicated native-style **WASAPI sample playback engine** embedded in the application.

The engine uses one decoded source sample per occupied Phoenix slot and performs pitch transposition directly while reading the PCM data. This avoids generating a separate WAV file for every MIDI note.

During development, extensive timing measurements exposed sporadic Windows/.NET scheduling interruptions. The final v1.0 engine therefore uses a GC-isolated design with fixed/preallocated real-time structures rather than allocating objects during playback.

---

# Software architecture

The final application can be viewed as five cooperating layers:

```text
┌──────────────────────────────────────────────────────────────┐
│                         WPF GUI                              │
│ Tabs • Waveform • Tables • Keyboard • Status • Dialogs      │
└──────────────────────────────┬───────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────┐
│                    PowerShell Application                    │
│ Banks • Editors • Validation • Backup • Library • Workflow  │
└───────────────┬───────────────────────┬──────────────────────┘
                │                       │
        ┌───────▼────────┐      ┌──────▼──────────┐
        │ Phoenix Files  │      │ Offline Preview │
        │ CFG / WAV /    │      │ Pattern / Song  │
        │ Pattern / Song │      │ DSP Rendering   │
        └────────────────┘      └─────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────────────────┐
│                  Embedded Native C# Layer                    │
│ WinMM MIDI • WASAPI • Voice Pool • Pitch • MMCSS             │
└──────────────────────────────────────────────────────────────┘
```

The architecture deliberately keeps storage editing separate from real-time audio. A slow backup, directory scan or metadata operation must never be part of the audio rendering algorithm.

---

# Installation and start

## Requirements

- Windows 10 or later
- Windows PowerShell 5.1
- WPF-capable Windows installation
- access to a Phoenix SD card, USB mass-storage volume or local Phoenix data copy
- optional Windows-compatible MIDI interface for MIDI input/output

No installer is required.

## Start

1. Download the Phoenix Librarian release ZIP.
2. Extract the complete archive to a local folder.
3. Start:

```text
Start_Phoenix_Librarian.cmd
```

4. Let the Librarian search for the Phoenix volume automatically or choose the Phoenix directory manually.
5. Before major edits, create a backup using **Backup & Restore**.

> Do not run the main `.ps1` from inside the ZIP archive. Extract the package first.

---

# Phoenix v1.1.0 compatibility

Phoenix Librarian v1.1.0 is intended for the current Project Phoenix release family:

```text
Project Phoenix firmware   v1.1.0 FINAL
Phoenix bank format        BANK16
Multisample format         10
PATTERNS.CFG               VERSION=1
SONG.CFG                   VERSION=2
INIT_SOUND.CFG             VERSION=1
```

The application still understands BANK15 so existing libraries can be inspected and migrated deliberately rather than through a forced bulk conversion.

---

# Phoenix storage structure

The Librarian understands the Phoenix bank-oriented directory layout. A typical structure is:

```text
PHOENIX/
├── SESSION_A.BIN
├── SESSION_B.BIN
├── LASTBANK.CFG
├── INIT_SOUND.CFG        (optional)
└── BANKS/
    ├── BANK01/
    │   ├── BANK.CFG
    │   ├── BANK.INFO
    │   ├── SLOT1.WAV
    │   ├── SLOT2.WAV
    │   ├── SLOT3.WAV
    │   ├── SLOT4.WAV
    │   ├── PATTERNS.CFG
    │   └── SONG.CFG
    ├── BANK02/
    └── ...
```

Not every bank must contain all four samples. The Librarian detects the actual content and reports missing or incomplete data.

`BANK.CFG` remains the core hardware configuration file. `BANK.INFO` adds human-readable library metadata such as bank name, author, category, description, license, tags and slot names.

For Phoenix v1.1.0 the current bank format is:

```text
PROJECT_PHOENIX_BANK=1
BANK_VERSION=16
```

The Librarian continues to read legacy BANK15 banks. It does **not** rewrite them just by browsing or loading them. An explicit Echo/Reverb/effects save writes the v1.1.0 Reverb fields and promotes the bank header to BANK16.

`SESSION_A.BIN`, `SESSION_B.BIN` and `LASTBANK.CFG` belong to the Phoenix hardware session-persistence system. The Librarian does not need to modify these files during normal bank editing. `INIT_SOUND.CFG` can be used as the optional sound/mapping template for a new Phoenix bank.

The Librarian includes a raw `BANK.CFG` view so advanced users can always inspect what is actually stored for the hardware.

---

# Feature tour

## Bank management

The bank manager is the central navigation area of the Librarian.

It can:

- scan all Phoenix banks
- create new banks
- copy banks
- move bank content
- delete banks with confirmation
- import bank data
- export banks
- show occupied and empty slots
- display sample duration and status
- expose important sample parameters at a glance
- refresh the Phoenix media after external changes

The bank overview shows, among other information:

- slot number
- sample name
- recording/sample status
- duration
- root note
- loop mode
- crossfade
- Trim status
- DC correction status
- Normalize status
- validation/result status

<!-- IMAGE PLACEHOLDER: Bank overview -->
<!-- Suggested file: images/bank-overview.png -->

---

## Bank metadata

Phoenix banks can carry descriptive metadata in addition to their technical sampler parameters.

Editable metadata includes:

- bank name
- category
- author
- description
- license
- tags
- slot/sample names

This information is especially useful when a larger Phoenix library is maintained on a PC or prepared for publication.

---

# Waveform editor

The waveform editor is one of the core parts of Phoenix Librarian.

It provides a graphical view of the sample together with the four Phoenix sample/loop markers:

```text
S.START        L.START                  L.END        S.END
   │              │                       │            │
   ▼              ▼                       ▼            ▼
---|--------------|=======================|------------|---
                  <----- loop area ------->
```

## Marker editing

The editor supports:

- `S.START` — sample start
- `L.START` — loop start
- `L.END` — loop end
- `S.END` — sample end
- graphical marker positioning
- precise numeric editing
- sample-accurate nudge operations
- marker consistency checks
- waveform zoom/navigation logic

## Zero crossing support

Loop and sample boundaries can be aligned to zero crossings to reduce clicks caused by discontinuities.

This is especially useful for sustained material and for preparing classic sampler-style loops.

## Sample processing

The editor contains tools for:

- Trim
- DC offset correction
- Normalize
- sample-bound validation

These operations are integrated into the Phoenix workflow instead of requiring a separate wave editor for every small correction.

## Loop modes

Phoenix Librarian supports the Phoenix loop modes:

### FORWARD

```text
L.START ───────────────► L.END
   ▲                       │
   └───────────────────────┘
```

### ALTERNATE / Ping-Pong

```text
L.START ───────────────► L.END
L.START ◄─────────────── L.END
```

The native preview engine reflects fractional playback positions correctly at Ping-Pong boundaries so non-integer pitch ratios do not repeatedly duplicate the boundary sample.

## Loop crossfade

Crossfade parameters can be edited and auditioned to smooth loop transitions where appropriate.

## One Shot preview

**One Shot** auditions the complete selected sample range:

```text
S.START ─────────────────────────────────► S.END
```

The white playback cursor starts at `S.START` and follows the sample to `S.END`.

## Loop Hold preview

**Loop Hold** is intended specifically for loop inspection.

The white playback cursor begins at `L.START` and follows only the loop region:

```text
L.START ───────────────► L.END     FORWARD
L.START ◄──────────────► L.END     ALTERNATE
```

This makes the visual display match what the user is evaluating acoustically.

<!-- IMAGE PLACEHOLDER: Waveform editor with S.START/L.START/L.END/S.END -->
<!-- Suggested file: images/waveform-editor.png -->

---

# Quattro routing

Phoenix uses four sample slots that can be organized in two fundamentally different ways.

## KEYZONE mode

In `KEYZONE` mode each slot represents a keyboard region.

For every slot the Librarian edits:

- LOW note
- ROOT note
- HIGH note

Example:

```text
S1        S2        S3        S4
C1–B2     C3–B3     C4–B4     C5–C7
```

The Librarian validates zone ranges and presents the mapping in a form that is much easier to inspect than a small hardware display.

## MULTI mode

In `MULTI` mode each slot can respond independently to a MIDI channel.

Editable parameters include:

- MIDI channel
- Root Note
- slot routing information

This makes Phoenix useful as a four-part sample module as well as a keyboard-mapped sampler.

## Mode-aware validation

An important design detail is that validation is aware of the current Quattro mode. A root note that would be invalid for a KEYZONE range should not be reported as a KEYZONE error when the bank is actually running in MULTI mode.

The Librarian therefore keeps both parameter sets and evaluates them according to the active routing mode.

<!-- IMAGE PLACEHOLDER: Quattro KEYZONE and MULTI view -->

---

# Sequencer and pattern editor

Phoenix Librarian contains a complete editor for the Phoenix pattern data.

The pattern system provides:

- patterns `P1` to `P4`
- sample tracks `S1` to `S4`
- up to 16 steps per track
- individual track lengths
- step On/Off
- MIDI Note
- note-name display
- Velocity
- Gate percentage
- BPM
- internal/external clock setting
- pattern copy/paste
- initialization functions
- pattern overview / active-step summary

The editor makes polymetric structures possible by allowing track lengths to differ.

Patterns can be auditioned from the PC and can also be sent through a selected MIDI output where appropriate.

A repeat function allows pattern passages to be monitored for several cycles without manually restarting playback.

<!-- IMAGE PLACEHOLDER: Pattern editor -->

---

# Song editor

The Song editor turns the Phoenix patterns into longer arrangements.

It supports:

- up to 16 song positions
- pattern selection per position
- repeat count
- `END`
- song-loop configuration
- validation of song entries
- PC preview

The editor gives a complete visual overview of an arrangement that would otherwise require stepping through individual values on the hardware.

<!-- IMAGE PLACEHOLDER: Song editor -->

---

# Echo, Reverb and effects editor

Phoenix Librarian v1.1.0 is synchronized with the **BANK16** effect data used by Phoenix firmware v1.1.0 FINAL.

## Global Echo

The editor exposes:

- Echo Time: **50–2000 ms**
- Feedback: **0–90 %**
- Echo Mix: **0–100 %**

Each slot also has its own `ECHO_SEND`.

## Global Reverb

Phoenix v1.1.0 adds four bank-level Reverb parameters:

- Reverb Size: **0–100 %**
- Reverb Decay: **0–100 %**
- Reverb Damp: **0–100 %**
- Reverb Mix: **0–100 %**

Each of the four slots has an independent:

- `REVERB_SEND`: **0–100 %**

The v1.1.0 default values are:

```text
ECHO_DELAY_MS=250
ECHO_FEEDBACK=35
ECHO_MIX=20

REVERB_SIZE=55
REVERB_DECAY=55
REVERB_DAMP=45
REVERB_MIX=20
```

New banks start with Echo Send and Reverb Send at 0 for all four slots.

## Other effect parameters

The established editor continues to expose parameters including:

- Filter Cutoff
- Resonance
- Filter Envelope amount
- Filter Velocity response
- Filter Keytrack
- Vintage preset
- Vintage rate
- Vintage bit depth
- Vintage filter
- Vintage jitter

The PC can render an offline preview for Filter, Echo and Vintage effect evaluation and A/B comparison.

The PC effect renderer is intended as an **editing preview**, not as a claim of bit-identical reproduction of the ESP32 Phoenix DSP implementation. In v1.1.0 the new hardware Reverb parameters are edited and stored exactly, but the ESP32-S3 Reverb itself is intentionally **not approximated in the PC preview**.

<!-- IMAGE PLACEHOLDER: Echo / Reverb / Effects editor -->

---

# MIDI and screen keyboard

The Librarian can be played like a temporary software sampler while editing a Phoenix bank.

## MIDI input

A Windows MIDI input device can be selected directly in the application.

Supported live functions include:

- Note On / Note Off
- velocity
- polyphonic playback
- Sustain Pedal
- Pitch Bend
- KEYZONE routing
- MULTI routing
- Phoenix Root Note handling
- Phoenix loop modes

## Screen keyboard

An integrated on-screen keyboard makes it possible to audition a bank without connecting an external MIDI keyboard.

This is particularly useful when preparing a library on a laptop.

## Polyphony

Phoenix Librarian v1.1.0 retains the proven v1.0 preview engine with a fixed pool of **16 preview voices**.

Voice resources are preallocated to avoid object creation in the time-critical audio render loop.

<!-- IMAGE PLACEHOLDER: MIDI and screen keyboard -->

---

# PC audio engine

The PC preview engine became one of the most extensively engineered parts of Phoenix Librarian.

## Why a custom engine was necessary

A normal Windows media player is convenient for simple WAV playback, but Phoenix requires sampler-specific behavior:

- immediate MIDI response
- pitch transposition from Root Note
- polyphony
- sample-accurate loop points
- FORWARD and ALTERNATE looping
- Sustain
- Pitch Bend
- repeated preview without reopening files
- predictable loop behavior

The final solution therefore does not use WPF `MediaPlayer` for the live sampler path.

## Single-source-sample RAM architecture

Each occupied Phoenix slot is decoded once and held as its original PCM source in memory.

Pitch is generated by changing the playback step in the native mixer:

```text
PlaybackStep = 2 ^ ((PlayedNote - RootNote) / 12)
```

Conceptually:

```text
Original WAV in RAM
       │
       ├── C3  step 0.500...
       ├── C4  step 1.000...
       ├── G4  step 1.498...
       └── C5  step 2.000...
```

This replaced earlier experiments that rendered large numbers of separate pitched WAV files. The final design uses far less memory and eliminates disk access from the normal Note-On path.

## Native WASAPI output

Phoenix Librarian v1.1.0 retains the event-driven WASAPI rendering path introduced and stabilized in v1.0.

The tested final profiles are:

### LIVE profile

```text
48 kHz
PCM16 stereo
480 frames
10.00 ms
```

Used for:

- MIDI input
- screen keyboard
- live sampler audition

### EDITOR profile

```text
48 kHz
PCM16 stereo
960 frames
20.00 ms
```

Used for:

- Waveform One Shot
- Waveform Loop Hold

The editor profile deliberately favors uninterrupted playback over the lowest possible latency because an extra few milliseconds are irrelevant when visually editing a loop.

## Exclusive mode with Shared fallback

The application first attempts the optimized WASAPI mode supported by the device. A Shared-mode fallback remains available for systems where the requested Exclusive format cannot be opened.

## On-demand Exclusive Audio

A critical design decision retained in v1.1.0 is that Phoenix Librarian **does not keep the Windows audio endpoint permanently locked**.

The application can be opened, scan the Phoenix SD card and edit banks without opening an Exclusive audio stream.

The audio device is requested only when Phoenix actually needs to make sound:

```text
Phoenix Librarian idle
        │
        └── Windows audio device remains free

User plays MIDI / keyboard / preview
        │
        ▼
Open WASAPI stream on demand
        │
        ▼
Render Phoenix audio
        │
        ▼
Stop / idle timeout
        │
        ▼
Release audio endpoint completely
```

This prevents Phoenix Librarian from unnecessarily blocking applications such as a media player while the user is only editing files.

While an Exclusive stream is actively open, Windows may still temporarily interrupt another application's Shared session. This is normal WASAPI Exclusive behavior. Phoenix releases the endpoint again as soon as the preview/live-audio session is finished.

## MMCSS Pro Audio scheduling

The render thread is registered with Windows multimedia scheduling under the **Pro Audio** category to reduce ordinary scheduling jitter.

## GC-isolated audio core

During release-candidate testing, rare audible dropouts were traced to long pauses in a managed/.NET audio path rather than to the DSP workload itself.

The final engine was hardened with:

- fixed 16-voice pool
- preallocated voice state
- preallocated PCM buffers
- fixed 256-entry command ring buffer
- no dynamic voice creation in the render loop
- no logging from the render loop
- no WPF/UI calls from the render loop
- deferred diagnostics
- direct PCM16 transfer into the WASAPI buffer path

This v1.0 stability milestone remains unchanged in v1.1.0.

## Audio diagnostics

Development builds measured:

- event wakeup timing
- mixer execution time
- output-write time
- complete render-loop time
- late wakeups
- severe wakeups
- dropouts
- active voices
- audio errors
- command queue state

These diagnostics were essential in separating sampler/loop bugs from Windows scheduling and .NET runtime effects.

---

# Offline preview rendering

Not every preview path needs live low-latency rendering.

Pattern, Song and effect comparisons use an offline rendering approach where appropriate. The required audio can be prepared as a complete block and then auditioned without putting sequencer/event timing into the real-time WPF layer.

This separation proved significantly more stable than trying to trigger many independent `MediaPlayer` instances for individual sequencer steps.

---

# Factory Library

Phoenix Librarian is also designed as a library-building tool.

The Factory Library section provides:

- full-text search
- category filter
- routing-mode filter
- status filter
- selection of suitable banks
- export of a filtered collection
- automatic bank renumbering where required

A Factory Library export can include descriptive index files such as:

```text
CONTENTS.csv
LIBRARY.INFO
README
```

This allows curated Phoenix bank collections to be distributed in a structured and documented form rather than as anonymous folders of WAV files.

---

# Backup and Restore

Because Phoenix Librarian edits the same media used by the hardware sampler, data safety was treated as a first-class feature rather than an afterthought.

The Backup & Restore Center supports:

- backup of the current bank
- full backup of the complete Phoenix content
- configurable backup destination
- backup list/history
- comments/metadata
- bank count
- file count
- transferred data size
- progress display
- elapsed/remaining time information
- cancellation of longer copy operations
- restore of individual bank backups
- complete Phoenix restore

## Safety backup before restore

A restore can overwrite valuable sampler data. Therefore the Librarian creates a **safety backup of the current content before destructive restore operations**.

This means a restore operation does not have to rely on the user remembering to create a manual backup first.

<!-- IMAGE PLACEHOLDER: Backup & Restore Center -->

---

# Validation and Self Test

Phoenix Librarian includes two levels of diagnostics.

## Bank validation

The `Prüfung` / Validation tab checks Phoenix data for invalid or suspicious combinations.

Examples include:

- invalid marker ordering
- invalid note ranges
- routing inconsistencies
- missing files
- configuration inconsistencies

Validation is routing-mode aware so KEYZONE-specific rules are not incorrectly applied to MULTI banks.

## Integrated Self Test

The integrated Self Test retained in v1.1.0 covers eleven core areas:

1. Phoenix directory
2. `BANKS` directory
3. `BANK.CFG` parser
4. WAV decoder
5. Pattern parser
6. Song parser
7. write access
8. backup path
9. MIDI subsystem
10. audio preview
11. preview cache / sample preparation

A fully successful test is reported as:

```text
11 OK | 0 warning(s) | 0 error(s)
```

The **System Status & Self Test** tab is especially useful before a long editing session or when the Phoenix storage has been moved to another computer.

---

# Data safety

Several safeguards are built into the editing workflow:

- validation before critical operations
- explicit confirmations for destructive operations
- bank-name confirmation for deletion where appropriate
- safety backup before restore
- incomplete backups removed after cancellation/failure
- unsaved editor-state checks
- file-lock handling
- controlled audio shutdown
- automatic release of the Windows audio endpoint
- direct inspection of `BANK.CFG`

Even with these protections, a full backup is strongly recommended before large library reorganizations.

---

# Development history

Phoenix Librarian was developed iteratively alongside Project Phoenix itself. The program did not begin as a monolithic finished design; new capabilities were added as the sampler firmware and the editing workflow became better understood.

A simplified development path is:

```text
v0.4–0.6   Basic bank/file handling and early editor functions
     │
     ▼
v0.7       Metadata, templates and bank import workflows
     │
     ▼
v0.8       KEYZONE / MULTI routing
     │
     ▼
v0.9       Waveform, Pattern, Song, Effects and preview system
     │
     ├── MIDI input and screen keyboard
     ├── Factory Library
     ├── Backup & Restore
     ├── Self Test
     └── UI / stability work
     │
     ▼
v1.0 RC    Dedicated WASAPI sampler engine
     │
     ├── native pitch
     ├── sample RAM cache
     ├── event-driven audio
     ├── Exclusive / Shared probing
     ├── MMCSS Pro Audio
     ├── stable 10 / 20 ms profiles
     ├── GC-isolated voice engine
     └── on-demand endpoint ownership
     │
     ▼
v1.0.0     Stable Windows audio / MIDI release basis
     │
     ▼
v1.1.0     Phoenix firmware synchronization
     │
     ├── BANK16
     ├── Reverb globals
     ├── Reverb Send S1–S4
     ├── INIT_SOUND Reverb support
     ├── final Echo limits
     └── v1.0 audio core retained
```

## What the audio development taught us

Several architectural changes came directly from measurement rather than assumption.

### 1. WPF MediaPlayer was not a sampler engine

It was useful for early prototypes but unsuitable for precise live pitch/loop playback.

### 2. Pre-rendering every pitch was wasteful

Large pitch caches consumed too much memory. The final native pitch engine requires only the source sample.

### 3. The smallest possible buffer was not the best release buffer

A 3 ms Exclusive mode was successfully reached during development, but real Windows scheduling spikes made it less robust on the test system. Version 1.0 therefore favors the stable 10 ms Live profile and 20 ms Editor profile.

### 4. Real-time code must be isolated from normal application code

The final GC-isolated voice pool and command ring buffer eliminated the audible dropouts seen when managed allocations and UI/diagnostic activity could interfere with the audio thread.

### 5. Exclusive audio should be owned only when needed

Keeping an Exclusive stream open while merely editing files unnecessarily blocked other Windows audio applications. Version 1.0 therefore opens the endpoint on demand and releases it automatically.

These decisions are part of the engineering history of the project and are intentionally documented rather than hidden.

---

# Known limitations

Phoenix Librarian v1.1.0 is a Windows companion editor, and several boundaries are intentional:

- Windows PowerShell 5.1 / WPF is currently required.
- PC audio preview is not intended to be a bit-identical replacement for every ESP32 hardware DSP detail.
- Filter/Vintage/Echo preview is an editing approximation where applicable.
- Phoenix v1.1.0 Reverb is **not** emulated by the PC preview; Reverb values are stored for the hardware exactly.
- Actual MIDI/audio latency depends on the Windows audio device and driver.
- WASAPI Exclusive playback can temporarily take ownership of the Windows output while Phoenix is actively producing sound; the endpoint is released automatically afterwards.
- BANK15 remains readable, but new Phoenix v1.1.0 Reverb persistence requires BANK16.
- The Phoenix hardware remains the reference for final playback behavior.

---

# Suggested GitHub repository structure

A clean v1.1.0 repository layout is:

```text
Phoenix-Librarian/
│
├── README.md
├── LICENSE
├── CHANGELOG.md
│
├── release/
│   └── Phoenix_Librarian_v1_1_0_FINAL.zip
│
├── src/
│   ├── PhoenixLibrarian.ps1
│   └── Start_Phoenix_Librarian.cmd
│
├── docs/
│   ├── USER_GUIDE.md
│   ├── BANK16_COMPATIBILITY.md
│   ├── PHOENIX_FILE_FORMAT.md
│   └── DEVELOPMENT_HISTORY.md
│
├── images/
│   └── ...
│
├── testdata/
│   └── ...
│
└── examples/
    └── ExampleBank/
```

For the GitHub Release, the main downloadable asset should be:

```text
Phoenix_Librarian_v1_1_0_FINAL.zip
```

The release notes should highlight **BANK16, Reverb synchronization, INIT_SOUND compatibility, BANK15 read compatibility and the retained v1.0 low-latency preview architecture**.

---

# Screenshots and media

1. **Main window / Bank Overview** — immediate overview of the application.
<p align="center">
<img src="images/RTAL_Wellenbad_Bankuebersicht.JPG" width="900">  
  
2. **Waveform Editor** — show S.START, L.START, L.END and S.END.
<p align="center">
<img src="images/RTAL_Wellenbad_Waveform-Editor.JPG" width="900">  
  
3. **Quattro KEYZONE** — visually explain keyboard mapping.
<p align="center">
<img src="images/RTAL_Wellenbad_Quattro-Routing.JPG" width="900">

4. **Quattro MULTI** — show the four independent MIDI channels.
<p align="center">
<img src="images/RTAL_Wellenbad_Quattro-Routing-Multi.JPG" width="900">   
  
5. **Pattern Editor** — demonstrate that Phoenix includes sequencing, not only sample management.
<p align="center">
<img src="images/RTAL_Wellenbad_Sequencer.JPG" width="900">    
  
6. **Song Editor** — show complete arrangement editing.
<p align="center">
<img src="images/RTAL_Wellenbad_Song-Editor.JPG" width="900">    
  
7. **MIDI & Keyboard** — demonstrate live PC audition.
<p align="center">
<img src="images/RTAL_Wellenbad_Midi.JPG" width="900">    
  
8. **Backup & Restore** — emphasize data safety.
<p align="center">
<img src="images/RTAL_Wellenbad_Backup-Restore.JPG" width="900">  

9. **Current Development Prototype**
<p align="center">
<img src="images/Phoenix_Development.jpg" width="900">  
 
---

# Project status

**Phoenix Librarian v1.1.0 FINAL is the current stable companion release for Project Phoenix v1.1.0 FINAL.**

The release intentionally preserves the frozen v1.0 Windows audio/MIDI core while synchronizing the editor and file workflow with the Phoenix v1.1.0 bank format.

The v1.1.0 architecture includes:

- stable Phoenix bank/file workflow
- **BANK16** current bank format
- **BANK15 read compatibility**
- controlled BANK15 → BANK16 promotion on explicit Reverb/effect save
- global Reverb Size / Decay / Damp / Mix
- per-slot Reverb Send for S1–S4
- Reverb-capable `INIT_SOUND.CFG`
- final Echo ranges synchronized with Phoenix v1.1.0
- complete established editor UI
- fixed 16-voice preview pool
- native pitch playback
- native Phoenix loop preview
- 10 ms Live WASAPI profile
- 20 ms Waveform Editor profile
- MMCSS Pro Audio scheduling
- GC-isolated real-time structures
- On-Demand Exclusive Audio
- automatic audio-endpoint release
- Shared fallback
- integrated diagnostics and Self Test

Future Librarian development should branch from v1.1.0 rather than modify the archived FINAL source directly.

---

# Project Phoenix

Phoenix Librarian is part of the **RTAL Project Phoenix** sampler development.

The long-term aim of Project Phoenix is not simply to reproduce the feature list of a vintage sampler, but to explore how a modern embedded platform can combine:

- classic sampler workflows
- direct hardware control
- modern storage
- MIDI integration
- real-time DSP
- visual editing tools
- open engineering documentation

The Librarian represents the PC side of that philosophy: transparent files, inspectable source code, measured engineering decisions and a workflow centered on the hardware instrument.

---

# RealTimeAudioLab / RTAL

**RealTimeAudioLab** documents and develops projects around embedded audio, digital musical instruments, MIDI, DSP, samplers, synthesizers and related hardware/software engineering.

If you find Phoenix useful or interesting, feedback, testing reports and technical discussion are welcome.

---

## Version

**Phoenix Librarian v1.1.0 FINAL**  
Phoenix v1.1.0 companion release — September 2026


