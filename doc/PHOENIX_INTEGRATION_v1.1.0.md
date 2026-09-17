# Phoenix Sampler Integration

Phoenix Librarian v1.1.0 is designed as a companion to the **RTAL Project Phoenix v1.1.0 FINAL** hardware sampler, not as a replacement for it.

## Division of responsibilities

### Phoenix hardware

- real-time standalone sample playback
- MIDI performance
- embedded audio processing
- Echo and stereo Reverb DSP
- hardware controls and display
- SD-based sample and bank storage
- hardware session persistence

### Phoenix Librarian

- visual bank management
- sample and loop editing
- routing preparation
- pattern and song editing
- BANK16 Echo / Reverb / effects setup
- `INIT_SOUND.CFG` editing
- metadata and library organization
- backups and restores
- PC-side audition and MIDI mapping checks

The PC therefore remains outside the hardware sampler's real-time playback dependency.

## Version compatibility

The v1.1.0 integration baseline is:

```text
Project Phoenix firmware   v1.1.0 FINAL
Phoenix Librarian          v1.1.0 FINAL
BANK_VERSION               16
Legacy BANK_VERSION        15 (read-compatible)
MULTISAMPLE_VERSION        10
PATTERNS.CFG               VERSION=1
SONG.CFG                   VERSION=2
INIT_SOUND.CFG             VERSION=1
```

## Storage workflow

A typical Phoenix v1.1.0 media layout contains:

```text
PHOENIX/
  SESSION_A.BIN
  SESSION_B.BIN
  LASTBANK.CFG
  INIT_SOUND.CFG          (optional)
  BANKS/
    BANK01/
      BANK.CFG
      BANK.INFO
      SLOT1.WAV
      SLOT2.WAV
      SLOT3.WAV
      SLOT4.WAV
      PATTERNS.CFG
      SONG.CFG
```

The exact bank contents depend on the bank and Phoenix firmware revision.

Phoenix Librarian treats the files on the Phoenix media as the authoritative data. The user edits those files through the Librarian and Phoenix subsequently reads them on the hardware.

## Hardware session files

Phoenix v1.1.0 uses:

```text
SESSION_A.BIN
SESSION_B.BIN
LASTBANK.CFG
```

for hardware-side session persistence and legacy fallback.

These files are **not normal bank-editing targets** for Phoenix Librarian.

The Librarian focuses on bank, sample, pattern, song and template data. Normal bank editing does not require modifying the hardware session journal.

## BANK15 and BANK16

Phoenix Librarian v1.1.0 can read existing BANK15 banks.

Opening a legacy bank does not automatically rewrite it.

When the user explicitly saves v1.1.0 Echo/Reverb/effect parameters, the Librarian:

1. writes the v1.1.0 effect data,
2. writes the Reverb fields,
3. promotes the header to `BANK_VERSION=16`.

This keeps migration deliberate.

## Reverb integration

Phoenix firmware v1.1.0 stores global Reverb values in `BANK.CFG`:

```text
REVERB_SIZE
REVERB_DECAY
REVERB_DAMP
REVERB_MIX
```

Each slot S1–S4 also stores:

```text
REVERB_SEND
```

Phoenix Librarian v1.1.0 reads, validates, edits and writes these values.

The supported range for each Reverb value is:

```text
0..100 %
```

## Echo integration

The final Phoenix v1.1.0 hardware-effective ranges are:

```text
ECHO_DELAY_MS    50..2000
ECHO_FEEDBACK    0..90
ECHO_MIX         0..100
ECHO_SEND        0..100
```

Phoenix Librarian v1.1.0 uses the same limits so the editor does not offer values that the hardware would immediately clamp.

## INIT_SOUND integration

The optional file:

```text
/PHOENIX/INIT_SOUND.CFG
```

can define reusable new-bank sound/mapping defaults.

Phoenix Librarian v1.1.0 supports the corresponding Echo/Reverb values and per-slot sends.

The template is not intended to carry the current WAV/sample paths or active song/pattern state.

## Sample markers

The waveform editor uses four important boundaries:

- `S.START` — sample playback start
- `L.START` — loop start
- `L.END` — loop end
- `S.END` — sample playback end

### One Shot

The visual playhead and audition start at `S.START` and continue toward `S.END`.

### Loop Hold

The dedicated loop audition starts visually at `L.START` and follows the loop region. FORWARD returns to L.START after L.END; ALTERNATE reverses direction at the loop limits.

## Quattro routing

Phoenix banks can use different Quattro routing concepts. The Librarian exposes the relevant routing data instead of forcing one interpretation on every bank.

### KEYZONE

The four slots can be mapped by Low / Root / High keyboard values.

### MULTI

Slots can be addressed using their configured MIDI channels. Root-note validation therefore differs from KEYZONE mode and is not treated as a key-zone error merely because a root note lies outside a zone that is not active in MULTI mode.

## PC audio preview vs. hardware DSP

The Librarian can provide useful PC audition for samples, loops, MIDI mapping and established preview effects.

The Phoenix v1.1.0 hardware Reverb is deliberately **not** presented as a bit-identical PC effect.

The Librarian stores the correct Reverb parameters; the actual Phoenix hardware DSP remains the reference for final sound.

This separation preserves the role of the Librarian as an editor/companion rather than making the Windows application part of the instrument's real-time audio path.

## USB mass storage and SD card use

Phoenix can expose its storage to Windows through USB mass storage, or the SD card can be mounted directly. The Librarian operates on the same bank structure in either case.

Before physically removing media, use the normal Windows safe-removal workflow and ensure Phoenix is no longer writing to it.

When using Phoenix USB Mass Storage, complete the Windows eject/safe-removal workflow before returning the hardware to normal sampler operation.
