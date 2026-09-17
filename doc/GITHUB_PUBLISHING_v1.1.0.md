# GitHub Publishing Checklist

This checklist applies to **Phoenix Librarian v1.1.0 FINAL**.

## Repository

Recommended repository name:

`Phoenix-Librarian`

Suggested description:

> Windows librarian, BANK16 sample editor, sequencer editor and low-latency audition environment for the RTAL Project Phoenix hardware sampler.

## Suggested topics

`sampler`, `esp32-s3`, `midi`, `audio-dsp`, `sample-editor`, `librarian`, `powershell`, `wpf`, `wasapi`, `realtime-audio`, `embedded-audio`, `music-technology`

## Before the v1.1.0 public release

- Verify that the main README reports **Phoenix Librarian v1.1.0 FINAL**.
- Verify that the documentation set is v1.1.0.
- Verify that screenshots in `images/` still match the current UI.
- Verify that the example bank contains only material that may be redistributed.
- Check the repository for personal paths, private sample names or machine-specific information.
- Confirm that new banks are written as `BANK_VERSION=16`.
- Confirm that existing BANK15 banks remain readable.
- Confirm that explicit Reverb/effect save promotes BANK15 to BANK16.
- Confirm Reverb Size / Decay / Damp / Mix save and reload.
- Confirm Reverb Send for S1–S4.
- Confirm Echo validation uses 50–2000 ms and 0–90 % feedback.
- Confirm `INIT_SOUND.CFG` load/save and Factory Defaults.
- Run the v1.1.0 Windows smoke/regression test.
- Keep the release ZIP in GitHub Releases rather than committing it to the normal source tree.

## Recommended image set

1. Main Phoenix Librarian window.
2. Waveform editor with S.START / L.START / L.END / S.END visible.
3. KEYZONE / MULTI routing view.
4. Pattern editor.
5. Song editor.
6. Echo / Reverb / Effects editor.
7. MIDI / screen keyboard.
8. Backup & Restore Center.
9. Phoenix hardware next to the Librarian running on the PC.

A short animated GIF showing bank selection, loop editing, Reverb editing and playback would make the project page significantly easier to understand at a glance.

## Recommended repository documentation

At minimum, publish:

```text
README.md
ARCHITECTURE.md
DEVELOPMENT_HISTORY.md
PHOENIX_INTEGRATION.md
GITHUB_PUBLISHING.md
BANK16_COMPATIBILITY.md
```

Recommended user documentation:

```text
Phoenix_Librarian_v1.1.0_Bedienungsanleitung_DE.pdf
Phoenix_Librarian_v1.1.0_Quick_Start_DE.pdf
Phoenix_Librarian_v1.1.0_Dateiformat_Referenz_DE.pdf
```

## Release

Create a GitHub Release with tag:

`v1.1.0`

Recommended release title:

`Phoenix Librarian v1.1.0 FINAL`

Attach:

`Phoenix_Librarian_v1_1_0_FINAL.zip`

Use the v1.1.0 release README / release notes as the release description.

Recommended source document:

`README_RELEASE_Phoenix_Librarian_v1.1.0.md`

or the corresponding `RELEASE_NOTES_v1_1_0_FINAL.md` from the release package.

## Release highlights

The GitHub release description should call out:

- Project Phoenix v1.1.0 FINAL compatibility
- BANK16
- BANK15 read compatibility
- controlled BANK15 → BANK16 migration
- Reverb Size / Decay / Damp / Mix
- Reverb Send for S1–S4
- `INIT_SOUND.CFG`
- final Echo ranges
- unchanged validated v1.0 WASAPI/MIDI core

## Suggested release assets

```text
Phoenix_Librarian_v1_1_0_FINAL.zip
Phoenix_Librarian_v1.1.0_Bedienungsanleitung_DE.pdf
Phoenix_Librarian_v1.1.0_Quick_Start_DE.pdf
Phoenix_Librarian_v1.1.0_Dateiformat_Referenz_DE.pdf
```

Optionally add a SHA-256 text file for the main release archive.

## Final verification after publishing

After creating the GitHub Release:

- confirm tag `v1.1.0` points to the intended commit
- download the release ZIP from GitHub and extract it
- start `Start_Phoenix_Librarian.cmd`
- confirm the title/version is v1.1.0
- open a BANK15 test bank
- save Reverb/effects and verify `BANK_VERSION=16`
- open a BANK16 bank and verify all Reverb values
- perform one live MIDI/audio preview test
- verify that all documentation links in the repository work
- verify that the release asset checksum matches the local package

Only after this download-back test should v1.1.0 be treated as the published release artifact.
