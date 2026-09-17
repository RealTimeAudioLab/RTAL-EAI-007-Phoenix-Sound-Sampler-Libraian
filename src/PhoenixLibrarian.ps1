# Phoenix Librarian v1.1.0 FINAL - BANK16 / Reverb synchronized release
# Offline bank browser, validator and backup tool for Project Phoenix.
# Compatible with Windows PowerShell 5.1 and Windows 10/11.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Windows Multimedia MIDI API. The C# wrapper keeps the PowerShell transport
# independent from optional third-party MIDI libraries.
if (-not ('PhoenixMidi' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PhoenixMidi {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MIDIOUTCAPS {
        public UInt16 wMid;
        public UInt16 wPid;
        public UInt32 vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public UInt16 wTechnology;
        public UInt16 wVoices;
        public UInt16 wNotes;
        public UInt16 wChannelMask;
        public UInt32 dwSupport;
    }
    [DllImport("winmm.dll")] public static extern UInt32 midiOutGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Auto)] public static extern UInt32 midiOutGetDevCaps(UInt32 uDeviceID, out MIDIOUTCAPS caps, UInt32 cbMidiOutCaps);
    [DllImport("winmm.dll")] public static extern UInt32 midiOutOpen(out IntPtr handle, UInt32 deviceID, IntPtr callback, IntPtr instance, UInt32 flags);
    [DllImport("winmm.dll")] public static extern UInt32 midiOutShortMsg(IntPtr handle, UInt32 message);
    [DllImport("winmm.dll")] public static extern UInt32 midiOutReset(IntPtr handle);
    [DllImport("winmm.dll")] public static extern UInt32 midiOutClose(IntPtr handle);
}
"@
}

# Windows Multimedia MIDI input wrapper. Incoming short messages are queued in C#
# and polled by the WPF dispatcher, keeping native callbacks outside PowerShell.
if (-not ('PhoenixMidiIn' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
public static class PhoenixMidiIn {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MIDIINCAPS { public UInt16 wMid,wPid; public UInt32 vDriverVersion; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string szPname; public UInt32 dwSupport; }
    public delegate void MidiInProc(IntPtr hMidiIn, UInt32 wMsg, IntPtr dwInstance, UInt32 dwParam1, UInt32 dwParam2);
    [DllImport("winmm.dll")] public static extern UInt32 midiInGetNumDevs();
    [DllImport("winmm.dll", CharSet=CharSet.Auto)] public static extern UInt32 midiInGetDevCaps(UInt32 id, out MIDIINCAPS caps, UInt32 size);
    [DllImport("winmm.dll")] static extern UInt32 midiInOpen(out IntPtr handle, UInt32 id, MidiInProc cb, IntPtr instance, UInt32 flags);
    [DllImport("winmm.dll")] static extern UInt32 midiInStart(IntPtr handle);
    [DllImport("winmm.dll")] static extern UInt32 midiInStop(IntPtr handle);
    [DllImport("winmm.dll")] static extern UInt32 midiInReset(IntPtr handle);
    [DllImport("winmm.dll")] static extern UInt32 midiInClose(IntPtr handle);
    static IntPtr handle=IntPtr.Zero; static MidiInProc callback; static readonly ConcurrentQueue<UInt32> queue=new ConcurrentQueue<UInt32>();
    static void OnMidi(IntPtr h, UInt32 msg, IntPtr inst, UInt32 p1, UInt32 p2){ if(msg==0x3C3) queue.Enqueue(p1); }
    public static UInt32 Open(UInt32 id){ Close(); callback=new MidiInProc(OnMidi); UInt32 rc=midiInOpen(out handle,id,callback,IntPtr.Zero,0x00030000); if(rc==0) rc=midiInStart(handle); return rc; }
    public static void Close(){ if(handle!=IntPtr.Zero){ midiInStop(handle); midiInReset(handle); midiInClose(handle); handle=IntPtr.Zero; } UInt32 x; while(queue.TryDequeue(out x)){} }
    public static UInt32[] Poll(){ var list=new System.Collections.Generic.List<UInt32>(); UInt32 x; while(queue.TryDequeue(out x)) list.Add(x); return list.ToArray(); }
}
"@
}

$script:AppVersion = '1.1.0'
$script:PhoenixRoot = $null
$script:BankRecords = @()
$script:CurrentBank = $null
$script:CurrentSlot = $null
$script:WaveformCache = @{}
$script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:PatternDirty = $false
$script:SongDirty = $false
$script:EffectsDirty = $false
$script:InitSoundDirty = $false
$script:InitSoundSyncing = $false
$script:InitSoundData = $null
$script:EditorDirty = $false
$script:SelfTestLastRun = $null

function Add-Log {
    param([string]$Message)
    $stamp = (Get-Date).ToString('HH:mm:ss')
    if ($script:LogBox) {
        $script:LogBox.AppendText("[$stamp] $Message`r`n")
        $script:LogBox.ScrollToEnd()
    }
}

function Get-ValueOrDefault {
    param(
        [hashtable]$Table,
        [string]$Key,
        $Default = ''
    )
    if ($null -ne $Table -and $Table.ContainsKey($Key)) { return $Table[$Key] }
    return $Default
}

function Convert-ToInt64Safe {
    param($Value, [long]$Default = 0)
    $parsed = 0L
    if ([long]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $Default
}

function Convert-ToBoolText {
    param($Value)
    if ((Convert-ToInt64Safe $Value 0) -ne 0) { return 'ON' }
    return 'OFF'
}

function Get-LoopModeText {
    param($Value)
    switch (Convert-ToInt64Safe $Value 0) {
        1 { return 'FORWARD' }
        2 { return 'ALTERNATE' }
        default { return 'OFF' }
    }
}

function Get-MidiNoteName {
    param($Value)
    $note = [int](Convert-ToInt64Safe $Value 60)
    if ($note -lt 0 -or $note -gt 127) { return [string]$note }
    $names = @('C','C#','D','D#','E','F','F#','G','G#','A','A#','B')
    $octave = [math]::Floor($note / 12) - 1
    return ('{0}{1} ({2})' -f $names[$note % 12], $octave, $note)
}

function Format-Duration {
    param([long]$Frames, [long]$SampleRate)
    if ($SampleRate -le 0) { return '-' }
    $seconds = [double]$Frames / [double]$SampleRate
    if ($seconds -lt 1.0) { return ('{0:N1} ms' -f ($seconds * 1000.0)) }
    return ('{0:N3} s' -f $seconds)
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Read-PhoenixConfig {
    param([Parameter(Mandatory=$true)][string]$Path)

    $result = [ordered]@{
        Header = @{}
        Global = @{}
        Slots = @(@{}, @{}, @{}, @{})
        OtherSections = @{}
        RawLines = @()
    }

    $section = ''
    foreach ($rawLine in [System.IO.File]::ReadAllLines($Path, $script:Utf8NoBom)) {
        $result.RawLines += $rawLine
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }

        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $section = $line.Substring(1, $line.Length - 2).Trim().ToUpperInvariant()
            if ($section -notmatch '^SLOT[1-4]$' -and $section -ne 'GLOBAL' -and -not $result.OtherSections.ContainsKey($section)) {
                $result.OtherSections[$section] = @{}
            }
            continue
        }

        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim().ToUpperInvariant()
        $value = $line.Substring($eq + 1).Trim()

        if ($section -match '^SLOT([1-4])$') {
            $slotIndex = [int]$Matches[1] - 1
            $result.Slots[$slotIndex][$key] = $value
        } elseif ($section -eq 'GLOBAL') {
            $result.Global[$key] = $value
        } elseif ([string]::IsNullOrEmpty($section)) {
            $result.Header[$key] = $value
        } else {
            $result.OtherSections[$section][$key] = $value
        }
    }

    return $result
}


function Get-DefaultBankInfo {
    param([string]$BankName = '')
    return [ordered]@{
        NAME = $BankName
        CATEGORY = 'Uncategorized'
        AUTHOR = 'RealTimeAudioLab'
        DESCRIPTION = ''
        LICENSE = 'All rights reserved'
        TAGS = ''
        TEMPLATE = 'EMPTY BANK'
        SLOT1_NAME = 'S1'
        SLOT2_NAME = 'S2'
        SLOT3_NAME = 'S3'
        SLOT4_NAME = 'S4'
    }
}

function Read-BankInfo {
    param([string]$BankPath, [string]$BankName)
    $info = Get-DefaultBankInfo $BankName
    $path = Join-Path $BankPath 'BANK.INFO'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $info }
    try {
        foreach ($raw in [System.IO.File]::ReadAllLines($path, $script:Utf8NoBom)) {
            $line = $raw.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
            $eq = $line.IndexOf('=')
            if ($eq -lt 1) { continue }
            $key = $line.Substring(0,$eq).Trim().ToUpperInvariant()
            $value = $line.Substring($eq+1).Trim()
            if ($info.Contains($key)) { $info[$key] = $value }
        }
    } catch { Add-Log ('BANK.INFO konnte nicht gelesen werden: ' + $_.Exception.Message) }
    return $info
}

function Write-BankInfo {
    param([string]$BankPath, $Info)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('PHOENIX_BANK_INFO=1')
    foreach ($key in @('NAME','CATEGORY','AUTHOR','DESCRIPTION','LICENSE','TAGS','TEMPLATE','SLOT1_NAME','SLOT2_NAME','SLOT3_NAME','SLOT4_NAME')) {
        $value = if (($Info -is [hashtable] -and $Info.ContainsKey($key)) -or ($Info -is [System.Collections.Specialized.OrderedDictionary] -and $Info.Contains($key))) { [string]$Info[$key] } else { '' }
        $value = $value.Replace("`r",' ').Replace("`n",' ')
        $lines.Add("$key=$value")
    }
    $temp = Join-Path $BankPath ('.BANK.INFO.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $dest = Join-Path $BankPath 'BANK.INFO'
    try {
        [System.IO.File]::WriteAllLines($temp,$lines,$script:Utf8Bom)
        Move-Item -LiteralPath $temp -Destination $dest -Force
    } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

function Get-BankInfoValue {
    param($Info,[string]$Key,[string]$Default='')
    if ($null -ne $Info -and $Info.Contains($Key)) { return [string]$Info[$Key] }
    return $Default
}

function Read-WavMetadata {
    param([Parameter(Mandatory=$true)][string]$Path)

    $meta = [ordered]@{
        Exists = $false
        Valid = $false
        Error = ''
        AudioFormat = 0
        Channels = 0
        SampleRate = 0
        BitsPerSample = 0
        DataBytes = 0L
        DataOffset = 0L
        Frames = 0L
        DurationSeconds = 0.0
        HasSmpl = $false
        RootNote = -1
        LoopType = -1
        LoopStart = -1L
        LoopEndExclusive = -1L
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$meta }
    $meta.Exists = $true

    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.BinaryReader($stream)
        if ($stream.Length -lt 12) { throw 'Datei ist zu kurz für einen RIFF/WAV-Header.' }

        $riff = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        [void]$reader.ReadUInt32()
        $wave = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($riff -ne 'RIFF' -or $wave -ne 'WAVE') { throw 'Kein RIFF/WAVE-Format.' }

        while (($stream.Position + 8) -le $stream.Length) {
            $chunkId = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
            $chunkSize = [long]$reader.ReadUInt32()
            $chunkDataStart = $stream.Position
            $chunkDataEnd = [math]::Min($stream.Length, $chunkDataStart + $chunkSize)

            switch ($chunkId) {
                'fmt ' {
                    if ($chunkSize -ge 16) {
                        $meta.AudioFormat = $reader.ReadUInt16()
                        $meta.Channels = $reader.ReadUInt16()
                        $meta.SampleRate = $reader.ReadUInt32()
                        [void]$reader.ReadUInt32()
                        [void]$reader.ReadUInt16()
                        $meta.BitsPerSample = $reader.ReadUInt16()
                    }
                }
                'data' {
                    $meta.DataOffset = $chunkDataStart
                    $meta.DataBytes = $chunkSize
                }
                'smpl' {
                    if ($chunkSize -ge 36) {
                        [void]$reader.ReadUInt32() # manufacturer
                        [void]$reader.ReadUInt32() # product
                        [void]$reader.ReadUInt32() # sample period
                        $meta.RootNote = [int]$reader.ReadUInt32()
                        [void]$reader.ReadUInt32() # pitch fraction
                        [void]$reader.ReadUInt32() # SMPTE format
                        [void]$reader.ReadUInt32() # SMPTE offset
                        $loopCount = [int]$reader.ReadUInt32()
                        [void]$reader.ReadUInt32() # sampler data
                        if ($loopCount -gt 0 -and ($stream.Position + 24) -le $chunkDataEnd) {
                            [void]$reader.ReadUInt32() # cue id
                            $meta.LoopType = [int]$reader.ReadUInt32()
                            $meta.LoopStart = [long]$reader.ReadUInt32()
                            $inclusiveEnd = [long]$reader.ReadUInt32()
                            $meta.LoopEndExclusive = $inclusiveEnd + 1
                            [void]$reader.ReadUInt32() # fraction
                            [void]$reader.ReadUInt32() # play count
                            $meta.HasSmpl = $true
                        }
                    }
                }
            }

            $stream.Position = $chunkDataEnd
            if (($chunkSize % 2) -ne 0 -and $stream.Position -lt $stream.Length) { $stream.Position++ }
        }

        $bytesPerFrame = [long]$meta.Channels * [long]([math]::Ceiling($meta.BitsPerSample / 8.0))
        if ($bytesPerFrame -gt 0) { $meta.Frames = [long]($meta.DataBytes / $bytesPerFrame) }
        if ($meta.SampleRate -gt 0) { $meta.DurationSeconds = [double]$meta.Frames / [double]$meta.SampleRate }
        $meta.Valid = ($meta.SampleRate -gt 0 -and $meta.Channels -gt 0 -and $meta.BitsPerSample -gt 0 -and $meta.DataBytes -gt 0)
        if (-not $meta.Valid) { $meta.Error = 'WAV enthält unvollständige Format- oder Audiodaten.' }
    } catch {
        $meta.Error = $_.Exception.Message
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }

    return [pscustomobject]$meta
}

function Get-BankDirectory {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }
    $candidates = @(
        (Join-Path $Root 'PHOENIX\BANKS'),
        (Join-Path $Root 'BANKS'),
        $Root
    )
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        $leaf = (Split-Path $candidate -Leaf).ToUpperInvariant()
        $hasBankCfg = Test-Path -LiteralPath (Join-Path $candidate 'BANK.CFG') -PathType Leaf
        $bankFolder = Get-ChildItem -LiteralPath $candidate -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^BANK\d\d$' } | Select-Object -First 1
        if ($hasBankCfg -or $bankFolder -or $leaf -eq 'BANKS') { return $candidate }
    }
    return $null
}

function Find-PhoenixRoots {
    $found = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            $root = $drive.RootDirectory.FullName
            $bankDir = Get-BankDirectory $root
            if ($bankDir) {
                $found += [pscustomobject]@{
                    Root = $root
                    BankDir = $bankDir
                    Label = if ([string]::IsNullOrWhiteSpace($drive.VolumeLabel)) { $drive.Name } else { $drive.VolumeLabel }
                }
            }
        } catch { }
    }
    return $found
}

function Get-BankRecord {
    param([Parameter(Mandatory=$true)][System.IO.DirectoryInfo]$Directory)

    $cfgPath = Join-Path $Directory.FullName 'BANK.CFG'
    if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) { return $null }

    try {
        $cfg = Read-PhoenixConfig $cfgPath
        $bankInfo = Read-BankInfo $Directory.FullName $Directory.Name
        $slotRecords = @()
        $issues = New-Object System.Collections.Generic.List[string]
        $recordedCount = 0
        $totalBytes = 0L
        # Routing mode determines which slot parameters are active and therefore
        # which validation rules are meaningful. 0 = KEYZONE, 1 = MULTI.
        $quattroMode = [int](Convert-ToInt64Safe (Get-ValueOrDefault $cfg.Global 'QUATTRO_MODE' 0) 0)

        for ($i = 0; $i -lt 4; $i++) {
            $slot = $cfg.Slots[$i]
            $wavPath = Join-Path $Directory.FullName ("SLOT{0}.WAV" -f ($i + 1))
            $wav = Read-WavMetadata $wavPath
            $recorded = (Convert-ToInt64Safe (Get-ValueOrDefault $slot 'RECORDED' 0) 0) -ne 0
            if ($recorded) { $recordedCount++ }
            if ($wav.Exists) { $totalBytes += (Get-Item -LiteralPath $wavPath).Length }

            $sampleRate = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'SAMPLE_RATE' $wav.SampleRate) $wav.SampleRate
            $frames = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'FRAME_COUNT' $wav.Frames) $wav.Frames
            $sampleStart = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'SAMPLE_START' 0) 0
            $sampleEnd = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'SAMPLE_END' $frames) $frames
            $loopStart = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'LOOP_START' 0) 0
            $loopEnd = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'LOOP_END' $sampleEnd) $sampleEnd
            $loopModeValue = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'LOOP_MODE' 0) 0
            $root = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'ROOT' 60) 60
            $keyLow = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'KEY_LOW' 0) 0
            $keyHigh = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'KEY_HIGH' 127) 127
            $midiChannel = Convert-ToInt64Safe (Get-ValueOrDefault $slot 'MIDI_CHANNEL' ($i + 1)) ($i + 1)

            $slotIssues = New-Object System.Collections.Generic.List[string]
            if ($quattroMode -eq 0) {
                # KEYZONE: Low/Root/High are active routing parameters.
                if ($keyLow -lt 0 -or $keyLow -gt 127 -or $keyHigh -lt 0 -or $keyHigh -gt 127 -or $keyLow -gt $keyHigh) {
                    $slotIssues.Add('Ungültiger Tastaturbereich')
                } elseif ($root -lt $keyLow -or $root -gt $keyHigh) {
                    $slotIssues.Add('Root Note liegt außerhalb des Tastaturbereichs')
                }
            } else {
                # MULTI: Slot selection is controlled by MIDI channel. Stored
                # keyzone values remain untouched but are intentionally not validated.
                if ($root -lt 0 -or $root -gt 127) { $slotIssues.Add('Root Note muss zwischen 0 und 127 liegen') }
                if ($midiChannel -lt 1 -or $midiChannel -gt 16) { $slotIssues.Add('MIDI-Kanal muss zwischen 1 und 16 liegen') }
            }
            if ($recorded -and -not $wav.Exists) { $slotIssues.Add('RECORDED=1, aber WAV fehlt') }
            if (-not $recorded -and $wav.Exists) { $slotIssues.Add('WAV vorhanden, RECORDED=0') }
            if ($wav.Exists -and -not $wav.Valid) { $slotIssues.Add('Ungültige WAV: ' + $wav.Error) }
            if ($wav.Valid -and $sampleRate -ne $wav.SampleRate) { $slotIssues.Add("Samplerate CFG/WAV: $sampleRate/$($wav.SampleRate)") }
            if ($wav.Valid -and $frames -ne $wav.Frames) { $slotIssues.Add("Frames CFG/WAV: $frames/$($wav.Frames)") }
            if ($sampleStart -lt 0 -or $sampleStart -gt $sampleEnd) { $slotIssues.Add('S.START außerhalb des Bereichs') }
            if ($sampleEnd -gt $frames) { $slotIssues.Add('S.END größer als FRAME_COUNT') }
            if ($loopModeValue -ne 0) {
                if ($loopStart -lt $sampleStart -or $loopEnd -gt $sampleEnd -or $loopEnd -le $loopStart) { $slotIssues.Add('Ungültige Loop-Grenzen') }
                if ($wav.Valid -and -not $wav.HasSmpl) { $slotIssues.Add('Loop aktiv, aber WAV ohne smpl-Chunk') }
                if ($wav.HasSmpl) {
                    if ($wav.LoopStart -ne $loopStart -or $wav.LoopEndExclusive -ne $loopEnd) { $slotIssues.Add('Loop CFG/WAV weicht ab') }
                    $expectedWavType = if ($loopModeValue -eq 2) { 1 } else { 0 }
                    if ($wav.LoopType -ne $expectedWavType) { $slotIssues.Add('Loop-Typ CFG/WAV weicht ab') }
                }
            }
            if ($wav.HasSmpl -and $wav.RootNote -ne $root) { $slotIssues.Add('Root Note CFG/WAV weicht ab') }

            foreach ($issue in $slotIssues) { $issues.Add("S$($i+1): $issue") }

            $slotRecords += [pscustomobject]@{
                Slot = "S$($i + 1)"
                SampleName = Get-BankInfoValue $bankInfo ("SLOT{0}_NAME" -f ($i+1)) ("S{0}" -f ($i+1))
                Recorded = if ($recorded) { 'YES' } else { 'NO' }
                Wav = if ($wav.Exists) { 'YES' } else { 'NO' }
                Duration = Format-Duration $frames $sampleRate
                SampleRate = $sampleRate
                Frames = $frames
                Root = Get-MidiNoteName $root
                RootValue = $root
                KeyLow = $keyLow
                KeyLowText = Get-MidiNoteLabel $keyLow
                KeyHigh = $keyHigh
                KeyHighText = Get-MidiNoteLabel $keyHigh
                KeyRange = "$(Get-MidiNoteName $keyLow) - $(Get-MidiNoteName $keyHigh)"
                MidiChannel = $midiChannel
                SampleStart = $sampleStart
                LoopStart = $loopStart
                LoopEnd = $loopEnd
                SampleEnd = $sampleEnd
                LoopMode = Get-LoopModeText $loopModeValue
                XFade = ((Get-ValueOrDefault $slot 'LOOP_XFADE_MS' '0') + ' ms')
                Trim = Convert-ToBoolText (Get-ValueOrDefault $slot 'TRIM_ENABLED' 0)
                DC = Convert-ToBoolText (Get-ValueOrDefault $slot 'DC_ENABLED' 0)
                Normalize = Convert-ToBoolText (Get-ValueOrDefault $slot 'NORMALIZE_ENABLED' 0)
                Level = Get-ValueOrDefault $slot 'LEVEL' '-'
                Pan = Get-ValueOrDefault $slot 'PAN' '-'
                Voices = Get-ValueOrDefault $slot 'VOICE_LIMIT' '-'
                FilePath = $wavPath
                Issue = if ($slotIssues.Count -eq 0) { 'OK' } else { [string]::Join('; ', $slotIssues) }
                WavMetadata = $wav
                Raw = $slot
            }
        }

        if ($quattroMode -eq 1) {
            $channels = @($slotRecords | ForEach-Object { [int]$_.MidiChannel })
            $duplicates = @($channels | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
            if ($duplicates.Count -gt 0) { $issues.Add('MULTI: MIDI-Kanal mehrfach verwendet: ' + [string]::Join(', ', $duplicates)) }
        }

        if ([string]::IsNullOrWhiteSpace((Get-BankInfoValue $bankInfo 'NAME' ''))) { $issues.Add('BANK.INFO: Name fehlt') }
        if ([string]::IsNullOrWhiteSpace((Get-BankInfoValue $bankInfo 'AUTHOR' ''))) { $issues.Add('BANK.INFO: Autor fehlt') }
        if ([string]::IsNullOrWhiteSpace((Get-BankInfoValue $bankInfo 'LICENSE' ''))) { $issues.Add('BANK.INFO: Lizenz fehlt') }

        $cfgInfo = Get-Item -LiteralPath $cfgPath
        $totalBytes += $cfgInfo.Length
        $otherFiles = Get-ChildItem -LiteralPath $Directory.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^SLOT[1-4]\.WAV$' -and $_.Name -ne 'BANK.CFG' }
        foreach ($file in $otherFiles) { $totalBytes += $file.Length }

        return [pscustomobject]@{
            Name = $Directory.Name
            DisplayName = $Directory.Name
            Path = $Directory.FullName
            Info = $bankInfo
            Version = Get-ValueOrDefault $cfg.Header 'BANK_VERSION' '?'
            RecordedSlots = $recordedCount
            Size = $totalBytes
            SizeText = Format-Bytes $totalBytes
            Modified = $Directory.LastWriteTime
            Status = if ($issues.Count -eq 0) { 'OK' } else { "$($issues.Count) Hinweis(e)" }
            Issues = $issues
            Config = $cfg
            Slots = $slotRecords
        }
    } catch {
        return [pscustomobject]@{
            Name = $Directory.Name
            DisplayName = $Directory.Name
            Path = $Directory.FullName
            Info = (Get-DefaultBankInfo $Directory.Name)
            Version = '?'
            RecordedSlots = 0
            Size = 0
            SizeText = '-'
            Modified = $Directory.LastWriteTime
            Status = 'FEHLER'
            Issues = @($_.Exception.Message)
            Config = $null
            Slots = @()
        }
    }
}

function Update-AccessModeIndicator {
    if ($null -eq $script:AccessModeText -or $null -eq $script:AccessModeBorder) { return }
    if ([string]::IsNullOrWhiteSpace($script:PhoenixRoot) -or -not (Test-Path -LiteralPath $script:PhoenixRoot -PathType Container)) {
        $script:AccessModeText.Text = 'ZUGRIFF: NICHT VERBUNDEN'
        $script:AccessModeText.Foreground = '#E7EDF3'
        $script:AccessModeBorder.Background = '#5A2529'
        $script:AccessModeBorder.BorderBrush = '#B45B63'
        return
    }
    $bankDir = Get-BankDirectory $script:PhoenixRoot
    if (-not $bankDir) {
        $script:AccessModeText.Text = 'ZUGRIFF: UNGÜLTIGER ORDNER'
        $script:AccessModeText.Foreground = '#FFFFFF'
        $script:AccessModeBorder.Background = '#5A2529'
        $script:AccessModeBorder.BorderBrush = '#B45B63'
        return
    }
    $testPath = Join-Path $bankDir ('.phoenix_access_probe_' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($testPath, 'probe', $script:Utf8NoBom)
        $script:AccessModeText.Text = 'ZUGRIFF: READ / WRITE'
        $script:AccessModeText.Foreground = '#07140C'
        $script:AccessModeBorder.Background = '#8ED3A5'
        $script:AccessModeBorder.BorderBrush = '#C5EED2'
    } catch {
        $script:AccessModeText.Text = 'ZUGRIFF: READ ONLY'
        $script:AccessModeText.Foreground = '#171105'
        $script:AccessModeBorder.Background = '#E7C96A'
        $script:AccessModeBorder.BorderBrush = '#F4E3A8'
    } finally {
        Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
    }
}

function Refresh-Banks {
    if ([string]::IsNullOrWhiteSpace($script:PhoenixRoot)) { return }
    $bankDir = Get-BankDirectory $script:PhoenixRoot
    if (-not $bankDir) {
        Update-AccessModeIndicator
        [System.Windows.MessageBox]::Show('Kein PHOENIX\BANKS-Verzeichnis gefunden.', 'Phoenix Librarian', 'OK', 'Warning') | Out-Null
        return
    }

    $script:PathBox.Text = $script:PhoenixRoot
    Update-AccessModeIndicator
    $script:StatusText.Text = "Scanne $bankDir ..."
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $records = @()
        $dirs = Get-ChildItem -LiteralPath $bankDir -Directory -ErrorAction Stop | Where-Object { $_.Name -match '^BANK\d\d$' } | Sort-Object Name
        foreach ($dir in $dirs) {
            $record = Get-BankRecord $dir
            if ($record) { $records += $record }
        }
        $script:BankRecords = $records
        $script:BankGrid.ItemsSource = $null
        $script:BankGrid.ItemsSource = $records
        $script:StatusText.Text = "$($records.Count) Bänke gefunden"
        Add-Log "$($records.Count) Bänke in $bankDir geladen."
        if ($records.Count -gt 0) { $script:BankGrid.SelectedIndex = 0 }
        else { Clear-BankDetails }
    } catch {
        $script:StatusText.Text = 'Scan fehlgeschlagen'
        Add-Log ('FEHLER beim Scan: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Scan fehlgeschlagen', 'OK', 'Error') | Out-Null
    } finally {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
}

function Clear-BankDetails {
    $script:CurrentBank = $null
$script:CurrentSlot = $null
$script:WaveformCache = @{}
$script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $script:BankTitle.Text = 'Keine Bank ausgewählt'
    $script:BankSummary.Text = ''
    $script:SlotGrid.ItemsSource = $null
    $script:MarkerGrid.ItemsSource = $null
    $script:IssueList.ItemsSource = $null
    $script:RawConfigBox.Text = ''
    if ($script:BankNameBox) { foreach ($n in @('BankNameBox','BankCategoryBox','BankAuthorBox','BankDescriptionBox','BankLicenseBox','BankTagsBox','Slot1NameBox','Slot2NameBox','Slot3NameBox','Slot4NameBox')) { (Get-Variable -Scope Script -Name $n -ValueOnly).Text = '' }; $script:BankTemplateText.Text = '' }
}

function Show-BankDetails {
    param($Bank)
    if ($script:SelectionGuard) { return }
    if ($null -eq $Bank) { Clear-BankDetails; return }
    $script:CurrentBank = $Bank
    $displayName = Get-BankInfoValue $Bank.Info 'NAME' $Bank.Name
    $script:BankTitle.Text = if ([string]::IsNullOrWhiteSpace($displayName) -or $displayName -eq $Bank.Name) { $Bank.Name } else { "$($Bank.Name) - $displayName" }
    $script:BankSummary.Text = "Version $($Bank.Version)  |  $($Bank.RecordedSlots)/4 Slots  |  $($Bank.SizeText)  |  geändert $($Bank.Modified.ToString('dd.MM.yyyy HH:mm'))"
    if ($script:BankNameBox) {
        $script:BankNameBox.Text = Get-BankInfoValue $Bank.Info 'NAME' $Bank.Name
        $script:BankCategoryBox.Text = Get-BankInfoValue $Bank.Info 'CATEGORY' 'Uncategorized'
        $script:BankAuthorBox.Text = Get-BankInfoValue $Bank.Info 'AUTHOR' 'RealTimeAudioLab'
        $script:BankDescriptionBox.Text = Get-BankInfoValue $Bank.Info 'DESCRIPTION' ''
        $script:BankLicenseBox.Text = Get-BankInfoValue $Bank.Info 'LICENSE' 'All rights reserved'
        $script:BankTagsBox.Text = Get-BankInfoValue $Bank.Info 'TAGS' ''
        $script:BankTemplateText.Text = Get-BankInfoValue $Bank.Info 'TEMPLATE' 'EMPTY BANK'
        for ($i=1; $i -le 4; $i++) { $box = Get-Variable -Scope Script -Name ("Slot{0}NameBox" -f $i) -ValueOnly; $box.Text = Get-BankInfoValue $Bank.Info ("SLOT{0}_NAME" -f $i) ("S{0}" -f $i) }
    }
    $script:SlotGrid.ItemsSource = $null
    $script:SlotGrid.ItemsSource = $Bank.Slots
    $script:MarkerGrid.ItemsSource = $null
    $script:MarkerGrid.ItemsSource = $Bank.Slots
    $script:IssueList.ItemsSource = $null
    if ($Bank.Issues.Count -eq 0) { $script:IssueList.ItemsSource = @('Keine Inkonsistenzen erkannt.') }
    else { $script:IssueList.ItemsSource = $Bank.Issues }
    if ($null -ne $Bank.Config) { $script:RawConfigBox.Text = [string]::Join("`r`n", $Bank.Config.RawLines) }
    else { $script:RawConfigBox.Text = '' }
}

function Select-PhoenixFolder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Phoenix SD-Karte oder PHOENIX-Ordner auswählen'
    $dialog.ShowNewFolderButton = $false
    if (-not [string]::IsNullOrWhiteSpace($script:PhoenixRoot) -and (Test-Path -LiteralPath $script:PhoenixRoot)) {
        $dialog.SelectedPath = $script:PhoenixRoot
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:PhoenixRoot = $dialog.SelectedPath
        Refresh-Banks
    }
}

function Auto-Detect-Phoenix {
    $found = @(Find-PhoenixRoots)
    if ($found.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Keine eingehängte Phoenix SD-Karte gefunden. Bitte USB Mass Storage aktivieren oder den Ordner manuell wählen.', 'Phoenix nicht gefunden', 'OK', 'Information') | Out-Null
        return
    }
    if ($found.Count -eq 1) {
        $script:PhoenixRoot = $found[0].Root
        Refresh-Banks
        return
    }

    $names = $found | ForEach-Object { "$($_.Label)  [$($_.Root)]" }
    $choice = [System.Windows.MessageBox]::Show("Mehrere Phoenix-Datenträger gefunden.`r`nEs wird der erste verwendet:`r`n$($names[0])", 'Phoenix Librarian', 'OKCancel', 'Question')
    if ($choice -eq [System.Windows.MessageBoxResult]::OK) {
        $script:PhoenixRoot = $found[0].Root
        Refresh-Banks
    }
}

function Format-TransferBytes {
    param([long]$Bytes)
    if($Bytes -ge 1GB){ return ('{0:N2} GB' -f ($Bytes/1GB)) }
    if($Bytes -ge 1MB){ return ('{0:N1} MB' -f ($Bytes/1MB)) }
    if($Bytes -ge 1KB){ return ('{0:N1} KB' -f ($Bytes/1KB)) }
    return ($Bytes.ToString()+' B')
}

function Show-TransferProgress {
    param([string]$Title='Phoenix Backup')
    $script:TransferCancelRequested=$false
    $xaml=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="$Title" Height="340" Width="670" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#10141A" Foreground="#E8EDF2">
<Grid Margin="18">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Name="TPTitle" Text="PHOENIX WIRD VERARBEITET ..." FontSize="20" FontWeight="Bold"/>
  <TextBlock Name="TPPhase" Grid.Row="1" Text="Vorbereitung ..." Margin="0,10,0,4" Foreground="#B9C8D6" FontWeight="SemiBold"/>
  <ProgressBar Name="TPBar" Grid.Row="2" Height="24" Minimum="0" Maximum="100" Value="0" Margin="0,4,0,8"/>
  <TextBlock Name="TPPercent" Grid.Row="3" Text="0 %" HorizontalAlignment="Right" FontSize="14" FontWeight="Bold"/>
  <Grid Grid.Row="4" Margin="0,8,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="125"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Bank:" Foreground="#9EB0C3"/><TextBlock Name="TPBank" Grid.Column="1" Text="-" TextTrimming="CharacterEllipsis"/></Grid>
  <Grid Grid.Row="5" Margin="0,5,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="125"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Datei:" Foreground="#9EB0C3"/><TextBlock Name="TPFile" Grid.Column="1" Text="-" TextTrimming="CharacterEllipsis"/></Grid>
  <Grid Grid.Row="6" Margin="0,5,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="125"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Fortschritt:" Foreground="#9EB0C3"/><TextBlock Name="TPBytes" Grid.Column="1" Text="-"/></Grid>
  <Grid Grid.Row="7" Margin="0,5,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="125"/><ColumnDefinition Width="*"/><ColumnDefinition Width="125"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Banken:" Foreground="#9EB0C3"/><TextBlock Name="TPBanks" Grid.Column="1" Text="-"/><TextBlock Grid.Column="2" Text="Dauer / Rest:" Foreground="#9EB0C3"/><TextBlock Name="TPTime" Grid.Column="3" Text="00:00 / -"/></Grid>
  <DockPanel Grid.Row="8" Margin="0,16,0,0"><TextBlock Name="TPStatus" Text="Bitte warten ..." Foreground="#9EB0C3" VerticalAlignment="Center"/><Button Name="TPCancel" DockPanel.Dock="Right" Content="Sicherung abbrechen" Padding="14,7" MinWidth="150"/></DockPanel>
</Grid></Window>
"@
    [xml]$doc=$xaml
    $reader=New-Object System.Xml.XmlNodeReader($doc)
    $w=[Windows.Markup.XamlReader]::Load($reader)
    $w.Owner=$script:Window
    $script:TransferWindow=$w
    foreach($n in 'TPTitle','TPPhase','TPBar','TPPercent','TPBank','TPFile','TPBytes','TPBanks','TPTime','TPStatus','TPCancel'){
        Set-Variable -Scope Script -Name $n -Value $w.FindName($n)
    }
    $script:TPCancel.Add_Click({$script:TransferCancelRequested=$true;$script:TPCancel.IsEnabled=$false;$script:TPStatus.Text='Abbruch wird vorbereitet ...'})
    $w.Add_Closing({param($sender,$e); if(-not $script:TransferFinished){$e.Cancel=$true;$script:TransferCancelRequested=$true;$script:TPCancel.IsEnabled=$false;$script:TPStatus.Text='Abbruch wird vorbereitet ...'}})
    $script:TransferFinished=$false
    $w.Show()
    $script:Window.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
}

function Update-TransferProgress {
    param([string]$Phase,[string]$CurrentFile,[long]$BytesDone,[long]$BytesTotal,[int]$FilesDone,[int]$FilesTotal,[string]$Bank,[int]$BanksDone,[int]$BanksTotal,[datetime]$Started)
    if($null -eq $script:TransferWindow){return}
    $pct=if($BytesTotal -gt 0){[Math]::Min(100,[Math]::Max(0,($BytesDone*100.0/$BytesTotal)))}else{0}
    $elapsed=(Get-Date)-$Started
    $remain='-'
    if($BytesDone -gt 0 -and $BytesTotal -gt $BytesDone -and $elapsed.TotalSeconds -gt 0.2){
        $rate=$BytesDone/$elapsed.TotalSeconds
        if($rate -gt 0){$rs=[Math]::Max(0,($BytesTotal-$BytesDone)/$rate);$remain=[TimeSpan]::FromSeconds($rs).ToString('mm\:ss')}
    }
    $script:TPPhase.Text=$Phase
    $script:TPBar.IsIndeterminate=$false
    $script:TPBar.Value=$pct
    $script:TPPercent.Text=('{0:N0} %' -f $pct)
    $script:TPBank.Text=if([string]::IsNullOrWhiteSpace($Bank)){'-'}else{$Bank}
    $script:TPFile.Text=if([string]::IsNullOrWhiteSpace($CurrentFile)){'-'}else{$CurrentFile}
    $script:TPBytes.Text=('{0} / {1}   |   Dateien {2} / {3}' -f (Format-TransferBytes $BytesDone),(Format-TransferBytes $BytesTotal),$FilesDone,$FilesTotal)
    $script:TPBanks.Text=if($BanksTotal -gt 0){("$BanksDone / $BanksTotal")}else{'-'}
    $script:TPTime.Text=($elapsed.ToString('mm\:ss')+' / '+$remain)
    $script:Window.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
}

function Close-TransferProgress {
    param([string]$Status='Fertig')
    if($null -ne $script:TransferWindow){
        $script:TransferFinished=$true
        $script:TPStatus.Text=$Status
        $script:Window.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
        try{$script:TransferWindow.Close()}catch{}
    }
    $script:TransferWindow=$null
}

function Get-TransferBankName {
    param([string]$Source,[string]$FilePath)
    $rel=$FilePath.Substring($Source.Length).TrimStart('\\')
    if($rel -match '(?i)(?:^|\\)(BANK\d\d)(?:\\|$)'){return $matches[1].ToUpperInvariant()}
    $leaf=(Split-Path $Source -Leaf)
    if($leaf -match '^BANK\d\d$'){return $leaf.ToUpperInvariant()}
    return ''
}

function Copy-DirectoryWithProgress {
    param([string]$Source,[string]$Destination,[string]$Phase='Dateien werden kopiert',[switch]$ShowProgress)
    if(-not(Test-Path -LiteralPath $Source -PathType Container)){throw "Quellordner fehlt: $Source"}
    $started=Get-Date
    if($ShowProgress -and $null -eq $script:TransferWindow){Show-TransferProgress 'Phoenix Backup & Restore'}
    if($ShowProgress){$script:TPBar.IsIndeterminate=$true;$script:TPPhase.Text='Dateien werden erfasst ...';$script:TPStatus.Text='Größe und Dateiliste werden ermittelt.';$script:Window.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)}
    $files=@(Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction Stop)
    $dirs=@(Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force -ErrorAction Stop)
    [long]$total=0;foreach($f in $files){$total+=$f.Length}
    $bankNames=@($files|ForEach-Object{Get-TransferBankName $Source $_.FullName}|Where-Object{$_}|Sort-Object -Unique)
    $bankTotal=$bankNames.Count;$seenBanks=New-Object 'System.Collections.Generic.HashSet[string]'
    [System.IO.Directory]::CreateDirectory($Destination)|Out-Null
    foreach($d in $dirs){if($script:TransferCancelRequested){throw [OperationCanceledException]::new('Vorgang vom Benutzer abgebrochen.')};$rel=$d.FullName.Substring($Source.Length).TrimStart('\\');[System.IO.Directory]::CreateDirectory((Join-Path $Destination $rel))|Out-Null}
    [long]$done=0;$fileDone=0
    $buffer=New-Object byte[] (1024*1024)
    foreach($f in $files){
        if($script:TransferCancelRequested){throw [OperationCanceledException]::new('Vorgang vom Benutzer abgebrochen.')}
        $rel=$f.FullName.Substring($Source.Length).TrimStart('\\');$dest=Join-Path $Destination $rel;[System.IO.Directory]::CreateDirectory((Split-Path $dest -Parent))|Out-Null
        $bank=Get-TransferBankName $Source $f.FullName;if($bank){[void]$seenBanks.Add($bank)}
        $in=$null;$out=$null
        try{
            $in=[IO.File]::Open($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            $out=[IO.File]::Open($dest,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
            while(($n=$in.Read($buffer,0,$buffer.Length)) -gt 0){
                if($script:TransferCancelRequested){throw [OperationCanceledException]::new('Vorgang vom Benutzer abgebrochen.')}
                $out.Write($buffer,0,$n);$done+=$n
                if($ShowProgress){Update-TransferProgress $Phase $rel $done $total $fileDone $files.Count $bank $seenBanks.Count $bankTotal $started}
            }
        } finally {if($out){$out.Dispose()};if($in){$in.Dispose()}}
        try{[IO.File]::SetLastWriteTime($dest,$f.LastWriteTime)}catch{}
        $fileDone++
        if($ShowProgress){Update-TransferProgress $Phase $rel $done $total $fileDone $files.Count $bank $seenBanks.Count $bankTotal $started}
    }
    return [pscustomobject]@{Bytes=$done;Files=$fileDone;Banks=$bankTotal;Duration=((Get-Date)-$started)}
}

function Copy-DirectorySafe {
    param([string]$Source,[string]$Destination)
    [void](Copy-DirectoryWithProgress -Source $Source -Destination $Destination)
}

function Backup-SelectedBank {
    if ($null -eq $script:CurrentBank) { return }
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Zielordner für das Bank-Backup auswählen'
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $destination = Join-Path $dialog.SelectedPath ("{0}_{1}" -f $script:CurrentBank.Name, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        [void](Copy-DirectoryWithProgress -Source $script:CurrentBank.Path -Destination $destination -Phase 'Bank wird gesichert' -ShowProgress)
        Add-Log "Backup erstellt: $destination"
        Close-TransferProgress 'Sicherung abgeschlossen.'
        [System.Windows.MessageBox]::Show("Backup erfolgreich erstellt:`r`n$destination", 'Phoenix Librarian', 'OK', 'Information') | Out-Null
    } catch {
        Add-Log ('Backup fehlgeschlagen: ' + $_.Exception.Message)
        Close-TransferProgress 'Fehler'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Backup fehlgeschlagen', 'OK', 'Error') | Out-Null
    } finally {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
}

function Backup-AllBanks {
    if ([string]::IsNullOrWhiteSpace($script:PhoenixRoot)) { return }
    $bankDir = Get-BankDirectory $script:PhoenixRoot
    if (-not $bankDir) { return }
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Zielordner für die vollständige Phoenix-Sicherung auswählen'
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $destination = Join-Path $dialog.SelectedPath ("PHOENIX_BACKUP_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        [void](Copy-DirectoryWithProgress -Source $bankDir -Destination $destination -Phase 'Banken werden gesichert' -ShowProgress)
        Add-Log "Komplettsicherung erstellt: $destination"
        Close-TransferProgress 'Sicherung abgeschlossen.'
        [System.Windows.MessageBox]::Show("Komplettsicherung erfolgreich erstellt:`r`n$destination", 'Phoenix Librarian', 'OK', 'Information') | Out-Null
    } catch {
        Add-Log ('Komplettsicherung fehlgeschlagen: ' + $_.Exception.Message)
        Close-TransferProgress 'Fehler'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Sicherung fehlgeschlagen', 'OK', 'Error') | Out-Null
    } finally {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
}


function Get-DefaultBackupRoot {
    try {
        $docs=[Environment]::GetFolderPath('MyDocuments')
        if([string]::IsNullOrWhiteSpace($docs)){$docs=$env:USERPROFILE}
        return (Join-Path $docs 'Phoenix Backups')
    } catch { return (Join-Path $env:TEMP 'Phoenix Backups') }
}

function Get-PhoenixContentRoot {
    if([string]::IsNullOrWhiteSpace($script:PhoenixRoot)){return $null}
    $direct=Join-Path $script:PhoenixRoot 'PHOENIX'
    if(Test-Path -LiteralPath $direct -PathType Container){return $direct}
    if((Split-Path $script:PhoenixRoot -Leaf).ToUpperInvariant() -eq 'PHOENIX'){return $script:PhoenixRoot}
    $bankDir=Get-BankDirectory $script:PhoenixRoot
    if($bankDir){
        $parent=Split-Path $bankDir -Parent
        if((Split-Path $parent -Leaf).ToUpperInvariant() -eq 'PHOENIX'){return $parent}
    }
    return $script:PhoenixRoot
}

function Write-BackupInfo {
    param([string]$Folder,[string]$Type,[string]$Source,[string]$Bank='',[string]$Comment='')
    $lines=@(
        'PHOENIX BACKUP',
        'VERSION=1',
        ('TYPE='+$Type),
        ('CREATED='+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('SOURCE='+$Source),
        ('SOURCE_BANK='+$Bank),
        ('LIBRARIAN_VERSION='+$script:AppVersion),
        ('COMMENT='+($Comment -replace "`r|`n",' '))
    )
    [IO.File]::WriteAllLines((Join-Path $Folder 'BACKUP.INFO'),$lines,$script:Utf8NoBom)
}

function Read-BackupInfo {
    param([string]$Folder)
    $map=@{}
    $f=Join-Path $Folder 'BACKUP.INFO'
    if(Test-Path -LiteralPath $f -PathType Leaf){
        foreach($line in [IO.File]::ReadAllLines($f)){
            if($line -match '^([^=]+)=(.*)$'){$map[$matches[1]]=$matches[2]}
        }
    }
    return $map
}

function Get-BackupRecords {
    $records=@()
    if([string]::IsNullOrWhiteSpace($script:BackupRoot) -or -not(Test-Path -LiteralPath $script:BackupRoot -PathType Container)){return $records}
    foreach($d in Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending){
        $info=Read-BackupInfo $d.FullName
        if($info.Count -eq 0){continue}
        $type=if($info.ContainsKey('TYPE')){$info['TYPE']}else{'?'}
        $bank=if($info.ContainsKey('SOURCE_BANK')){$info['SOURCE_BANK']}else{''}
        $created=if($info.ContainsKey('CREATED')){$info['CREATED']}else{$d.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')}
        $comment=if($info.ContainsKey('COMMENT')){$info['COMMENT']}else{''}
        $status='Backup verfügbar'
        if($type -eq 'BANK' -and -not[string]::IsNullOrWhiteSpace($bank)){
            $bankDir=Get-BankDirectory $script:PhoenixRoot
            if($bankDir){$status=if(Test-Path -LiteralPath (Join-Path $bankDir $bank) -PathType Container){'Bank vorhanden'}else{'Bank fehlt aktuell'}}
        } elseif($type -eq 'FULL'){$status='Vollbackup'}
        $records += [pscustomobject]@{Name=$d.Name;Type=$type;Bank=$bank;Created=$created;Comment=$comment;Status=$status;Path=$d.FullName}
    }
    return $records
}

function Refresh-BackupCenter {
    if($null -eq $script:BackupPathBox){return}
    if([string]::IsNullOrWhiteSpace($script:BackupRoot)){$script:BackupRoot=Get-DefaultBackupRoot}
    $script:BackupPathBox.Text=$script:BackupRoot
    if(-not(Test-Path -LiteralPath $script:BackupRoot -PathType Container)){
        try{New-Item -ItemType Directory -Path $script:BackupRoot -Force|Out-Null}catch{}
    }
    $script:BackupGrid.ItemsSource=$null
    $script:BackupGrid.ItemsSource=@(Get-BackupRecords)
    $count=@($script:BackupGrid.ItemsSource).Count
    $script:BackupStatusText.Text=("{0} Backup(s) gefunden" -f $count)
}

function Select-BackupRoot {
    $dialog=New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description='Ordner für Phoenix-Backups auswählen'
    $dialog.ShowNewFolderButton=$true
    if(Test-Path -LiteralPath $script:BackupRoot -PathType Container){$dialog.SelectedPath=$script:BackupRoot}
    if($dialog.ShowDialog()-eq [System.Windows.Forms.DialogResult]::OK){$script:BackupRoot=$dialog.SelectedPath;Refresh-BackupCenter}
}

function New-FullPhoenixBackup {
    $src=Get-PhoenixContentRoot
    if(-not $src -or -not(Test-Path -LiteralPath $src -PathType Container)){[System.Windows.MessageBox]::Show('Keine gültige Phoenix-Quelle gewählt.','Backup','OK','Warning')|Out-Null;return}
    Refresh-BackupCenter
    $comment=if($script:BackupCommentBox){$script:BackupCommentBox.Text.Trim()}else{''}
    $folder=Join-Path $script:BackupRoot ('PHOENIX_FULL_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
    Show-TransferProgress 'Phoenix komplett sichern'
    $script:TPTitle.Text='PHOENIX WIRD GESICHERT ...';$script:TPCancel.Content='Sicherung abbrechen'
    try{
        New-Item -ItemType Directory -Path $folder -Force|Out-Null
        $payload=Join-Path $folder 'PHOENIX'
        $r=Copy-DirectoryWithProgress -Source $src -Destination $payload -Phase 'Phoenix-Dateien werden gesichert' -ShowProgress
        if($script:TransferCancelRequested){throw [OperationCanceledException]::new('Sicherung abgebrochen.')}
        $script:TPPhase.Text='BACKUP.INFO wird erstellt ...';$script:Window.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
        Write-BackupInfo $folder 'FULL' $src '' $comment
        $script:TPBar.Value=100;$script:TPPercent.Text='100 %';$script:TPStatus.Text='Sicherung erfolgreich abgeschlossen.'
        Add-Log ('Vollbackup erstellt: '+$folder);Refresh-BackupCenter
        Close-TransferProgress 'Sicherung abgeschlossen.'
        [System.Windows.MessageBox]::Show(("BACKUP ERFOLGREICH`r`n`r`n{0} Banken`r`n{1} Dateien`r`n{2}`r`nDauer: {3}`r`n`r`n{4}" -f $r.Banks,$r.Files,(Format-TransferBytes $r.Bytes),$r.Duration.ToString('mm\:ss'),$folder),'Backup & Restore','OK','Information')|Out-Null
    }catch [OperationCanceledException]{Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue;Add-Log('Vollbackup vom Benutzer abgebrochen.');Close-TransferProgress 'Sicherung abgebrochen.';[System.Windows.MessageBox]::Show('Die Sicherung wurde abgebrochen. Unvollständige Backupdaten wurden entfernt.','Backup & Restore','OK','Information')|Out-Null}
    catch{Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue;Add-Log('Vollbackup fehlgeschlagen: '+$_.Exception.Message);Close-TransferProgress 'Fehler';[System.Windows.MessageBox]::Show($_.Exception.Message,'Backup fehlgeschlagen','OK','Error')|Out-Null}
}

function New-CurrentBankBackup {
    if($null -eq $script:CurrentBank){return}
    Refresh-BackupCenter
    $comment=if($script:BackupCommentBox){$script:BackupCommentBox.Text.Trim()}else{''}
    $folder=Join-Path $script:BackupRoot (($script:CurrentBank.Name)+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
    Show-TransferProgress 'Bank sichern';$script:TPTitle.Text=($script:CurrentBank.Name+' WIRD GESICHERT ...');$script:TPCancel.Content='Sicherung abbrechen'
    try{
        New-Item -ItemType Directory -Path $folder -Force|Out-Null
        $payload=Join-Path (Join-Path $folder 'BANK') $script:CurrentBank.Name
        $r=Copy-DirectoryWithProgress -Source $script:CurrentBank.Path -Destination $payload -Phase 'Bank wird gesichert' -ShowProgress
        Write-BackupInfo $folder 'BANK' $script:CurrentBank.Path $script:CurrentBank.Name $comment
        Add-Log ('Bank-Backup erstellt: '+$folder);Refresh-BackupCenter;Close-TransferProgress 'Sicherung abgeschlossen.'
        [System.Windows.MessageBox]::Show(("Bank-Backup erstellt.`r`n`r`n{0} Dateien | {1} | {2}`r`n`r`n{3}" -f $r.Files,(Format-TransferBytes $r.Bytes),$r.Duration.ToString('mm\:ss'),$folder),'Backup & Restore','OK','Information')|Out-Null
    }catch [OperationCanceledException]{Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue;Add-Log('Bank-Backup abgebrochen.');Close-TransferProgress 'Sicherung abgebrochen.'}
    catch{Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue;Add-Log('Bank-Backup fehlgeschlagen: '+$_.Exception.Message);Close-TransferProgress 'Fehler';[System.Windows.MessageBox]::Show($_.Exception.Message,'Backup fehlgeschlagen','OK','Error')|Out-Null}
}

function Get-SelectedBackupRecord { if($null -eq $script:BackupGrid){return $null}; return $script:BackupGrid.SelectedItem }

function Open-SelectedBackupFolder {
    $b=Get-SelectedBackupRecord;if($null-eq$b){return};Start-Process explorer.exe -ArgumentList ('"'+$b.Path+'"')
}

function Restore-BankBackup {
    $b=Get-SelectedBackupRecord;if($null-eq$b){return}
    if($b.Type-ne'BANK'){[System.Windows.MessageBox]::Show('Bitte ein BANK-Backup auswählen.','Restore','OK','Information')|Out-Null;return}
    $bankName=$b.Bank;if([string]::IsNullOrWhiteSpace($bankName)){return}
    $source=Join-Path (Join-Path $b.Path 'BANK') $bankName
    if(-not(Test-Path -LiteralPath $source -PathType Container)){[System.Windows.MessageBox]::Show('Backup-Nutzdaten fehlen.','Restore','OK','Error')|Out-Null;return}
    $bankDir=Get-BankDirectory $script:PhoenixRoot;if(-not$bankDir){return};$target=Join-Path $bankDir $bankName
    $ans=[System.Windows.MessageBox]::Show("$bankName aus Backup wiederherstellen?`r`nVorhandene Bankdaten werden ersetzt. Vorher wird automatisch ein Sicherheitsbackup erstellt.",'Bank wiederherstellen','YesNo','Warning');if($ans-ne[System.Windows.MessageBoxResult]::Yes){return}
    Show-TransferProgress 'Bank wiederherstellen';$script:TPTitle.Text=($bankName+' WIRD WIEDERHERGESTELLT ...');$script:TPCancel.Content='Restore abbrechen'
    try{
        [void](Test-PhoenixWriteAccess)
        if(Test-Path -LiteralPath $target -PathType Container){$safe=Join-Path $script:BackupRoot ('SAFETY_'+$bankName+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss'));New-Item -ItemType Directory -Path $safe -Force|Out-Null;[void](Copy-DirectoryWithProgress -Source $target -Destination (Join-Path (Join-Path $safe 'BANK') $bankName) -Phase 'Sicherheitsbackup vor Restore' -ShowProgress);Write-BackupInfo $safe 'BANK' $target $bankName 'Automatisch vor Restore';if($script:TransferCancelRequested){throw [OperationCanceledException]::new('Restore abgebrochen.')};Remove-Item -LiteralPath $target -Recurse -Force}
        [void](Copy-DirectoryWithProgress -Source $source -Destination $target -Phase 'Bank wird wiederhergestellt' -ShowProgress)
        Add-Log("Bank wiederhergestellt: $bankName aus $($b.Name)");Refresh-Banks;Apply-BankFilter;Refresh-BackupCenter;Close-TransferProgress 'Restore abgeschlossen.';[System.Windows.MessageBox]::Show("$bankName wurde wiederhergestellt.",'Restore','OK','Information')|Out-Null
    }catch [OperationCanceledException]{Add-Log('Bank-Restore abgebrochen.');Close-TransferProgress 'Restore abgebrochen.'}
    catch{Add-Log('Bank-Restore fehlgeschlagen: '+$_.Exception.Message);Close-TransferProgress 'Fehler';[System.Windows.MessageBox]::Show($_.Exception.Message,'Restore fehlgeschlagen','OK','Error')|Out-Null}
}

function Restore-FullBackup {
    $b=Get-SelectedBackupRecord;if($null-eq$b){return}
    if($b.Type-ne'FULL'){[System.Windows.MessageBox]::Show('Bitte ein FULL-Backup auswählen.','Restore','OK','Information')|Out-Null;return}
    $source=Join-Path $b.Path 'PHOENIX';$target=Get-PhoenixContentRoot
    if(-not(Test-Path -LiteralPath $source -PathType Container)-or-not$target){[System.Windows.MessageBox]::Show('Backup-Nutzdaten oder Phoenix-Ziel fehlen.','Restore','OK','Error')|Out-Null;return}
    $ans=[System.Windows.MessageBox]::Show("KOMPLETTES Phoenix-System aus '$($b.Name)' wiederherstellen?`r`n`r`nDer aktuelle PHOENIX-Inhalt wird vorher automatisch vollständig gesichert und danach ersetzt.",'Vollständige Wiederherstellung','YesNo','Warning');if($ans-ne[System.Windows.MessageBoxResult]::Yes){return}
    Show-TransferProgress 'Phoenix komplett wiederherstellen';$script:TPTitle.Text='PHOENIX WIRD WIEDERHERGESTELLT ...';$script:TPCancel.Content='Restore abbrechen'
    try{
        [void](Test-PhoenixWriteAccess)
        $safe=Join-Path $script:BackupRoot ('SAFETY_FULL_'+(Get-Date -Format 'yyyyMMdd_HHmmss'));New-Item -ItemType Directory -Path $safe -Force|Out-Null
        [void](Copy-DirectoryWithProgress -Source $target -Destination (Join-Path $safe 'PHOENIX') -Phase 'Sicherheitsbackup vor Voll-Restore' -ShowProgress);Write-BackupInfo $safe 'FULL' $target '' 'Automatisch vor Voll-Restore'
        if($script:TransferCancelRequested){throw [OperationCanceledException]::new('Restore abgebrochen.')}
        $script:TPPhase.Text='Aktueller Phoenix-Inhalt wird entfernt ...';$script:TPBar.IsIndeterminate=$true;$script:Window.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
        foreach($item in Get-ChildItem -LiteralPath $target -Force -ErrorAction Stop){if($script:TransferCancelRequested){throw [OperationCanceledException]::new('Restore abgebrochen.')};Remove-Item -LiteralPath $item.FullName -Recurse -Force}
        [void](Copy-DirectoryWithProgress -Source $source -Destination $target -Phase 'Phoenix wird wiederhergestellt' -ShowProgress)
        Add-Log('Phoenix-Vollrestore abgeschlossen: '+$b.Name);Refresh-Banks;Apply-BankFilter;Refresh-BackupCenter;Close-TransferProgress 'Restore abgeschlossen.';[System.Windows.MessageBox]::Show('Phoenix-System wurde vollständig wiederhergestellt.','Restore','OK','Information')|Out-Null
    }catch [OperationCanceledException]{Add-Log('Vollrestore abgebrochen.');Close-TransferProgress 'Restore abgebrochen.';[System.Windows.MessageBox]::Show('Restore wurde abgebrochen. Das automatisch erzeugte Sicherheitsbackup bleibt erhalten.','Restore','OK','Information')|Out-Null}
    catch{Add-Log('Vollrestore fehlgeschlagen: '+$_.Exception.Message);Close-TransferProgress 'Fehler';[System.Windows.MessageBox]::Show($_.Exception.Message,'Restore fehlgeschlagen','OK','Error')|Out-Null}
}

function Compare-SelectedBackup {
    $b=Get-SelectedBackupRecord;if($null-eq$b){return}
    if($b.Type-eq'BANK'){
        $bankDir=Get-BankDirectory $script:PhoenixRoot;$target=if($bankDir){Join-Path $bankDir $b.Bank}else{$null}
        $src=Join-Path (Join-Path $b.Path 'BANK') $b.Bank
        if(-not(Test-Path -LiteralPath $target -PathType Container)){$script:BackupStatusText.Text="$($b.Bank): fehlt aktuell";return}
        $a=@(Get-ChildItem -LiteralPath $src -File -Recurse|ForEach-Object{$_.FullName.Substring($src.Length).TrimStart('\')+'|'+$_.Length}|Sort-Object)
        $c=@(Get-ChildItem -LiteralPath $target -File -Recurse|ForEach-Object{$_.FullName.Substring($target.Length).TrimStart('\')+'|'+$_.Length}|Sort-Object)
        $same=($a.Count-eq$c.Count -and (($a-join "`n")-eq($c-join "`n")))
        $script:BackupStatusText.Text=if($same){"$($b.Bank): Struktur/Dateigrößen identisch"}else{"$($b.Bank): Unterschiede gefunden"}
    }else{
        $src=Join-Path $b.Path 'PHOENIX';$srcBanks=Join-Path $src 'BANKS';$cur=Get-BankDirectory $script:PhoenixRoot
        $n1=if(Test-Path$srcBanks){@(Get-ChildItem $srcBanks -Directory|Where-Object{$_.Name-match'^BANK\d\d$'}).Count}else{0};$n2=if($cur){@(Get-ChildItem $cur -Directory|Where-Object{$_.Name-match'^BANK\d\d$'}).Count}else{0}
        $script:BackupStatusText.Text=("Vollbackup: {0} Banken | aktuell: {1} Banken" -f $n1,$n2)
    }
}

function Open-SelectedBankFolder {
    if ($null -eq $script:CurrentBank) { return }
    Start-Process explorer.exe -ArgumentList ('"' + $script:CurrentBank.Path + '"')
}

function Export-Report {
    if ($script:BankRecords.Count -eq 0) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = 'Phoenix Library Report speichern'
    $dialog.Filter = 'Textdatei (*.txt)|*.txt|Alle Dateien (*.*)|*.*'
    $dialog.FileName = 'Phoenix_Library_Report_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt'
    if ($dialog.ShowDialog() -ne $true) { return }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Phoenix Librarian v$script:AppVersion")
    $lines.Add("Quelle: $script:PhoenixRoot")
    $lines.Add("Erstellt: $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')")
    $lines.Add('')
    foreach ($bank in $script:BankRecords) {
        $lines.Add("[$($bank.Name)] Version=$($bank.Version) Slots=$($bank.RecordedSlots)/4 Size=$($bank.SizeText) Status=$($bank.Status)")
        foreach ($slot in $bank.Slots) {
            $lines.Add("  $($slot.Slot) REC=$($slot.Recorded) WAV=$($slot.Wav) Duration=$($slot.Duration) Root=$($slot.Root) Loop=$($slot.LoopMode) XFade=$($slot.XFade) T=$($slot.Trim) DC=$($slot.DC) NM=$($slot.Normalize) Status=$($slot.Issue)")
        }
        foreach ($issue in $bank.Issues) { $lines.Add("  WARNING: $issue") }
        $lines.Add('')
    }
    [System.IO.File]::WriteAllLines($dialog.FileName, $lines, $script:Utf8Bom)
    Add-Log "Report gespeichert: $($dialog.FileName)"
}


# --------------------------- Phase 2: waveform and bank management ---------------------------

function Clear-Waveform {
    $script:CurrentSlot = $null
    if ($script:WaveformCanvas) { $script:WaveformCanvas.Children.Clear() }
    if ($script:WaveformInfo) { $script:WaveformInfo.Text = 'Kein Slot ausgewählt.' }
    if ($script:OpenWavButton) { $script:OpenWavButton.IsEnabled = $false }
}

function Clear-BankDetails {
    $script:CurrentBank = $null
    $script:BankTitle.Text = 'Keine Bank ausgewählt'
    $script:BankSummary.Text = ''
    $script:SlotGrid.ItemsSource = $null
    $script:MarkerGrid.ItemsSource = $null
    $script:IssueList.ItemsSource = $null
    $script:RawConfigBox.Text = ''
    Clear-Waveform
}

function Show-BankDetails {
    param($Bank)
    if ($script:SelectionGuard) { return }
    if ($null -eq $Bank) { Clear-BankDetails; return }
    $script:CurrentBank = $Bank
    $displayName = Get-BankInfoValue $Bank.Info 'NAME' $Bank.Name
    $script:BankTitle.Text = if ([string]::IsNullOrWhiteSpace($displayName) -or $displayName -eq $Bank.Name) { $Bank.Name } else { "$($Bank.Name) - $displayName" }
    $script:BankSummary.Text = "Version $($Bank.Version)  |  $($Bank.RecordedSlots)/4 Slots  |  $($Bank.SizeText)  |  geändert $($Bank.Modified.ToString('dd.MM.yyyy HH:mm'))"
    if ($script:BankNameBox) {
        $script:BankNameBox.Text = Get-BankInfoValue $Bank.Info 'NAME' $Bank.Name
        $script:BankCategoryBox.Text = Get-BankInfoValue $Bank.Info 'CATEGORY' 'Uncategorized'
        $script:BankAuthorBox.Text = Get-BankInfoValue $Bank.Info 'AUTHOR' 'RealTimeAudioLab'
        $script:BankDescriptionBox.Text = Get-BankInfoValue $Bank.Info 'DESCRIPTION' ''
        $script:BankLicenseBox.Text = Get-BankInfoValue $Bank.Info 'LICENSE' 'All rights reserved'
        $script:BankTagsBox.Text = Get-BankInfoValue $Bank.Info 'TAGS' ''
        $script:BankTemplateText.Text = Get-BankInfoValue $Bank.Info 'TEMPLATE' 'EMPTY BANK'
        for ($i=1; $i -le 4; $i++) { $box = Get-Variable -Scope Script -Name ("Slot{0}NameBox" -f $i) -ValueOnly; $box.Text = Get-BankInfoValue $Bank.Info ("SLOT{0}_NAME" -f $i) ("S{0}" -f $i) }
    }
    $script:SlotGrid.ItemsSource = $null
    $script:SlotGrid.ItemsSource = $Bank.Slots
    $script:MarkerGrid.ItemsSource = $null
    $script:MarkerGrid.ItemsSource = $Bank.Slots
    $script:IssueList.ItemsSource = $null
    if ($Bank.Issues.Count -eq 0) { $script:IssueList.ItemsSource = @('Keine Inkonsistenzen erkannt.') }
    else { $script:IssueList.ItemsSource = $Bank.Issues }
    if ($null -ne $Bank.Config) { $script:RawConfigBox.Text = [string]::Join("`r`n", $Bank.Config.RawLines) }
    else { $script:RawConfigBox.Text = '' }
    if ($Bank.Slots.Count -gt 0) { $script:SlotGrid.SelectedIndex = 0 }
    else { Clear-Waveform }
}

function Get-WaveformEnvelope {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][int]$Width
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'WAV-Datei fehlt.' }
    $meta = Read-WavMetadata $Path
    if (-not $meta.Valid) { throw ('Ungültige WAV-Datei: ' + $meta.Error) }
    if ($meta.AudioFormat -ne 1 -or $meta.BitsPerSample -ne 16) {
        throw "Waveform-Vorschau unterstützt derzeit PCM mit 16 Bit. Datei: Format=$($meta.AudioFormat), Bits=$($meta.BitsPerSample)."
    }
    if ($meta.DataOffset -le 0 -or $meta.Frames -le 0) { throw 'Keine auswertbaren PCM-Daten gefunden.' }

    $Width = [math]::Max(128, [math]::Min(1600, $Width))
    $item = Get-Item -LiteralPath $Path
    $cacheKey = "$Path|$($item.LastWriteTimeUtc.Ticks)|$Width"
    if ($script:WaveformCache.ContainsKey($cacheKey)) { return $script:WaveformCache[$cacheKey] }

    $mins = New-Object 'double[]' $Width
    $maxs = New-Object 'double[]' $Width
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.BinaryReader($stream)
        $bytesPerFrame = [long]$meta.Channels * 2L
        for ($x = 0; $x -lt $Width; $x++) {
            $startFrame = [long][math]::Floor(([double]$x * $meta.Frames) / $Width)
            $endFrame = [long][math]::Floor(([double]($x + 1) * $meta.Frames) / $Width)
            if ($endFrame -le $startFrame) { $endFrame = [math]::Min($meta.Frames, $startFrame + 1) }
            $span = [math]::Max(1L, $endFrame - $startFrame)
            $step = [long][math]::Max(1.0, [math]::Floor($span / 96.0))
            $minValue = 32767
            $maxValue = -32768
            for ($frame = $startFrame; $frame -lt $endFrame; $frame += $step) {
                $position = $meta.DataOffset + ($frame * $bytesPerFrame)
                if (($position + $bytesPerFrame) -gt $stream.Length) { break }
                $stream.Position = $position
                for ($channel = 0; $channel -lt $meta.Channels; $channel++) {
                    $sample = [int]$reader.ReadInt16()
                    if ($sample -lt $minValue) { $minValue = $sample }
                    if ($sample -gt $maxValue) { $maxValue = $sample }
                }
            }
            if ($minValue -eq 32767 -and $maxValue -eq -32768) { $minValue = 0; $maxValue = 0 }
            $mins[$x] = [double]$minValue / 32768.0
            $maxs[$x] = [double]$maxValue / 32768.0
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }

    $result = [pscustomobject]@{ Min = $mins; Max = $maxs; Metadata = $meta }
    if ($script:WaveformCache.Count -gt 24) { $script:WaveformCache.Clear() }
    $script:WaveformCache[$cacheKey] = $result
    return $result
}

function Add-WaveLine {
    param($Canvas, [double]$X1, [double]$Y1, [double]$X2, [double]$Y2, [string]$Color, [double]$Thickness = 1.0, [double]$Opacity = 1.0)
    $line = New-Object System.Windows.Shapes.Line
    $line.X1 = $X1; $line.Y1 = $Y1; $line.X2 = $X2; $line.Y2 = $Y2
    $line.Stroke = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color)
    $line.StrokeThickness = $Thickness
    $line.Opacity = $Opacity
    [void]$Canvas.Children.Add($line)
}

function Add-WaveLabel {
    param($Canvas, [string]$Text, [double]$X, [double]$Y, [string]$Color)
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = 10
    $label.FontWeight = 'SemiBold'
    $label.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color)
    [System.Windows.Controls.Canvas]::SetLeft($label, $X)
    [System.Windows.Controls.Canvas]::SetTop($label, $Y)
    [void]$Canvas.Children.Add($label)
}

function Draw-Waveform {
    if (-not $script:WaveformCanvas) { return }
    $script:WaveformCanvas.Children.Clear()
    if ($null -eq $script:CurrentSlot) {
        $script:WaveformInfo.Text = 'Kein Slot ausgewählt.'
        $script:OpenWavButton.IsEnabled = $false
        return
    }
    if (-not (Test-Path -LiteralPath $script:CurrentSlot.FilePath -PathType Leaf)) {
        $script:WaveformInfo.Text = "$($script:CurrentSlot.Slot): Keine WAV-Datei vorhanden."
        $script:OpenWavButton.IsEnabled = $false
        return
    }

    $width = [int][math]::Floor($script:WaveformCanvas.ActualWidth)
    $height = [int][math]::Floor($script:WaveformCanvas.ActualHeight)
    if ($width -lt 128) { $width = 760 }
    if ($height -lt 80) { $height = 300 }
    try {
        $envelope = Get-WaveformEnvelope $script:CurrentSlot.FilePath $width
        $center = $height / 2.0
        $amplitude = [math]::Max(20.0, ($height - 34.0) / 2.0)
        Add-WaveLine $script:WaveformCanvas 0 $center $width $center '#405064' 1.0 0.8
        for ($x = 0; $x -lt $width; $x++) {
            $yTop = $center - ($envelope.Max[$x] * $amplitude)
            $yBottom = $center - ($envelope.Min[$x] * $amplitude)
            Add-WaveLine $script:WaveformCanvas $x $yTop $x $yBottom '#78B7E6' 1.0 0.92
        }

        $frames = [double][math]::Max(1L, $script:CurrentSlot.Frames)
        $markers = @(
            @{ Label='S.START'; Value=[double]$script:CurrentSlot.SampleStart; Color='#F5D76E' },
            @{ Label='L.START'; Value=[double]$script:CurrentSlot.LoopStart; Color='#71D18B' },
            @{ Label='L.END'; Value=[double]$script:CurrentSlot.LoopEnd; Color='#F09B59' },
            @{ Label='S.END'; Value=[double]$script:CurrentSlot.SampleEnd; Color='#E56A76' }
        )
        $labelRow = 0
        foreach ($marker in $markers) {
            $mx = [math]::Max(0.0, [math]::Min([double]($width - 1), ($marker.Value / $frames) * $width))
            Add-WaveLine $script:WaveformCanvas $mx 0 $mx $height $marker.Color 1.5 0.95
            $labelX = [math]::Max(2.0, [math]::Min([double]($width - 56), $mx + 3.0))
            Add-WaveLabel $script:WaveformCanvas $marker.Label $labelX (2 + (12 * ($labelRow % 2))) $marker.Color
            $labelRow++
        }
        if ($script:PreviewSourcePosition -ge 0) {
            $px = [math]::Max(0.0, [math]::Min([double]($width - 1), (([double]$script:PreviewSourcePosition / $frames) * $width)))
            Add-WaveLine $script:WaveformCanvas $px 0 $px $height '#FFFFFF' 2.0 1.0
        }

        $meta = $envelope.Metadata
        $fileName = [System.IO.Path]::GetFileName($script:CurrentSlot.FilePath)
        $script:WaveformInfo.Text = "$($script:CurrentSlot.Slot)  $fileName  |  $($meta.Channels) Kanal/Kanäle, $($meta.BitsPerSample) Bit, $($meta.SampleRate) Hz  |  $($script:CurrentSlot.Duration)  |  Loop $($script:CurrentSlot.LoopMode)"
        $script:OpenWavButton.IsEnabled = $true
    } catch {
        $script:WaveformInfo.Text = 'Waveform nicht verfügbar: ' + $_.Exception.Message
        $script:OpenWavButton.IsEnabled = $true
        Add-Log ('Waveform-Fehler: ' + $_.Exception.Message)
    }
}

function Update-WaveformSelection {
    $slot = $script:SlotGrid.SelectedItem
    if ($null -eq $slot) { Clear-Waveform; return }
    $script:CurrentSlot = $slot
    Draw-Waveform
}

function Open-SelectedWav {
    if ($null -eq $script:CurrentSlot) { return }
    if (Test-Path -LiteralPath $script:CurrentSlot.FilePath -PathType Leaf) {
        Start-Process -FilePath $script:CurrentSlot.FilePath
    }
}

function Test-PhoenixWriteAccess {
    $bankDir = Get-BankDirectory $script:PhoenixRoot
    if (-not $bankDir) { throw 'Kein PHOENIX\\BANKS-Verzeichnis gefunden.' }
    $testPath = Join-Path $bankDir ('.phoenix_librarian_write_test_' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($testPath, 'Phoenix Librarian write test', $script:Utf8NoBom)
    } catch {
        throw 'Der Phoenix-Datenträger ist nicht beschreibbar. Bitte Phoenix USB MASS STORAGE auf READ / WRITE stellen.'
    } finally {
        Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
    }
    return $bankDir
}

function Get-FirstFreeBankName {
    param([string]$BankDir)
    for ($i = 1; $i -le 99; $i++) {
        $name = ('BANK{0:D2}' -f $i)
        if (-not (Test-Path -LiteralPath (Join-Path $BankDir $name))) { return $name }
    }
    return 'BANK01'
}



function Request-NewBankSettings {
    param([string]$DefaultTarget)
    [xml]$dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Neue Phoenix-Bank" Width="520" Height="450" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#17212B" Foreground="#E7EDF3">
<Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock Text="Neue Bank und Vorlage" FontSize="20" FontWeight="Bold" Margin="0,0,0,14"/>
<Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
<TextBlock Text="Zielplatz" Margin="0,7"/><TextBox Name="Target" Grid.Column="1" Margin="0,4"/>
<TextBlock Grid.Row="1" Text="Vorlage" Margin="0,7"/><ComboBox Name="Template" Grid.Row="1" Grid.Column="1" Margin="0,4"><ComboBoxItem Content="EMPTY BANK"/><ComboBoxItem Content="DRUM KIT"/><ComboBoxItem Content="FOUR SOUNDS"/><ComboBoxItem Content="SYNTH WAVES"/><ComboBoxItem Content="LOOP BANK"/><ComboBoxItem Content="MULTISAMPLE PREPARATION"/></ComboBox>
<TextBlock Grid.Row="2" Text="Name" Margin="0,7"/><TextBox Name="Name" Grid.Row="2" Grid.Column="1" Margin="0,4"/>
<TextBlock Grid.Row="3" Text="Kategorie" Margin="0,7"/><ComboBox Name="Category" Grid.Row="3" Grid.Column="1" Margin="0,4" IsEditable="True"><ComboBoxItem Content="Drums"/><ComboBoxItem Content="Synth Waves"/><ComboBoxItem Content="Loops"/><ComboBoxItem Content="Multisample"/><ComboBoxItem Content="SFX"/><ComboBoxItem Content="Other"/></ComboBox>
<TextBlock Grid.Row="4" Text="Autor" Margin="0,7"/><TextBox Name="Author" Grid.Row="4" Grid.Column="1" Margin="0,4" Text="RealTimeAudioLab"/>
<TextBlock Grid.Row="5" Text="Lizenz" Margin="0,7"/><ComboBox Name="License" Grid.Row="5" Grid.Column="1" Margin="0,4" IsEditable="True"><ComboBoxItem Content="All rights reserved"/><ComboBoxItem Content="CC BY 4.0"/><ComboBoxItem Content="CC0 1.0"/></ComboBox>
<TextBlock Grid.Row="6" Text="Beschreibung" Margin="0,7"/><TextBox Name="Description" Grid.Row="6" Grid.Column="1" Margin="0,4" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
</Grid>
<StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0"><Button Name="Cancel" Content="Abbrechen" Width="100" Margin="5"/><Button Name="Ok" Content="Erstellen" Width="100" Margin="5"/></StackPanel>
</Grid></Window>
"@
    $r=New-Object System.Xml.XmlNodeReader($dx); $w=[Windows.Markup.XamlReader]::Load($r); $w.Owner=$script:Window
    foreach($n in @('Target','Template','Name','Category','Author','License','Description','Ok','Cancel')){Set-Variable -Scope Local -Name $n -Value $w.FindName($n)}
    $Target.Text=$DefaultTarget; $Template.SelectedIndex=0; $Category.Text='Other'; $License.Text='All rights reserved'
    $result=$null
    $Ok.Add_Click({ $script:NewBankDialogResult=[pscustomobject]@{Target=$Target.Text.Trim().ToUpperInvariant();Template=[string]$Template.Text;Name=$Name.Text.Trim();Category=[string]$Category.Text;Author=$Author.Text.Trim();License=[string]$License.Text;Description=$Description.Text.Trim()};$w.DialogResult=$true;$w.Close() })
    $Cancel.Add_Click({$w.DialogResult=$false;$w.Close()})
    $script:NewBankDialogResult=$null
    [void]$w.ShowDialog(); return $script:NewBankDialogResult
}

function Get-TemplateSlotDefaults {
    param([string]$Template,[int]$Slot)
    $d=@{ROOT=60;KEY_LOW=0;KEY_HIGH=127;LEVEL=100;PAN=0;VOICE_LIMIT=12;ATTACK_MS=5;DECAY_MS=80;SUSTAIN_PCT=100;RELEASE_MS=80}
    switch($Template){
        'DRUM KIT' { $roots=@(36,38,42,46);$d.ROOT=$roots[$Slot-1];$d.KEY_LOW=$d.ROOT;$d.KEY_HIGH=$d.ROOT;$d.RELEASE_MS=120 }
        'FOUR SOUNDS' { $roots=@(60,62,64,65);$d.ROOT=$roots[$Slot-1] }
        'SYNTH WAVES' { $d.ROOT=60;$d.ATTACK_MS=10;$d.RELEASE_MS=350 }
        'LOOP BANK' { $d.ROOT=60;$d.ATTACK_MS=5;$d.RELEASE_MS=500 }
        'MULTISAMPLE PREPARATION' { $low=@(0,32,64,96);$high=@(31,63,95,127);$roots=@(24,48,72,96);$d.KEY_LOW=$low[$Slot-1];$d.KEY_HIGH=$high[$Slot-1];$d.ROOT=$roots[$Slot-1] }
    }
    return $d
}

function New-EmptyBankConfigText {
    param([string]$BankName,[string]$Template='EMPTY BANK')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('PROJECT_PHOENIX_BANK=1')
    $lines.Add('BANK_VERSION=16')
    $lines.Add('[GLOBAL]')
    $lines.Add('ECHO_DELAY_MS=250')
    $lines.Add('ECHO_FEEDBACK=35')
    $lines.Add('ECHO_MIX=20')
    $lines.Add('REVERB_SIZE=55')
    $lines.Add('REVERB_DECAY=55')
    $lines.Add('REVERB_DAMP=45')
    $lines.Add('REVERB_MIX=20')
    $lines.Add('TRIGGER_AUTO=1')
    $lines.Add('TRIGGER_LEVEL=4')
    $lines.Add('REPLAY_REVERSE=0')
    $lines.Add('QUATTRO_MODE=0')
    for ($slot = 1; $slot -le 4; $slot++) {
        $td = Get-TemplateSlotDefaults $Template $slot
        $lines.Add("[SLOT$slot]")
        $lines.Add('RECORDED=0')
        $lines.Add('SAMPLE_RATE=32000')
        $lines.Add('FRAME_COUNT=0')
        $lines.Add('SAMPLE_START=0')
        $lines.Add('SAMPLE_END=0')
        $lines.Add('TRIM_ENABLED=0')
        $lines.Add('TRIM_UNDO_VALID=0')
        $lines.Add('TRIM_UNDO_SAMPLE_START=0')
        $lines.Add('TRIM_UNDO_LOOP_START=0')
        $lines.Add('TRIM_UNDO_LOOP_END=0')
        $lines.Add('TRIM_UNDO_SAMPLE_END=0')
        $lines.Add('DC_ENABLED=0')
        $lines.Add('DC_OFFSET=0')
        $lines.Add('NORMALIZE_ENABLED=0')
        $lines.Add('NORMALIZE_GAIN_Q16=65536')
        $lines.Add('LOOP=0')
        $lines.Add('LOOP_MODE=0')
        $lines.Add('LOOP_XFADE_MS=0')
        $lines.Add('LOOP_START=0')
        $lines.Add('LOOP_END=0')
        $lines.Add('COARSE=0')
        $lines.Add('FINE=0')
        $lines.Add('ROOT=' + [string]$td.ROOT)
        $lines.Add('PITCH_BEND_RANGE=2')
        $lines.Add('KEY_LOW=' + [string]$td.KEY_LOW)
        $lines.Add('KEY_HIGH=' + [string]$td.KEY_HIGH)
        $lines.Add('MIDI_CHANNEL=' + [string]$slot)
        $lines.Add('OCTAVE=0')
        $lines.Add('PITCH_TRACK=1')
        $lines.Add('ATTACK_MS=' + [string]$td.ATTACK_MS)
        $lines.Add('DECAY_MS=' + [string]$td.DECAY_MS)
        $lines.Add('SUSTAIN_PCT=' + [string]$td.SUSTAIN_PCT)
        $lines.Add('RELEASE_MS=' + [string]$td.RELEASE_MS)
        $lines.Add('LEVEL=' + [string]$td.LEVEL)
        $lines.Add('PAN=' + [string]$td.PAN)
        $lines.Add('VOICE_MODE=0')
        $lines.Add('VOICE_LIMIT=' + [string]$td.VOICE_LIMIT)
        $lines.Add('ECHO_SEND=0')
        $lines.Add('REVERB_SEND=0')
    }
    return [string]::Join("`r`n", $lines) + "`r`n"
}

function New-EmptyBank {
    try {
        if (Test-EditorHasChanges) {
            [System.Windows.MessageBox]::Show(
                'Bitte die aktuellen Editor-Änderungen zuerst speichern oder zurücksetzen.',
                'Neue Bank', 'OK', 'Information') | Out-Null
            return
        }
        $bankDir = Test-PhoenixWriteAccess
        $defaultTarget = Get-FirstFreeBankName $bankDir
        $settings = Request-NewBankSettings $defaultTarget
        if ($null -eq $settings) { return }
        $targetName = $settings.Target
        if ($targetName -notmatch '^BANK\d\d$') { [System.Windows.MessageBox]::Show('Bitte einen Bankplatz BANK01 bis BANK99 angeben.','Neue Bank','OK','Warning')|Out-Null; return }
        $destination = Join-Path $bankDir $targetName
        if (Test-Path -LiteralPath $destination) {
            [System.Windows.MessageBox]::Show(
                "$targetName ist bereits belegt. Für eine neue leere Bank bitte einen freien Platz wählen.",
                'Neue Bank', 'OK', 'Warning') | Out-Null
            return
        }
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        [System.IO.Directory]::CreateDirectory($destination) | Out-Null
        $cfgPath = Join-Path $destination 'BANK.CFG'
        [System.IO.File]::WriteAllText($cfgPath, (New-EmptyBankConfigText $targetName $settings.Template), $script:Utf8NoBom)
        $info = Get-DefaultBankInfo $targetName
        $info['NAME'] = if ([string]::IsNullOrWhiteSpace($settings.Name)) { $targetName } else { $settings.Name }
        $info['CATEGORY'] = $settings.Category; $info['AUTHOR']=$settings.Author; $info['LICENSE']=$settings.License; $info['DESCRIPTION']=$settings.Description; $info['TEMPLATE']=$settings.Template
        Write-BankInfo $destination $info
        [void](Read-PhoenixConfig $cfgPath)
        Add-Log "Leere Bank $targetName erstellt."
        Refresh-And-SelectBank $targetName
    } catch {
        Add-Log ('Neue Bank konnte nicht erstellt werden: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Neue Bank fehlgeschlagen', 'OK', 'Error') | Out-Null
    } finally {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
}

function Delete-SelectedBank {
    if ($null -eq $script:CurrentBank) { return }
    try {
        if (Test-EditorHasChanges) {
            [System.Windows.MessageBox]::Show(
                'Die ausgewählte Bank enthält nicht gespeicherte Editor-Änderungen. Bitte zuerst speichern oder zurücksetzen.',
                'Bank löschen', 'OK', 'Warning') | Out-Null
            return
        }
        [void](Test-PhoenixWriteAccess)
        $name = $script:CurrentBank.Name
        $path = $script:CurrentBank.Path
        $confirmation = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Diese Aktion löscht die komplette Bank einschließlich aller SLOT-WAV-Dateien dauerhaft.`r`n`r`nZur Bestätigung bitte $name eingeben:",
            'Bank endgültig löschen', '')
        if ([string]::IsNullOrWhiteSpace($confirmation)) { return }
        if (-not $confirmation.Trim().Equals($name, [System.StringComparison]::OrdinalIgnoreCase)) {
            [System.Windows.MessageBox]::Show('Die Bestätigung stimmt nicht mit dem Banknamen überein. Es wurde nichts gelöscht.', 'Bank löschen', 'OK', 'Information') | Out-Null
            return
        }
        $final = [System.Windows.MessageBox]::Show(
            "$name jetzt endgültig löschen?`r`n`r`nDiese Aktion kann im Librarian nicht rückgängig gemacht werden.",
            'Letzte Sicherheitsabfrage', 'YesNo', 'Warning')
        if ($final -ne [System.Windows.MessageBoxResult]::Yes) { return }
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        Remove-Item -LiteralPath $path -Recurse -Force
        Add-Log "$name wurde gelöscht."
        Clear-BankDetails
        Refresh-Banks
        Apply-BankFilter
    } catch {
        Add-Log ('Bank löschen fehlgeschlagen: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Bank löschen fehlgeschlagen', 'OK', 'Error') | Out-Null
    } finally {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
}

function Request-TargetBankName {
    param([string]$Title, [string]$DefaultName)
    $inputValue = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Zielbank eingeben (1 bis 99 oder BANK01 bis BANK99):", $Title, $DefaultName)
    if ([string]::IsNullOrWhiteSpace($inputValue)) { return $null }
    $trimmed = $inputValue.Trim().ToUpperInvariant()
    $number = 0
    if ($trimmed -match '^BANK(\d{1,2})$') { $number = [int]$Matches[1] }
    elseif ($trimmed -match '^\d{1,2}$') { $number = [int]$trimmed }
    if ($number -lt 1 -or $number -gt 99) {
        [System.Windows.MessageBox]::Show('Ungültige Zielbank. Erlaubt sind BANK01 bis BANK99.', $Title, 'OK', 'Warning') | Out-Null
        return $null
    }
    return ('BANK{0:D2}' -f $number)
}

function Resolve-BankSourceFolder {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ((Split-Path $Path -Leaf).ToUpperInvariant() -eq 'BANK.CFG') { return (Split-Path $Path -Parent) }
        throw 'Die gewählte Datei ist keine BANK.CFG.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'Importquelle wurde nicht gefunden.' }
    if (Test-Path -LiteralPath (Join-Path $Path 'BANK.CFG') -PathType Leaf) { return $Path }
    $matches = @(Get-ChildItem -LiteralPath $Path -Filter 'BANK.CFG' -File -Recurse -ErrorAction Stop)
    if ($matches.Count -eq 0) { throw 'In der Importquelle wurde keine BANK.CFG gefunden.' }
    if ($matches.Count -gt 1) { throw 'Die Importquelle enthält mehrere Banken. Bitte eine einzelne Bank auswählen.' }
    return $matches[0].Directory.FullName
}

function Install-BankTransactional {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination,
        [switch]$RemoveSourceAfterSuccess
    )
    $sourceFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destinationFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ($sourceFull.Equals($destinationFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Quell- und Zielbank sind identisch.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $sourceFull 'BANK.CFG') -PathType Leaf)) {
        throw 'Die Quelle enthält keine BANK.CFG.'
    }

    $parent = Split-Path $destinationFull -Parent
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $leaf = Split-Path $destinationFull -Leaf
    $token = [guid]::NewGuid().ToString('N')
    $incoming = Join-Path $parent ('.' + $leaf + '.incoming_' + $token)
    $rollback = Join-Path $parent ('.' + $leaf + '.rollback_' + $token)
    $destinationMoved = $false
    try {
        Copy-DirectorySafe $sourceFull $incoming
        if (-not (Test-Path -LiteralPath (Join-Path $incoming 'BANK.CFG') -PathType Leaf)) { throw 'Temporäre Importkopie ist unvollständig.' }
        [void](Read-PhoenixConfig (Join-Path $incoming 'BANK.CFG'))
        if (Test-Path -LiteralPath $destinationFull -PathType Container) {
            Move-Item -LiteralPath $destinationFull -Destination $rollback -Force
            $destinationMoved = $true
        }
        Move-Item -LiteralPath $incoming -Destination $destinationFull -Force
        if ($destinationMoved -and (Test-Path -LiteralPath $rollback)) { Remove-Item -LiteralPath $rollback -Recurse -Force }
        if ($RemoveSourceAfterSuccess -and (Test-Path -LiteralPath $sourceFull -PathType Container)) {
            Remove-Item -LiteralPath $sourceFull -Recurse -Force
        }
    } catch {
        if (-not (Test-Path -LiteralPath $destinationFull) -and (Test-Path -LiteralPath $rollback)) {
            Move-Item -LiteralPath $rollback -Destination $destinationFull -Force -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        Remove-Item -LiteralPath $incoming -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $rollback -PathType Container) {
            # A rollback directory remains only if restoration itself failed. Keep it for manual recovery.
            Add-Log "Sicherungsordner zur manuellen Wiederherstellung erhalten: $rollback"
        }
    }
}

function Refresh-And-SelectBank {
    param([string]$BankName)
    Refresh-Banks
    if ([string]::IsNullOrWhiteSpace($BankName)) { return }
    for ($i = 0; $i -lt $script:BankRecords.Count; $i++) {
        if ($script:BankRecords[$i].Name -eq $BankName) {
            $script:BankGrid.SelectedIndex = $i
            $script:BankGrid.ScrollIntoView($script:BankRecords[$i])
            break
        }
    }
}

function Confirm-OverwriteBank {
    param([string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { return $true }
    $name = Split-Path $Destination -Leaf
    $answer = [System.Windows.MessageBox]::Show(
        "$name ist bereits belegt.`r`n`r`nDie vorhandene Bank wird nur nach erfolgreichem Kopieren ersetzt. Trotzdem sollte vorher eine Sicherung vorhanden sein.`r`n`r`n$name wirklich überschreiben?",
        'Überschreibschutz', 'YesNo', 'Warning')
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Copy-Or-MoveSelectedBank {
    param([bool]$Move)
    if ($null -eq $script:CurrentBank) { return }
    try {
        $bankDir = Test-PhoenixWriteAccess
        $defaultTarget = Get-FirstFreeBankName $bankDir
        $title = if ($Move) { 'Bank verschieben' } else { 'Bank kopieren' }
        $targetName = Request-TargetBankName $title $defaultTarget
        if ($null -eq $targetName) { return }
        $destination = Join-Path $bankDir $targetName
        if (-not (Confirm-OverwriteBank $destination)) { return }
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        Install-BankTransactional $script:CurrentBank.Path $destination -RemoveSourceAfterSuccess:$Move
        $action = if ($Move) { 'verschoben' } else { 'kopiert' }
        Add-Log "$($script:CurrentBank.Name) nach $targetName $action."
        Refresh-And-SelectBank $targetName
    } catch {
        Add-Log ('Bankoperation fehlgeschlagen: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Bankoperation fehlgeschlagen', 'OK', 'Error') | Out-Null
    } finally {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
}

function Import-Bank {
    $tempExtract = $null
    try {
        $bankDir = Test-PhoenixWriteAccess
        $choice = [System.Windows.MessageBox]::Show(
            "Importquelle wählen:`r`n`r`nJA = ZIP-Archiv`r`nNEIN = Bankordner`r`nABBRECHEN = keine Aktion",
            'Bank importieren', 'YesNoCancel', 'Question')
        if ($choice -eq [System.Windows.MessageBoxResult]::Cancel) { return }
        $source = $null
        if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
            $dialog = New-Object Microsoft.Win32.OpenFileDialog
            $dialog.Title = 'Phoenix-Bank als ZIP auswählen'
            $dialog.Filter = 'ZIP-Archiv (*.zip)|*.zip|Alle Dateien (*.*)|*.*'
            if ($dialog.ShowDialog() -ne $true) { return }
            $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) ('PhoenixLibrarian_' + [guid]::NewGuid().ToString('N'))
            [System.IO.Directory]::CreateDirectory($tempExtract) | Out-Null
            [System.IO.Compression.ZipFile]::ExtractToDirectory($dialog.FileName, $tempExtract)
            $source = Resolve-BankSourceFolder $tempExtract
        } else {
            $folder = New-Object System.Windows.Forms.FolderBrowserDialog
            $folder.Description = 'Bankordner mit BANK.CFG auswählen'
            $folder.ShowNewFolderButton = $false
            if ($folder.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $source = Resolve-BankSourceFolder $folder.SelectedPath
        }

        $sourceName = Split-Path $source -Leaf
        $defaultTarget = if ($sourceName -match '^BANK\d\d$') { $sourceName } else { Get-FirstFreeBankName $bankDir }
        $targetName = Request-TargetBankName 'Bank importieren' $defaultTarget
        if ($null -eq $targetName) { return }
        $destination = Join-Path $bankDir $targetName
        if (-not (Confirm-OverwriteBank $destination)) { return }
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        Install-BankTransactional $source $destination
        Add-Log "Bank nach $targetName importiert. Quelle: $source"
        Refresh-And-SelectBank $targetName
    } catch {
        Add-Log ('Import fehlgeschlagen: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Import fehlgeschlagen', 'OK', 'Error') | Out-Null
    } finally {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
        if ($tempExtract -and (Test-Path -LiteralPath $tempExtract)) { Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Export-SelectedBankZip {
    if ($null -eq $script:CurrentBank) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = 'Phoenix-Bank als ZIP exportieren'
    $dialog.Filter = 'ZIP-Archiv (*.zip)|*.zip'
    $dialog.FileName = $script:CurrentBank.Name + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.zip'
    if ($dialog.ShowDialog() -ne $true) { return }
    try {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        if (Test-Path -LiteralPath $dialog.FileName) { Remove-Item -LiteralPath $dialog.FileName -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $script:CurrentBank.Path, $dialog.FileName,
            [System.IO.Compression.CompressionLevel]::Optimal, $true)
        Add-Log "Bank als ZIP exportiert: $($dialog.FileName)"
        [System.Windows.MessageBox]::Show("Export erfolgreich:`r`n$($dialog.FileName)", 'Phoenix Librarian', 'OK', 'Information') | Out-Null
    } catch {
        Add-Log ('ZIP-Export fehlgeschlagen: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Export fehlgeschlagen', 'OK', 'Error') | Out-Null
    } finally {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
}



# ---------------------------------------------------------------------------
# Phase 6: Slot & Bank Builder
# ---------------------------------------------------------------------------
function Get-EmptySlotUpdates {
    return @{
        'RECORDED'='0'; 'SAMPLE_RATE'='32000'; 'FRAME_COUNT'='0';
        'SAMPLE_START'='0'; 'LOOP_START'='0'; 'LOOP_END'='0'; 'SAMPLE_END'='0';
        'LOOP'='0'; 'LOOP_MODE'='0'; 'LOOP_XFADE_MS'='0'; 'ROOT'='60';
        'TRIM_ENABLED'='0'; 'TRIM_UNDO_VALID'='0';
        'TRIM_UNDO_SAMPLE_START'='0'; 'TRIM_UNDO_LOOP_START'='0';
        'TRIM_UNDO_LOOP_END'='0'; 'TRIM_UNDO_SAMPLE_END'='0';
        'DC_ENABLED'='0'; 'DC_OFFSET'='0';
        'NORMALIZE_ENABLED'='0'; 'NORMALIZE_GAIN_Q16'='65536';
        'COARSE'='0'; 'FINE'='0'; 'PITCH_BEND_RANGE'='2';
        'KEY_LOW'='0'; 'KEY_HIGH'='127'; 'MIDI_CHANNEL'='1'; 'OCTAVE'='0'; 'PITCH_TRACK'='1';
        'ATTACK_MS'='5'; 'DECAY_MS'='80'; 'SUSTAIN_PCT'='90'; 'RELEASE_MS'='250';
        'LEVEL'='100'; 'PAN'='0'; 'VOICE_MODE'='0'; 'VOICE_LIMIT'='12'
    }
}

function Clear-CurrentSlot {
    if ($null -eq $script:CurrentBank -or $null -eq $script:CurrentSlot) { return }
    if (Test-EditorHasChanges) {
        [System.Windows.MessageBox]::Show('Bitte die aktuellen Editor-Änderungen zuerst speichern oder zurücksetzen.','Slot leeren','OK','Information') | Out-Null
        return
    }
    $slotIndex = Get-CurrentSlotIndex
    if ($slotIndex -lt 0) { return }
    $answer = [System.Windows.MessageBox]::Show(
        "$($script:CurrentBank.Name) / S$($slotIndex+1) vollständig leeren?`r`n`r`nDie WAV-Datei und alle Slotparameter werden entfernt.",
        'Slot leeren','YesNo','Warning')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    try {
        [void](Test-PhoenixWriteAccess)
        $cfgPath=Join-Path $script:CurrentBank.Path 'BANK.CFG'
        $wavPath=Join-Path $script:CurrentBank.Path ("SLOT{0}.WAV" -f ($slotIndex+1))
        $token=[guid]::NewGuid().ToString('N')
        $cfgTemp=Join-Path $script:CurrentBank.Path ('.BANK.CFG.clear_'+$token)
        $cfgBackup=Join-Path $script:CurrentBank.Path ('.BANK.CFG.backup_'+$token)
        $wavBackup=Join-Path $script:CurrentBank.Path ('.SLOT.backup_'+$token+'.WAV')
        Write-ConfigWithSlotUpdates $cfgPath $cfgTemp ($slotIndex+1) (Get-EmptySlotUpdates)
        Move-Item $cfgPath $cfgBackup -Force
        try {
            Move-Item $cfgTemp $cfgPath -Force
            if (Test-Path $wavPath) { Move-Item $wavPath $wavBackup -Force }
            Remove-Item $cfgBackup -Force -ErrorAction SilentlyContinue
            Remove-Item $wavBackup -Force -ErrorAction SilentlyContinue
        } catch {
            Remove-Item $cfgPath -Force -ErrorAction SilentlyContinue
            if (Test-Path $cfgBackup) { Move-Item $cfgBackup $cfgPath -Force }
            if (Test-Path $wavBackup) { Move-Item $wavBackup $wavPath -Force }
            throw
        }
        Add-Log "$($script:CurrentBank.Name) / S$($slotIndex+1) wurde geleert."
        $bankName=$script:CurrentBank.Name
        Refresh-And-SelectBank $bankName
        $script:SlotGrid.SelectedIndex=$slotIndex
    } catch {
        Add-Log ('Slot leeren fehlgeschlagen: '+$_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message,'Slot leeren fehlgeschlagen','OK','Error') | Out-Null
    }
}

function Request-TargetSlotNumber {
    param([string]$Title,[int]$Default=1)
    $v=[Microsoft.VisualBasic.Interaction]::InputBox('Zielslot eingeben (1 bis 4):',$Title,[string]$Default)
    if ([string]::IsNullOrWhiteSpace($v)) { return 0 }
    $n=0
    if (-not [int]::TryParse($v.Trim(),[ref]$n) -or $n -lt 1 -or $n -gt 4) {
        [System.Windows.MessageBox]::Show('Erlaubt sind die Slots 1 bis 4.',$Title,'OK','Warning') | Out-Null
        return 0
    }
    return $n
}

function Get-SlotUpdatesFromRaw {
    param($Slot)
    $u=@{}
    foreach($k in $Slot.Raw.Keys) { $u[[string]$k]=[string]$Slot.Raw[$k] }
    return $u
}

function Copy-Or-MoveCurrentSlot {
    param([bool]$Move)
    if ($null -eq $script:CurrentBank -or $null -eq $script:CurrentSlot) { return }
    if (Test-EditorHasChanges) {
        [System.Windows.MessageBox]::Show('Bitte die aktuellen Editor-Änderungen zuerst speichern oder zurücksetzen.','Slotoperation','OK','Information') | Out-Null; return
    }
    $sourceIndex=Get-CurrentSlotIndex
    if ($sourceIndex -lt 0) { return }
    $title=if($Move){'Slot verschieben'}else{'Slot kopieren'}
    $target=Request-TargetSlotNumber $title ([math]::Min(4,$sourceIndex+2))
    if ($target -eq 0 -or $target -eq ($sourceIndex+1)) { return }
    $targetSlot=$script:CurrentBank.Slots[$target-1]
    if ($targetSlot.Recorded -eq 'Ja' -or $targetSlot.WavMetadata.Exists) {
        $ans=[System.Windows.MessageBox]::Show("S$target ist belegt und wird ersetzt. Fortfahren?",$title,'YesNo','Warning')
        if($ans -ne [System.Windows.MessageBoxResult]::Yes){return}
    }
    try {
        [void](Test-PhoenixWriteAccess)
        $cfg=Join-Path $script:CurrentBank.Path 'BANK.CFG'
        $srcWav=Join-Path $script:CurrentBank.Path ("SLOT{0}.WAV" -f ($sourceIndex+1))
        $dstWav=Join-Path $script:CurrentBank.Path ("SLOT{0}.WAV" -f $target)
        $token=[guid]::NewGuid().ToString('N')
        $cfg1=Join-Path $script:CurrentBank.Path ('.BANK.CFG.slot1_'+$token)
        $cfg2=Join-Path $script:CurrentBank.Path ('.BANK.CFG.slot2_'+$token)
        $cfgBak=Join-Path $script:CurrentBank.Path ('.BANK.CFG.slotbak_'+$token)
        $dstBak=Join-Path $script:CurrentBank.Path ('.SLOT.dstbak_'+$token+'.WAV')
        $srcBak=Join-Path $script:CurrentBank.Path ('.SLOT.srcbak_'+$token+'.WAV')
        Write-ConfigWithSlotUpdates $cfg $cfg1 $target (Get-SlotUpdatesFromRaw $script:CurrentSlot)
        if($Move){ Write-ConfigWithSlotUpdates $cfg1 $cfg2 ($sourceIndex+1) (Get-EmptySlotUpdates) } else { Move-Item $cfg1 $cfg2 }
        Move-Item $cfg $cfgBak -Force
        try {
            Move-Item $cfg2 $cfg -Force
            if(Test-Path $dstWav){Move-Item $dstWav $dstBak -Force}
            if(Test-Path $srcWav){
                if($Move){Move-Item $srcWav $srcBak -Force; Copy-Item $srcBak $dstWav -Force}
                else{Copy-Item $srcWav $dstWav -Force}
            }
            if($Move -and (Test-Path $srcBak)){Remove-Item $srcBak -Force}
            Remove-Item $dstBak,$cfgBak -Force -ErrorAction SilentlyContinue
        } catch {
            Remove-Item $cfg -Force -ErrorAction SilentlyContinue
            if(Test-Path $cfgBak){Move-Item $cfgBak $cfg -Force}
            Remove-Item $dstWav -Force -ErrorAction SilentlyContinue
            if(Test-Path $dstBak){Move-Item $dstBak $dstWav -Force}
            if(Test-Path $srcBak){Move-Item $srcBak $srcWav -Force}
            throw
        }
        $action=if($Move){'verschoben'}else{'kopiert'}
        Add-Log "$($script:CurrentBank.Name): S$($sourceIndex+1) nach S$target $action."
        $bankName=$script:CurrentBank.Name
        Refresh-And-SelectBank $bankName
        $script:SlotGrid.SelectedIndex=$target-1
    } catch {
        Add-Log ('Slotoperation fehlgeschlagen: '+$_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message,'Slotoperation fehlgeschlagen','OK','Error') | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Phase 3: Offline Sample Editor
# ---------------------------------------------------------------------------
$script:EditorState = $null
$script:EditorDirty = $false
$script:EditorBaselineSignature = $null
$script:EditorSyncing = $false
$script:EditorSelectedMarker = 'S.START'
$script:EditorDraggingMarker = $null
$script:MediaPlayer = New-Object System.Windows.Media.MediaPlayer
$script:MediaPlaying = $false
$script:PreviewMode = ''
$script:PreviewTempFile = $null
$script:PreviewSourcePosition = -1L
$script:PreviewStartedAt = [datetime]::MinValue
$script:PreviewStopwatch = $null
$script:PreviewPlayheadLine = $null
$script:PreviewDurationSec = 0.0
$script:WaveformPreviewVoiceId = -1005001
$script:PreviewRefreshPending = $false
$script:LoopLinkEnabled = $false
$script:SelectionGuard = $false
$script:XFadeValues = @(0, 2, 4, 8, 16, 32)

if (-not ('PhoenixLibrarianAudio' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Text;

public sealed class PhoenixAudioAnalysisResult {
    public short DcOffset;
    public uint NormalizeGainQ16;
}

public sealed class PhoenixWavConversionResult {
    public long SourceFrames;
    public int SourceSampleRate;
    public int SourceChannels;
    public int SourceBitsPerSample;
    public int SourceFormatTag;
    public long OutputFrames;
    public bool Truncated;
    public int RootNote;
    public int LoopMode;
    public uint LoopStart;
    public uint LoopEndExclusive;
}

public static class PhoenixLibrarianAudio {
    private static short ReadFrameAverage(BinaryReader br, int channels) {
        int sum = 0;
        for (int c = 0; c < channels; c++) sum += br.ReadInt16();
        return (short)(sum / Math.Max(1, channels));
    }

    public static long FindNearestZeroCrossing(string path, long dataOffset, int channels,
                                                long frames, long target, int radius) {
        if (channels < 1 || frames < 2) return -1;
        long first = Math.Max(0, target - radius - 1);
        long last = Math.Min(frames - 1, target + radius + 1);
        int count = checked((int)(last - first + 1));
        short[] samples = new short[count];
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (BinaryReader br = new BinaryReader(fs)) {
            fs.Position = dataOffset + first * channels * 2L;
            for (int i = 0; i < count; i++) samples[i] = ReadFrameAverage(br, channels);
        }
        long best = -1;
        long bestDistance = long.MaxValue;
        for (int i = 1; i < samples.Length; i++) {
            int a = samples[i - 1];
            int b = samples[i];
            if (a == 0 || b == 0 || (a < 0 && b > 0) || (a > 0 && b < 0)) {
                long candidate;
                if (a == 0) candidate = first + i - 1;
                else if (b == 0) candidate = first + i;
                else candidate = Math.Abs(a) <= Math.Abs(b) ? first + i - 1 : first + i;
                long distance = Math.Abs(candidate - target);
                if (distance < bestDistance) { best = candidate; bestDistance = distance; }
            }
        }
        return best;
    }

    public static PhoenixAudioAnalysisResult AnalyzePcm16(string path, long dataOffset, int channels,
                                                            long begin, long end,
                                                            bool dcEnabled, bool normalizeEnabled) {
        PhoenixAudioAnalysisResult result = new PhoenixAudioAnalysisResult();
        result.DcOffset = 0;
        result.NormalizeGainQ16 = 65536U;
        if ((!dcEnabled && !normalizeEnabled) || channels < 1 || end <= begin) return result;
        long count = end - begin;
        long sum = 0;
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (BinaryReader br = new BinaryReader(fs)) {
            fs.Position = dataOffset + begin * channels * 2L;
            for (long i = 0; i < count; i++) sum += ReadFrameAverage(br, channels);
        }
        int dc = count > 0 ? (int)(sum / count) : 0;
        if (dcEnabled) {
            if (dc < short.MinValue) dc = short.MinValue;
            if (dc > short.MaxValue) dc = short.MaxValue;
            result.DcOffset = (short)dc;
        }
        if (normalizeEnabled) {
            uint peak = 0;
            int appliedDc = dcEnabled ? result.DcOffset : 0;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (BinaryReader br = new BinaryReader(fs)) {
                fs.Position = dataOffset + begin * channels * 2L;
                for (long i = 0; i < count; i++) {
                    int v = ReadFrameAverage(br, channels) - appliedDc;
                    uint a = (uint)Math.Abs(v);
                    if (a > peak) peak = a;
                }
            }
            if (peak > 0) {
                ulong gain = (29204UL << 16) / peak;
                ulong maxGain = 16UL << 16;
                if (gain > maxGain) gain = maxGain;
                result.NormalizeGainQ16 = (uint)gain;
            }
        }
        return result;
    }

    private static void CopyExactly(Stream input, Stream output, long bytes) {
        byte[] buffer = new byte[65536];
        while (bytes > 0) {
            int request = (int)Math.Min(buffer.Length, bytes);
            int got = input.Read(buffer, 0, request);
            if (got <= 0) throw new EndOfStreamException();
            output.Write(buffer, 0, got);
            bytes -= got;
        }
    }

    private static void WriteUInt32LE(BinaryWriter bw, uint value) { bw.Write(value); }

    public static void RewriteSmplChunk(string sourcePath, string destinationPath,
                                        int rootNote, int loopMode,
                                        uint loopStart, uint loopEndExclusive,
                                        uint sampleRate) {
        using (FileStream input = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (BinaryReader br = new BinaryReader(input))
        using (FileStream output = new FileStream(destinationPath, FileMode.Create, FileAccess.ReadWrite, FileShare.None))
        using (BinaryWriter bw = new BinaryWriter(output)) {
            if (input.Length < 12) throw new InvalidDataException("WAV-Datei ist zu kurz.");
            string riff = Encoding.ASCII.GetString(br.ReadBytes(4));
            br.ReadUInt32();
            string wave = Encoding.ASCII.GetString(br.ReadBytes(4));
            if (riff != "RIFF" || wave != "WAVE") throw new InvalidDataException("Kein RIFF/WAVE-Format.");
            bw.Write(Encoding.ASCII.GetBytes("RIFF"));
            bw.Write((uint)0);
            bw.Write(Encoding.ASCII.GetBytes("WAVE"));

            while (input.Position + 8 <= input.Length) {
                byte[] idBytes = br.ReadBytes(4);
                if (idBytes.Length < 4) break;
                string id = Encoding.ASCII.GetString(idBytes);
                uint size = br.ReadUInt32();
                long available = input.Length - input.Position;
                if (size > available) throw new InvalidDataException("Ungültige RIFF-Chunkgröße.");
                if (id == "smpl") {
                    input.Position += size;
                    if ((size & 1U) != 0 && input.Position < input.Length) input.Position++;
                    continue;
                }
                bw.Write(idBytes);
                bw.Write(size);
                CopyExactly(input, output, size);
                if ((size & 1U) != 0) {
                    int pad = input.ReadByte();
                    output.WriteByte(pad >= 0 ? (byte)pad : (byte)0);
                }
            }

            if (loopMode != 0 && loopEndExclusive > loopStart + 1U) {
                bw.Write(Encoding.ASCII.GetBytes("smpl"));
                WriteUInt32LE(bw, 60U);
                WriteUInt32LE(bw, 0U);
                WriteUInt32LE(bw, 0U);
                WriteUInt32LE(bw, sampleRate > 0 ? 1000000000U / sampleRate : 0U);
                WriteUInt32LE(bw, (uint)Math.Max(0, Math.Min(127, rootNote)));
                WriteUInt32LE(bw, 0U);
                WriteUInt32LE(bw, 0U);
                WriteUInt32LE(bw, 0U);
                WriteUInt32LE(bw, 1U);
                WriteUInt32LE(bw, 0U);
                WriteUInt32LE(bw, 0U);
                WriteUInt32LE(bw, loopMode == 2 ? 1U : 0U);
                WriteUInt32LE(bw, loopStart);
                WriteUInt32LE(bw, loopEndExclusive - 1U);
                WriteUInt32LE(bw, 0U);
                WriteUInt32LE(bw, 0U);
            }

            long length = output.Length;
            output.Position = 4;
            bw.Write((uint)(length - 8));
            bw.Flush();
        }
    }

    private sealed class WavInputInfo {
        public int FormatTag;
        public int Channels;
        public int SampleRate;
        public int BitsPerSample;
        public int BlockAlign;
        public long DataOffset;
        public long DataBytes;
        public long Frames;
        public bool HasSamplerChunk;
        public int RootNote = 60;
        public int LoopType = -1;
        public long LoopStart = -1;
        public long LoopEndExclusive = -1;
    }

    private static WavInputInfo ReadInputInfo(BinaryReader br) {
        Stream stream = br.BaseStream;
        if (stream.Length < 12) throw new InvalidDataException("WAV-Datei ist zu kurz.");
        string riff = Encoding.ASCII.GetString(br.ReadBytes(4));
        br.ReadUInt32();
        string wave = Encoding.ASCII.GetString(br.ReadBytes(4));
        if (riff != "RIFF" || wave != "WAVE") throw new InvalidDataException("Kein RIFF/WAVE-Format.");

        WavInputInfo info = new WavInputInfo();
        bool haveFmt = false;
        bool haveData = false;
        while (stream.Position + 8 <= stream.Length) {
            string id = Encoding.ASCII.GetString(br.ReadBytes(4));
            uint size = br.ReadUInt32();
            long chunkStart = stream.Position;
            long chunkEnd = chunkStart + size;
            if (chunkEnd > stream.Length) throw new InvalidDataException("Ungültige RIFF-Chunkgröße.");

            if (id == "fmt ") {
                if (size < 16) throw new InvalidDataException("Ungültiger fmt-Chunk.");
                int formatTag = br.ReadUInt16();
                info.Channels = br.ReadUInt16();
                info.SampleRate = checked((int)br.ReadUInt32());
                br.ReadUInt32();
                info.BlockAlign = br.ReadUInt16();
                info.BitsPerSample = br.ReadUInt16();
                if (formatTag == 0xFFFE && size >= 40) {
                    ushort cbSize = br.ReadUInt16();
                    if (cbSize >= 22 && stream.Position + 22 <= chunkEnd) {
                        br.ReadUInt16(); // valid bits
                        br.ReadUInt32(); // channel mask
                        byte[] subFormat = br.ReadBytes(16);
                        if (subFormat.Length == 16) formatTag = subFormat[0] | (subFormat[1] << 8);
                    }
                }
                info.FormatTag = formatTag;
                haveFmt = true;
            } else if (id == "data") {
                info.DataOffset = chunkStart;
                info.DataBytes = size;
                haveData = true;
            } else if (id == "smpl" && size >= 36) {
                br.ReadUInt32(); br.ReadUInt32(); br.ReadUInt32();
                uint root = br.ReadUInt32();
                info.RootNote = (int)Math.Max(0U, Math.Min(127U, root));
                br.ReadUInt32(); br.ReadUInt32(); br.ReadUInt32();
                uint loopCount = br.ReadUInt32();
                br.ReadUInt32();
                info.HasSamplerChunk = true;
                if (loopCount > 0 && stream.Position + 24 <= chunkEnd) {
                    br.ReadUInt32();
                    info.LoopType = checked((int)br.ReadUInt32());
                    info.LoopStart = br.ReadUInt32();
                    info.LoopEndExclusive = (long)br.ReadUInt32() + 1L;
                    br.ReadUInt32(); br.ReadUInt32();
                }
            }
            stream.Position = chunkEnd;
            if ((size & 1U) != 0 && stream.Position < stream.Length) stream.Position++;
        }

        if (!haveFmt || !haveData) throw new InvalidDataException("WAV enthält keinen vollständigen fmt-/data-Chunk.");
        if (info.FormatTag != 1 && info.FormatTag != 3) throw new NotSupportedException("Unterstützt werden PCM und IEEE-Float WAV.");
        if (info.Channels < 1 || info.Channels > 8) throw new NotSupportedException("Unterstützt werden 1 bis 8 Kanäle.");
        if (info.SampleRate < 4000 || info.SampleRate > 384000) throw new NotSupportedException("Nicht unterstützte Samplerate.");
        if (info.FormatTag == 1 && info.BitsPerSample != 8 && info.BitsPerSample != 16 && info.BitsPerSample != 24 && info.BitsPerSample != 32)
            throw new NotSupportedException("PCM wird mit 8, 16, 24 oder 32 Bit unterstützt.");
        if (info.FormatTag == 3 && info.BitsPerSample != 32 && info.BitsPerSample != 64)
            throw new NotSupportedException("IEEE-Float wird mit 32 oder 64 Bit unterstützt.");
        int minimumAlign = info.Channels * ((info.BitsPerSample + 7) / 8);
        if (info.BlockAlign < minimumAlign) throw new InvalidDataException("Ungültiges WAV-BlockAlign.");
        info.Frames = info.DataBytes / info.BlockAlign;
        if (info.Frames < 1) throw new InvalidDataException("WAV enthält keine Samples.");
        return info;
    }

    private static double ReadNormalizedSample(BinaryReader br, int formatTag, int bits) {
        if (formatTag == 3) {
            double fv = bits == 32 ? (double)br.ReadSingle() : br.ReadDouble();
            if (Double.IsNaN(fv) || Double.IsInfinity(fv)) return 0.0;
            return Math.Max(-1.0, Math.Min(1.0, fv));
        }
        switch (bits) {
            case 8:
                return (br.ReadByte() - 128) / 128.0;
            case 16:
                return br.ReadInt16() / 32768.0;
            case 24:
                int b0 = br.ReadByte();
                int b1 = br.ReadByte();
                int b2 = br.ReadByte();
                int v24 = b0 | (b1 << 8) | (b2 << 16);
                if ((v24 & 0x800000) != 0) v24 |= unchecked((int)0xFF000000);
                return v24 / 8388608.0;
            case 32:
                return br.ReadInt32() / 2147483648.0;
            default:
                throw new NotSupportedException("Nicht unterstützte Wortbreite.");
        }
    }

    private static short DoubleToPcm16(double value) {
        value = Math.Max(-1.0, Math.Min(1.0, value));
        int scaled = value >= 0.0
            ? (int)Math.Round(value * 32767.0)
            : (int)Math.Round(value * 32768.0);
        if (scaled < short.MinValue) scaled = short.MinValue;
        if (scaled > short.MaxValue) scaled = short.MaxValue;
        return (short)scaled;
    }

    private static uint ScaleFrame(long frame, int sourceRate, int targetRate, long maximum) {
        long value = (long)Math.Round((double)frame * targetRate / sourceRate);
        if (value < 0) value = 0;
        if (value > maximum) value = maximum;
        return (uint)value;
    }

    public static PhoenixWavConversionResult ConvertToPhoenixWav(string sourcePath, string destinationPath,
                                                                   int targetRate, long maximumOutputFrames) {
        if (targetRate <= 0 || maximumOutputFrames < 2) throw new ArgumentOutOfRangeException();
        WavInputInfo info;
        float[] sourceMono;
        long outputFrames;
        long neededSourceFrames;

        using (FileStream input = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (BinaryReader br = new BinaryReader(input)) {
            info = ReadInputInfo(br);
            long naturalOutputFrames = (long)Math.Round((double)info.Frames * targetRate / info.SampleRate);
            if (naturalOutputFrames < 1) naturalOutputFrames = 1;
            outputFrames = Math.Min(naturalOutputFrames, maximumOutputFrames);
            double lastSourcePosition = outputFrames > 1 ? (double)(outputFrames - 1) * info.SampleRate / targetRate : 0.0;
            neededSourceFrames = Math.Min(info.Frames, (long)Math.Floor(lastSourcePosition) + 2L);
            if (neededSourceFrames > Int32.MaxValue) throw new InvalidDataException("Quelldatei ist für die Konvertierung zu groß.");
            sourceMono = new float[(int)neededSourceFrames];
            input.Position = info.DataOffset;
            for (int frame = 0; frame < sourceMono.Length; frame++) {
                long frameStart = input.Position;
                double sum = 0.0;
                for (int channel = 0; channel < info.Channels; channel++)
                    sum += ReadNormalizedSample(br, info.FormatTag, info.BitsPerSample);
                sourceMono[frame] = (float)(sum / info.Channels);
                input.Position = frameStart + info.BlockAlign;
            }
        }

        int loopMode = 0;
        uint loopStart = 0;
        uint loopEnd = (uint)outputFrames;
        if (info.LoopStart >= 0 && info.LoopEndExclusive > info.LoopStart) {
            uint scaledStart = ScaleFrame(info.LoopStart, info.SampleRate, targetRate, outputFrames);
            uint scaledEnd = ScaleFrame(info.LoopEndExclusive, info.SampleRate, targetRate, outputFrames);
            if (scaledEnd >= scaledStart + 2U) {
                loopMode = info.LoopType == 1 ? 2 : 1;
                loopStart = scaledStart;
                loopEnd = scaledEnd;
            }
        }

        using (FileStream output = new FileStream(destinationPath, FileMode.Create, FileAccess.ReadWrite, FileShare.None))
        using (BinaryWriter bw = new BinaryWriter(output)) {
            bw.Write(Encoding.ASCII.GetBytes("RIFF"));
            bw.Write((uint)0);
            bw.Write(Encoding.ASCII.GetBytes("WAVE"));
            bw.Write(Encoding.ASCII.GetBytes("fmt "));
            bw.Write((uint)16);
            bw.Write((ushort)1);
            bw.Write((ushort)1);
            bw.Write((uint)targetRate);
            bw.Write((uint)(targetRate * 2));
            bw.Write((ushort)2);
            bw.Write((ushort)16);
            bw.Write(Encoding.ASCII.GetBytes("data"));
            bw.Write((uint)(outputFrames * 2L));

            for (long i = 0; i < outputFrames; i++) {
                double sourcePosition = (double)i * info.SampleRate / targetRate;
                int index = (int)Math.Floor(sourcePosition);
                double fraction = sourcePosition - index;
                if (index >= sourceMono.Length - 1) {
                    bw.Write(DoubleToPcm16(sourceMono[sourceMono.Length - 1]));
                } else {
                    double sample = sourceMono[index] + (sourceMono[index + 1] - sourceMono[index]) * fraction;
                    bw.Write(DoubleToPcm16(sample));
                }
            }

            if (loopMode != 0) {
                bw.Write(Encoding.ASCII.GetBytes("smpl"));
                bw.Write((uint)60);
                bw.Write((uint)0); bw.Write((uint)0);
                bw.Write((uint)(1000000000U / (uint)targetRate));
                bw.Write((uint)Math.Max(0, Math.Min(127, info.RootNote)));
                bw.Write((uint)0); bw.Write((uint)0); bw.Write((uint)0);
                bw.Write((uint)1); bw.Write((uint)0);
                bw.Write((uint)0);
                bw.Write((uint)(loopMode == 2 ? 1 : 0));
                bw.Write(loopStart);
                bw.Write(loopEnd - 1U);
                bw.Write((uint)0); bw.Write((uint)0);
            }
            long length = output.Length;
            output.Position = 4;
            bw.Write((uint)(length - 8));
            bw.Flush();
        }

        PhoenixWavConversionResult result = new PhoenixWavConversionResult();
        result.SourceFrames = info.Frames;
        result.SourceSampleRate = info.SampleRate;
        result.SourceChannels = info.Channels;
        result.SourceBitsPerSample = info.BitsPerSample;
        result.SourceFormatTag = info.FormatTag;
        result.OutputFrames = outputFrames;
        result.Truncated = ((long)Math.Round((double)info.Frames * targetRate / info.SampleRate) > maximumOutputFrames);
        result.RootNote = info.RootNote;
        result.LoopMode = loopMode;
        result.LoopStart = loopStart;
        result.LoopEndExclusive = loopEnd;
        return result;
    }
}
'@
}

if (-not ('PhoenixLoopPreviewRenderer' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Collections.Concurrent;

public static class PhoenixLoopPreviewRenderer {
    private sealed class WavData {
        public int SampleRate;
        public int Channels;
        public short[] Mono;
    }

    private static WavData ReadPcm16(string path) {
        using (var fs = File.OpenRead(path))
        using (var br = new BinaryReader(fs)) {
            if (new string(br.ReadChars(4)) != "RIFF") throw new InvalidDataException("Keine RIFF-WAV-Datei.");
            br.ReadUInt32();
            if (new string(br.ReadChars(4)) != "WAVE") throw new InvalidDataException("Keine WAVE-Datei.");
            ushort format = 0, channels = 0, bits = 0, blockAlign = 0;
            int sampleRate = 0;
            long dataOffset = -1; uint dataSize = 0;
            while (fs.Position + 8 <= fs.Length) {
                string id = new string(br.ReadChars(4)); uint size = br.ReadUInt32(); long next = fs.Position + size;
                if (id == "fmt ") {
                    format = br.ReadUInt16(); channels = br.ReadUInt16(); sampleRate = br.ReadInt32();
                    br.ReadUInt32(); blockAlign = br.ReadUInt16(); bits = br.ReadUInt16();
                } else if (id == "data") { dataOffset = fs.Position; dataSize = size; }
                fs.Position = Math.Min(fs.Length, next + (size & 1));
            }
            if (format != 1 || bits != 16 || channels < 1 || dataOffset < 0) throw new NotSupportedException("Vorschau benötigt PCM 16 Bit.");
            int frames = checked((int)(dataSize / blockAlign));
            short[] mono = new short[frames]; fs.Position = dataOffset;
            for (int i=0;i<frames;i++) {
                int sum=0; for(int c=0;c<channels;c++) sum += br.ReadInt16();
                mono[i]=(short)(sum/channels);
            }
            return new WavData { SampleRate=sampleRate, Channels=channels, Mono=mono };
        }
    }

    private static short Process(short input, double dc, double gain) {
        double v = (input - dc) * gain;
        if (v > 32767) v = 32767; if (v < -32768) v = -32768;
        return (short)Math.Round(v);
    }

    private static void WriteHeader(BinaryWriter bw, int sampleRate, int frames) {
        int dataBytes = frames * 2;
        bw.Write(new char[]{'R','I','F','F'}); bw.Write(36 + dataBytes);
        bw.Write(new char[]{'W','A','V','E'}); bw.Write(new char[]{'f','m','t',' '}); bw.Write(16);
        bw.Write((short)1); bw.Write((short)1); bw.Write(sampleRate); bw.Write(sampleRate*2); bw.Write((short)2); bw.Write((short)16);
        bw.Write(new char[]{'d','a','t','a'}); bw.Write(dataBytes);
    }

    public static double Render(string inputPath, string outputPath, long sampleStart, long loopStart, long loopEnd,
                                long sampleEnd, int loopMode, int xfadeMs, bool dcEnabled, bool normEnabled,
                                bool holdLoop, double maxSeconds) {
        var w = ReadPcm16(inputPath); int n=w.Mono.Length;
        int ss=(int)Math.Max(0,Math.Min(n-1,sampleStart)); int ls=(int)Math.Max(ss,Math.Min(n-1,loopStart));
        int le=(int)Math.Max(ls+1,Math.Min(n,loopEnd)); int se=(int)Math.Max(le,Math.Min(n,sampleEnd));
        double dc=0.0; double gain=1.0;
        if (dcEnabled || normEnabled) {
            long sum=0; for(int i=ss;i<se;i++) sum+=w.Mono[i]; dc=dcEnabled ? (double)sum/Math.Max(1,se-ss) : 0.0;
            if(normEnabled) { double peak=1; for(int i=ss;i<se;i++) peak=Math.Max(peak,Math.Abs(w.Mono[i]-dc)); gain=(32767.0*Math.Pow(10.0,-1.0/20.0))/peak; if(gain>16)gain=16; }
        }
        int maxFrames=(int)Math.Max(1,Math.Min(Int32.MaxValue,(long)(maxSeconds*w.SampleRate)));
        var outSamples=new List<short>(Math.Min(maxFrames, w.SampleRate*30));
        Action<int> add = idx => { if(outSamples.Count<maxFrames) outSamples.Add(Process(w.Mono[Math.Max(0,Math.Min(n-1,idx))],dc,gain)); };
        if(!holdLoop || loopMode==0) {
            for(int i=ss;i<se && outSamples.Count<maxFrames;i++) add(i);
        } else {
            for(int i=ss;i<ls && outSamples.Count<maxFrames;i++) add(i);
            if(loopMode==1) {
                int len=le-ls; int xf=Math.Min(len/2, Math.Max(0,xfadeMs*w.SampleRate/1000));
                while(outSamples.Count<maxFrames) {
                    int plainEnd=le-xf;
                    for(int i=ls;i<plainEnd && outSamples.Count<maxFrames;i++) add(i);
                    for(int j=0;j<xf && outSamples.Count<maxFrames;j++) {
                        double t=(j+1.0)/(xf+1.0); double a=w.Mono[plainEnd+j]; double b=w.Mono[ls+j];
                        double v=((a*(1.0-t)+b*t)-dc)*gain; if(v>32767)v=32767;if(v<-32768)v=-32768;outSamples.Add((short)Math.Round(v));
                    }
                    if(xf==0 && len<=0) break;
                }
            } else {
                bool forward=true;
                while(outSamples.Count<maxFrames) {
                    if(forward) for(int i=ls;i<le && outSamples.Count<maxFrames;i++) add(i);
                    else for(int i=le-2;i>ls && outSamples.Count<maxFrames;i--) add(i);
                    forward=!forward;
                }
            }
        }
        using(var fs=File.Create(outputPath)) using(var bw=new BinaryWriter(fs)) { WriteHeader(bw,w.SampleRate,outSamples.Count); foreach(var v in outSamples) bw.Write(v); }
        return outSamples.Count/(double)w.SampleRate;
    }

    private static double Interp(short[] data, double pos) {
        if (data == null || data.Length == 0) return 0.0;
        if (pos <= 0.0) return data[0];
        if (pos >= data.Length - 1) return data[data.Length - 1];
        int i = (int)Math.Floor(pos); double f = pos - i;
        return data[i] + (data[i + 1] - data[i]) * f;
    }

    // v0.9.13a: pitch is rendered into the WAV itself.  WPF MediaPlayer then runs at SpeedRatio=1.0.
    public static double RenderPitched(string inputPath, string outputPath, long sampleStart, long loopStart, long loopEnd,
                                long sampleEnd, int loopMode, int xfadeMs, bool dcEnabled, bool normEnabled,
                                bool holdLoop, double maxSeconds, int note, int root) {
        var w = ReadPcm16(inputPath); int n = w.Mono.Length;
        int ss=(int)Math.Max(0,Math.Min(n-1,sampleStart)); int ls=(int)Math.Max(ss,Math.Min(n-1,loopStart));
        int le=(int)Math.Max(ls+1,Math.Min(n,loopEnd)); int se=(int)Math.Max(le,Math.Min(n,sampleEnd));
        double dc=0.0, gain=1.0;
        if (dcEnabled || normEnabled) {
            long sum=0; for(int i=ss;i<se;i++) sum+=w.Mono[i]; dc=dcEnabled ? (double)sum/Math.Max(1,se-ss) : 0.0;
            if(normEnabled) { double peak=1; for(int i=ss;i<se;i++) peak=Math.Max(peak,Math.Abs(w.Mono[i]-dc)); gain=(32767.0*Math.Pow(10.0,-1.0/20.0))/peak; if(gain>16)gain=16; }
        }
        double step=Math.Pow(2.0,(note-root)/12.0);
        if(step<0.0625)step=0.0625; if(step>16.0)step=16.0;
        int maxFrames=(int)Math.Max(1,Math.Min(Int32.MaxValue,(long)(maxSeconds*w.SampleRate)));
        var outSamples=new List<short>(Math.Min(maxFrames,w.SampleRate*30));
        Action<double,double> addValue=(raw,g)=>{ if(outSamples.Count>=maxFrames)return; double v=(raw-dc)*gain*g; if(v>32767)v=32767;if(v<-32768)v=-32768;outSamples.Add((short)Math.Round(v)); };
        double pos=ss;
        if(!holdLoop || loopMode==0) {
            while(pos<se && outSamples.Count<maxFrames) { addValue(Interp(w.Mono,pos),1.0); pos+=step; }
        } else {
            while(pos<ls && outSamples.Count<maxFrames) { addValue(Interp(w.Mono,pos),1.0); pos+=step; }
            if(loopMode==1) {
                double loopLen=Math.Max(1.0,le-ls);
                double xf=Math.Min(loopLen/2.0,Math.Max(0.0,xfadeMs*w.SampleRate/1000.0));
                if(pos<ls)pos=ls;
                while(outSamples.Count<maxFrames) {
                    while(pos>=le)pos=ls+(pos-le);
                    if(xf>0.0 && pos>=le-xf) {
                        double t=(pos-(le-xf))/xf;
                        double a=Interp(w.Mono,pos);
                        double b=Interp(w.Mono,ls+(pos-(le-xf)));
                        addValue(a*(1.0-t)+b*t,1.0);
                    } else addValue(Interp(w.Mono,pos),1.0);
                    pos+=step;
                }
            } else {
                bool forward=true; if(pos<ls)pos=ls;
                while(outSamples.Count<maxFrames) {
                    if(forward) {
                        addValue(Interp(w.Mono,pos),1.0); pos+=step;
                        if(pos>=le){pos=le-Math.Max(0.0001,pos-le);forward=false;}
                    } else {
                        addValue(Interp(w.Mono,pos),1.0); pos-=step;
                        if(pos<=ls){pos=ls+Math.Max(0.0001,ls-pos);forward=true;}
                    }
                    if(pos<ls)pos=ls; if(pos>le-0.0001)pos=le-0.0001;
                }
            }
        }
        using(var fs=File.Create(outputPath)) using(var bw=new BinaryWriter(fs)) { WriteHeader(bw,w.SampleRate,outSamples.Count); foreach(var v in outSamples) bw.Write(v); }
        return outSamples.Count/(double)w.SampleRate;
    }


    // RC2: compact pitch-correct segments for low-latency live playback.
    // segmentKind: 0=attack (S.START..L.START), 1=loop cycle, 2=release (L.END..S.END).
    public static double RenderPitchedSegment(string inputPath, string outputPath, long sampleStart, long loopStart, long loopEnd,
                                long sampleEnd, int loopMode, int xfadeMs, bool dcEnabled, bool normEnabled,
                                int note, int root, int segmentKind) {
        var w=ReadPcm16(inputPath); int n=w.Mono.Length;
        int ss=(int)Math.Max(0,Math.Min(n-1,sampleStart)); int ls=(int)Math.Max(ss,Math.Min(n-1,loopStart));
        int le=(int)Math.Max(ls+1,Math.Min(n,loopEnd)); int se=(int)Math.Max(le,Math.Min(n,sampleEnd));
        double dc=0.0,gain=1.0;
        if(dcEnabled || normEnabled){
            long sum=0; for(int i=ss;i<se;i++)sum+=w.Mono[i]; dc=dcEnabled?(double)sum/Math.Max(1,se-ss):0.0;
            if(normEnabled){double peak=1;for(int i=ss;i<se;i++)peak=Math.Max(peak,Math.Abs(w.Mono[i]-dc));gain=(32767.0*Math.Pow(10.0,-1.0/20.0))/peak;if(gain>16)gain=16;}
        }
        double step=Math.Pow(2.0,(note-root)/12.0); if(step<0.0625)step=0.0625;if(step>16.0)step=16.0;
        var o=new List<short>();
        Action<double> add=raw=>{double v=(raw-dc)*gain;if(v>32767)v=32767;if(v<-32768)v=-32768;o.Add((short)Math.Round(v));};
        if(segmentKind==0){
            double pos=ss; while(pos<ls){add(Interp(w.Mono,pos));pos+=step;}
        } else if(segmentKind==2){
            double pos=le; while(pos<se){add(Interp(w.Mono,pos));pos+=step;}
        } else {
            if(loopMode==2){
                double pos=ls; while(pos<le){add(Interp(w.Mono,pos));pos+=step;}
                pos=le-step; while(pos>ls){add(Interp(w.Mono,pos));pos-=step;}
            } else {
                double loopLen=Math.Max(1.0,le-ls); double xf=Math.Min(loopLen/2.0,Math.Max(0.0,xfadeMs*w.SampleRate/1000.0));
                double pos=ls; while(pos<le){
                    if(xf>0.0 && pos>=le-xf){double t=(pos-(le-xf))/xf;double a=Interp(w.Mono,pos);double b=Interp(w.Mono,ls+(pos-(le-xf)));add(a*(1.0-t)+b*t);}
                    else add(Interp(w.Mono,pos));
                    pos+=step;
                }
            }
        }
        // MediaPlayer dislikes zero-length WAVs; write one silent sample for an empty attack/release.
        if(o.Count==0)o.Add(0);
        using(var fs=File.Create(outputPath))using(var bw=new BinaryWriter(fs)){WriteHeader(bw,w.SampleRate,o.Count);foreach(var v in o)bw.Write(v);}
        return o.Count/(double)w.SampleRate;
    }
}
'@
}

function Get-CurrentSlotIndex {
    if ($null -eq $script:CurrentSlot) { return -1 }
    $text = [string]$script:CurrentSlot.Slot
    if ($text -match '^S([1-4])$') { return ([int]$Matches[1] - 1) }
    return -1
}


function Get-EditorStateSignature {
    if ($null -eq $script:EditorState) { return $null }
    $s = $script:EditorState
    return [string]::Join('|', @(
        [string][long]$s.Frames,
        [string][long]$s.SampleRate,
        [string][long]$s.SampleStart,
        [string][long]$s.LoopStart,
        [string][long]$s.LoopEnd,
        [string][long]$s.SampleEnd,
        [string][int]$s.LoopMode,
        [string][int]$s.XFade,
        [string][int]$s.Root,
        [string][int]$s.KeyLow,
        [string][int]$s.KeyHigh,
        $(if ([bool]$s.Trim) { '1' } else { '0' }),
        $(if ([bool]$s.DC) { '1' } else { '0' }),
        $(if ([bool]$s.Normalize) { '1' } else { '0' }),
        [string][int]$s.Level,
        [string][int]$s.Pan,
        [string][int]$s.Voices
    ))
}

function Update-EditorDirtyState {
    if ($null -eq $script:EditorState) {
        Set-EditorDirty $false
        return $false
    }
    $current = Get-EditorStateSignature
    $dirty = (-not [string]::Equals(
        [string]$script:EditorBaselineSignature,
        [string]$current,
        [System.StringComparison]::Ordinal))
    Set-EditorDirty $dirty
    return $dirty
}

function Test-EditorHasChanges {
    $waveDirty = $false
    try { $waveDirty = [bool](Update-EditorDirtyState) } catch {}
    return [bool]($waveDirty -or $script:PatternDirty -or $script:SongDirty -or $script:EffectsDirty -or $script:InitSoundDirty)
}

function Get-SystemStatusText {
    $root = if([string]::IsNullOrWhiteSpace($script:PhoenixRoot)){'nicht verbunden'}else{$script:PhoenixRoot}
    $bankCount = @($script:BankRecords).Count
    $bank = if($null -eq $script:CurrentBank){'-'}else{[string]$script:CurrentBank.Name}
    $midi = if($script:MidiInputOpen){
        $idx = if($script:MidiInputCombo){$script:MidiInputCombo.SelectedIndex}else{-1}
        if($idx -ge 0 -and $script:MidiInputCombo.SelectedItem){[string]$script:MidiInputCombo.SelectedItem}else{'aktiv'}
    }else{'AUS'}
    $voices = 0
    try { $voices = @($script:ActiveLivePcVoices | Where-Object { $_.Active }).Count } catch {}
    $cache = 0
    try { $cache = $script:LivePreviewCache.Count } catch {}
    $dirty = @()
    try { if(Update-EditorDirtyState){$dirty += 'Waveform'} } catch {}
    if($script:PatternDirty){$dirty += 'Pattern'}
    if($script:SongDirty){$dirty += 'Song'}
    if($script:EffectsDirty){$dirty += 'Effekte'}
    if($script:InitSoundDirty){$dirty += 'INIT SOUND'}
    $dirtyText = if($dirty.Count -eq 0){'NEIN'}else{($dirty -join ', ')}
    return ("Phoenix: {0}`r`nBanken: {1}`r`nAktive Bank: {2}`r`nMIDI IN: {3}`r`nAktive Preview-Stimmen: {4} / 16`r`nPreview-Cache: {5} Eintrag/Einträge`r`nNicht gespeichert: {6}" -f $root,$bankCount,$bank,$midi,$voices,$cache,$dirtyText)
}

function Update-SystemStatusView {
    if($script:SystemStatusText){$script:SystemStatusText.Text = Get-SystemStatusText}
    if($script:SelfTestLastRunText){
        $script:SelfTestLastRunText.Text = if($null -eq $script:SelfTestLastRun){'Self Test noch nicht ausgeführt'}else{('Letzter Self Test: '+$script:SelfTestLastRun.ToString('dd.MM.yyyy HH:mm:ss'))}
    }
}

function Invoke-PhoenixSelfTest {
    $results = New-Object System.Collections.Generic.List[string]
    $pass=0; $warn=0; $fail=0
    function Add-TestResult([string]$State,[string]$Name,[string]$Detail){
        switch($State){'OK'{$script:__stPass++};'WARN'{$script:__stWarn++};default{$script:__stFail++}}
        [void]$script:__stResults.Add(("{0,-5} {1}{2}" -f $State,$Name,$(if([string]::IsNullOrWhiteSpace($Detail)){''}else{' - '+$Detail})))
    }
    $script:__stResults=$results; $script:__stPass=0; $script:__stWarn=0; $script:__stFail=0
    try {
        if(-not [string]::IsNullOrWhiteSpace($script:PhoenixRoot) -and (Test-Path -LiteralPath $script:PhoenixRoot -PathType Container)){Add-TestResult 'OK' 'Phoenix-Verzeichnis' $script:PhoenixRoot}else{Add-TestResult 'FEHLER' 'Phoenix-Verzeichnis' 'nicht verbunden oder nicht gefunden'}
        $bankDir=Get-BankDirectory $script:PhoenixRoot
        if($bankDir -and (Test-Path -LiteralPath $bankDir -PathType Container)){Add-TestResult 'OK' 'BANKS-Verzeichnis' $bankDir}else{Add-TestResult 'FEHLER' 'BANKS-Verzeichnis' 'nicht gefunden'}
        if($null-ne$script:CurrentBank -and $script:CurrentBank.Path){
            $selfTestCfgPath = Join-Path $script:CurrentBank.Path 'BANK.CFG'
            if(Test-Path -LiteralPath $selfTestCfgPath -PathType Leaf){
                try{[void](Read-PhoenixConfig $selfTestCfgPath);Add-TestResult 'OK' 'BANK.CFG Parser' $script:CurrentBank.Name}catch{Add-TestResult 'FEHLER' 'BANK.CFG Parser' $_.Exception.Message}
            }else{Add-TestResult 'FEHLER' 'BANK.CFG Parser' ('BANK.CFG fehlt in '+$script:CurrentBank.Name)}
        }else{Add-TestResult 'WARN' 'BANK.CFG Parser' 'keine Bank ausgewählt'}
        $wav=$null; try{$wav=@($script:CurrentBank.Slots|Where-Object{$_.FilePath -and (Test-Path -LiteralPath $_.FilePath)}|Select-Object -First 1)[0]}catch{}
        if($wav){try{$wm=Read-WavMetadata $wav.FilePath;Add-TestResult 'OK' 'WAV-Decoder' (("{0} Hz, {1} Bit, {2} Kanal/Kanäle" -f $wm.SampleRate,$wm.BitsPerSample,$wm.Channels))}catch{Add-TestResult 'FEHLER' 'WAV-Decoder' $_.Exception.Message}}else{Add-TestResult 'WARN' 'WAV-Decoder' 'kein belegter Slot in aktiver Bank'}
        if($null-ne$script:CurrentBank){try{[void](Read-PhoenixPatterns $script:CurrentBank.Path);Add-TestResult 'OK' 'Pattern-Parser' 'PATTERNS.CFG/Default lesbar'}catch{Add-TestResult 'FEHLER' 'Pattern-Parser' $_.Exception.Message};try{[void](Read-PhoenixSong $script:CurrentBank.Path);Add-TestResult 'OK' 'Song-Parser' 'SONG.CFG/Default lesbar'}catch{Add-TestResult 'FEHLER' 'Song-Parser' $_.Exception.Message}}else{Add-TestResult 'WARN' 'Pattern-/Song-Parser' 'keine Bank ausgewählt'}
        try{if(Test-PhoenixWriteAccess){Add-TestResult 'OK' 'Schreibzugriff' 'READ / WRITE'}else{Add-TestResult 'WARN' 'Schreibzugriff' 'READ ONLY oder nicht verbunden'}}catch{Add-TestResult 'FEHLER' 'Schreibzugriff' $_.Exception.Message}
        try{if(-not(Test-Path -LiteralPath $script:BackupRoot)){[void](New-Item -ItemType Directory -Path $script:BackupRoot -Force)};Add-TestResult 'OK' 'Backup-Pfad' $script:BackupRoot}catch{Add-TestResult 'FEHLER' 'Backup-Pfad' $_.Exception.Message}
        if(('PhoenixMidi' -as [type]) -and ('PhoenixMidiIn' -as [type])){Add-TestResult 'OK' 'MIDI-System' 'winmm Wrapper geladen'}else{Add-TestResult 'FEHLER' 'MIDI-System' 'Wrapper nicht geladen'}
        if(('PhoenixOfflineRenderer' -as [type]) -and ('PhoenixWasapiLiveEngine' -as [type])){Add-TestResult 'OK' 'Audio Preview' ('Offline-Renderer + '+[PhoenixWasapiLiveEngine]::Status)}else{Add-TestResult 'FEHLER' 'Audio Preview' 'Renderer/WASAPI nicht bereit'}
        try{if($null-ne$script:LivePreviewCache){Add-TestResult 'OK' 'Preview-Cache' (("{0} Eintrag/Einträge" -f $script:LivePreviewCache.Count))}else{Add-TestResult 'WARN' 'Preview-Cache' 'noch nicht initialisiert'}}catch{Add-TestResult 'WARN' 'Preview-Cache' $_.Exception.Message}
    } catch { Add-TestResult 'FEHLER' 'Self Test' $_.Exception.Message }
    $script:SelfTestLastRun=Get-Date
    $summary=("Self Test: {0} OK | {1} Warnung(en) | {2} Fehler" -f $script:__stPass,$script:__stWarn,$script:__stFail)
    $text=$summary+"`r`n`r`n"+($script:__stResults -join "`r`n")
    if($script:SelfTestResultsBox){$script:SelfTestResultsBox.Text=$text}
    if($script:SelfTestSummaryText){$script:SelfTestSummaryText.Text=$summary;$script:SelfTestSummaryText.Foreground=$(if($script:__stFail -gt 0){'#EF7B7B'}elseif($script:__stWarn -gt 0){'#E7C96A'}else{'#8ED3A5'})}
    Add-Log $summary
    Update-SystemStatusView
    Remove-Variable __stResults,__stPass,__stWarn,__stFail -Scope Script -ErrorAction SilentlyContinue
}

function Set-EditorDirty {
    param([bool]$Dirty)
    $script:EditorDirty = $Dirty
    if ($script:SaveEditorButton) { $script:SaveEditorButton.IsEnabled = ($Dirty -and $null -ne $script:EditorState) }
    if ($script:BankTitle -and $null -ne $script:CurrentBank) {
        $script:BankTitle.Text = $script:CurrentBank.Name + $(if ($Dirty) { ' *' } else { '' })
    }
    if ($script:EditorStatusText) {
        $script:EditorStatusText.Text = if ($Dirty) { 'Nicht gespeicherte PC-Änderungen' } else { 'Gespeichert' }
        $script:EditorStatusText.Foreground = if ($Dirty) { '#F1C66A' } else { '#87C58B' }
    }
}

function Get-EditorMarkerValue {
    param([string]$Marker)
    if ($null -eq $script:EditorState) { return 0L }
    switch ($Marker) {
        'S.START' { return [long]$script:EditorState.SampleStart }
        'L.START' { return [long]$script:EditorState.LoopStart }
        'L.END'   { return [long]$script:EditorState.LoopEnd }
        'S.END'   { return [long]$script:EditorState.SampleEnd }
    }
    return 0L
}

function Set-EditorSelectedMarker {
    param([string]$Marker)
    if (@('S.START','L.START','L.END','S.END') -notcontains $Marker) { return }
    $script:EditorSelectedMarker = $Marker
    if ($script:MarkerSelectCombo -and -not $script:EditorSyncing) {
        $script:EditorSyncing = $true
        $script:MarkerSelectCombo.SelectedIndex = [array]::IndexOf(@('S.START','L.START','L.END','S.END'), $Marker)
        $script:EditorSyncing = $false
    }
    Draw-Waveform
}

function Set-EditorMarkerCascade {
    param([string]$Marker, [long]$Value)
    if ($null -eq $script:EditorState) { return }
    $s = $script:EditorState
    $frames = [long]$s.Frames
    if ($frames -lt 2) { return }
    $old = Get-EditorMarkerValue $Marker
    switch ($Marker) {
        'S.START' {
            $v = [math]::Max(0L, [math]::Min($frames - 2L, $Value))
            $s.SampleStart = $v
            if ($s.LoopStart -lt $v) { $s.LoopStart = $v }
            if ($s.LoopEnd -lt $s.LoopStart + 2L) { $s.LoopEnd = $s.LoopStart + 2L }
            if ($s.SampleEnd -lt $s.LoopEnd) { $s.SampleEnd = $s.LoopEnd }
            if ($s.SampleEnd -gt $frames) {
                $s.SampleEnd = $frames; $s.LoopEnd = $frames
                $s.LoopStart = [math]::Min($s.LoopStart, $frames - 2L)
                $s.SampleStart = [math]::Min($s.SampleStart, $s.LoopStart)
            }
        }
        'L.START' {
            $v = [math]::Max(0L, [math]::Min($frames - 2L, $Value))
            if ($v -lt $old -and $v -lt $s.SampleStart) { $s.SampleStart = $v }
            $s.LoopStart = $v
            if ($s.LoopEnd -lt $v + 2L) { $s.LoopEnd = $v + 2L }
            if ($s.SampleEnd -lt $s.LoopEnd) { $s.SampleEnd = $s.LoopEnd }
            if ($s.SampleEnd -gt $frames) {
                $s.SampleEnd = $frames; $s.LoopEnd = $frames; $s.LoopStart = $frames - 2L
                if ($s.SampleStart -gt $s.LoopStart) { $s.SampleStart = $s.LoopStart }
            }
        }
        'L.END' {
            $v = [math]::Max(2L, [math]::Min($frames, $Value))
            if ($v -gt $old -and $v -gt $s.SampleEnd) { $s.SampleEnd = $v }
            $s.LoopEnd = $v
            if ($s.LoopStart -gt $v - 2L) { $s.LoopStart = $v - 2L }
            if ($s.SampleStart -gt $s.LoopStart) { $s.SampleStart = $s.LoopStart }
        }
        'S.END' {
            $v = [math]::Max(2L, [math]::Min($frames, $Value))
            $s.SampleEnd = $v
            if ($s.LoopEnd -gt $v) { $s.LoopEnd = $v }
            if ($s.LoopStart -gt $s.LoopEnd - 2L) { $s.LoopStart = $s.LoopEnd - 2L }
            if ($s.SampleStart -gt $s.LoopStart) { $s.SampleStart = $s.LoopStart }
        }
    }
    Sync-EditorControls
    [void](Update-EditorDirtyState)
    Request-PreviewRefresh
}


function Get-MidiNoteLabel {
    param([int]$Note)
    $noteNames = @('C','C#','D','D#','E','F','F#','G','G#','A','A#','B')
    $n = [math]::Max(0, [math]::Min(127, $Note))
    $octave = [math]::Floor($n / 12) - 1
    return "$($noteNames[$n % 12])$octave ($n)"
}

function Get-PanLabel {
    param([int]$Pan)
    $p = [math]::Max(-100, [math]::Min(100, $Pan))
    if ($p -eq 0) { return 'CENTER (0)' }
    if ($p -lt 0) { return "L$([math]::Abs($p)) ($p)" }
    return "R$p (+$p)"
}

function Initialize-EditorState {
    param($Slot)
    if ($null -eq $Slot) {
        $script:EditorState = $null
        $script:EditorBaselineSignature = $null
        if ($script:EditorControlsPanel) { $script:EditorControlsPanel.IsEnabled = $false }
        if ($script:WaveformCanvas) { $script:WaveformCanvas.Children.Clear() }
        Set-EditorDirty $false
        return
    }
    $raw = $Slot.Raw
    $loopMode = [int](Convert-ToInt64Safe (Get-ValueOrDefault $raw 'LOOP_MODE' 0) 0)
    $xfade = [int](Convert-ToInt64Safe (Get-ValueOrDefault $raw 'LOOP_XFADE_MS' 0) 0)
    $root = [int](Convert-ToInt64Safe (Get-ValueOrDefault $raw 'ROOT' 60) 60)
    $script:EditorState = [pscustomobject]@{
        Frames = [long]$Slot.Frames
        SampleRate = [long]$Slot.SampleRate
        SampleStart = [long]$Slot.SampleStart
        LoopStart = [long]$Slot.LoopStart
        LoopEnd = [long]$Slot.LoopEnd
        SampleEnd = [long]$Slot.SampleEnd
        LoopMode = $loopMode
        XFade = $xfade
        Root = $root
        KeyLow = [int](Convert-ToInt64Safe (Get-ValueOrDefault $raw 'KEY_LOW' 0) 0)
        KeyHigh = [int](Convert-ToInt64Safe (Get-ValueOrDefault $raw 'KEY_HIGH' 127) 127)
        Trim = ((Convert-ToInt64Safe (Get-ValueOrDefault $raw 'TRIM_ENABLED' 0) 0) -ne 0)
        DC = ((Convert-ToInt64Safe (Get-ValueOrDefault $raw 'DC_ENABLED' 0) 0) -ne 0)
        Normalize = ((Convert-ToInt64Safe (Get-ValueOrDefault $raw 'NORMALIZE_ENABLED' 0) 0) -ne 0)
        Level = [int](Convert-ToInt64Safe (Get-ValueOrDefault $raw 'LEVEL' 100) 100)
        Pan = [int](Convert-ToInt64Safe (Get-ValueOrDefault $raw 'PAN' 0) 0)
        Voices = 12
    }
    if ($script:EditorControlsPanel) { $script:EditorControlsPanel.IsEnabled = ($Slot.WavMetadata.Valid -and $Slot.WavMetadata.BitsPerSample -eq 16) }
    if ($script:OpenWavButton) { $script:OpenWavButton.IsEnabled = [bool]$Slot.WavMetadata.Valid }
    if ($script:PlayWavButton) { $script:PlayWavButton.IsEnabled = [bool]$Slot.WavMetadata.Valid }
    Sync-EditorControls
    $script:EditorBaselineSignature = Get-EditorStateSignature
    Set-EditorDirty $false
}

function Sync-EditorControls {
    if ($null -eq $script:EditorState) { return }
    $script:EditorSyncing = $true
    try {
        $s = $script:EditorState
        $script:SStartBox.Text = [string]$s.SampleStart
        $script:LStartBox.Text = [string]$s.LoopStart
        $script:LEndBox.Text = [string]$s.LoopEnd
        $script:SEndBox.Text = [string]$s.SampleEnd
        $script:RootCombo.SelectedIndex = [math]::Max(0, [math]::Min(127, [int]$s.Root))
        $script:KeyLowCombo.SelectedIndex = [math]::Max(0, [math]::Min(127, [int]$s.KeyLow))
        $script:KeyHighCombo.SelectedIndex = [math]::Max(0, [math]::Min(127, [int]$s.KeyHigh))
        $script:LevelBox.Text = [string]$s.Level
        $script:PanCombo.SelectedIndex = [math]::Max(0, [math]::Min(200, [int]$s.Pan + 100))
        $script:VoicesBox.Text = '12'
        $script:LoopModeCombo.SelectedIndex = [math]::Max(0, [math]::Min(2, $s.LoopMode))
        $xIndex = [array]::IndexOf($script:XFadeValues, [int]$s.XFade)
        if ($xIndex -lt 0) { $xIndex = 0 }
        $script:XFadeCombo.SelectedIndex = $xIndex
        $script:TrimCheck.IsChecked = [bool]$s.Trim
        $script:DCCheck.IsChecked = [bool]$s.DC
        $script:NormCheck.IsChecked = [bool]$s.Normalize
                $script:MarkerSelectCombo.SelectedIndex = [array]::IndexOf(@('S.START','L.START','L.END','S.END'), $script:EditorSelectedMarker)
        $script:EditorSlotText.Text = if ($script:CurrentSlot) { "$($script:CurrentSlot.Slot) · $($script:CurrentSlot.Duration) · $($s.SampleRate) Hz · $($s.Frames) Frames" } else { '' }
        Update-LoopStatistics
    } finally {
        $script:EditorSyncing = $false
    }
    Draw-Waveform
}

function Update-MarkerFromTextBox {
    param([string]$Marker, $TextBox)
    if ($script:EditorSyncing -or $null -eq $script:EditorState) { return }
    $value = 0L
    if (-not [long]::TryParse($TextBox.Text.Trim(), [ref]$value)) {
        [System.Windows.MessageBox]::Show('Bitte eine gültige ganzzahlige Sampleposition eingeben.', 'Marker', 'OK', 'Warning') | Out-Null
        Sync-EditorControls
        return
    }
    Set-EditorSelectedMarker $Marker
    Set-EditorMarkerCascade $Marker $value
}

function Update-EditorParametersFromControls {
    if ($script:EditorSyncing -or $null -eq $script:EditorState) { return $false }
    $level = 0
    if (-not [int]::TryParse($script:LevelBox.Text.Trim(), [ref]$level) -or $level -lt 0 -or $level -gt 100) {
        [System.Windows.MessageBox]::Show('Level muss zwischen 0 und 100 liegen.', 'Slot-Editor', 'OK', 'Warning') | Out-Null; return $false
    }
    $root = [math]::Max(0, [math]::Min(127, [int]$script:RootCombo.SelectedIndex))
    $keyLow = [math]::Max(0, [math]::Min(127, [int]$script:KeyLowCombo.SelectedIndex))
    $keyHigh = [math]::Max(0, [math]::Min(127, [int]$script:KeyHighCombo.SelectedIndex))
    if ($keyLow -gt $keyHigh) {
        [System.Windows.MessageBox]::Show('LOW NOTE darf nicht über HIGH NOTE liegen.', 'Tastaturbereich', 'OK', 'Warning') | Out-Null; return $false
    }
    if ($root -lt $keyLow -or $root -gt $keyHigh) {
        [System.Windows.MessageBox]::Show('ROOT NOTE muss innerhalb des Tastaturbereichs liegen.', 'Tastaturbereich', 'OK', 'Warning') | Out-Null; return $false
    }
    $pan = [math]::Max(-100, [math]::Min(100, [int]$script:PanCombo.SelectedIndex - 100))
    $s = $script:EditorState
    $s.Root = $root; $s.KeyLow = $keyLow; $s.KeyHigh = $keyHigh; $s.Level = $level; $s.Pan = $pan; $s.Voices = 12
    $s.LoopMode = [math]::Max(0, $script:LoopModeCombo.SelectedIndex)
    $xIndex = [math]::Max(0, $script:XFadeCombo.SelectedIndex)
    $s.XFade = $script:XFadeValues[$xIndex]
    $s.Trim = [bool]$script:TrimCheck.IsChecked
    $s.DC = [bool]$script:DCCheck.IsChecked
    $s.Normalize = [bool]$script:NormCheck.IsChecked
    [void](Update-EditorDirtyState)
    Request-PreviewRefresh
    Draw-Waveform
    return $true
}

function Get-MarkerDefinitions {
    return @(
        [pscustomobject]@{ Key='S.START'; Label='S'; Value=[long]$script:EditorState.SampleStart; Color='#F3D05C' },
        [pscustomobject]@{ Key='L.START'; Label='LS'; Value=[long]$script:EditorState.LoopStart; Color='#70D89A' },
        [pscustomobject]@{ Key='L.END'; Label='LE'; Value=[long]$script:EditorState.LoopEnd; Color='#EE8A5B' },
        [pscustomobject]@{ Key='S.END'; Label='E'; Value=[long]$script:EditorState.SampleEnd; Color='#D77AE8' }
    )
}

function Draw-Waveform {
    if (-not $script:WaveformCanvas) { return }
    $script:WaveformCanvas.Children.Clear()
    if ($null -eq $script:CurrentSlot -or $null -eq $script:EditorState) {
        $script:WaveformInfo.Text = 'Kein Slot ausgewählt.'; return
    }
    if (-not $script:CurrentSlot.WavMetadata.Valid) {
        $script:WaveformInfo.Text = "$($script:CurrentSlot.Slot): Keine gültige WAV-Datei vorhanden."; return
    }
    $width = [int][math]::Floor($script:WaveformCanvas.ActualWidth)
    $height = [int][math]::Floor($script:WaveformCanvas.ActualHeight)
    if ($width -lt 32 -or $height -lt 40) { return }
    try {
        $envelope = Get-WaveformEnvelope $script:CurrentSlot.FilePath $width

        # v0.9.13b: Die Darstellung wird visuell um die Mitte des tatsächlich
        # sichtbaren Signalbereichs zentriert. Das verändert ausschließlich die
        # Anzeige - WAV-Daten, Marker und DC-Korrektur bleiben unangetastet.
        $displayMin = 1.0
        $displayMax = -1.0
        for ($i = 0; $i -lt $width; $i++) {
            $mn = [double]$envelope.Min[$i]
            $mx = [double]$envelope.Max[$i]
            if ($mn -lt $displayMin) { $displayMin = $mn }
            if ($mx -gt $displayMax) { $displayMax = $mx }
        }
        if ($displayMax -lt $displayMin) { $displayMin = -1.0; $displayMax = 1.0 }

        $displayOffset = ($displayMax + $displayMin) / 2.0
        $displayHalfRange = [math]::Max(0.000001, ($displayMax - $displayMin) / 2.0)
        $center = $height / 2.0
        $displayAmplitude = [math]::Max(12.0, ($height * 0.44) / $displayHalfRange)

        # Referenzlinie der zentrierten Anzeige.
        Add-WaveLine $script:WaveformCanvas 0 $center $width $center '#405064' 1.0 0.8
        for ($x = 0; $x -lt $width; $x++) {
            $top = [double]$envelope.Min[$x] - $displayOffset
            $bottom = [double]$envelope.Max[$x] - $displayOffset
            $yTop = $center - ($bottom * $displayAmplitude)
            $yBottom = $center - ($top * $displayAmplitude)
            # v0.9.14b: Die gezeichnete Amplitude bleibt garantiert innerhalb
            # der tatsächlich sichtbaren Canvas-Fläche. Dadurch kann die
            # Wellenform auch bei engem Fensterlayout nicht in die Parameterzeilen ragen.
            $yTop = [math]::Max(2.0, [math]::Min([double]($height - 2), $yTop))
            $yBottom = [math]::Max(2.0, [math]::Min([double]($height - 2), $yBottom))
            Add-WaveLine $script:WaveformCanvas $x $yTop $x $yBottom '#78B7E6' 1.0 0.92
        }
        $frames = [math]::Max(1L, [long]$script:EditorState.Frames)
        $row = 0
        foreach ($marker in Get-MarkerDefinitions) {
            $mx = [math]::Round(([double]$marker.Value / [double]$frames) * ($width - 1))
            $active = ($marker.Key -eq $script:EditorSelectedMarker)
            Add-WaveLine $script:WaveformCanvas $mx 0 $mx $height $marker.Color $(if ($active) { 3.0 } else { 1.5 }) 0.98
            Add-WaveLabel $script:WaveformCanvas $marker.Label ([math]::Max(1, [math]::Min($width - 22, $mx + 3))) (2 + (13 * ($row % 2))) $marker.Color
            $row++
        }
        if ($script:PreviewSourcePosition -ge 0) {
            $px = [math]::Max(0.0, [math]::Min([double]($width - 1), (([double]$script:PreviewSourcePosition / [double]$frames) * ($width - 1))))
            Add-WaveLine $script:WaveformCanvas $px 0 $px $height '#FFFFFF' 2.2 1.0
        }
        $modeText = @('OFF','FORWARD','ALTERNATE')[[math]::Max(0,[math]::Min(2,$script:EditorState.LoopMode))]
        $fileName = Split-Path $script:CurrentSlot.FilePath -Leaf
        $script:WaveformInfo.Text = "$($script:CurrentSlot.Slot)  $fileName  |  Loop $modeText  |  Marker ziehen · Mausrad später für Zoom vorgesehen"
    } catch {
        $script:WaveformInfo.Text = 'Waveform nicht verfügbar: ' + $_.Exception.Message
        Add-Log ('Waveform-Fehler: ' + $_.Exception.Message)
    }
}

function Find-NearestMarkerAtX {
    param([double]$X)
    if ($null -eq $script:EditorState) { return $null }
    $width = [math]::Max(2.0, $script:WaveformCanvas.ActualWidth)
    $frames = [math]::Max(1L, [long]$script:EditorState.Frames)
    $best = $null; $bestDistance = 13.0
    foreach ($marker in Get-MarkerDefinitions) {
        $mx = ([double]$marker.Value / [double]$frames) * ($width - 1.0)
        $distance = [math]::Abs($mx - $X)
        if ($distance -lt $bestDistance) { $best = $marker.Key; $bestDistance = $distance }
    }
    return $best
}

function Update-DraggedMarker {
    param([double]$X)
    if ([string]::IsNullOrWhiteSpace($script:EditorDraggingMarker) -or $null -eq $script:EditorState) { return }
    $width = [math]::Max(2.0, $script:WaveformCanvas.ActualWidth)
    $ratio = [math]::Max(0.0, [math]::Min(1.0, $X / ($width - 1.0)))
    $frame = [long][math]::Round($ratio * [double]$script:EditorState.Frames)
    Set-EditorMarkerCascade $script:EditorDraggingMarker $frame
}

function Update-LoopStatistics {
    if (-not $script:LoopStatsText -or $null -eq $script:EditorState) { return }
    $s = $script:EditorState
    $length = [long][math]::Max(0L, ([long]$s.LoopEnd - [long]$s.LoopStart))
    $rate = [double][math]::Max(1.0, [double]$s.SampleRate)
    $ms = ([double]$length / $rate) * 1000.0
    $hz = if ($length -gt 0) { $rate / [double]$length } else { 0.0 }
    $script:LoopStatsText.Text = ('Loop: {0} Samples · {1:N3} ms · {2:N3} Hz' -f $length, $ms, $hz)
}

function Nudge-SelectedMarker {
    param([long]$Delta)
    if ($null -eq $script:EditorState) { return }
    $marker = $script:EditorSelectedMarker
    if ($script:LoopLinkEnabled -and @('L.START','L.END') -contains $marker) {
        $s = $script:EditorState
        $newStart = [long]$s.LoopStart + $Delta
        $newEnd = [long]$s.LoopEnd + $Delta
        if ($newStart -lt [long]$s.SampleStart) {
            $Delta += ([long]$s.SampleStart - $newStart)
        }
        $newStart = [long]$s.LoopStart + $Delta
        $newEnd = [long]$s.LoopEnd + $Delta
        if ($newEnd -gt [long]$s.SampleEnd) {
            $Delta -= ($newEnd - [long]$s.SampleEnd)
        }
        $s.LoopStart = [long]$s.LoopStart + $Delta
        $s.LoopEnd = [long]$s.LoopEnd + $Delta
        Sync-EditorControls
        [void](Update-EditorDirtyState)
        Request-PreviewRefresh
        return
    }
    Set-EditorMarkerCascade $marker ((Get-EditorMarkerValue $marker) + $Delta)
}

function Select-LoopRegion {
    if ($null -eq $script:EditorState) { return }
    Set-EditorSelectedMarker 'L.START'
    if ($script:WaveformInfo) {
        $script:WaveformInfo.Text = "$($script:CurrentSlot.Slot) · Loopbereich L.START bis L.END · Feinjustierung aktiv"
    }
}

function Snap-SelectedMarker {
    if ($null -eq $script:CurrentSlot -or $null -eq $script:EditorState) { return }
    $meta = $script:CurrentSlot.WavMetadata
    if (-not $meta.Valid -or $meta.BitsPerSample -ne 16) {
        [System.Windows.MessageBox]::Show('Zero-Crossing Snap benötigt eine gültige 16-Bit-PCM-WAV-Datei.', 'Zero Crossing', 'OK', 'Warning') | Out-Null; return
    }
    try {
        $target = Get-EditorMarkerValue $script:EditorSelectedMarker
        $crossing = [PhoenixLibrarianAudio]::FindNearestZeroCrossing(
            $script:CurrentSlot.FilePath, [long]$meta.DataOffset, [int]$meta.Channels,
            [long]$meta.Frames, [long]$target, 2048)
        if ($crossing -lt 0) {
            [System.Windows.MessageBox]::Show('Im Bereich ±2048 Samples wurde kein Nulldurchgang gefunden.', 'Zero Crossing', 'OK', 'Information') | Out-Null; return
        }
        Set-EditorMarkerCascade $script:EditorSelectedMarker $crossing
        Add-Log "$($script:CurrentSlot.Slot) $script:EditorSelectedMarker auf Nulldurchgang $crossing gesetzt."
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Zero-Crossing-Fehler', 'OK', 'Error') | Out-Null
    }
}

function Write-ConfigWithSlotUpdates {
    param([string]$Source, [string]$Destination, [int]$SlotNumber, [hashtable]$Updates)
    $lines = [System.IO.File]::ReadAllLines($Source, $script:Utf8NoBom)
    $target = "SLOT$SlotNumber"
    $output = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $inside = $false; $foundSection = $false
    $appendMissing = {
        foreach ($key in $Updates.Keys) {
            if (-not $seen.ContainsKey($key)) { $output.Add("$key=$($Updates[$key])") }
        }
    }
    foreach ($raw in $lines) {
        $trim = $raw.Trim()
        if ($trim.StartsWith('[') -and $trim.EndsWith(']')) {
            if ($inside) { & $appendMissing; $inside = $false }
            $section = $trim.Substring(1, $trim.Length - 2).Trim().ToUpperInvariant()
            $inside = ($section -eq $target)
            if ($inside) { $foundSection = $true; $seen.Clear() }
            $output.Add($raw)
            continue
        }
        if ($inside) {
            $eq = $raw.IndexOf('=')
            if ($eq -gt 0) {
                $key = $raw.Substring(0, $eq).Trim().ToUpperInvariant()
                if ($Updates.ContainsKey($key)) {
                    $output.Add("$key=$($Updates[$key])")
                    $seen[$key] = $true
                    continue
                }
            }
        }
        $output.Add($raw)
    }
    if ($inside) { & $appendMissing }
    if (-not $foundSection) {
        if ($output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($output[$output.Count-1])) { $output.Add('') }
        $output.Add("[$target]")
        foreach ($key in $Updates.Keys) { $output.Add("$key=$($Updates[$key])") }
    }
    [System.IO.File]::WriteAllLines($Destination, $output, $script:Utf8NoBom)
}



function Write-ConfigWithGlobalUpdates {
    param([string]$Source, [string]$Destination, [hashtable]$Updates)
    $lines = [System.IO.File]::ReadAllLines($Source, $script:Utf8NoBom)
    $output = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $inside = $false; $foundSection = $false
    $appendMissing = {
        foreach ($key in $Updates.Keys) {
            if (-not $seen.ContainsKey($key)) { $output.Add("$key=$($Updates[$key])") }
        }
    }
    foreach ($raw in $lines) {
        $trim = $raw.Trim()
        if ($trim.StartsWith('[') -and $trim.EndsWith(']')) {
            if ($inside) { & $appendMissing; $inside = $false }
            $section = $trim.Substring(1, $trim.Length - 2).Trim().ToUpperInvariant()
            $inside = ($section -eq 'GLOBAL')
            if ($inside) { $foundSection = $true; $seen.Clear() }
            $output.Add($raw)
            continue
        }
        if ($inside) {
            $eq = $raw.IndexOf('=')
            if ($eq -gt 0) {
                $key = $raw.Substring(0, $eq).Trim().ToUpperInvariant()
                if ($Updates.ContainsKey($key)) {
                    $output.Add("$key=$($Updates[$key])")
                    $seen[$key] = $true
                    continue
                }
            }
        }
        $output.Add($raw)
    }
    if ($inside) { & $appendMissing }
    if (-not $foundSection) {
        if ($output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($output[$output.Count-1])) { $output.Add('') }
        $output.Add('[GLOBAL]')
        foreach ($key in $Updates.Keys) { $output.Add("$key=$($Updates[$key])") }
    }
    [System.IO.File]::WriteAllLines($Destination, $output, $script:Utf8NoBom)
}


function Write-ConfigWithBankVersion {
    param([string]$Source,[string]$Destination,[int]$Version=16)
    $lines=[System.IO.File]::ReadAllLines($Source,$script:Utf8NoBom)
    $output=New-Object System.Collections.Generic.List[string]
    $found=$false
    foreach($raw in $lines){
        $trim=$raw.Trim()
        if(-not $found -and $trim -match '^BANK_VERSION\s*='){
            $output.Add('BANK_VERSION='+$Version)
            $found=$true
            continue
        }
        if(-not $found -and $trim.StartsWith('[')){
            $output.Add('BANK_VERSION='+$Version)
            $found=$true
        }
        $output.Add($raw)
    }
    if(-not $found){
        if($output.Count -gt 0){$output.Insert([Math]::Min(1,$output.Count),'BANK_VERSION='+$Version)}
        else{$output.Add('BANK_VERSION='+$Version)}
    }
    [System.IO.File]::WriteAllLines($Destination,$output,$script:Utf8NoBom)
}


function Save-CurrentBankInfo {
    if ($null -eq $script:CurrentBank) { return }
    try {
        [void](Test-PhoenixWriteAccess)
        $info=@{
            NAME=$script:BankNameBox.Text.Trim(); CATEGORY=$script:BankCategoryBox.Text.Trim(); AUTHOR=$script:BankAuthorBox.Text.Trim();
            DESCRIPTION=$script:BankDescriptionBox.Text.Trim(); LICENSE=$script:BankLicenseBox.Text.Trim(); TAGS=$script:BankTagsBox.Text.Trim();
            TEMPLATE=$script:BankTemplateText.Text.Trim(); SLOT1_NAME=$script:Slot1NameBox.Text.Trim(); SLOT2_NAME=$script:Slot2NameBox.Text.Trim();
            SLOT3_NAME=$script:Slot3NameBox.Text.Trim(); SLOT4_NAME=$script:Slot4NameBox.Text.Trim()
        }
        Write-BankInfo $script:CurrentBank.Path $info
        $name=$script:CurrentBank.Name; Add-Log "${name}: BANK.INFO gespeichert."; $script:StatusText.Text='Bank-Metadaten gespeichert'; Refresh-And-SelectBank $name
    } catch { [System.Windows.MessageBox]::Show($_.Exception.Message,'Metadaten speichern','OK','Error')|Out-Null }
}

function Import-WavFileToSlot {
    param([string]$BankPath,[string]$BankName,[int]$SlotIndex,[string]$SourcePath)
    $sourceMeta=Read-WavMetadata $SourcePath
    if(-not $sourceMeta.Valid){throw "Ungültige WAV-Datei ${SourcePath}: $($sourceMeta.Error)"}
    $token=[guid]::NewGuid().ToString('N');$cfgPath=Join-Path $BankPath 'BANK.CFG';$wavPath=Join-Path $BankPath ("SLOT{0}.WAV" -f ($SlotIndex+1))
    $cfgTemp=Join-Path $BankPath ('.BANK.CFG.multi_'+$token);$wavTemp=Join-Path $BankPath ('.SLOT.multi_'+$token+'.WAV')
    $cfgRollback=Join-Path $BankPath ('.BANK.CFG.rollback_'+$token);$wavRollback=Join-Path $BankPath ('.SLOT.rollback_'+$token+'.WAV')
    $cfgMoved=$false;$wavMoved=$false;$cfgInstalled=$false;$wavInstalled=$false;$committed=$false
    try{
        $result=[PhoenixLibrarianAudio]::ConvertToPhoenixWav($SourcePath,$wavTemp,32000,320000)
        $loopMode=[int]$result.LoopMode;$loopStart=if($loopMode-ne 0){[long]$result.LoopStart}else{0L};$loopEnd=if($loopMode-ne 0){[long]$result.LoopEndExclusive}else{[long]$result.OutputFrames}
        $updates=@{'RECORDED'='1';'SAMPLE_RATE'='32000';'FRAME_COUNT'=[string]$result.OutputFrames;'SAMPLE_START'='0';'LOOP_START'=[string]$loopStart;'LOOP_END'=[string]$loopEnd;'SAMPLE_END'=[string]$result.OutputFrames;'LOOP'=$(if($loopMode-eq 0){'0'}else{'1'});'LOOP_MODE'=[string]$loopMode;'LOOP_XFADE_MS'='0';'ROOT'=[string]$result.RootNote;'TRIM_ENABLED'='0';'TRIM_UNDO_VALID'='0';'TRIM_UNDO_SAMPLE_START'='0';'TRIM_UNDO_LOOP_START'=[string]$loopStart;'TRIM_UNDO_LOOP_END'=[string]$loopEnd;'TRIM_UNDO_SAMPLE_END'=[string]$result.OutputFrames;'DC_ENABLED'='0';'DC_OFFSET'='0';'NORMALIZE_ENABLED'='0';'NORMALIZE_GAIN_Q16'='65536';'VOICE_LIMIT'='12'}
        Write-ConfigWithSlotUpdates $cfgPath $cfgTemp ($SlotIndex+1) $updates
        Move-Item $cfgPath $cfgRollback -Force;$cfgMoved=$true;Move-Item $cfgTemp $cfgPath -Force;$cfgInstalled=$true
        if(Test-Path $wavPath){Move-Item $wavPath $wavRollback -Force;$wavMoved=$true};Move-Item $wavTemp $wavPath -Force;$wavInstalled=$true
        Remove-Item $cfgRollback,$wavRollback -Force -ErrorAction SilentlyContinue;$committed=$true
        return $result
    }catch{
        if(-not $committed -and $cfgMoved){if($cfgInstalled -and (Test-Path $cfgPath)){Remove-Item $cfgPath -Force};if(Test-Path $cfgRollback){Move-Item $cfgRollback $cfgPath -Force}}
        if(-not $committed -and $wavMoved){if($wavInstalled -and (Test-Path $wavPath)){Remove-Item $wavPath -Force};if(Test-Path $wavRollback){Move-Item $wavRollback $wavPath -Force}}elseif(-not $committed -and $wavInstalled -and (Test-Path $wavPath)){Remove-Item $wavPath -Force}
        throw
    }finally{Remove-Item $cfgTemp,$wavTemp -Force -ErrorAction SilentlyContinue}
}

function Import-FourWavs {
    if($null -eq $script:CurrentBank){[System.Windows.MessageBox]::Show('Bitte zuerst eine Bank auswählen.','Vierfach-Import','OK','Information')|Out-Null;return}
    if(Test-EditorHasChanges){[System.Windows.MessageBox]::Show('Bitte aktuelle Editor-Änderungen zuerst speichern oder zurücksetzen.','Vierfach-Import','OK','Information')|Out-Null;return}
    $d=New-Object Microsoft.Win32.OpenFileDialog;$d.Title='Bis zu vier WAV-Dateien auswählen (Reihenfolge = S1 bis S4)';$d.Filter='WAV-Audiodateien (*.wav)|*.wav';$d.Multiselect=$true
    if($d.ShowDialog()-ne $true){return};$files=@($d.FileNames);if($files.Count-lt 1 -or $files.Count-gt 4){[System.Windows.MessageBox]::Show('Bitte eine bis vier WAV-Dateien auswählen.','Vierfach-Import','OK','Warning')|Out-Null;return}
    $map=for($i=0;$i-lt $files.Count;$i++){"S$($i+1)  <-  $([IO.Path]::GetFileName($files[$i]))"}
    if([System.Windows.MessageBox]::Show("Folgende Zuordnung wird importiert:`r`n`r`n$([string]::Join("`r`n",$map))`r`n`r`nVorhandene Zielslots werden ersetzt.",'Vierfach-WAV-Import','YesNo','Question')-ne [System.Windows.MessageBoxResult]::Yes){return}
    try{[void](Test-PhoenixWriteAccess);$script:Window.Cursor=[System.Windows.Input.Cursors]::Wait
        for($i=0;$i-lt $files.Count;$i++){ $script:StatusText.Text="Importiere S$($i+1) ...";[void](Import-WavFileToSlot $script:CurrentBank.Path $script:CurrentBank.Name $i $files[$i]);Add-Log "$($script:CurrentBank.Name) / S$($i+1): $([IO.Path]::GetFileName($files[$i])) importiert." }
        $bn=$script:CurrentBank.Name;Refresh-And-SelectBank $bn;[System.Windows.MessageBox]::Show("$($files.Count) WAV-Datei(en) wurden erfolgreich auf S1 bis S$($files.Count) verteilt.",'Vierfach-Import','OK','Information')|Out-Null
    }catch{[System.Windows.MessageBox]::Show($_.Exception.Message,'Vierfach-Import fehlgeschlagen','OK','Error')|Out-Null}finally{$script:Window.Cursor=[System.Windows.Input.Cursors]::Arrow;$script:StatusText.Text=''}
}

function Import-WavToCurrentSlot {
    if ($null -eq $script:CurrentBank -or $null -eq $script:CurrentSlot) {
        [System.Windows.MessageBox]::Show('Bitte zuerst eine Bank und einen Slot auswählen.', 'WAV importieren', 'OK', 'Information') | Out-Null
        return
    }

    if (Test-EditorHasChanges) {
        $answer = [System.Windows.MessageBox]::Show(
            "Der aktuelle Slot enthält nicht gespeicherte Editor-Änderungen.`r`n`r`nJA = zuerst speichern`r`nNEIN = Änderungen verwerfen und importieren`r`nABBRECHEN = keine Aktion",
            'WAV importieren', 'YesNoCancel', 'Question')
        if ($answer -eq [System.Windows.MessageBoxResult]::Cancel) { return }
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            Save-EditorChanges
            if (Test-EditorHasChanges) { return }
        } else {
            Initialize-EditorState $script:CurrentSlot
        }
    }

    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = "WAV für $($script:CurrentBank.Name) / $($script:CurrentSlot.Slot) auswählen"
    $dialog.Filter = 'WAV-Audiodatei (*.wav)|*.wav|Alle Dateien (*.*)|*.*'
    if ($dialog.ShowDialog() -ne $true) { return }

    $sourceMeta = Read-WavMetadata $dialog.FileName
    if (-not $sourceMeta.Valid) {
        [System.Windows.MessageBox]::Show(
            "Die WAV-Datei kann nicht gelesen werden:`r`n$($sourceMeta.Error)",
            'WAV importieren', 'OK', 'Error') | Out-Null
        return
    }

    $slotIndex = Get-CurrentSlotIndex
    if ($slotIndex -lt 0) { return }
    $sourceDuration = Format-Duration $sourceMeta.Frames $sourceMeta.SampleRate
    $naturalFrames = [long][math]::Round(([double]$sourceMeta.Frames * 32000.0) / [math]::Max(1.0, [double]$sourceMeta.SampleRate))
    $willTruncate = $naturalFrames -gt 320000L
    $outputFrames = [math]::Min(320000L, [math]::Max(1L, $naturalFrames))
    $outputDuration = Format-Duration $outputFrames 32000
    $formatText = if ($sourceMeta.AudioFormat -eq 3) { 'IEEE FLOAT' } elseif ($sourceMeta.AudioFormat -eq 1 -or $sourceMeta.AudioFormat -eq 65534) { 'PCM' } else { "FORMAT $($sourceMeta.AudioFormat)" }
    $loopText = if ($sourceMeta.HasSmpl) {
        "Loop $($sourceMeta.LoopStart)-$($sourceMeta.LoopEndExclusive), Root $($sourceMeta.RootNote)"
    } else { 'kein WAV-Loop' }
    $truncateText = if ($willTruncate) { "`r`nACHTUNG: Die Ausgabe wird auf 10,000 s / 320000 Samples begrenzt." } else { '' }
    $existingText = if ($script:CurrentSlot.WavMetadata.Exists) { "Der vorhandene Inhalt von $($script:CurrentSlot.Slot) wird sicher ersetzt." } else { "$($script:CurrentSlot.Slot) ist derzeit leer." }
    $message = @"
Quelle: $([System.IO.Path]::GetFileName($dialog.FileName))
$($sourceMeta.Channels) Kanal/Kanäle · $($sourceMeta.BitsPerSample) Bit $formatText · $($sourceMeta.SampleRate) Hz · $sourceDuration
$loopText

Phoenix-Ausgabe:
Mono · 16 Bit PCM · 32000 Hz · $outputDuration
$existingText$truncateText

Import starten?
"@
    $confirm = [System.Windows.MessageBox]::Show($message, 'WAV in Phoenix-Slot importieren', 'YesNo', 'Question')
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $token = [guid]::NewGuid().ToString('N')
    $cfgPath = Join-Path $script:CurrentBank.Path 'BANK.CFG'
    $wavPath = Join-Path $script:CurrentBank.Path ("SLOT{0}.WAV" -f ($slotIndex + 1))
    $cfgTemp = Join-Path $script:CurrentBank.Path ('.BANK.CFG.import_' + $token)
    $wavTemp = Join-Path $script:CurrentBank.Path ('.SLOT.import_' + $token + '.WAV')
    $cfgRollback = Join-Path $script:CurrentBank.Path ('.BANK.CFG.rollback_' + $token)
    $wavRollback = Join-Path $script:CurrentBank.Path ('.SLOT.rollback_' + $token + '.WAV')
    $cfgMoved = $false
    $wavMoved = $false
    $cfgInstalled = $false
    $wavInstalled = $false
    $committed = $false

    try {
        [void](Test-PhoenixWriteAccess)
        if ($script:MediaPlaying) {
            Stop-PhoenixTransport
    Close-MidiOutput
    Stop-LoopPreview
    if($script:PreviewTempFile){Remove-Item -LiteralPath $script:PreviewTempFile -Force -ErrorAction SilentlyContinue}; $script:MediaPlaying = $false
            $script:PlayWavButton.Content = 'WAV abspielen'
        }
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        $script:StatusText.Text = "Konvertiere WAV für $($script:CurrentSlot.Slot) ..."
        $result = [PhoenixLibrarianAudio]::ConvertToPhoenixWav($dialog.FileName, $wavTemp, 32000, 320000)

        $loopMode = [int]$result.LoopMode
        $loopStart = if ($loopMode -ne 0) { [long]$result.LoopStart } else { 0L }
        $loopEnd = if ($loopMode -ne 0) { [long]$result.LoopEndExclusive } else { [long]$result.OutputFrames }
        $updates = @{
            'RECORDED' = '1'
            'SAMPLE_RATE' = '32000'
            'FRAME_COUNT' = [string]$result.OutputFrames
            'SAMPLE_START' = '0'
            'LOOP_START' = [string]$loopStart
            'LOOP_END' = [string]$loopEnd
            'SAMPLE_END' = [string]$result.OutputFrames
            'LOOP' = $(if ($loopMode -eq 0) { '0' } else { '1' })
            'LOOP_MODE' = [string]$loopMode
            'LOOP_XFADE_MS' = '0'
            'ROOT' = [string]$result.RootNote
            'TRIM_ENABLED' = '0'
            'TRIM_UNDO_VALID' = '0'
            'TRIM_UNDO_SAMPLE_START' = '0'
            'TRIM_UNDO_LOOP_START' = [string]$loopStart
            'TRIM_UNDO_LOOP_END' = [string]$loopEnd
            'TRIM_UNDO_SAMPLE_END' = [string]$result.OutputFrames
            'DC_ENABLED' = '0'
            'DC_OFFSET' = '0'
            'NORMALIZE_ENABLED' = '0'
            'NORMALIZE_GAIN_Q16' = '65536'
        }
        Write-ConfigWithSlotUpdates $cfgPath $cfgTemp ($slotIndex + 1) $updates

        Move-Item -LiteralPath $cfgPath -Destination $cfgRollback -Force
        $cfgMoved = $true
        Move-Item -LiteralPath $cfgTemp -Destination $cfgPath -Force
        $cfgInstalled = $true
        if (Test-Path -LiteralPath $wavPath -PathType Leaf) {
            Move-Item -LiteralPath $wavPath -Destination $wavRollback -Force
            $wavMoved = $true
        }
        Move-Item -LiteralPath $wavTemp -Destination $wavPath -Force
        $wavInstalled = $true
        Remove-Item -LiteralPath $cfgRollback -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $wavRollback -Force -ErrorAction SilentlyContinue
        $committed = $true
        if ($script:WaveformCache.ContainsKey($wavPath)) { $script:WaveformCache.Remove($wavPath) }

        $bankName = $script:CurrentBank.Name
        $sourceDescription = "$($result.SourceChannels)ch/$($result.SourceBitsPerSample)bit/$($result.SourceSampleRate)Hz"
        $importNote = if ($result.Truncated) { ' (auf 10 Sekunden begrenzt)' } else { '' }
        Add-Log "$bankName / S$($slotIndex + 1): WAV importiert und konvertiert: $sourceDescription -> mono/16bit/32000Hz$importNote."
        Initialize-EditorState $null
        Refresh-And-SelectBank $bankName
        $script:SlotGrid.SelectedIndex = $slotIndex
        $script:MainTabs.SelectedItem = $script:WaveformEditorTab
        [System.Windows.MessageBox]::Show(
            "WAV erfolgreich importiert.`r`n`r`nAusgabe: $($result.OutputFrames) Samples / $(Format-Duration $result.OutputFrames 32000)`r`nLoop: $(Get-LoopModeText $result.LoopMode)`r`nRoot Note: $($result.RootNote)$importNote",
            'Phoenix Librarian', 'OK', 'Information') | Out-Null
    } catch {
        if (-not $committed -and $cfgMoved) {
            if ($cfgInstalled -and (Test-Path -LiteralPath $cfgPath -PathType Leaf)) { Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $cfgRollback -PathType Leaf) {
                Move-Item -LiteralPath $cfgRollback -Destination $cfgPath -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $committed -and $wavMoved) {
            if ($wavInstalled -and (Test-Path -LiteralPath $wavPath -PathType Leaf)) { Remove-Item -LiteralPath $wavPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $wavRollback -PathType Leaf) {
                Move-Item -LiteralPath $wavRollback -Destination $wavPath -Force -ErrorAction SilentlyContinue
            }
        } elseif (-not $committed -and $wavInstalled -and (Test-Path -LiteralPath $wavPath -PathType Leaf)) {
            # The slot was empty before the import; remove only the newly installed WAV.
            Remove-Item -LiteralPath $wavPath -Force -ErrorAction SilentlyContinue
        }
        Add-Log ('WAV-Import fehlgeschlagen: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'WAV-Import fehlgeschlagen', 'OK', 'Error') | Out-Null
    } finally {
        Remove-Item -LiteralPath $cfgTemp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $wavTemp -Force -ErrorAction SilentlyContinue
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
        $script:StatusText.Text = ''
    }
}

function Save-EditorChanges {
    if ($null -eq $script:CurrentBank -or $null -eq $script:CurrentSlot -or $null -eq $script:EditorState) { return }
    if (-not (Update-EditorParametersFromControls)) { return }
    $s = $script:EditorState
    if ($s.SampleStart -lt 0 -or $s.SampleStart -gt $s.LoopStart -or $s.LoopStart + 2L -gt $s.LoopEnd -or $s.LoopEnd -gt $s.SampleEnd -or $s.SampleEnd -gt $s.Frames) {
        [System.Windows.MessageBox]::Show('Markerreihenfolge ungültig. Erforderlich: S.START <= L.START < L.END <= S.END.', 'Slot-Editor', 'OK', 'Warning') | Out-Null; return
    }
    $slotIndex = Get-CurrentSlotIndex
    if ($slotIndex -lt 0) { return }
    try {
        [void](Test-PhoenixWriteAccess)
        $meta = $script:CurrentSlot.WavMetadata
        if (-not $meta.Valid -or $meta.BitsPerSample -ne 16) { throw 'Speichern erfordert eine gültige 16-Bit-PCM-WAV-Datei.' }
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        $analysis = [PhoenixLibrarianAudio]::AnalyzePcm16(
            $script:CurrentSlot.FilePath, [long]$meta.DataOffset, [int]$meta.Channels,
            [long]$s.SampleStart, [long]$s.SampleEnd, [bool]$s.DC, [bool]$s.Normalize)
        $updates = @{
            'SAMPLE_START' = [string]$s.SampleStart
            'LOOP_START' = [string]$s.LoopStart
            'LOOP_END' = [string]$s.LoopEnd
            'SAMPLE_END' = [string]$s.SampleEnd
            'LOOP' = $(if ($s.LoopMode -eq 0) { '0' } else { '1' })
            'LOOP_MODE' = [string]$s.LoopMode
            'LOOP_XFADE_MS' = [string]$s.XFade
            'ROOT' = [string]$s.Root
            'KEY_LOW' = [string]$s.KeyLow
            'KEY_HIGH' = [string]$s.KeyHigh
            'TRIM_ENABLED' = $(if ($s.Trim) { '1' } else { '0' })
            'DC_ENABLED' = $(if ($s.DC) { '1' } else { '0' })
            'DC_OFFSET' = [string]$analysis.DcOffset
            'NORMALIZE_ENABLED' = $(if ($s.Normalize) { '1' } else { '0' })
            'NORMALIZE_GAIN_Q16' = [string]$analysis.NormalizeGainQ16
            'LEVEL' = [string]$s.Level
            'PAN' = [string]$s.Pan
            'VOICE_LIMIT' = [string]$s.Voices
        }
        $cfgPath = Join-Path $script:CurrentBank.Path 'BANK.CFG'
        $wavPath = $script:CurrentSlot.FilePath
        $token = [guid]::NewGuid().ToString('N')
        $cfgTemp = Join-Path $script:CurrentBank.Path ('.BANK.CFG.editor_' + $token)
        $wavTemp = Join-Path $script:CurrentBank.Path ('.SLOT.editor_' + $token + '.WAV')
        $cfgRollback = Join-Path $script:CurrentBank.Path ('.BANK.CFG.rollback_' + $token)
        $wavRollback = Join-Path $script:CurrentBank.Path ('.SLOT.rollback_' + $token + '.WAV')
        Write-ConfigWithSlotUpdates $cfgPath $cfgTemp ($slotIndex + 1) $updates
        [PhoenixLibrarianAudio]::RewriteSmplChunk(
            $wavPath, $wavTemp, [int]$s.Root, [int]$s.LoopMode,
            [uint32]$s.LoopStart, [uint32]$s.LoopEnd, [uint32]$s.SampleRate)
        $cfgMoved = $false; $wavMoved = $false
        try {
            Move-Item -LiteralPath $cfgPath -Destination $cfgRollback -Force; $cfgMoved = $true
            Move-Item -LiteralPath $cfgTemp -Destination $cfgPath -Force
            Move-Item -LiteralPath $wavPath -Destination $wavRollback -Force; $wavMoved = $true
            Move-Item -LiteralPath $wavTemp -Destination $wavPath -Force
            Remove-Item -LiteralPath $cfgRollback -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wavRollback -Force -ErrorAction SilentlyContinue
        } catch {
            if (Test-Path -LiteralPath $cfgPath) { Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue }
            if ($cfgMoved -and (Test-Path -LiteralPath $cfgRollback)) { Move-Item -LiteralPath $cfgRollback -Destination $cfgPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $wavPath) { Remove-Item -LiteralPath $wavPath -Force -ErrorAction SilentlyContinue }
            if ($wavMoved -and (Test-Path -LiteralPath $wavRollback)) { Move-Item -LiteralPath $wavRollback -Destination $wavPath -Force -ErrorAction SilentlyContinue }
            throw
        } finally {
            Remove-Item -LiteralPath $cfgTemp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wavTemp -Force -ErrorAction SilentlyContinue
        }
        $bankName = $script:CurrentBank.Name
        $script:EditorBaselineSignature = Get-EditorStateSignature
        Set-EditorDirty $false
        Add-Log "$bankName / S$($slotIndex + 1): Marker und Parameter gespeichert; WAV-smpl synchronisiert."
        Refresh-And-SelectBank $bankName
        $script:SlotGrid.SelectedIndex = $slotIndex
        [System.Windows.MessageBox]::Show('Slot-Metadaten und WAV-Loop wurden erfolgreich gespeichert.', 'Phoenix Librarian', 'OK', 'Information') | Out-Null
    } catch {
        Add-Log ('Editor-Speichern fehlgeschlagen: ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Speichern fehlgeschlagen', 'OK', 'Error') | Out-Null
    } finally {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
}

function Reload-EditorState {
    if (Test-EditorHasChanges) {
        $answer = [System.Windows.MessageBox]::Show('Nicht gespeicherte PC-Änderungen verwerfen?', 'Editor zurücksetzen', 'YesNo', 'Question')
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    Initialize-EditorState $script:CurrentSlot
}

function Stop-LoopPreview {
    $oldPath=$script:PreviewTempFile
    try { [PhoenixWasapiLiveEngine]::StopVoice([int]$script:WaveformPreviewVoiceId) } catch {}
    # The legacy WPF MediaPlayer is deliberately not used for waveform playback
    # in RC5a because Exclusive WASAPI owns the endpoint.
    try { $script:MediaPlayer.Stop(); $script:MediaPlayer.Close() } catch {}
    $script:MediaPlaying = $false; $script:PreviewMode=''; $script:PreviewSourcePosition=-1L
    if ($script:PreviewTimer) { $script:PreviewTimer.Stop() }
    if($script:PreviewStopwatch){try{$script:PreviewStopwatch.Stop()}catch{}}
    $script:PreviewStopwatch=$null;$script:PreviewDurationSec=0.0
    if ($script:PlayLoopButton) { $script:PlayLoopButton.Content='Loop halten' }
    Draw-Waveform
    $script:PreviewPlayheadLine=$null
    if(-not [string]::IsNullOrWhiteSpace([string]$oldPath)){
        try{[PhoenixWasapiLiveEngine]::UnloadSample($oldPath)}catch{}
        Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
        if($script:PreviewTempFile -eq $oldPath){$script:PreviewTempFile=$null}
    }
    try {
        $gcSummary=[PhoenixWasapiLiveEngine]::EndNoGcPreview()
        Add-Log ('WASAPI RC5l Preview Summary: '+[PhoenixWasapiLiveEngine]::TimingDiagnostics)
        Add-Log ('WASAPI RC5l GC Summary: '+$gcSummary)
        Add-Log ('WASAPI RC5l Health: '+[PhoenixWasapiLiveEngine]::HealthDiagnostics)
    } catch { Add-Log ('WASAPI RC5l GC-Ende Warnung: '+$_.Exception.Message) }
    try {
        [PhoenixWasapiLiveEngine]::Shutdown()
        $profileResult=[PhoenixWasapiLiveEngine]::SetAudioProfile(480)
        Add-Log ('WASAPI RC5l RELEASE: Waveform beendet, Endpoint freigegeben; '+$profileResult)
    } catch { Add-Log ('WASAPI RC5l Release Warnung: '+$_.Exception.Message) }
}

function Get-PreviewTempPath {
    $dir=Join-Path ([IO.Path]::GetTempPath()) 'PhoenixLibrarian'
    if(-not(Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
    # Unique file name prevents stale decoded PCM from a previous editor render.
    return (Join-Path $dir ('phoenix_waveform_preview_'+[guid]::NewGuid().ToString('N')+'.wav'))
}

function Start-LoopPreview {
    param([ValidateSet('HOLD','ONESHOT')][string]$Mode)
    if($null -eq $script:CurrentSlot -or $null -eq $script:EditorState -or -not(Test-Path -LiteralPath $script:CurrentSlot.FilePath)){return}
    try {
        if($script:MediaPlaying){Stop-LoopPreview}
        $tmp=Get-PreviewTempPath; $s=$script:EditorState
        # RC5c: render ONLY the compact edited source S.START..S.END. Do not bake a 30 s loop.
        # DC removal / Normalize are still applied here. The stable native WASAPI mixer owns
        # FORWARD / ALTERNATE / Crossfade exactly once, using relative loop markers below.
        [void][PhoenixLoopPreviewRenderer]::Render($script:CurrentSlot.FilePath,$tmp,[long]$s.SampleStart,[long]$s.LoopStart,[long]$s.LoopEnd,[long]$s.SampleEnd,[int]$s.LoopMode,[int]$s.XFade,[bool]$s.DC,[bool]$s.Normalize,$false,3600.0)
        $profileResult=[PhoenixWasapiLiveEngine]::SetAudioProfile(960); Add-Log ('WASAPI RC5l Profile: '+$profileResult)
        if(-not ([PhoenixWasapiLiveEngine]::Start())){throw ('WASAPI konnte nicht gestartet werden: '+[PhoenixWasapiLiveEngine]::Status)}
        Touch-LiveAudioActivity
        Add-Log ('WASAPI RC5l ON-DEMAND OPEN: '+[PhoenixWasapiLiveEngine]::Status)
        $script:PreviewTempFile=$tmp; $script:PreviewMode=$Mode; $script:PreviewStartedAt=[datetime]::Now; $script:PreviewSourcePosition=[long]$s.SampleStart
        $sourceFrames=[int][Math]::Max(1,([long]$s.SampleEnd-[long]$s.SampleStart))
        $sourceDuration=[Math]::Max(0.001,([double]$sourceFrames/[double][Math]::Max(1,$s.SampleRate)))
        $script:PreviewDurationSec=$(if($Mode -eq 'HOLD') { 30.0 } else { $sourceDuration })
        if(-not [PhoenixWasapiLiveEngine]::Preload($tmp)){throw ('Waveform-WASAPI Preload fehlgeschlagen: '+[PhoenixWasapiLiveEngine]::Status)}
        $gcStart=[PhoenixWasapiLiveEngine]::BeginNoGcPreview(); Add-Log ('WASAPI RC5l No-GC Preview: '+$gcStart)
        $relLoopStart=[int][Math]::Max(0,([long]$s.LoopStart-[long]$s.SampleStart))
        $relLoopEnd=[int][Math]::Max($relLoopStart+1,([long]$s.LoopEnd-[long]$s.SampleStart))
        if($relLoopEnd-gt$sourceFrames){$relLoopEnd=$sourceFrames}
        $nativeLoopMode=$(if($Mode -eq 'HOLD') {[int]$s.LoopMode} else {0})
        # If no valid Phoenix loop is selected, HOLD behaves as a normal source one-shot.
        if($nativeLoopMode-lt1 -or $nativeLoopMode-gt2){$nativeLoopMode=0}
        # v1.0 UI fix: HOLD is a loop-inspection mode visually. The white playhead
        # starts directly at L.START; ONESHOT continues to start at S.START.
        $script:PreviewSourcePosition = if($Mode -eq 'HOLD' -and $nativeLoopMode -ne 0){[long]$s.LoopStart}else{[long]$s.SampleStart}
        $ok=[PhoenixWasapiLiveEngine]::PlayNativePreloaded([int]$script:WaveformPreviewVoiceId,$tmp,[single]1.0,[single]0.0,0,[double]1.0,0,$relLoopStart,$relLoopEnd,$sourceFrames,$nativeLoopMode,[int]$s.XFade)
        if(-not $ok){throw ('Waveform-WASAPI Native Play fehlgeschlagen: '+[PhoenixWasapiLiveEngine]::Status)}
        $script:PreviewStopwatch=[System.Diagnostics.Stopwatch]::StartNew();$script:MediaPlaying=$true
        if($script:PreviewTimer){$script:PreviewTimer.Start()}
        if($script:PlayLoopButton){$script:PlayLoopButton.Content=if($Mode -eq 'HOLD'){'Loop neu starten'}else{'Loop halten'}}
        Add-Log ('Waveform Preview WASAPI NATIVE/COMPACT RC5l GC-ISOLATED: {0}, {1:N2}s, Source={2}f, Loop={3}..{4}, Mode={5}, {6}' -f $Mode,$script:PreviewDurationSec,$sourceFrames,$relLoopStart,$relLoopEnd,$nativeLoopMode,[PhoenixWasapiLiveEngine]::Status)
        Draw-Waveform
        Update-PreviewPlayheadVisual
    } catch {
        $bad=$tmp
        if(-not [string]::IsNullOrWhiteSpace([string]$bad)){try{[PhoenixWasapiLiveEngine]::UnloadSample($bad)}catch{};Remove-Item -LiteralPath $bad -Force -ErrorAction SilentlyContinue}
        $script:MediaPlaying=$false;$script:PreviewStopwatch=$null
        try{[void][PhoenixWasapiLiveEngine]::EndNoGcPreview()}catch{}
        [System.Windows.MessageBox]::Show($_.Exception.Message,'Vorschau fehlgeschlagen','OK','Error')|Out-Null
    }
}

function Update-PreviewPlayheadVisual {
    if(-not $script:WaveformCanvas -or $null -eq $script:EditorState){return}
    $width=[double][math]::Max(2.0,$script:WaveformCanvas.ActualWidth)
    $height=[double][math]::Max(2.0,$script:WaveformCanvas.ActualHeight)
    $frames=[double][math]::Max(1,[long]$script:EditorState.Frames)
    $px=[math]::Max(0.0,[math]::Min($width-1.0,(([double]$script:PreviewSourcePosition/$frames)*($width-1.0))))
    if($null -eq $script:PreviewPlayheadLine){
        $line=New-Object System.Windows.Shapes.Line
        $line.Stroke=[System.Windows.Media.Brushes]::White
        $line.StrokeThickness=2.2
        $line.Opacity=1.0
        $line.IsHitTestVisible=$false
        $script:PreviewPlayheadLine=$line
        [void]$script:WaveformCanvas.Children.Add($line)
    } elseif(-not $script:WaveformCanvas.Children.Contains($script:PreviewPlayheadLine)) {
        [void]$script:WaveformCanvas.Children.Add($script:PreviewPlayheadLine)
    }
    $script:PreviewPlayheadLine.X1=$px;$script:PreviewPlayheadLine.X2=$px
    $script:PreviewPlayheadLine.Y1=0.0;$script:PreviewPlayheadLine.Y2=$height
}

function Update-PreviewPlayhead {
    if(-not $script:MediaPlaying -or $null -eq $script:EditorState -or $null -eq $script:PreviewStopwatch){return}
    $s=$script:EditorState; $sr=[double][math]::Max(1,$s.SampleRate); $elapsed=[double]$script:PreviewStopwatch.Elapsed.TotalSeconds
    if($script:PreviewDurationSec -gt 0 -and $elapsed -ge $script:PreviewDurationSec){Stop-LoopPreview;return}
    $frames=[long][math]::Floor($elapsed*$sr)
    if($script:PreviewMode -eq 'ONESHOT' -or $s.LoopMode -eq 0){$pos=[long]$s.SampleStart+$frames; if($pos -gt $s.SampleEnd){$pos=$s.SampleEnd}}
    else {
        # v1.0 UI fix: HOLD playhead represents the loop itself, not the attack portion.
        $rel=$frames; $len=[long][math]::Max(1,$s.LoopEnd-$s.LoopStart)
        if($s.LoopMode -eq 1){$pos=[long]$s.LoopStart+($rel%$len)}
        else {$period=[long][math]::Max(1,2*$len-2);$phase=$rel%$period;$pos=if($phase-lt $len){[long]$s.LoopStart+$phase}else{[long]$s.LoopEnd-2-($phase-$len)}}
    }
    $script:PreviewSourcePosition=[long]$pos; Update-PreviewPlayheadVisual
}

function Request-PreviewRefresh {
    if(-not $script:MediaPlaying){return}
    $script:PreviewRefreshPending=$true
    if($script:PreviewRefreshTimer){$script:PreviewRefreshTimer.Stop();$script:PreviewRefreshTimer.Start()}
}

function Toggle-WavPlayback { Start-LoopPreview 'ONESHOT' }

function Export-FactoryLibrary {
    $banks=@($script:BankGrid.ItemsSource)
    if($banks.Count -eq 0){[System.Windows.MessageBox]::Show('Keine Banken entsprechen dem aktuellen Filter.','Factory Library','OK','Information')|Out-Null;return}
    $dlg=New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title='Phoenix Factory Library als ZIP exportieren'
    $dlg.Filter='ZIP-Archiv (*.zip)|*.zip'
    $dlg.FileName=('Phoenix_Factory_Library_{0}.zip' -f (Get-Date -Format 'yyyyMMdd'))
    if($dlg.ShowDialog()-ne [System.Windows.Forms.DialogResult]::OK){return}
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('PhoenixFactory_'+[guid]::NewGuid().ToString('N'))
    try{
        New-Item -ItemType Directory -Path $stage -Force|Out-Null
        $banksDir=Join-Path $stage 'BANKS';New-Item -ItemType Directory -Path $banksDir -Force|Out-Null
        $rows=New-Object System.Collections.Generic.List[object]
        $index=1
        foreach($b in $banks){
            $targetName=('BANK{0:D2}' -f $index)
            Copy-DirectorySafe $b.Path (Join-Path $banksDir $targetName)
            $mode='KEYZONE';if($null-ne$b.Config -and ([int](Convert-ToInt64Safe (Get-ValueOrDefault $b.Config.Global 'QUATTRO_MODE' 0) 0))-eq 1){$mode='MULTI'}
            $rows.Add([pscustomobject]@{LibraryBank=$targetName;SourceBank=$b.Name;Name=(Get-BankInfoValue $b.Info 'NAME' $b.Name);Category=(Get-BankInfoValue $b.Info 'CATEGORY' 'Uncategorized');Tags=(Get-BankInfoValue $b.Info 'TAGS' '');Author=(Get-BankInfoValue $b.Info 'AUTHOR' '');License=(Get-BankInfoValue $b.Info 'LICENSE' '');Routing=$mode;Slots=$b.RecordedSlots;SizeBytes=$b.Size;Status=$b.Status})
            $index++
        }
        $rows|Export-Csv -LiteralPath (Join-Path $stage 'CONTENTS.csv') -NoTypeInformation -Encoding UTF8
        $info=@("PHOENIX FACTORY LIBRARY","VERSION=1","CREATED="+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),"BANK_COUNT="+$banks.Count,"SOURCE=Phoenix Librarian v$script:AppVersion")
        [IO.File]::WriteAllLines((Join-Path $stage 'LIBRARY.INFO'),$info,$script:Utf8NoBom)
        $md=New-Object System.Collections.Generic.List[string]
        $md.Add('# Phoenix Factory Library');$md.Add('');$md.Add(('Erstellt mit Phoenix Librarian v{0} am {1}.' -f $script:AppVersion,(Get-Date -Format 'dd.MM.yyyy HH:mm')));$md.Add('');$md.Add('| Bank | Name | Kategorie | Routing | Slots |');$md.Add('|---|---|---|---|---:|')
        foreach($r in $rows){$md.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $r.LibraryBank,($r.Name-replace '\|','/'),($r.Category-replace '\|','/'),$r.Routing,$r.Slots))}
        [IO.File]::WriteAllLines((Join-Path $stage 'README.md'),$md,$script:Utf8NoBom)
        if(Test-Path -LiteralPath $dlg.FileName){Remove-Item -LiteralPath $dlg.FileName -Force}
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [IO.Compression.ZipFile]::CreateFromDirectory($stage,$dlg.FileName,[IO.Compression.CompressionLevel]::Optimal,$false)
        Add-Log ("Factory Library exportiert: {0} Banken -> {1}" -f $banks.Count,$dlg.FileName)
        [System.Windows.MessageBox]::Show(("Factory Library mit {0} Banken erstellt.`r`n`r`n{1}" -f $banks.Count,$dlg.FileName),'Factory Library','OK','Information')|Out-Null
    }catch{Add-Log ('Factory-Export Fehler: '+$_.Exception.Message);[System.Windows.MessageBox]::Show($_.Exception.Message,'Factory-Export fehlgeschlagen','OK','Error')|Out-Null}
    finally{Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
}

function Get-ComboTextSafe {
    param($Combo,[string]$Default='Alle')
    if($null -eq $Combo -or $Combo.SelectedIndex -lt 0){return $Default}
    $item=$Combo.SelectedItem
    if($null -ne $item -and $null -ne $item.Content){return [string]$item.Content}
    if(-not [string]::IsNullOrWhiteSpace([string]$Combo.Text)){return [string]$Combo.Text}
    return $Default
}

function Apply-BankFilter {
    if (-not $script:BankGrid) { return }
    $query = if ($script:BankFilterBox) { $script:BankFilterBox.Text.Trim() } else { '' }
    $category=Get-ComboTextSafe $script:CategoryFilterCombo
    $routing=Get-ComboTextSafe $script:RoutingFilterCombo
    $status=Get-ComboTextSafe $script:StatusFilterCombo
    $filtered = @($script:BankRecords | Where-Object {
        $b=$_
        $display=Get-BankInfoValue $b.Info 'NAME' $b.Name
        $cat=Get-BankInfoValue $b.Info 'CATEGORY' 'Uncategorized'
        $tags=Get-BankInfoValue $b.Info 'TAGS' ''
        $author=Get-BankInfoValue $b.Info 'AUTHOR' ''
        $desc=Get-BankInfoValue $b.Info 'DESCRIPTION' ''
        $mode='KEYZONE'
        if($null -ne $b.Config){$mode=if(([int](Convert-ToInt64Safe (Get-ValueOrDefault $b.Config.Global 'QUATTRO_MODE' 0) 0))-eq 1){'MULTI'}else{'KEYZONE'}}
        $haystack=@($b.Name,$display,$cat,$tags,$author,$desc,$b.Status,($b.Issues -join ' '),($b.Slots.SampleName -join ' ')) -join ' '
        $queryOk=[string]::IsNullOrWhiteSpace($query) -or $haystack.IndexOf($query,[System.StringComparison]::OrdinalIgnoreCase)-ge 0
        $catOk=($category -eq 'Alle') -or ($cat -eq $category)
        $routeOk=($routing -eq 'Alle') -or ($mode -eq $routing)
        $statusOk=switch($status){
            'OK' {$b.Issues.Count -eq 0}
            'Hinweise' {$b.Issues.Count -gt 0 -and $b.Status -ne 'FEHLER'}
            'Fehler' {$b.Status -eq 'FEHLER'}
            'Belegt' {$b.RecordedSlots -gt 0}
            'Leer' {$b.RecordedSlots -eq 0}
            default {$true}
        }
        $queryOk -and $catOk -and $routeOk -and $statusOk
    })
    $script:BankGrid.ItemsSource = $null
    $script:BankGrid.ItemsSource = $filtered
    $script:StatusText.Text = "$($filtered.Count) von $($script:BankRecords.Count) Bänken angezeigt"
    if ($filtered.Count -gt 0) { $script:BankGrid.SelectedIndex = 0 } else { Clear-BankDetails }
}

function Clear-BankDetails {
    $script:CurrentBank = $null; $script:CurrentSlot = $null; $script:EditorState = $null
    $script:EditorBaselineSignature = $null
    $script:BankTitle.Text = 'Keine Bank ausgewählt'; $script:BankSummary.Text = ''
    $script:SlotGrid.ItemsSource = $null; $script:MarkerGrid.ItemsSource = $null
    $script:IssueList.ItemsSource = $null; $script:RawConfigBox.Text = ''
    if($script:PatternStepGrid){$script:PatternStepGrid.ItemsSource=$null;$script:PatternSummaryGrid.ItemsSource=$null;$script:PatternStatusText.Text=''}
    if($script:SongGrid){$script:SongGrid.ItemsSource=$null;$script:SongStatusText.Text=''}
    if($script:EffectsGrid){$script:EffectsGrid.ItemsSource=$null}; if($script:EchoDelayBox){$script:EchoDelayBox.Text=''}; if($script:EchoFeedbackBox){$script:EchoFeedbackBox.Text=''}; if($script:EchoMixBox){$script:EchoMixBox.Text=''}
    if ($script:WaveformCanvas) { $script:WaveformCanvas.Children.Clear() }
    Set-EditorDirty $false
}

function Show-BankDetails {
    param($Bank)
    if ($script:SelectionGuard) { return }
    if ($null -eq $Bank) { Clear-BankDetails; return }
    if ((Test-EditorHasChanges) -and $null -ne $script:CurrentBank -and $script:CurrentBank.Name -ne $Bank.Name) {
        $answer = [System.Windows.MessageBox]::Show('Nicht gespeicherte Editor-Änderungen verwerfen und Bank wechseln?', 'Bank wechseln', 'YesNo', 'Question')
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            $script:SelectionGuard = $true
            try {
                for ($i=0; $i -lt $script:BankGrid.Items.Count; $i++) {
                    if ($script:BankGrid.Items[$i].Name -eq $script:CurrentBank.Name) { $script:BankGrid.SelectedIndex = $i; break }
                }
            } finally { $script:SelectionGuard = $false }
            return
        }
    }
    $script:CurrentBank = $Bank
    $displayName = Get-BankInfoValue $Bank.Info 'NAME' $Bank.Name
    $script:BankTitle.Text = if ([string]::IsNullOrWhiteSpace($displayName) -or $displayName -eq $Bank.Name) { $Bank.Name } else { "$($Bank.Name) - $displayName" }
    $script:BankSummary.Text = "Version $($Bank.Version)  |  $($Bank.RecordedSlots)/4 Slots  |  $($Bank.SizeText)  |  geändert $($Bank.Modified.ToString('dd.MM.yyyy HH:mm'))"
    if ($script:BankNameBox) {
        $script:BankNameBox.Text = Get-BankInfoValue $Bank.Info 'NAME' $Bank.Name
        $script:BankCategoryBox.Text = Get-BankInfoValue $Bank.Info 'CATEGORY' 'Uncategorized'
        $script:BankAuthorBox.Text = Get-BankInfoValue $Bank.Info 'AUTHOR' 'RealTimeAudioLab'
        $script:BankDescriptionBox.Text = Get-BankInfoValue $Bank.Info 'DESCRIPTION' ''
        $script:BankLicenseBox.Text = Get-BankInfoValue $Bank.Info 'LICENSE' 'All rights reserved'
        $script:BankTagsBox.Text = Get-BankInfoValue $Bank.Info 'TAGS' ''
        $script:BankTemplateText.Text = Get-BankInfoValue $Bank.Info 'TEMPLATE' 'EMPTY BANK'
        for ($i=1; $i -le 4; $i++) { $box = Get-Variable -Scope Script -Name ("Slot{0}NameBox" -f $i) -ValueOnly; $box.Text = Get-BankInfoValue $Bank.Info ("SLOT{0}_NAME" -f $i) ("S{0}" -f $i) }
    }
    $script:SlotGrid.ItemsSource = $null; $script:SlotGrid.ItemsSource = $Bank.Slots
    $script:MarkerGrid.ItemsSource = $null; $script:MarkerGrid.ItemsSource = $Bank.Slots
    $script:IssueList.ItemsSource = $null
    $script:IssueList.ItemsSource = if ($Bank.Issues.Count -eq 0) { @('Keine Inkonsistenzen erkannt.') } else { $Bank.Issues }
    $script:RawConfigBox.Text = if ($null -ne $Bank.Config) { [string]::Join("`r`n", $Bank.Config.RawLines) } else { '' }
    Sync-KeyRangeEditor
    Update-AllInspectors
    Set-EditorDirty $false
    # Live-Audio-Cache beim Bankwechsel vorbereiten. Das verschiebt die Renderzeit
    # vom ersten Tastendruck auf die Bankauswahl und reduziert die Spiel-Latenz.
    try { Warm-LivePreviewCache } catch { Add-Log ('Live-Cache Startfehler: '+$_.Exception.Message) }
    if ($Bank.Slots.Count -gt 0) {
        $first = 0
        for ($i=0; $i -lt $Bank.Slots.Count; $i++) { if ($Bank.Slots[$i].Recorded -eq 'YES') { $first=$i; break } }
        $script:SlotGrid.SelectedIndex = $first
    }
}

function Update-WaveformSelection {
    if ($script:SelectionGuard) { return }
    if ((Test-EditorHasChanges) -and $null -ne $script:CurrentSlot -and $null -ne $script:SlotGrid.SelectedItem -and $script:CurrentSlot.Slot -ne $script:SlotGrid.SelectedItem.Slot) {
        $answer = [System.Windows.MessageBox]::Show('Nicht gespeicherte Editor-Änderungen verwerfen und Slot wechseln?', 'Slot wechseln', 'YesNo', 'Question')
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            $script:SelectionGuard = $true
            try {
                for ($i=0; $i -lt $script:SlotGrid.Items.Count; $i++) {
                    if ($script:SlotGrid.Items[$i].Slot -eq $script:CurrentSlot.Slot) { $script:SlotGrid.SelectedIndex = $i; break }
                }
            } finally { $script:SelectionGuard = $false }
            return
        }
    }
    $script:CurrentSlot = $script:SlotGrid.SelectedItem
    if ($null -eq $script:CurrentSlot) { Initialize-EditorState $null; return }
    Initialize-EditorState $script:CurrentSlot
}



function Get-KeyRangeControls {
    param([int]$SlotNo)
    return [pscustomobject]@{
        Low = Get-Variable -Scope Script -Name ("S{0}LowCombo" -f $SlotNo) -ValueOnly
        Root = Get-Variable -Scope Script -Name ("S{0}RootCombo" -f $SlotNo) -ValueOnly
        High = Get-Variable -Scope Script -Name ("S{0}HighCombo" -f $SlotNo) -ValueOnly
        Text = Get-Variable -Scope Script -Name ("S{0}RangeText" -f $SlotNo) -ValueOnly
        Channel = Get-Variable -Scope Script -Name ("S{0}ChannelCombo" -f $SlotNo) -ValueOnly
        MultiRoot = Get-Variable -Scope Script -Name ("S{0}MultiRootCombo" -f $SlotNo) -ValueOnly
        MultiText = Get-Variable -Scope Script -Name ("S{0}MultiText" -f $SlotNo) -ValueOnly
    }
}

function Get-QuattroModeValue {
    if ($null -eq $script:QuattroModeCombo -or $script:QuattroModeCombo.SelectedIndex -lt 0) { return 0 }
    return [int]$script:QuattroModeCombo.SelectedIndex
}

function Update-QuattroModeView {
    if ($null -eq $script:KeyzonePanel -or $null -eq $script:MultiPanel) { return }
    $multi = (Get-QuattroModeValue) -eq 1
    $script:KeyzonePanel.Visibility = if ($multi) { 'Collapsed' } else { 'Visible' }
    $script:MultiPanel.Visibility = if ($multi) { 'Visible' } else { 'Collapsed' }
    if ($script:KeyRangeDescription) {
        $script:KeyRangeDescription.Text = if ($multi) {
            'MULTI: Jeder Slot empfängt auf seinem eigenen MIDI-Kanal über den vollständigen Notenbereich.'
        } else {
            'KEYZONE: Low, Root und High verteilen die vier Slots über eine gemeinsame MIDI-Tastatur.'
        }
    }
    if (-not $multi) { Draw-KeyRangeKeyboard }
}

function Sync-KeyRangeEditor {
    if ($null -eq $script:CurrentBank) { return }
    $script:KeyRangeSyncing = $true
    try {
        $mode = [int](Convert-ToInt64Safe (Get-ValueOrDefault $script:CurrentBank.Config.Global 'QUATTRO_MODE' 0) 0)
        $script:QuattroModeCombo.SelectedIndex = [math]::Max(0,[math]::Min(1,$mode))
        for ($i=0; $i -lt 4; $i++) {
            $controls = Get-KeyRangeControls ($i+1)
            $slot = $script:CurrentBank.Slots[$i]
            $low = [int](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'KEY_LOW' 0) 0)
            $root = [int](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'ROOT' 60) 60)
            $high = [int](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'KEY_HIGH' 127) 127)
            $channel = [int](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'MIDI_CHANNEL' ($i+1)) ($i+1))
            $controls.Low.SelectedIndex=[math]::Max(0,[math]::Min(127,$low))
            $controls.Root.SelectedIndex=[math]::Max(0,[math]::Min(127,$root))
            $controls.High.SelectedIndex=[math]::Max(0,[math]::Min(127,$high))
            $controls.MultiRoot.SelectedIndex=[math]::Max(0,[math]::Min(127,$root))
            $controls.Channel.SelectedIndex=[math]::Max(0,[math]::Min(15,$channel-1))
            $controls.Text.Text = "$(Get-MidiNoteName $low) bis $(Get-MidiNoteName $high) · Root $(Get-MidiNoteName $root)"
            $controls.MultiText.Text = "Kanal $channel · Root $(Get-MidiNoteName $root) · voller Bereich"
        }
    } finally { $script:KeyRangeSyncing = $false }
    Update-QuattroModeView
}

function Draw-KeyRangeKeyboard {
    if (-not $script:KeyRangeCanvas -or (Get-QuattroModeValue) -eq 1) { return }
    $script:KeyRangeCanvas.Children.Clear()
    $w=[math]::Max(640.0,$script:KeyRangeCanvas.ActualWidth); $h=[math]::Max(180.0,$script:KeyRangeCanvas.ActualHeight)
    $left=38.0; $top=8.0; $keyboardW=$w-$left-8.0; $rowH=42.0
    $blackNotes=@(1,3,6,8,10)
    for ($n=0; $n -le 127; $n++) {
        $x=$left+($n/128.0)*$keyboardW; $x2=$left+(($n+1)/128.0)*$keyboardW
        $isBlack=$blackNotes -contains ($n%12)
        $rect=New-Object System.Windows.Shapes.Rectangle; $rect.Width=[math]::Max(1.0,$x2-$x); $rect.Height=25; $rect.Fill=New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($(if($isBlack){'#39414B'}else{'#FFFFFF'}))); $rect.Stroke=New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString('#9CA9B5')); $rect.StrokeThickness=0.35
        [System.Windows.Controls.Canvas]::SetLeft($rect,$x); [System.Windows.Controls.Canvas]::SetTop($rect,$top); [void]$script:KeyRangeCanvas.Children.Add($rect)
    }
    $colors=@('#F3D05C','#70D89A','#EE8A5B','#D77AE8')
    for ($i=0; $i -lt 4; $i++) {
        $c=Get-KeyRangeControls ($i+1); $low=[math]::Max(0,$c.Low.SelectedIndex); $root=[math]::Max(0,$c.Root.SelectedIndex); $high=[math]::Max(0,$c.High.SelectedIndex)
        $y=$top+32+($i*$rowH); $x1=$left+($low/128.0)*$keyboardW; $x2=$left+(($high+1)/128.0)*$keyboardW
        $label=New-Object System.Windows.Controls.TextBlock; $label.Text="S$($i+1)"; $label.FontWeight='Bold'; $label.Foreground=New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($colors[$i])); [System.Windows.Controls.Canvas]::SetLeft($label,5); [System.Windows.Controls.Canvas]::SetTop($label,$y+8); [void]$script:KeyRangeCanvas.Children.Add($label)
        $bar=New-Object System.Windows.Shapes.Rectangle; $bar.Width=[math]::Max(2.0,$x2-$x1); $bar.Height=25; $bar.Fill=New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($colors[$i])); $bar.Opacity=0.72; $bar.Stroke=New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString('#17212B')); $bar.StrokeThickness=1
        [System.Windows.Controls.Canvas]::SetLeft($bar,$x1); [System.Windows.Controls.Canvas]::SetTop($bar,$y); [void]$script:KeyRangeCanvas.Children.Add($bar)
        $rx=$left+($root/128.0)*$keyboardW; $line=New-Object System.Windows.Shapes.Line; $line.X1=$rx; $line.X2=$rx; $line.Y1=$y-2; $line.Y2=$y+29; $line.Stroke=New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString('#101010')); $line.StrokeThickness=2; [void]$script:KeyRangeCanvas.Children.Add($line)
    }
}

function Update-KeyRangeText {
    param([int]$SlotNo)
    if ($script:KeyRangeSyncing) { return }
    $c=Get-KeyRangeControls $SlotNo
    $low=[math]::Max(0,$c.Low.SelectedIndex); $root=[math]::Max(0,$c.Root.SelectedIndex); $high=[math]::Max(0,$c.High.SelectedIndex)
    $script:KeyRangeSyncing=$true
    try { $c.MultiRoot.SelectedIndex=$root } finally { $script:KeyRangeSyncing=$false }
    $c.Text.Text="$(Get-MidiNoteName $low) bis $(Get-MidiNoteName $high) · Root $(Get-MidiNoteName $root)"
    $channel=[math]::Max(1,$c.Channel.SelectedIndex+1); $c.MultiText.Text="Kanal $channel · Root $(Get-MidiNoteName $root) · voller Bereich"
    Draw-KeyRangeKeyboard
}

function Update-MultiRoutingText {
    param([int]$SlotNo)
    if ($script:KeyRangeSyncing) { return }
    $c=Get-KeyRangeControls $SlotNo
    $root=[math]::Max(0,$c.MultiRoot.SelectedIndex); $channel=[math]::Max(1,$c.Channel.SelectedIndex+1)
    $script:KeyRangeSyncing=$true
    try {
        $c.Root.SelectedIndex=$root
        if ($root -lt $c.Low.SelectedIndex) { $c.Low.SelectedIndex=$root }
        if ($root -gt $c.High.SelectedIndex) { $c.High.SelectedIndex=$root }
    } finally { $script:KeyRangeSyncing=$false }
    $c.MultiText.Text="Kanal $channel · Root $(Get-MidiNoteName $root) · voller Bereich"
    $low=[math]::Max(0,$c.Low.SelectedIndex); $high=[math]::Max(0,$c.High.SelectedIndex)
    $c.Text.Text="$(Get-MidiNoteName $low) bis $(Get-MidiNoteName $high) · Root $(Get-MidiNoteName $root)"
}

function Set-KeyRangePreset {
    param([string]$Preset)
    $ranges = switch ($Preset) {
        'EQUAL' { @(@(0,24,31),@(32,48,63),@(64,72,95),@(96,108,127)) }
        'DRUM' { @(@(36,36,36),@(38,38,38),@(42,42,42),@(46,46,46)) }
        default { @(@(0,60,127),@(0,60,127),@(0,60,127),@(0,60,127)) }
    }
    $script:KeyRangeSyncing=$true
    try { for($i=0;$i -lt 4;$i++){ $c=Get-KeyRangeControls ($i+1); $c.Low.SelectedIndex=$ranges[$i][0]; $c.Root.SelectedIndex=$ranges[$i][1]; $c.MultiRoot.SelectedIndex=$ranges[$i][1]; $c.High.SelectedIndex=$ranges[$i][2]; $c.Text.Text="$(Get-MidiNoteName $ranges[$i][0]) bis $(Get-MidiNoteName $ranges[$i][2]) · Root $(Get-MidiNoteName $ranges[$i][1])" } } finally { $script:KeyRangeSyncing=$false }
    Draw-KeyRangeKeyboard
}

function Set-MultiChannelPreset {
    $script:KeyRangeSyncing=$true
    try { for($i=0;$i -lt 4;$i++){ $c=Get-KeyRangeControls ($i+1); $c.Channel.SelectedIndex=$i; $root=[math]::Max(0,$c.MultiRoot.SelectedIndex); $c.MultiText.Text="Kanal $($i+1) · Root $(Get-MidiNoteName $root) · voller Bereich" } } finally { $script:KeyRangeSyncing=$false }
}

function Save-QuattroRouting {
    if ($null -eq $script:CurrentBank) { return }
    try {
        [void](Test-PhoenixWriteAccess)
        $cfgPath=Join-Path $script:CurrentBank.Path 'BANK.CFG'; $temp=Join-Path $script:CurrentBank.Path ('.BANK.CFG.routing_'+[guid]::NewGuid().ToString('N'))
        $routingMode = Get-QuattroModeValue
        Write-ConfigWithGlobalUpdates $cfgPath $temp @{ 'QUATTRO_MODE'=[string]$routingMode }
        for($i=0;$i -lt 4;$i++){
            $c=Get-KeyRangeControls ($i+1)
            $low=$c.Low.SelectedIndex; $high=$c.High.SelectedIndex; $channel=$c.Channel.SelectedIndex+1
            $root = if($routingMode -eq 1){ $c.MultiRoot.SelectedIndex } else { $c.Root.SelectedIndex }
            if($routingMode -eq 0){
                if($low -lt 0 -or $root -lt 0 -or $high -lt 0 -or $low -gt $high){ throw "S$($i+1): ungültiger Tastaturbereich." }
                if($root -lt $low -or $root -gt $high){ throw "S$($i+1): Root Note liegt außerhalb des Bereichs." }
            } else {
                if($root -lt 0 -or $root -gt 127){ throw "S$($i+1): Root Note muss zwischen 0 und 127 liegen." }
                if($channel -lt 1 -or $channel -gt 16){ throw "S$($i+1): MIDI-Kanal muss zwischen 1 und 16 liegen." }
            }
            $next=$temp+'.next'; Write-ConfigWithSlotUpdates $temp $next ($i+1) @{ 'KEY_LOW'=[string]$low; 'ROOT'=[string]$root; 'KEY_HIGH'=[string]$high; 'MIDI_CHANNEL'=[string]$channel }; Move-Item -LiteralPath $next -Destination $temp -Force
        }
        Move-Item -LiteralPath $temp -Destination $cfgPath -Force
        $modeName=if((Get-QuattroModeValue)-eq 1){'MULTI'}else{'KEYZONE'}
        $name=$script:CurrentBank.Name; Add-Log "${name}: Quattro-Routing $modeName gespeichert."; Refresh-And-SelectBank $name
    } catch { Add-Log ('Quattro-Routing konnte nicht gespeichert werden: '+$_.Exception.Message); [System.Windows.MessageBox]::Show($_.Exception.Message,'Quattro-Routing','OK','Error')|Out-Null }
}

[xml]
# -----------------------------------------------------------------------------
# v0.9.0: Sequencer, Pattern, Song and Effects Inspector
# Read-only inspector for the exact C028e firmware formats:
# PATTERNS.CFG VERSION=1, SONG.CFG VERSION=2 and BANK.CFG echo/effect values.
# -----------------------------------------------------------------------------
function Read-PhoenixPatterns {
    param([string]$BankPath)
    $result = [ordered]@{ Exists=$false; Valid=$true; CurrentPattern=1; ClockMode='INT'; BPM=120; Patterns=@() ; Error='' }
    for($p=1;$p -le 4;$p++){
        $tracks=@()
        for($t=1;$t -le 4;$t++){
            $steps=@()
            for($st=1;$st -le 16;$st++){
                $steps += [pscustomobject]@{ Step=$st; Active=$false; Note=60+2*($t-1); NoteText=(Get-MidiNoteName (60+2*($t-1))); Velocity=100; Gate=50 }
            }
            $tracks += [pscustomobject]@{ Track=$t; Length=16; Steps=$steps }
        }
        $result.Patterns += [pscustomobject]@{ Pattern=$p; Tracks=$tracks }
    }
    $path=Join-Path $BankPath 'PATTERNS.CFG'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ return [pscustomobject]$result }
    $result.Exists=$true
    try{
        $pat=0
        foreach($raw in [IO.File]::ReadAllLines($path)){
            $line=$raw.Trim(); if(-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')){continue}
            if($line -match '^CURRENT_PATTERN=(\d+)$'){ $result.CurrentPattern=[Math]::Max(1,[Math]::Min(4,[int]$Matches[1])); continue }
            if($line -match '^CLOCK_MODE=(INT|EXT)$'){ $result.ClockMode=$Matches[1]; continue }
            if($line -match '^BPM=(\d+)$'){ $result.BPM=[Math]::Max(40,[Math]::Min(240,[int]$Matches[1])); continue }
            if($line -match '^\[P([1-4])\]$'){ $pat=[int]$Matches[1]; continue }
            if($pat -gt 0 -and $line -match '^TRACK([1-4])_LENGTH=(\d+)$'){
                $t=[int]$Matches[1]; $result.Patterns[$pat-1].Tracks[$t-1].Length=[Math]::Max(1,[Math]::Min(16,[int]$Matches[2])); continue
            }
            if($pat -gt 0 -and $line -match '^T([1-4])_STEP(\d{1,2})=(\d+),(\d+),(\d+),(\d+)$'){
                $t=[int]$Matches[1]; $st=[int]$Matches[2]
                if($st -ge 1 -and $st -le 16){
                    $obj=$result.Patterns[$pat-1].Tracks[$t-1].Steps[$st-1]
                    $obj.Active=([int]$Matches[3] -ne 0)
                    $obj.Note=[Math]::Max(0,[Math]::Min(127,[int]$Matches[4])); $obj.NoteText=Get-MidiNoteName $obj.Note
                    $obj.Velocity=[Math]::Max(1,[Math]::Min(127,[int]$Matches[5]))
                    $obj.Gate=[Math]::Max(10,[Math]::Min(100,[int]$Matches[6]))
                }
            }
        }
    }catch{ $result.Valid=$false; $result.Error=$_.Exception.Message }
    return [pscustomobject]$result
}

function Read-PhoenixSong {
    param([string]$BankPath)
    $entries=@(); for($i=1;$i -le 16;$i++){ $entries += [pscustomobject]@{ Position=$i; Pattern='END'; Repeats=''; End=$true } }
    $result=[ordered]@{ Exists=$false; Valid=$true; LoopMode=1; LoopModeText='SONG'; LoopStart=1; LoopEnd=1; Entries=$entries; Error='' }
    $path=Join-Path $BankPath 'SONG.CFG'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ return [pscustomobject]$result }
    $result.Exists=$true
    try{
        foreach($raw in [IO.File]::ReadAllLines($path)){
            $line=$raw.Trim(); if(-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')){continue}
            if($line -match '^LOOP_MODE=(\d+)$'){ $result.LoopMode=[Math]::Max(0,[Math]::Min(2,[int]$Matches[1])); continue }
            if($line -match '^LOOP_START=(\d+)$'){ $result.LoopStart=[Math]::Max(1,[Math]::Min(16,[int]$Matches[1])); continue }
            if($line -match '^LOOP_END=(\d+)$'){ $result.LoopEnd=[Math]::Max(1,[Math]::Min(16,[int]$Matches[1])); continue }
            if($line -match '^POS(\d{1,2})=(.+)$'){
                $pos=[int]$Matches[1]; $data=$Matches[2].Trim().ToUpperInvariant()
                if($pos -ge 1 -and $pos -le 16){
                    if($data -eq 'END'){ $result.Entries[$pos-1]=[pscustomobject]@{Position=$pos;Pattern='END';Repeats='';End=$true} }
                    elseif($data -match '^P([1-4]),(\d+)$'){
                        $rep=[Math]::Max(1,[Math]::Min(16,[int]$Matches[2]))
                        $result.Entries[$pos-1]=[pscustomobject]@{Position=$pos;Pattern=('P'+$Matches[1]);Repeats=$rep;End=$false}
                    }
                }
            }
        }
        $result.LoopModeText=@('OFF','SONG','PATTERN')[$result.LoopMode]
    }catch{ $result.Valid=$false; $result.Error=$_.Exception.Message }
    return [pscustomobject]$result
}

function Get-ConfigInt {
    param($Dictionary,[string]$Key,[int]$Default=0)
    return [int](Convert-ToInt64Safe (Get-ValueOrDefault $Dictionary $Key $Default) $Default)
}

function Read-PhoenixEffects {
    param($Bank)
    $g=$Bank.Config.Global
    $slots=@()
    for($i=0;$i -lt 4;$i++){
        $r=$Bank.Config.Slots[$i]
        $slots += [pscustomobject]@{
            Slot=('S'+($i+1)); EchoSend=(Get-ConfigInt $r 'ECHO_SEND' 0); ReverbSend=(Get-ConfigInt $r 'REVERB_SEND' 0)
            FilterCutoff=(Get-ConfigInt $r 'FILTER_CUTOFF' 100); Resonance=(Get-ConfigInt $r 'FILTER_RESONANCE' 0)
            FilterEnv=(Get-ConfigInt $r 'FILTER_ENV_AMOUNT' 0); FilterVelocity=(Get-ConfigInt $r 'FILTER_VELOCITY' 0)
            FilterKeytrack=(Get-ConfigInt $r 'FILTER_KEYTRACK' 0)
            VintagePreset=(Get-ConfigInt $r 'VINTAGE_PRESET' 0); VintageRate=(Get-ConfigInt $r 'VINTAGE_SAMPLE_RATE' 0)
            VintageBits=(Get-ConfigInt $r 'VINTAGE_BIT_DEPTH' 0); VintageFilter=(Get-ConfigInt $r 'VINTAGE_FILTER' 0); VintageJitter=(Get-ConfigInt $r 'VINTAGE_JITTER' 0)
        }
    }
    return [pscustomobject]@{
        EchoDelay=(Get-ConfigInt $g 'ECHO_DELAY_MS' 250); EchoFeedback=(Get-ConfigInt $g 'ECHO_FEEDBACK' 35); EchoMix=(Get-ConfigInt $g 'ECHO_MIX' 20); ReverbSize=(Get-ConfigInt $g 'REVERB_SIZE' 55); ReverbDecay=(Get-ConfigInt $g 'REVERB_DECAY' 55); ReverbDamp=(Get-ConfigInt $g 'REVERB_DAMP' 45); ReverbMix=(Get-ConfigInt $g 'REVERB_MIX' 20); Slots=$slots
    }
}


# -----------------------------------------------------------------------------
# v0.9.9 Phase 14: Pattern/Song transport, internal PC audio and Windows MIDI output
# -----------------------------------------------------------------------------
$script:MidiHandle = [IntPtr]::Zero
$script:MidiDeviceId = -1
$script:TransportTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:TransportTimer.Interval = [TimeSpan]::FromMilliseconds(5)
$script:TransportClock = New-Object System.Diagnostics.Stopwatch
$script:TransportState = $null
$script:TransportActiveNotes = New-Object System.Collections.ArrayList
$script:TransportAudioVoices = New-Object System.Collections.ArrayList


# Offline Pattern/Song Renderer (v0.9.9g): renders a stable preview WAV before playback.
if(-not ('PhoenixOfflineRenderer' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.IO;

public static class PhoenixOfflineRenderer {
    sealed class Sample { public float[] L,R; public int Rate; public string Info; }
    sealed class Ev { public int Slot; public long Start,Length; public int Note,Root,Velocity; public double Level,Pan; public int EchoSend,Cutoff,Resonance,FilterEnv,FilterVelocity,FilterKeytrack,VintagePreset,VintageRate,VintageBits,VintageFilter,VintageJitter; }
    static bool EffectsEnabled=false,FilterEnabled=true,VintageEnabled=true,EchoEnabled=true; static int EchoDelayMs=250,EchoFeedback=35,EchoMix=20;
    static readonly Dictionary<int,Sample> Samples=new Dictionary<int,Sample>();
    static readonly List<Ev> Events=new List<Ev>();
    const int OutRate=44100;

    public static void Clear(){ Samples.Clear(); Events.Clear(); }
    public static bool LoadSample(int slot,string path){ try{Samples[slot]=ReadWav(path);return true;}catch{Samples.Remove(slot);return false;} }
    public static string GetSampleInfo(int slot){ Sample s; return Samples.TryGetValue(slot,out s)?s.Info:"nicht geladen"; }
    public static void ClearEvents(){ Events.Clear(); }
    public static void SetEffects(bool enabled,bool filterEnabled,bool vintageEnabled,bool echoEnabled,int delayMs,int feedback,int mix){ EffectsEnabled=enabled; FilterEnabled=filterEnabled; VintageEnabled=vintageEnabled; EchoEnabled=echoEnabled; EchoDelayMs=Math.Max(50,Math.Min(2000,delayMs)); EchoFeedback=Math.Max(0,Math.Min(90,feedback)); EchoMix=Math.Max(0,Math.Min(100,mix)); }
    public static void AddEvent(int slot,long startFrame,long lengthFrames,int note,int root,int velocity,double level,double pan,int echoSend,int cutoff,int resonance,int filterEnv,int filterVelocity,int filterKeytrack,int vintagePreset,int vintageRate,int vintageBits,int vintageFilter,int vintageJitter){
        if(lengthFrames<1)return; Events.Add(new Ev{Slot=slot,Start=Math.Max(0,startFrame),Length=lengthFrames,Note=note,Root=root,Velocity=velocity,Level=level,Pan=pan,EchoSend=echoSend,Cutoff=cutoff,Resonance=resonance,FilterEnv=filterEnv,FilterVelocity=filterVelocity,FilterKeytrack=filterKeytrack,VintagePreset=vintagePreset,VintageRate=vintageRate,VintageBits=vintageBits,VintageFilter=vintageFilter,VintageJitter=vintageJitter});
    }
    public static string Render(string path,long totalFrames){
        totalFrames=Math.Max(1,Math.Min(totalFrames,(long)OutRate*180));
        var l=new float[totalFrames]; var r=new float[totalFrames]; var sendL=new float[totalFrames]; var sendR=new float[totalFrames];
        foreach(var e in Events){ Sample sm; if(!Samples.TryGetValue(e.Slot,out sm))continue;
            double ratio=Math.Pow(2.0,(e.Note-e.Root)/12.0)*(double)sm.Rate/OutRate;
            double bal=Math.Max(-1.0,Math.Min(1.0,e.Pan/100.0));
            double baseGain=Math.Max(0.0,Math.Min(1.5,e.Level/100.0))*Math.Max(0,Math.Min(127,e.Velocity))/127.0*0.35;
            double gl=baseGain*(bal>0?1.0-bal:1.0), gr=baseGain*(bal<0?1.0+bal:1.0);
            long max=Math.Min(e.Length,totalFrames-e.Start); int fade=(int)Math.Min(192,Math.Max(16,max/8)); double fl=0,fr=0,bl=0,br=0; uint rng=(uint)(0x9E3779B9u+(uint)(e.Slot*977)+(uint)(e.Start&0xffffffff));
            for(long i=0;i<max;i++){
                double pos=i*ratio; int p=(int)pos; if(p>=sm.L.Length-1)break; double f=pos-p;
                double env=1.0; if(i<fade)env=(double)i/fade; if(max-i-1<fade)env=Math.Min(env,(double)(max-i-1)/fade);
                if(EffectsEnabled && VintageEnabled){
                    int preset=Math.Max(0,Math.Min(15,e.VintagePreset));
                    int vr=Math.Max(e.VintageRate,Math.Min(100,preset*4));
                    if(vr>0){ int hold=1+(int)Math.Round(vr/100.0*31.0); double qpos=Math.Floor(i/(double)hold)*hold*ratio;
                        if(e.VintageJitter>0){ rng=1664525u*rng+1013904223u; double rnd=((rng>>8)&0xffff)/32767.5-1.0; qpos+=rnd*(e.VintageJitter/100.0)*hold*0.45; if(qpos<0)qpos=0; }
                        p=(int)qpos; if(p>=sm.L.Length-1)break; f=qpos-p; }
                }
                float sl=(float)(sm.L[p]+(sm.L[p+1]-sm.L[p])*f), sr=(float)(sm.R[p]+(sm.R[p+1]-sm.R[p])*f);
                if(EffectsEnabled && VintageEnabled){ int vb=Math.Max(e.VintageBits,Math.Min(100,e.VintagePreset*3)); if(vb>0){ int bits=Math.Max(4,16-(int)Math.Round(vb/100.0*12.0)); double levels=Math.Pow(2,bits-1)-1; sl=(float)(Math.Round(sl*levels)/levels); sr=(float)(Math.Round(sr*levels)/levels); } }
                if(EffectsEnabled && FilterEnabled && (e.Cutoff<100 || e.Resonance>0 || e.FilterEnv!=0 || e.FilterVelocity>0 || e.FilterKeytrack>0 || (VintageEnabled && e.VintageFilter>0))){
                    double progress=max>1?(double)i/(max-1):1.0; double envShape=Math.Exp(-5.0*progress);
                    double cutoff=e.Cutoff + e.FilterEnv*envShape*0.55 + e.FilterVelocity*((e.Velocity-64)/63.0)*0.35 + e.FilterKeytrack*(e.Note-e.Root)/24.0;
                    cutoff=Math.Max(1.0,Math.Min(100.0,cutoff)); double c=0.008+0.46*Math.Pow(cutoff/100.0,2.2);
                    if(VintageEnabled && e.VintageFilter>0)c*=Math.Max(0.18,1.0-e.VintageFilter/125.0);
                    double res=Math.Max(0.0,Math.Min(0.92,e.Resonance/108.0));
                    bl+=(sl-fl-c*bl)*c; fl+=bl; bl*=1.0-res*0.18; br+=(sr-fr-c*br)*c; fr+=br; br*=1.0-res*0.18;
                    sl=(float)fl; sr=(float)fr;
                }
                long d=e.Start+i; float dl=(float)(sl*gl*env), dr=(float)(sr*gr*env); l[d]+=dl; r[d]+=dr;
                if(EffectsEnabled && EchoEnabled && e.EchoSend>0){ float sg=(float)(Math.Max(0,Math.Min(100,e.EchoSend))/100.0); sendL[d]+=dl*sg; sendR[d]+=dr*sg; }
            }
        }
        if(EffectsEnabled && EchoEnabled && EchoMix>0){ int delay=Math.Max(1,(int)Math.Round(OutRate*EchoDelayMs/1000.0)); float fb=EchoFeedback/100f, mix=EchoMix/100f; for(long i=delay;i<totalFrames;i++){ sendL[i]+=sendL[i-delay]*fb; sendR[i]+=sendR[i-delay]*fb; l[i]+=sendL[i-delay]*mix; r[i]+=sendR[i-delay]*mix; } }
        double peak=0; for(long i=0;i<totalFrames;i++){peak=Math.Max(peak,Math.Max(Math.Abs(l[i]),Math.Abs(r[i])));} double scale=peak>0.95?0.95/peak:1.0;
        using(var bw=new BinaryWriter(File.Open(path,FileMode.Create,FileAccess.Write,FileShare.Read))){
            int dataBytes=checked((int)totalFrames*4); bw.Write(new char[]{'R','I','F','F'});bw.Write(36+dataBytes);bw.Write(new char[]{'W','A','V','E'});
            bw.Write(new char[]{'f','m','t',' '});bw.Write(16);bw.Write((ushort)1);bw.Write((ushort)2);bw.Write(OutRate);bw.Write(OutRate*4);bw.Write((ushort)4);bw.Write((ushort)16);
            bw.Write(new char[]{'d','a','t','a'});bw.Write(dataBytes);
            for(long i=0;i<totalFrames;i++){double a=Math.Max(-1,Math.Min(1,l[i]*scale)),b=Math.Max(-1,Math.Min(1,r[i]*scale));bw.Write((short)Math.Round(a*32767));bw.Write((short)Math.Round(b*32767));}
        }
        return String.Format("{0} Events, {1:F2} s, Peak {2:F4}, Gain {3:F4}",Events.Count,(double)totalFrames/OutRate,peak,scale);
    }
    static Sample ReadWav(string path){
        using(var br=new BinaryReader(File.Open(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))){
            if(new string(br.ReadChars(4))!="RIFF")throw new InvalidDataException("RIFF fehlt");br.ReadUInt32();if(new string(br.ReadChars(4))!="WAVE")throw new InvalidDataException("WAVE fehlt");
            ushort fmt=1,ch=1,bits=16,validBits=0;int sr=44100;byte[] data=null;
            while(br.BaseStream.Position+8<=br.BaseStream.Length){string id=new string(br.ReadChars(4));int len=br.ReadInt32();long next=br.BaseStream.Position+len+(len&1);
                if(id=="fmt "){long fs=br.BaseStream.Position;fmt=br.ReadUInt16();ch=br.ReadUInt16();sr=br.ReadInt32();br.ReadUInt32();br.ReadUInt16();bits=br.ReadUInt16();if(fmt==0xFFFE&&len>=40){br.ReadUInt16();validBits=br.ReadUInt16();br.ReadUInt32();byte[] guid=br.ReadBytes(16);if(guid.Length>=2)fmt=BitConverter.ToUInt16(guid,0);}br.BaseStream.Position=Math.Min(fs+len,br.BaseStream.Length);}else if(id=="data"){data=br.ReadBytes(len);}br.BaseStream.Position=Math.Min(next,br.BaseStream.Length);if(data!=null&&id=="data")break;}
            if(data==null||ch<1||ch>2)throw new InvalidDataException("Daten/Kanäle ungültig");int bps=bits/8,count=data.Length/(bps*ch);var l=new float[count];var r=new float[count];double peak=0,dc=0;
            for(int i=0,o=0;i<count;i++){float a=ReadOne(data,ref o,fmt,bits,validBits),b=ch==2?ReadOne(data,ref o,fmt,bits,validBits):a;a=Math.Max(-1f,Math.Min(1f,a));b=Math.Max(-1f,Math.Min(1f,b));l[i]=a;r[i]=b;peak=Math.Max(peak,Math.Max(Math.Abs(a),Math.Abs(b)));dc+=(a+b)*0.5;}if(count>0)dc/=count;
            return new Sample{L=l,R=r,Rate=sr,Info=String.Format("{0} Hz, {1} Bit, {2} Kanal/Kanäle, Format {3}, {4} Frames, Peak {5:F4}, DC {6:F5}",sr,bits,ch,fmt,count,peak,dc)};
        }
    }
    static float ReadOne(byte[] d,ref int o,ushort fmt,int bits,ushort validBits){if(fmt==3&&bits==32){float v=BitConverter.ToSingle(d,o);o+=4;return v;}if(bits==8)return(d[o++]-128)/128f;if(bits==16){short v=BitConverter.ToInt16(d,o);o+=2;return v/32768f;}if(bits==24){int v=d[o]|(d[o+1]<<8)|(d[o+2]<<16);if((v&0x800000)!=0)v|=unchecked((int)0xFF000000);o+=3;return v/8388608f;}if(bits==32){int v=BitConverter.ToInt32(d,o);o+=4;return v/2147483648f;}throw new InvalidDataException("Nicht unterstütztes WAV-Format");}
}
"@
}
$script:TransportMediaPlayer = New-Object System.Windows.Media.MediaPlayer
$script:TransportRenderPath = $null
$script:TransportRenderedDurationMs = 0.0

function Get-TransportOutputMode {
    if($null -eq $script:TransportOutputCombo -or $script:TransportOutputCombo.SelectedIndex -lt 0){return 'PC'}
    switch($script:TransportOutputCombo.SelectedIndex){1{return 'MIDI'};2{return 'BOTH'};default{return 'PC'}}
}

function Test-TransportUsesAudio { $m=Get-TransportOutputMode; return ($m -eq 'PC' -or $m -eq 'BOTH') }
function Test-TransportUsesMidi  { $m=Get-TransportOutputMode; return ($m -eq 'MIDI' -or $m -eq 'BOTH') }

function New-TransportRenderPath {
    try { $script:TransportMediaPlayer.Stop(); $script:TransportMediaPlayer.Close() } catch {}
    $oldPath = $script:TransportRenderPath
    $script:TransportRenderPath = Join-Path ([IO.Path]::GetTempPath()) ('Phoenix_TransportPreview_' + [Guid]::NewGuid().ToString('N') + '.wav')
    if(-not [string]::IsNullOrWhiteSpace([string]$oldPath) -and (Test-Path -LiteralPath $oldPath)){
        try {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    return $script:TransportRenderPath
}


function Stop-TransportAudioVoices {
    try { $script:TransportMediaPlayer.Stop(); $script:TransportMediaPlayer.Close() } catch {}
    $script:TransportAudioVoices.Clear()
}

function Preload-TransportAudioSamples {
    try { [PhoenixOfflineRenderer]::Clear() } catch {}
    if($null -eq $script:CurrentBank){return}
    for($i=0;$i -lt [Math]::Min(4,$script:CurrentBank.Slots.Count);$i++){
        $slot=$script:CurrentBank.Slots[$i]
        if($null-ne$slot -and -not [string]::IsNullOrWhiteSpace([string]$slot.FilePath) -and (Test-Path -LiteralPath $slot.FilePath)){
            try { if(-not [PhoenixOfflineRenderer]::LoadSample($i,[string]$slot.FilePath)){Add-Log ('PC-Audio: S'+($i+1)+' konnte nicht geladen werden.')} else { Add-Log ('PC-Audio S'+($i+1)+': '+[PhoenixOfflineRenderer]::GetSampleInfo($i)) } }
            catch { Add-Log ('PC-Audio S'+($i+1)+': '+$_.Exception.Message) }
        }
    }
}

function Set-OfflinePreviewEffects {
    Commit-EffectsGridEdits
    $enabled=($null-ne$script:EffectsPreviewCheck -and $script:EffectsPreviewCheck.IsChecked -eq $true)
    $filterOn=($null-eq$script:EffectsFilterCheck -or $script:EffectsFilterCheck.IsChecked -eq $true)
    $vintageOn=($null-eq$script:EffectsVintageCheck -or $script:EffectsVintageCheck.IsChecked -eq $true)
    $echoOn=($null-eq$script:EffectsEchoCheck -or $script:EffectsEchoCheck.IsChecked -eq $true)
    [PhoenixOfflineRenderer]::SetEffects($enabled,$filterOn,$vintageOn,$echoOn,(Get-EffectsInt $script:EchoDelayBox 250),(Get-EffectsInt $script:EchoFeedbackBox 35),(Get-EffectsInt $script:EchoMixBox 20))
}

function Add-OfflinePatternEvents {
    param([int]$PatternIndex,[long]$BaseFrame,[double]$StepFrames,[bool]$ForceRootPitch=$false,[bool]$FullSample=$false)
    $pattern=$script:PatternInspectorData.Patterns[$PatternIndex]
    for($stepIndex=0;$stepIndex-lt16;$stepIndex++){
        for($t=0;$t-lt4;$t++){
            $track=$pattern.Tracks[$t];$local=$stepIndex%[int]$track.Length;$step=$track.Steps[$local]
            if(-not $step.Active){continue}
            $slot=$script:CurrentBank.Slots[$t];if($null-eq$slot){continue}
            $root=[int](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'ROOT' 60) 60)
            $level=[double](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'LEVEL' 100) 100)
            $pan=[double](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'PAN' 0) 0)
            $start=[long][Math]::Round($BaseFrame+$stepIndex*$StepFrames)
            $length=$(if($FullSample){[long]132300}else{[long][Math]::Max(1,[Math]::Round($StepFrames*[Math]::Max(10,[Math]::Min(100,[int]$step.Gate))/100.0))})
            $playNote=$(if($ForceRootPitch){$root}else{[int]$step.Note})
            $fx=$script:EffectsInspectorData.Slots[$t]
            [PhoenixOfflineRenderer]::AddEvent($t,$start,$length,$playNote,$root,[int]$step.Velocity,$level,$pan,[int]$fx.EchoSend,[int]$fx.FilterCutoff,[int]$fx.Resonance,[int]$fx.FilterEnv,[int]$fx.FilterVelocity,[int]$fx.FilterKeytrack,[int]$fx.VintagePreset,[int]$fx.VintageRate,[int]$fx.VintageBits,[int]$fx.VintageFilter,[int]$fx.VintageJitter)
        }
    }
}

function Get-PatternPreviewRepeatCount {
    param([double]$StepMs)
    if($null -eq $script:PatternRepeatCheck -or $script:PatternRepeatCheck.IsChecked -ne $true){return 1}
    $patternMs=16.0*$StepMs
    if($patternMs-le0){return 1}
    return [Math]::Max(1,[Math]::Min(8,[int][Math]::Floor(180000.0/$patternMs)))
}

function Render-TransportAudio {
    param([ValidateSet('PATTERN','SONG')][string]$Mode,[double]$StepMs,[int]$PatternIndex,[bool]$ForceRootPitch=$false,[bool]$FullSample=$false)
    [PhoenixOfflineRenderer]::ClearEvents();Set-OfflinePreviewEffects;$stepFrames=44100.0*$StepMs/1000.0;$cursor=[long]0;$maxFrames=[long](44100*180)
    if($Mode-eq'PATTERN'){
        $repeatCount=Get-PatternPreviewRepeatCount $StepMs
        $patternFrames=[long][Math]::Round(16*$stepFrames)
        for($rep=0;$rep-lt$repeatCount -and $cursor-lt$maxFrames;$rep++){
            Add-OfflinePatternEvents $PatternIndex $cursor $stepFrames $ForceRootPitch $FullSample
            $cursor+=$patternFrames
        }
    } else {
        $pos=0;$loopSafety=0;$activeEnd=Get-SongActiveEnd
        while($pos-lt$activeEnd -and $cursor-lt$maxFrames -and $loopSafety-lt512){
            $entry=$script:SongInspectorData.Entries[$pos];if($entry.End){break};$pi=[int]$entry.Pattern.Substring(1)-1
            for($rep=0;$rep-lt[Math]::Max(1,[int]$entry.Repeats)-and$cursor-lt$maxFrames;$rep++){Add-OfflinePatternEvents $pi $cursor $stepFrames $ForceRootPitch $FullSample;$cursor+=[long][Math]::Round(16*$stepFrames)}
            $next=$pos+1;$lm=[int]$script:SongInspectorData.LoopMode
            if($lm-eq2){$next=$pos}elseif($lm-eq1 -and ($next-ge[int]$script:SongInspectorData.LoopEnd -or $next-ge$activeEnd)){$next=[int]$script:SongInspectorData.LoopStart-1}
            elseif($next-ge$activeEnd){break};$pos=$next;$loopSafety++
        }
    }
    if($FullSample){$cursor=[long][Math]::Min($maxFrames,$cursor+132300)}
    $cursor=[long][Math]::Max(1,[Math]::Min($cursor,$maxFrames))
    try {
        $renderPath=New-TransportRenderPath
        $info=[PhoenixOfflineRenderer]::Render($renderPath,$cursor)
        $script:TransportRenderedDurationMs=1000.0*$cursor/44100.0;Add-Log ('Offline-Renderer: '+$info)
        $script:TransportMediaPlayer.Open((New-Object System.Uri -ArgumentList $renderPath));$script:TransportMediaPlayer.Play()
    } catch {
        Add-Log ('Offline-Renderer Fehler: '+$_.Exception.Message)
        [Windows.MessageBox]::Show(('Die Audiovorschau konnte nicht erzeugt werden.`n`n'+$_.Exception.Message),'Audiovorschau','OK','Error')|Out-Null
    }
}

function Start-TransportAudioVoice { param([int]$TrackIndex,[int]$Note,[int]$Velocity,[double]$OffAt) }
function Update-TransportAudioVoices { param([double]$Now) }

function Get-MidiOutputDevices {
    $items = New-Object System.Collections.ArrayList
    [void]$items.Add([pscustomobject]@{ Id=-1; Name='Kein MIDI-Ausgang (nur Lauflicht)' })
    try {
        $count = [int][PhoenixMidi]::midiOutGetNumDevs()
        for($i=0; $i -lt $count; $i++) {
            $caps = New-Object PhoenixMidi+MIDIOUTCAPS
            $rc = [PhoenixMidi]::midiOutGetDevCaps([uint32]$i, [ref]$caps, [uint32][Runtime.InteropServices.Marshal]::SizeOf([type]'PhoenixMidi+MIDIOUTCAPS'))
            if($rc -eq 0) { [void]$items.Add([pscustomobject]@{ Id=$i; Name=$caps.szPname }) }
        }
    } catch { Add-Log ('MIDI-Geräte konnten nicht gelesen werden: ' + $_.Exception.Message) }
    return $items
}

function Refresh-MidiOutputs {
    if(-not $script:MidiOutputCombo){return}
    $oldId = -1
    if($null -ne $script:MidiOutputCombo.SelectedItem){$oldId=[int]$script:MidiOutputCombo.SelectedItem.Id}
    $devices = @(Get-MidiOutputDevices)
    $script:MidiOutputCombo.ItemsSource=$null
    $script:MidiOutputCombo.ItemsSource=$devices
    $script:MidiOutputCombo.DisplayMemberPath='Name'
    $sel=0
    for($i=0;$i-lt$devices.Count;$i++){if([int]$devices[$i].Id-eq$oldId){$sel=$i;break}}
    $script:MidiOutputCombo.SelectedIndex=$sel
}

function Close-MidiOutput {
    if($script:MidiHandle -ne [IntPtr]::Zero){
        try{[void][PhoenixMidi]::midiOutReset($script:MidiHandle);[void][PhoenixMidi]::midiOutClose($script:MidiHandle)}catch{}
    }
    $script:MidiHandle=[IntPtr]::Zero;$script:MidiDeviceId=-1
}

function Ensure-MidiOutput {
    if($null -eq $script:MidiOutputCombo.SelectedItem -or [int]$script:MidiOutputCombo.SelectedItem.Id -lt 0){Close-MidiOutput;return $false}
    $id=[int]$script:MidiOutputCombo.SelectedItem.Id
    if($script:MidiHandle-ne[IntPtr]::Zero -and $script:MidiDeviceId-eq$id){return $true}
    Close-MidiOutput
    $h=[IntPtr]::Zero
    $rc=[PhoenixMidi]::midiOutOpen([ref]$h,[uint32]$id,[IntPtr]::Zero,[IntPtr]::Zero,0)
    if($rc-ne0){Add-Log "MIDI-Ausgang konnte nicht geöffnet werden (Fehler $rc).";return $false}
    $script:MidiHandle=$h;$script:MidiDeviceId=$id;Add-Log ('MIDI-Ausgang geöffnet: '+$script:MidiOutputCombo.SelectedItem.Name);return $true
}

function Send-MidiShort {
    param([int]$Status,[int]$Data1=0,[int]$Data2=0)
    if($script:MidiHandle-eq[IntPtr]::Zero){return}
    $msg=[uint32](($Status -band 0xFF) -bor (($Data1 -band 0x7F) -shl 8) -bor (($Data2 -band 0x7F) -shl 16))
    [void][PhoenixMidi]::midiOutShortMsg($script:MidiHandle,$msg)
}
function Send-MidiRealtime { param([int]$Status) if($script:MidiHandle-ne[IntPtr]::Zero){[void][PhoenixMidi]::midiOutShortMsg($script:MidiHandle,[uint32]($Status -band 0xFF))} }

function Get-TransportChannel {
    param([int]$TrackIndex)
    if($null -eq $script:CurrentBank){return $TrackIndex}
    $ch=Get-ConfigInt $script:CurrentBank.Config.Slots[$TrackIndex] 'MIDI_CHANNEL' ($TrackIndex+1)
    return [Math]::Max(0,[Math]::Min(15,$ch-1))
}

function Send-TransportPanic {
    Stop-TransportAudioVoices
    foreach($n in @($script:TransportActiveNotes)){Send-MidiShort (0x80+[int]$n.Channel) ([int]$n.Note) 0}
    $script:TransportActiveNotes.Clear()
    for($ch=0;$ch-lt16;$ch++){Send-MidiShort (0xB0+$ch) 123 0}
    if($script:MidiHandle-ne[IntPtr]::Zero){try{[void][PhoenixMidi]::midiOutReset($script:MidiHandle)}catch{}}
}

function Update-TransportVisuals {
    param([int]$Step,[int]$SongPosition=-1)
    if($script:PatternStepGrid -and $Step-ge0 -and $Step-lt16){$script:PatternStepGrid.SelectedIndex=$Step;$script:PatternStepGrid.ScrollIntoView($script:PatternStepGrid.Items[$Step])}
    if($script:SongGrid -and $SongPosition-ge0 -and $SongPosition-lt16){$script:SongGrid.SelectedIndex=$SongPosition;$script:SongGrid.ScrollIntoView($script:SongGrid.Items[$SongPosition])}
}

function Stop-PhoenixTransport {
    param([bool]$SendStop=$true)
    if($script:TransportTimer.IsEnabled){$script:TransportTimer.Stop()}
    if($SendStop -and $null-ne$script:TransportState -and $script:TransportState.MidiClock -and (Test-TransportUsesMidi)){Send-MidiRealtime 0xFC}
    Send-TransportPanic
    $script:TransportClock.Stop();$script:TransportClock.Reset();$script:TransportState=$null
    if($script:TransportStatusText){$script:TransportStatusText.Text='STOP'}
    if($script:PatternPlayButton){$script:PatternPlayButton.IsEnabled=$true}
    if($script:SongPlayButton){$script:SongPlayButton.IsEnabled=$true}
}

function Start-PhoenixTransport {
    param([ValidateSet('PATTERN','SONG')][string]$Mode)
    if($null-eq$script:PatternInspectorData){[Windows.MessageBox]::Show('Keine Pattern-Daten geladen.','Transport','OK','Warning')|Out-Null;return}
    Commit-PatternGridEdits
    if($Mode-eq'SONG'){Commit-SongGridEdits;if($null-eq$script:SongInspectorData){return}}
    Stop-PhoenixTransport -SendStop:$false
    if(Test-TransportUsesMidi){[void](Ensure-MidiOutput)}else{Close-MidiOutput}
    if(Test-TransportUsesAudio){Preload-TransportAudioSamples}
    $bpm=[Math]::Max(40,[Math]::Min(240,[int]$script:PatternInspectorData.BPM))
    $stepMs=60000.0/[double]$bpm/4.0
    $patternIndex=[Math]::Max(0,[Math]::Min(3,$script:PatternSelectCombo.SelectedIndex))
    $script:TransportState=[pscustomobject]@{
        Mode=$Mode; PatternIndex=$patternIndex; Step=0; SongPosition=0; RepeatsLeft=1
        PatternCyclesRemaining=$(if($Mode-eq'PATTERN'){Get-PatternPreviewRepeatCount $stepMs}else{1})
        StepMs=$stepMs; NextStepMs=0.0; NextClockMs=0.0; ClockMs=(60000.0/[double]$bpm/24.0)
        MidiClock=($script:MidiClockCheck.IsChecked-eq$true)
    }
    if($Mode-eq'SONG'){
        $end=Get-SongActiveEnd
        if($end-lt1){return}
        $e=$script:SongInspectorData.Entries[0]
        if($e.End){return}
        $script:TransportState.PatternIndex=[int]$e.Pattern.Substring(1)-1
        $script:TransportState.RepeatsLeft=[Math]::Max(1,[int]$e.Repeats)
    }
    if(Test-TransportUsesAudio){
        try { Render-TransportAudio $Mode $stepMs $script:TransportState.PatternIndex }
        catch { [Windows.MessageBox]::Show(('PC-Audio konnte nicht gerendert werden:`n'+$_.Exception.Message),'Offline Renderer','OK','Error')|Out-Null; if(-not (Test-TransportUsesMidi)){return} }
    }
    $script:TransportClock.Restart();if((Test-TransportUsesMidi) -and $script:TransportState.MidiClock){Send-MidiRealtime 0xFA}
    $script:TransportTimer.Start()
    $script:PatternPlayButton.IsEnabled=$false;$script:SongPlayButton.IsEnabled=$false
    $script:TransportStatusText.Text=$(if($Mode-eq'PATTERN' -and $script:TransportState.PatternCyclesRemaining-gt1){'PATTERN LOOP ×'+$script:TransportState.PatternCyclesRemaining+' | '+$bpm+' BPM'}else{('{0} | {1} BPM' -f $Mode,$bpm)})
    Add-Log ('Transport gestartet: '+$Mode)
}

function Advance-SongTransport {
    $st=$script:TransportState
    $st.RepeatsLeft--
    if($st.RepeatsLeft-gt0){return $true}
    $next=$st.SongPosition+1
    $activeEnd=Get-SongActiveEnd
    $loopMode=[int]$script:SongInspectorData.LoopMode
    if($loopMode-eq2){$next=$st.SongPosition}
    elseif($loopMode-eq1 -and ($next-ge[int]$script:SongInspectorData.LoopEnd -or $next-ge$activeEnd)){$next=[int]$script:SongInspectorData.LoopStart-1}
    elseif($next-ge$activeEnd){return $false}
    $entry=$script:SongInspectorData.Entries[$next]
    if($entry.End){return $false}
    $st.SongPosition=$next;$st.PatternIndex=[int]$entry.Pattern.Substring(1)-1;$st.RepeatsLeft=[Math]::Max(1,[int]$entry.Repeats)
    return $true
}

function Invoke-TransportStep {
    $st=$script:TransportState;if($null-eq$st){return}
    $now=$script:TransportClock.Elapsed.TotalMilliseconds
    # End notes and PC-audio voices whose gate time has elapsed.
    Update-TransportAudioVoices $now
    for($i=$script:TransportActiveNotes.Count-1;$i-ge0;$i--){$n=$script:TransportActiveNotes[$i];if([double]$n.OffAt-le$now){Send-MidiShort (0x80+[int]$n.Channel) ([int]$n.Note) 0;$script:TransportActiveNotes.RemoveAt($i)}}
    if($st.MidiClock -and (Test-TransportUsesMidi)){while($now-ge$st.NextClockMs){Send-MidiRealtime 0xF8;$st.NextClockMs+=$st.ClockMs}}
    while($now-ge$st.NextStepMs){
        $pattern=$script:PatternInspectorData.Patterns[[int]$st.PatternIndex]
        for($t=0;$t-lt4;$t++){
            $track=$pattern.Tracks[$t];$local=[int]$st.Step%[int]$track.Length;$step=$track.Steps[$local]
            if($step.Active){
                $ch=Get-TransportChannel $t;$note=[Math]::Max(0,[Math]::Min(127,[int]$step.Note));$vel=[Math]::Max(1,[Math]::Min(127,[int]$step.Velocity))
                $offAt=($st.NextStepMs+($st.StepMs*[Math]::Max(10,[Math]::Min(100,[int]$step.Gate))/100.0))
                if(Test-TransportUsesMidi){
                    Send-MidiShort (0x90+$ch) $note $vel
                    [void]$script:TransportActiveNotes.Add([pscustomobject]@{Channel=$ch;Note=$note;OffAt=$offAt})
                }
            }
        }
        Update-TransportVisuals ([int]$st.Step) $(if($st.Mode-eq'SONG'){[int]$st.SongPosition}else{-1})
        $st.Step++
        if($st.Step-ge16){
            $st.Step=0
            if($st.Mode-eq'SONG'){
                if(-not (Advance-SongTransport)){Stop-PhoenixTransport;return}
            } else {
                $st.PatternCyclesRemaining--
                if($st.PatternCyclesRemaining-le0){Stop-PhoenixTransport;return}
            }
        }
        $st.NextStepMs+=$st.StepMs
        if($now-$st.NextStepMs -gt ($st.StepMs*2)){ $st.NextStepMs=$now+$st.StepMs }
    }
}

$script:TransportTimer.Add_Tick({try{Invoke-TransportStep}catch{Add-Log ('Transportfehler: '+$_.Exception.Message);Stop-PhoenixTransport}})

function Set-PatternDirty {
    param([bool]$Dirty=$true)
    $script:PatternDirty=$Dirty
    if($script:PatternSaveButton){$script:PatternSaveButton.IsEnabled=$Dirty}
    if($script:PatternDirtyText){$script:PatternDirtyText.Text=$(if($Dirty){'NICHT GESPEICHERT'}else{''})}
    Update-SystemStatusView
}

function Update-PatternSummary {
    if($null -eq $script:PatternInspectorData){return}
    $summary=@()
    foreach($pat in $script:PatternInspectorData.Patterns){ foreach($tr in $pat.Tracks){ $on=@($tr.Steps | Where-Object {$_.Active}).Count; $summary += [pscustomobject]@{Pattern=('P'+$pat.Pattern);Track=('S'+$tr.Track);Length=$tr.Length;ActiveSteps=$on} } }
    $script:PatternSummaryGrid.ItemsSource=$null; $script:PatternSummaryGrid.ItemsSource=$summary
}

function Update-PatternInspector {
    if($null -eq $script:CurrentBank){return}
    $script:PatternSyncing=$true
    try{
        $script:PatternInspectorData=Read-PhoenixPatterns $script:CurrentBank.Path
        $p=$script:PatternInspectorData
        $script:PatternStatusText.Text = if(-not $p.Exists){'PATTERNS.CFG fehlt - beim Speichern wird eine kompatible Datei angelegt.'}elseif(-not $p.Valid){'PATTERNS.CFG fehlerhaft: '+$p.Error}else{"PATTERNS.CFG v1  |  Aktuell P$($p.CurrentPattern)"}
        $script:PatternSelectCombo.SelectedIndex=[Math]::Max(0,$p.CurrentPattern-1)
        if($script:PatternTrackCombo.SelectedIndex -lt 0){$script:PatternTrackCombo.SelectedIndex=0}
        $script:PatternBpmBox.Text=[string]$p.BPM
        $script:PatternClockCombo.SelectedIndex=$(if($p.ClockMode -eq 'EXT'){1}else{0})
        Update-PatternStepGrid
        Update-PatternSummary
        Set-PatternDirty $false
    } finally {$script:PatternSyncing=$false}
}

function Update-PatternStepGrid {
    if($null -eq $script:PatternInspectorData){return}
    $script:PatternSyncing=$true
    try{
        $pi=[Math]::Max(0,$script:PatternSelectCombo.SelectedIndex); $ti=[Math]::Max(0,$script:PatternTrackCombo.SelectedIndex)
        $track=$script:PatternInspectorData.Patterns[$pi].Tracks[$ti]
        $rows=@(); foreach($st in $track.Steps){
            $st.Note=[Math]::Max(0,[Math]::Min(127,[int]$st.Note)); $st.Velocity=[Math]::Max(1,[Math]::Min(127,[int]$st.Velocity)); $st.Gate=[Math]::Max(10,[Math]::Min(100,[int]$st.Gate)); $st.NoteText=Get-MidiNoteName $st.Note
            Add-Member -InputObject $st -NotePropertyName InLength -NotePropertyValue $(if($st.Step -le $track.Length){'JA'}else{'NEIN'}) -Force
            $rows += $st
        }
        $script:PatternStepGrid.ItemsSource=$null; $script:PatternStepGrid.ItemsSource=$rows
        $script:PatternLengthCombo.SelectedIndex=$track.Length-1
        $script:PatternValidationText.Text='MIDI 0-127  |  Velocity 1-127  |  Gate 10-100 %'
    } finally {$script:PatternSyncing=$false}
}

function Commit-PatternGridEdits {
    if($script:PatternStepGrid){
        [void]$script:PatternStepGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Cell,$true)
        [void]$script:PatternStepGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row,$true)
    }
    if($null -eq $script:PatternInspectorData){return}
    foreach($st in @($script:PatternStepGrid.ItemsSource)){
        $st.Note=[Math]::Max(0,[Math]::Min(127,[int](Convert-ToInt64Safe $st.Note 60)))
        $st.Velocity=[Math]::Max(1,[Math]::Min(127,[int](Convert-ToInt64Safe $st.Velocity 100)))
        $st.Gate=[Math]::Max(10,[Math]::Min(100,[int](Convert-ToInt64Safe $st.Gate 50)))
        $st.NoteText=Get-MidiNoteName $st.Note
    }
}

function Save-PhoenixPatterns {
    if($null -eq $script:CurrentBank -or $null -eq $script:PatternInspectorData){return}
    Commit-PatternGridEdits
    $bpm=[Math]::Max(40,[Math]::Min(240,[int](Convert-ToInt64Safe $script:PatternBpmBox.Text 120)))
    $script:PatternInspectorData.BPM=$bpm; $script:PatternBpmBox.Text=[string]$bpm
    $script:PatternInspectorData.ClockMode=$(if($script:PatternClockCombo.SelectedIndex -eq 1){'EXT'}else{'INT'})
    $script:PatternInspectorData.CurrentPattern=[Math]::Max(1,$script:PatternSelectCombo.SelectedIndex+1)
    $path=Join-Path $script:CurrentBank.Path 'PATTERNS.CFG'
    try{
        if(Test-Path -LiteralPath $path){ Copy-Item -LiteralPath $path -Destination ($path+'.bak_'+(Get-Date -Format 'yyyyMMdd_HHmmss')) -Force }
        $lines=New-Object System.Collections.Generic.List[string]
        $lines.Add('VERSION=1'); $lines.Add(('CURRENT_PATTERN={0}' -f $script:PatternInspectorData.CurrentPattern)); $lines.Add(('CLOCK_MODE={0}' -f $script:PatternInspectorData.ClockMode)); $lines.Add(('BPM={0}' -f $script:PatternInspectorData.BPM)); $lines.Add('')
        foreach($pat in $script:PatternInspectorData.Patterns){
            $lines.Add(('[P{0}]' -f $pat.Pattern))
            foreach($tr in $pat.Tracks){
                $lines.Add(('TRACK{0}_LENGTH={1}' -f $tr.Track,$tr.Length))
                foreach($st in $tr.Steps){
                    $active=$(if($st.Active){1}else{0})
                    $lines.Add(('T{0}_STEP{1}={2},{3},{4},{5}' -f $tr.Track,$st.Step,$active,$st.Note,$st.Velocity,$st.Gate))
                }
            }
            $lines.Add('')
        }
        [IO.File]::WriteAllLines($path,$lines,$script:Utf8NoBom)
        Set-PatternDirty $false; Add-Log "PATTERNS.CFG gespeichert: $path"; $script:StatusText.Text='Pattern gespeichert.'
        Update-PatternSummary
    }catch{[System.Windows.MessageBox]::Show("PATTERNS.CFG konnte nicht gespeichert werden:`n$($_.Exception.Message)",'Phoenix Librarian','OK','Error')|Out-Null}
}

function Initialize-PatternTrack {
    if($null -eq $script:PatternInspectorData){return}; $pi=[Math]::Max(0,$script:PatternSelectCombo.SelectedIndex);$ti=[Math]::Max(0,$script:PatternTrackCombo.SelectedIndex);$tr=$script:PatternInspectorData.Patterns[$pi].Tracks[$ti]
    foreach($st in $tr.Steps){$st.Active=$false;$st.Note=60+2*$ti;$st.NoteText=Get-MidiNoteName $st.Note;$st.Velocity=100;$st.Gate=50};$tr.Length=16;Update-PatternStepGrid;Set-PatternDirty
}

function Copy-PatternTrack { if($null -eq $script:PatternInspectorData){return};Commit-PatternGridEdits;$pi=[Math]::Max(0,$script:PatternSelectCombo.SelectedIndex);$ti=[Math]::Max(0,$script:PatternTrackCombo.SelectedIndex);$tr=$script:PatternInspectorData.Patterns[$pi].Tracks[$ti];$script:PatternTrackClipboard=[pscustomobject]@{Length=$tr.Length;Steps=@($tr.Steps|ForEach-Object{[pscustomobject]@{Active=$_.Active;Note=$_.Note;Velocity=$_.Velocity;Gate=$_.Gate}})};$script:StatusText.Text='Spur kopiert.' }
function Paste-PatternTrack { if($null -eq $script:PatternTrackClipboard -or $null -eq $script:PatternInspectorData){return};$pi=[Math]::Max(0,$script:PatternSelectCombo.SelectedIndex);$ti=[Math]::Max(0,$script:PatternTrackCombo.SelectedIndex);$tr=$script:PatternInspectorData.Patterns[$pi].Tracks[$ti];$tr.Length=$script:PatternTrackClipboard.Length;for($i=0;$i-lt16;$i++){$s=$script:PatternTrackClipboard.Steps[$i];$tr.Steps[$i].Active=$s.Active;$tr.Steps[$i].Note=$s.Note;$tr.Steps[$i].Velocity=$s.Velocity;$tr.Steps[$i].Gate=$s.Gate};Update-PatternStepGrid;Update-PatternSummary;Set-PatternDirty }
function Copy-WholePattern { if($null -eq $script:PatternInspectorData){return};Commit-PatternGridEdits;$pi=[Math]::Max(0,$script:PatternSelectCombo.SelectedIndex);$p=$script:PatternInspectorData.Patterns[$pi];$script:PatternClipboard=@();foreach($tr in $p.Tracks){$script:PatternClipboard += [pscustomobject]@{Length=$tr.Length;Steps=@($tr.Steps|ForEach-Object{[pscustomobject]@{Active=$_.Active;Note=$_.Note;Velocity=$_.Velocity;Gate=$_.Gate}})}};$script:StatusText.Text='Pattern kopiert.' }
function Paste-WholePattern { if($null -eq $script:PatternClipboard -or $null -eq $script:PatternInspectorData){return};$pi=[Math]::Max(0,$script:PatternSelectCombo.SelectedIndex);for($t=0;$t-lt4;$t++){$tr=$script:PatternInspectorData.Patterns[$pi].Tracks[$t];$src=$script:PatternClipboard[$t];$tr.Length=$src.Length;for($i=0;$i-lt16;$i++){$s=$src.Steps[$i];$tr.Steps[$i].Active=$s.Active;$tr.Steps[$i].Note=$s.Note;$tr.Steps[$i].Velocity=$s.Velocity;$tr.Steps[$i].Gate=$s.Gate}};Update-PatternStepGrid;Update-PatternSummary;Set-PatternDirty }

function Set-SongDirty {
    param([bool]$Dirty=$true)
    $script:SongDirty=$Dirty
    if($script:SongSaveButton){$script:SongSaveButton.IsEnabled=$Dirty}
    if($script:SongDirtyText){$script:SongDirtyText.Text=$(if($Dirty){'NICHT GESPEICHERT'}else{''})}
    Update-SystemStatusView
}

function Normalize-SongEntry {
    param($Entry)
    if($null -eq $Entry){return}
    $pattern=([string]$Entry.Pattern).Trim().ToUpperInvariant()
    $isEnd=[bool]$Entry.End -or $pattern -eq 'END'
    if($isEnd){$Entry.Pattern='END';$Entry.Repeats='';$Entry.End=$true;return}
    if($pattern -notmatch '^P[1-4]$'){$pattern='P1'}
    $Entry.Pattern=$pattern
    $Entry.Repeats=[Math]::Max(1,[Math]::Min(16,[int](Convert-ToInt64Safe $Entry.Repeats 1)))
    $Entry.End=$false
}

function Commit-SongGridEdits {
    if($script:SongGrid){
        [void]$script:SongGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Cell,$true)
        [void]$script:SongGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row,$true)
    }
    if($null -eq $script:SongInspectorData){return}
    foreach($entry in $script:SongInspectorData.Entries){Normalize-SongEntry $entry}
}

function Get-SongActiveEnd {
    if($null -eq $script:SongInspectorData){return 1}
    for($i=0;$i -lt 16;$i++){if($script:SongInspectorData.Entries[$i].End){return [Math]::Max(1,$i)}}
    return 16
}

function Update-SongDuration {
    if($null -eq $script:SongInspectorData){return}
    $bpm=120
    if($null -ne $script:PatternInspectorData){$bpm=[Math]::Max(40,[int]$script:PatternInspectorData.BPM)}
    $seconds=0.0; $used=0
    foreach($entry in $script:SongInspectorData.Entries){
        Normalize-SongEntry $entry
        if($entry.End){break}
        $pi=[int]$entry.Pattern.Substring(1)-1
        $bars=1.0
        if($null -ne $script:PatternInspectorData){
            $maxLen=1
            foreach($tr in $script:PatternInspectorData.Patterns[$pi].Tracks){$maxLen=[Math]::Max($maxLen,[int]$tr.Length)}
            $bars=$maxLen/16.0
        }
        $seconds += (240.0/$bpm)*$bars*[int]$entry.Repeats
        $used++
    }
    $ts=[TimeSpan]::FromSeconds($seconds)
    $durationText = $ts.ToString('mm\:ss')
    $script:SongDurationText.Text=('Geschätzte Länge: {0}  |  {1} aktive Position(en)  |  Basis {2} BPM' -f $durationText,$used,$bpm)
}

function Update-SongValidation {
    if($null -eq $script:SongInspectorData){return}
    Commit-SongGridEdits
    $start=$script:SongLoopStartCombo.SelectedIndex+1; if($start -lt 1){$start=1}
    $end=$script:SongLoopEndCombo.SelectedIndex+1; if($end -lt 1){$end=1}
    $mode=[Math]::Max(0,$script:SongLoopModeCombo.SelectedIndex)
    $firstEnd=17
    for($i=0;$i-lt16;$i++){if($script:SongInspectorData.Entries[$i].End){$firstEnd=$i+1;break}}
    $message='Pattern P1-P4  |  Wiederholungen 1-16'
    if($mode -eq 1 -and $start -gt $end){$message='Hinweis: Loop Start liegt hinter Loop End.'}
    elseif($mode -eq 1 -and ($start -ge $firstEnd -or $end -ge $firstEnd)){$message='Hinweis: Song-Loop liegt ganz oder teilweise hinter END.'}
    elseif($mode -eq 2){$message='PATTERN wiederholt das jeweils laufende Pattern; Start/End bleiben gespeichert.'}
    $script:SongValidationText.Text=$message
    Update-SongDuration
}

function Update-SongInspector {
    if($null -eq $script:CurrentBank){return}
    $script:SongSyncing=$true
    try{
        $script:SongInspectorData=Read-PhoenixSong $script:CurrentBank.Path
        $song=$script:SongInspectorData
        $script:SongStatusText.Text=if(-not $song.Exists){'SONG.CFG fehlt - beim Speichern wird P1 ×1 gefolgt von END angelegt.'}elseif(-not $song.Valid){'SONG.CFG fehlerhaft: '+$song.Error}else{"SONG.CFG v2  |  Loop $($song.LoopModeText)  |  Bereich $($song.LoopStart)-$($song.LoopEnd)"}
        $script:SongGrid.ItemsSource=$null; $script:SongGrid.ItemsSource=$song.Entries
        $script:SongLoopModeCombo.SelectedIndex=[Math]::Max(0,[Math]::Min(2,[int]$song.LoopMode))
        $script:SongLoopStartCombo.SelectedIndex=[Math]::Max(0,[Math]::Min(15,[int]$song.LoopStart-1))
        $script:SongLoopEndCombo.SelectedIndex=[Math]::Max(0,[Math]::Min(15,[int]$song.LoopEnd-1))
        Set-SongDirty $false
        Update-SongValidation
    } finally {$script:SongSyncing=$false}
}

function Save-PhoenixSong {
    if($null -eq $script:CurrentBank -or $null -eq $script:SongInspectorData){return}
    Commit-SongGridEdits
    $script:SongInspectorData.LoopMode=[Math]::Max(0,$script:SongLoopModeCombo.SelectedIndex)
    $script:SongInspectorData.LoopStart=[Math]::Max(1,$script:SongLoopStartCombo.SelectedIndex+1)
    $script:SongInspectorData.LoopEnd=[Math]::Max(1,$script:SongLoopEndCombo.SelectedIndex+1)
    if($script:SongInspectorData.LoopMode -eq 1 -and $script:SongInspectorData.LoopStart -gt $script:SongInspectorData.LoopEnd){
        [System.Windows.MessageBox]::Show('Loop Start darf im Modus SONG nicht hinter Loop End liegen.','Phoenix Librarian','OK','Warning')|Out-Null;return
    }
    $path=Join-Path $script:CurrentBank.Path 'SONG.CFG'
    try{
        if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination ($path+'.bak_'+(Get-Date -Format 'yyyyMMdd_HHmmss')) -Force}
        $lines=New-Object System.Collections.Generic.List[string]
        $lines.Add('VERSION=2')
        $lines.Add(('LOOP_MODE={0}' -f $script:SongInspectorData.LoopMode))
        $lines.Add(('LOOP_START={0}' -f $script:SongInspectorData.LoopStart))
        $lines.Add(('LOOP_END={0}' -f $script:SongInspectorData.LoopEnd))
        for($i=0;$i-lt16;$i++){
            $entry=$script:SongInspectorData.Entries[$i];Normalize-SongEntry $entry
            $value=$(if($entry.End){'END'}else{('{0},{1}' -f $entry.Pattern,$entry.Repeats)})
            $lines.Add(('POS{0:D2}={1}' -f ($i+1),$value))
        }
        [IO.File]::WriteAllLines($path,$lines,$script:Utf8NoBom)
        $script:SongInspectorData.Exists=$true;$script:SongInspectorData.Valid=$true
        $script:SongInspectorData.LoopModeText=@('OFF','SONG','PATTERN')[$script:SongInspectorData.LoopMode]
        Set-SongDirty $false;Add-Log "SONG.CFG gespeichert: $path";$script:StatusText.Text='Song gespeichert.'
        $script:SongStatusText.Text="SONG.CFG v2  |  Loop $($script:SongInspectorData.LoopModeText)  |  Bereich $($script:SongInspectorData.LoopStart)-$($script:SongInspectorData.LoopEnd)"
    }catch{[System.Windows.MessageBox]::Show("SONG.CFG konnte nicht gespeichert werden:`n$($_.Exception.Message)",'Phoenix Librarian','OK','Error')|Out-Null}
}

function Initialize-PhoenixSong {
    if($null -eq $script:SongInspectorData){return}
    for($i=0;$i-lt16;$i++){$e=$script:SongInspectorData.Entries[$i];$e.Pattern=$(if($i-eq0){'P1'}else{'END'});$e.Repeats=$(if($i-eq0){1}else{''});$e.End=($i-ne0)}
    $script:SongLoopModeCombo.SelectedIndex=1;$script:SongLoopStartCombo.SelectedIndex=0;$script:SongLoopEndCombo.SelectedIndex=0
    $script:SongGrid.Items.Refresh();Set-SongDirty;Update-SongValidation
}

function Move-SongEntry {
    param([int]$Direction)
    if($null -eq $script:SongInspectorData -or $null -eq $script:SongGrid.SelectedItem){return}
    Commit-SongGridEdits;$idx=[int]$script:SongGrid.SelectedItem.Position-1;$target=$idx+$Direction
    if($target-lt0-or$target-ge16){return}
    $a=$script:SongInspectorData.Entries[$idx];$b=$script:SongInspectorData.Entries[$target]
    $tmp=[pscustomobject]@{Pattern=$a.Pattern;Repeats=$a.Repeats;End=$a.End}
    $a.Pattern=$b.Pattern;$a.Repeats=$b.Repeats;$a.End=$b.End;$b.Pattern=$tmp.Pattern;$b.Repeats=$tmp.Repeats;$b.End=$tmp.End
    $script:SongGrid.Items.Refresh();$script:SongGrid.SelectedIndex=$target;Set-SongDirty;Update-SongValidation
}

function Insert-SongEntry {
    if($null -eq $script:SongInspectorData){return};Commit-SongGridEdits
    $idx=$(if($null-ne$script:SongGrid.SelectedItem){[int]$script:SongGrid.SelectedItem.Position-1}else{0})
    for($i=15;$i-gt$idx;$i--){$src=$script:SongInspectorData.Entries[$i-1];$dst=$script:SongInspectorData.Entries[$i];$dst.Pattern=$src.Pattern;$dst.Repeats=$src.Repeats;$dst.End=$src.End}
    $e=$script:SongInspectorData.Entries[$idx];$e.Pattern='P1';$e.Repeats=1;$e.End=$false
    $script:SongGrid.Items.Refresh();$script:SongGrid.SelectedIndex=$idx;Set-SongDirty;Update-SongValidation
}

function Delete-SongEntry {
    if($null -eq $script:SongInspectorData -or $null -eq $script:SongGrid.SelectedItem){return};Commit-SongGridEdits
    $idx=[int]$script:SongGrid.SelectedItem.Position-1
    for($i=$idx;$i-lt15;$i++){$src=$script:SongInspectorData.Entries[$i+1];$dst=$script:SongInspectorData.Entries[$i];$dst.Pattern=$src.Pattern;$dst.Repeats=$src.Repeats;$dst.End=$src.End}
    $last=$script:SongInspectorData.Entries[15];$last.Pattern='END';$last.Repeats='';$last.End=$true
    $script:SongGrid.Items.Refresh();$script:SongGrid.SelectedIndex=[Math]::Min($idx,15);Set-SongDirty;Update-SongValidation
}

# -----------------------------------------------------------------------------
# v1.1.0 FINAL: INIT SOUND TEMPLATE + Reverb synchronized with BANK16 firmware
# Dedicated /PHOENIX/INIT_SOUND.CFG format; never stores WAV/sample paths.
# -----------------------------------------------------------------------------
function Get-InitSoundPath {
    $root = Get-PhoenixContentRoot
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    return (Join-Path $root 'INIT_SOUND.CFG')
}

function New-InitSoundFactoryData {
    $slots = New-Object System.Collections.ArrayList
    for ($i=0; $i -lt 4; $i++) {
        [void]$slots.Add([pscustomobject]@{
            Slot=('S'+($i+1)); Multisample=$false; Low=0; High=127; Root=60;
            Coarse=0; Fine=0; RootNote=60; Octave=0; PitchTrack=$true; Bend=2;
            Attack=5; Decay=80; Sustain=100; Release=80;
            Level=100; Pan=0; SampleGain=100; Velocity=100;
            Cutoff=100; Resonance=0; FilterEnv=0; FilterVelocity=0; Keytrack=0;
            FilterAttack=0; FilterDecay=250; FilterSustain=0; FilterRelease=300;
            VintagePreset=0; VintageRate=0; VintageBits=0; VintageFilter=0; VintageJitter=0;
            VoiceMode=0; VoiceLimit=12; Priority=0; Glide=0; EchoSend=0; ReverbSend=0;
            QuattroLow=0; QuattroHigh=127; MidiChannel=($i+1)
        })
    }
    return [pscustomobject]@{ Version=1; QuattroMode=1; EchoDelay=250; EchoFeedback=35; EchoMix=20; ReverbSize=55; ReverbDecay=55; ReverbDamp=45; ReverbMix=20; Slots=$slots }
}

function Set-InitSoundDirty {
    param([bool]$Dirty=$true)
    $script:InitSoundDirty=$Dirty
    if($script:InitSoundDirtyText){$script:InitSoundDirtyText.Text=$(if($Dirty){'NICHT GESPEICHERT'}else{''})}
    if($script:InitSoundSaveButton){$script:InitSoundSaveButton.IsEnabled=$Dirty}
    Update-SystemStatusView
}

function Commit-InitSoundGridEdits {
    if($script:InitSoundGrid){
        $script:InitSoundGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell,$true)|Out-Null
        $script:InitSoundGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row,$true)|Out-Null
    }
}

function Convert-InitBool {
    param([string]$Text,[bool]$Default=$false)
    if([string]::IsNullOrWhiteSpace($Text)){return $Default}
    $t=$Text.Trim().ToUpperInvariant()
    if($t -in @('1','TRUE','ON','YES')){return $true}
    if($t -in @('0','FALSE','OFF','NO')){return $false}
    return $Default
}

function Convert-InitInt {
    param([string]$Text,[int]$Default,[int]$Min,[int]$Max)
    $v=0
    if(-not [int]::TryParse($Text,[ref]$v)){$v=$Default}
    return [Math]::Max($Min,[Math]::Min($Max,$v))
}

function Read-InitSoundTemplate {
    $data=New-InitSoundFactoryData
    $path=Get-InitSoundPath
    if([string]::IsNullOrWhiteSpace($path) -or -not(Test-Path -LiteralPath $path -PathType Leaf)){return $data}
    try {
        $section=''
        $versionOk=$false
        foreach($raw in [IO.File]::ReadAllLines($path)){
            $line=$raw.Trim()
            if([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith(';')){continue}
            if($line.StartsWith('[') -and $line.EndsWith(']')){$section=$line.Substring(1,$line.Length-2).Trim().ToUpperInvariant();continue}
            $eq=$line.IndexOf('='); if($eq -lt 1){continue}
            $k=$line.Substring(0,$eq).Trim().ToUpperInvariant(); $v=$line.Substring($eq+1).Trim()
            if([string]::IsNullOrEmpty($section)){
                if($k -eq 'VERSION'){$versionOk=([int](Convert-ToInt64Safe $v 0) -eq 1)}
                continue
            }
            if($section -eq 'GLOBAL'){
                if($k -eq 'QUATTRO_MODE'){$data.QuattroMode=Convert-InitInt $v 1 0 1}
                continue
            }
            if($section -eq 'FX'){
                if($k -eq 'ECHO_DELAY_MS'){$data.EchoDelay=Convert-InitInt $v 250 50 2000}
                elseif($k -eq 'ECHO_FEEDBACK'){$data.EchoFeedback=Convert-InitInt $v 35 0 90}
                elseif($k -eq 'ECHO_MIX'){$data.EchoMix=Convert-InitInt $v 20 0 100}
                elseif($k -eq 'REVERB_SIZE'){$data.ReverbSize=Convert-InitInt $v 55 0 100}
                elseif($k -eq 'REVERB_DECAY'){$data.ReverbDecay=Convert-InitInt $v 55 0 100}
                elseif($k -eq 'REVERB_DAMP'){$data.ReverbDamp=Convert-InitInt $v 45 0 100}
                elseif($k -eq 'REVERB_MIX'){$data.ReverbMix=Convert-InitInt $v 20 0 100}
                continue
            }
            if($section -match '^SLOT([1-4])$'){
                $o=$data.Slots[[int]$Matches[1]-1]
                switch($k){
                    'MULTISAMPLE_ENABLED'{$o.Multisample=Convert-InitBool $v $false}
                    'LOW'{$o.Low=Convert-InitInt $v 0 0 127}; 'HIGH'{$o.High=Convert-InitInt $v 127 0 127}; 'ROOT'{$o.Root=Convert-InitInt $v 60 0 127}
                    'COARSE'{$o.Coarse=Convert-InitInt $v 0 -24 24}; 'FINE_CENT'{$o.Fine=Convert-InitInt $v 0 -100 100}; 'ROOT_NOTE'{$o.RootNote=Convert-InitInt $v 60 0 127}; 'OCTAVE'{$o.Octave=Convert-InitInt $v 0 -2 2}; 'PITCH_TRACKING'{$o.PitchTrack=Convert-InitBool $v $true}; 'PITCH_BEND_RANGE'{$o.Bend=Convert-InitInt $v 2 0 24}
                    'ATTACK_MS'{$o.Attack=Convert-InitInt $v 5 0 2000}; 'DECAY_MS'{$o.Decay=Convert-InitInt $v 80 0 2000}; 'SUSTAIN_PCT'{$o.Sustain=Convert-InitInt $v 100 0 100}; 'RELEASE_MS'{$o.Release=Convert-InitInt $v 80 0 2000}
                    'LEVEL'{$o.Level=Convert-InitInt $v 100 0 100}; 'PAN'{$o.Pan=Convert-InitInt $v 0 -100 100}; 'SAMPLE_GAIN_PCT'{$o.SampleGain=Convert-InitInt $v 100 0 200}; 'VELOCITY_AMOUNT_PCT'{$o.Velocity=Convert-InitInt $v 100 0 100}
                    'FILTER_CUTOFF'{$o.Cutoff=Convert-InitInt $v 100 0 100}; 'FILTER_RESONANCE'{$o.Resonance=Convert-InitInt $v 0 0 100}; 'FILTER_ENV_AMOUNT'{$o.FilterEnv=Convert-InitInt $v 0 -100 100}; 'FILTER_VELOCITY'{$o.FilterVelocity=Convert-InitInt $v 0 0 100}; 'FILTER_KEYTRACK'{$o.Keytrack=Convert-InitInt $v 0 0 100}
                    'FILTER_ATTACK_MS'{$o.FilterAttack=Convert-InitInt $v 0 0 2000}; 'FILTER_DECAY_MS'{$o.FilterDecay=Convert-InitInt $v 250 0 2000}; 'FILTER_SUSTAIN_PCT'{$o.FilterSustain=Convert-InitInt $v 0 0 100}; 'FILTER_RELEASE_MS'{$o.FilterRelease=Convert-InitInt $v 300 0 2000}
                    'VINTAGE_PRESET'{$o.VintagePreset=Convert-InitInt $v 0 0 15}; 'VINTAGE_SAMPLE_RATE'{$o.VintageRate=Convert-InitInt $v 0 0 100}; 'VINTAGE_BIT_DEPTH'{$o.VintageBits=Convert-InitInt $v 0 0 100}; 'VINTAGE_FILTER'{$o.VintageFilter=Convert-InitInt $v 0 0 100}; 'VINTAGE_JITTER'{$o.VintageJitter=Convert-InitInt $v 0 0 100}
                    'VOICE_MODE'{$o.VoiceMode=Convert-InitInt $v 0 0 2}; 'VOICE_LIMIT'{$o.VoiceLimit=Convert-InitInt $v 12 1 12}; 'NOTE_PRIORITY'{$o.Priority=Convert-InitInt $v 0 0 2}; 'GLIDE_MS'{$o.Glide=Convert-InitInt $v 0 0 2000}
                    'ECHO_SEND'{$o.EchoSend=Convert-InitInt $v 0 0 100}; 'REVERB_SEND'{$o.ReverbSend=Convert-InitInt $v 0 0 100}; 'QUATTRO_LOW'{$o.QuattroLow=Convert-InitInt $v 0 0 127}; 'QUATTRO_HIGH'{$o.QuattroHigh=Convert-InitInt $v 127 0 127}; 'MIDI_CHANNEL'{$o.MidiChannel=Convert-InitInt $v ([int]$Matches[1]) 1 16}
                }
            }
        }
        if(-not $versionOk){Add-Log 'INIT_SOUND.CFG: ungueltige oder fehlende VERSION; Factory Defaults verwendet.';return (New-InitSoundFactoryData)}
    } catch { Add-Log ('INIT_SOUND.CFG lesen fehlgeschlagen: '+$_.Exception.Message); return (New-InitSoundFactoryData) }
    return $data
}

function Add-InitRangeIssue {
    param($Issues,[string]$Slot,[string]$Name,$Value,[int]$Min,[int]$Max)
    $iv=0
    if($null -eq $Value -or -not [int]::TryParse([string]$Value,[ref]$iv)){
        $Issues.Add("${Slot}: $Name is not an integer")
        return
    }
    if($iv -lt $Min -or $iv -gt $Max){$Issues.Add("${Slot}: $Name $Min..$Max")}
}

function Update-InitSoundValidation {
    if($null-eq$script:InitSoundData){return $false}
    Commit-InitSoundGridEdits
    $issues=New-Object System.Collections.Generic.List[string]

    Add-InitRangeIssue $issues 'GLOBAL' 'QUATTRO_MODE' $script:InitQuattroModeBox.Text 0 1
    Add-InitRangeIssue $issues 'FX' 'ECHO_DELAY_MS' $script:InitEchoDelayBox.Text 50 2000
    Add-InitRangeIssue $issues 'FX' 'ECHO_FEEDBACK' $script:InitEchoFeedbackBox.Text 0 90
    Add-InitRangeIssue $issues 'FX' 'ECHO_MIX' $script:InitEchoMixBox.Text 0 100
    Add-InitRangeIssue $issues 'FX' 'REVERB_SIZE' $script:InitReverbSizeBox.Text 0 100
    Add-InitRangeIssue $issues 'FX' 'REVERB_DECAY' $script:InitReverbDecayBox.Text 0 100
    Add-InitRangeIssue $issues 'FX' 'REVERB_DAMP' $script:InitReverbDampBox.Text 0 100
    Add-InitRangeIssue $issues 'FX' 'REVERB_MIX' $script:InitReverbMixBox.Text 0 100

    foreach($r in $script:InitSoundData.Slots){
        $sn=[string]$r.Slot
        Add-InitRangeIssue $issues $sn 'LOW' $r.Low 0 127
        Add-InitRangeIssue $issues $sn 'HIGH' $r.High 0 127
        Add-InitRangeIssue $issues $sn 'ROOT' $r.Root 0 127
        Add-InitRangeIssue $issues $sn 'COARSE' $r.Coarse -24 24
        Add-InitRangeIssue $issues $sn 'FINE_CENT' $r.Fine -100 100
        Add-InitRangeIssue $issues $sn 'ROOT_NOTE' $r.RootNote 0 127
        Add-InitRangeIssue $issues $sn 'OCTAVE' $r.Octave -2 2
        Add-InitRangeIssue $issues $sn 'PITCH_BEND_RANGE' $r.Bend 0 24
        Add-InitRangeIssue $issues $sn 'ATTACK_MS' $r.Attack 0 2000
        Add-InitRangeIssue $issues $sn 'DECAY_MS' $r.Decay 0 2000
        Add-InitRangeIssue $issues $sn 'SUSTAIN_PCT' $r.Sustain 0 100
        Add-InitRangeIssue $issues $sn 'RELEASE_MS' $r.Release 0 2000
        Add-InitRangeIssue $issues $sn 'LEVEL' $r.Level 0 100
        Add-InitRangeIssue $issues $sn 'PAN' $r.Pan -100 100
        Add-InitRangeIssue $issues $sn 'SAMPLE_GAIN_PCT' $r.SampleGain 0 200
        Add-InitRangeIssue $issues $sn 'VELOCITY_AMOUNT_PCT' $r.Velocity 0 100
        Add-InitRangeIssue $issues $sn 'FILTER_CUTOFF' $r.Cutoff 0 100
        Add-InitRangeIssue $issues $sn 'FILTER_RESONANCE' $r.Resonance 0 100
        Add-InitRangeIssue $issues $sn 'FILTER_ENV_AMOUNT' $r.FilterEnv -100 100
        Add-InitRangeIssue $issues $sn 'FILTER_VELOCITY' $r.FilterVelocity 0 100
        Add-InitRangeIssue $issues $sn 'FILTER_KEYTRACK' $r.Keytrack 0 100
        Add-InitRangeIssue $issues $sn 'FILTER_ATTACK_MS' $r.FilterAttack 0 2000
        Add-InitRangeIssue $issues $sn 'FILTER_DECAY_MS' $r.FilterDecay 0 2000
        Add-InitRangeIssue $issues $sn 'FILTER_SUSTAIN_PCT' $r.FilterSustain 0 100
        Add-InitRangeIssue $issues $sn 'FILTER_RELEASE_MS' $r.FilterRelease 0 2000
        Add-InitRangeIssue $issues $sn 'VINTAGE_PRESET' $r.VintagePreset 0 15
        Add-InitRangeIssue $issues $sn 'VINTAGE_SAMPLE_RATE' $r.VintageRate 0 100
        Add-InitRangeIssue $issues $sn 'VINTAGE_BIT_DEPTH' $r.VintageBits 0 100
        Add-InitRangeIssue $issues $sn 'VINTAGE_FILTER' $r.VintageFilter 0 100
        Add-InitRangeIssue $issues $sn 'VINTAGE_JITTER' $r.VintageJitter 0 100
        Add-InitRangeIssue $issues $sn 'VOICE_MODE' $r.VoiceMode 0 2
        Add-InitRangeIssue $issues $sn 'VOICE_LIMIT' $r.VoiceLimit 1 12
        Add-InitRangeIssue $issues $sn 'NOTE_PRIORITY' $r.Priority 0 2
        Add-InitRangeIssue $issues $sn 'GLIDE_MS' $r.Glide 0 2000
        Add-InitRangeIssue $issues $sn 'ECHO_SEND' $r.EchoSend 0 100
        Add-InitRangeIssue $issues $sn 'REVERB_SEND' $r.ReverbSend 0 100
        Add-InitRangeIssue $issues $sn 'QUATTRO_LOW' $r.QuattroLow 0 127
        Add-InitRangeIssue $issues $sn 'QUATTRO_HIGH' $r.QuattroHigh 0 127
        Add-InitRangeIssue $issues $sn 'MIDI_CHANNEL' $r.MidiChannel 1 16

        if(([int]$r.Low) -gt ([int]$r.High)){$issues.Add("${sn}: LOW must be <= HIGH")}
        if(([int]$r.QuattroLow) -gt ([int]$r.QuattroHigh)){$issues.Add("${sn}: QUATTRO_LOW must be <= QUATTRO_HIGH")}
    }
    if($issues.Count -eq 0){
        $script:InitSoundValidationText.Text='Firmware limits: OK'
        $script:InitSoundValidationText.Foreground='#87C58B'
        return $true
    }
    $show=@($issues | Select-Object -First 6)
    $suffix=$(if($issues.Count -gt 6){" | +$($issues.Count-6) more"}else{''})
    $script:InitSoundValidationText.Text=([string]::Join(' | ',$show)+$suffix)
    $script:InitSoundValidationText.Foreground='#F0A060'
    return $false
}

function Update-InitSoundEditor {
    if($null-eq$script:InitSoundGrid){return}
    $script:InitSoundSyncing=$true
    try {
        $script:InitSoundData=Read-InitSoundTemplate
        $d=$script:InitSoundData
        $script:InitQuattroModeBox.Text=[string]$d.QuattroMode
        $script:InitEchoDelayBox.Text=[string]$d.EchoDelay
        $script:InitEchoFeedbackBox.Text=[string]$d.EchoFeedback
        $script:InitEchoMixBox.Text=[string]$d.EchoMix
        $script:InitReverbSizeBox.Text=[string]$d.ReverbSize
        $script:InitReverbDecayBox.Text=[string]$d.ReverbDecay
        $script:InitReverbDampBox.Text=[string]$d.ReverbDamp
        $script:InitReverbMixBox.Text=[string]$d.ReverbMix
        $script:InitSoundGrid.ItemsSource=$null; $script:InitSoundGrid.ItemsSource=$d.Slots
        $path=Get-InitSoundPath; $script:InitSoundPathText.Text=$(if($path){$path}else{'Phoenix nicht verbunden'})
        Set-InitSoundDirty $false; [void](Update-InitSoundValidation)
    } finally { $script:InitSoundSyncing=$false }
}

function Restore-InitSoundFactory {
    $script:InitSoundSyncing=$true
    try {
        $script:InitSoundData=New-InitSoundFactoryData; $d=$script:InitSoundData
        $script:InitQuattroModeBox.Text=[string]$d.QuattroMode; $script:InitEchoDelayBox.Text=[string]$d.EchoDelay; $script:InitEchoFeedbackBox.Text=[string]$d.EchoFeedback; $script:InitEchoMixBox.Text=[string]$d.EchoMix
        $script:InitReverbSizeBox.Text=[string]$d.ReverbSize
        $script:InitReverbDecayBox.Text=[string]$d.ReverbDecay
        $script:InitReverbDampBox.Text=[string]$d.ReverbDamp
        $script:InitReverbMixBox.Text=[string]$d.ReverbMix
        $script:InitSoundGrid.ItemsSource=$null; $script:InitSoundGrid.ItemsSource=$d.Slots
    } finally { $script:InitSoundSyncing=$false }
    Set-InitSoundDirty; [void](Update-InitSoundValidation)
}

function Save-InitSoundTemplate {
    if($null-eq$script:InitSoundData){return}
    Commit-InitSoundGridEdits
    if(-not(Update-InitSoundValidation)){return}
    $path=Get-InitSoundPath
    if([string]::IsNullOrWhiteSpace($path)){[Windows.MessageBox]::Show('Phoenix ist nicht verbunden.','INIT SOUND','OK','Warning')|Out-Null;return}
    try {
        [void](Test-PhoenixWriteAccess)
        $qm=Convert-InitInt $script:InitQuattroModeBox.Text 1 0 1; $ed=Convert-InitInt $script:InitEchoDelayBox.Text 250 50 2000; $ef=Convert-InitInt $script:InitEchoFeedbackBox.Text 35 0 90; $em=Convert-InitInt $script:InitEchoMixBox.Text 20 0 100; $rs=Convert-InitInt $script:InitReverbSizeBox.Text 55 0 100; $rd=Convert-InitInt $script:InitReverbDecayBox.Text 55 0 100; $rp=Convert-InitInt $script:InitReverbDampBox.Text 45 0 100; $rm=Convert-InitInt $script:InitReverbMixBox.Text 20 0 100
        $lines=New-Object System.Collections.Generic.List[string]
        $lines.Add('VERSION=1');$lines.Add('');$lines.Add('[GLOBAL]');$lines.Add('QUATTRO_MODE='+$qm);$lines.Add('');$lines.Add('[FX]');$lines.Add('ECHO_DELAY_MS='+$ed);$lines.Add('ECHO_FEEDBACK='+$ef);$lines.Add('ECHO_MIX='+$em);$lines.Add('REVERB_SIZE='+$rs);$lines.Add('REVERB_DECAY='+$rd);$lines.Add('REVERB_DAMP='+$rp);$lines.Add('REVERB_MIX='+$rm)
        for($i=0;$i-lt4;$i++){$r=$script:InitSoundData.Slots[$i];$lines.Add('');$lines.Add('[SLOT'+($i+1)+']')
            $pairs=[ordered]@{
                MULTISAMPLE_ENABLED=$(if($r.Multisample){1}else{0}); LOW=$r.Low; HIGH=$r.High; ROOT=$r.Root; COARSE=$r.Coarse; FINE_CENT=$r.Fine; ROOT_NOTE=$r.RootNote; OCTAVE=$r.Octave; PITCH_TRACKING=$(if($r.PitchTrack){1}else{0}); PITCH_BEND_RANGE=$r.Bend;
                ATTACK_MS=$r.Attack; DECAY_MS=$r.Decay; SUSTAIN_PCT=$r.Sustain; RELEASE_MS=$r.Release; LEVEL=$r.Level; PAN=$r.Pan; SAMPLE_GAIN_PCT=$r.SampleGain; VELOCITY_AMOUNT_PCT=$r.Velocity;
                FILTER_CUTOFF=$r.Cutoff; FILTER_RESONANCE=$r.Resonance; FILTER_ENV_AMOUNT=$r.FilterEnv; FILTER_VELOCITY=$r.FilterVelocity; FILTER_KEYTRACK=$r.Keytrack; FILTER_ATTACK_MS=$r.FilterAttack; FILTER_DECAY_MS=$r.FilterDecay; FILTER_SUSTAIN_PCT=$r.FilterSustain; FILTER_RELEASE_MS=$r.FilterRelease;
                VINTAGE_PRESET=$r.VintagePreset; VINTAGE_SAMPLE_RATE=$r.VintageRate; VINTAGE_BIT_DEPTH=$r.VintageBits; VINTAGE_FILTER=$r.VintageFilter; VINTAGE_JITTER=$r.VintageJitter; VOICE_MODE=$r.VoiceMode; VOICE_LIMIT=$r.VoiceLimit; NOTE_PRIORITY=$r.Priority; GLIDE_MS=$r.Glide; ECHO_SEND=$r.EchoSend; REVERB_SEND=$r.ReverbSend; QUATTRO_LOW=$r.QuattroLow; QUATTRO_HIGH=$r.QuattroHigh; MIDI_CHANNEL=$r.MidiChannel
            }
            foreach($k in $pairs.Keys){$lines.Add($k+'='+$pairs[$k])}
        }
        if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination ($path+'.bak') -Force}
        # PowerShell 5.1-safe UTF-8 without relying on default encoding semantics.
        [IO.File]::WriteAllLines($path,$lines,(New-Object Text.UTF8Encoding($false)))
        Add-Log ('INIT_SOUND.CFG gespeichert: '+$path); $script:StatusText.Text='INIT SOUND TEMPLATE gespeichert'; Set-InitSoundDirty $false
    } catch { [Windows.MessageBox]::Show($_.Exception.Message,'INIT SOUND speichern','OK','Error')|Out-Null }
}

function Set-EffectsDirty {
    param([bool]$Dirty=$true)
    $script:EffectsDirty=$Dirty
    if($script:EffectsSaveButton){$script:EffectsSaveButton.IsEnabled=$Dirty}
    if($script:EffectsDirtyText){$script:EffectsDirtyText.Text=$(if($Dirty){'NICHT GESPEICHERT'}else{''})}
    Update-SystemStatusView
}

function Get-EffectsInt {
    param($Control,[int]$Default=0)
    $v=0
    if($null-ne$Control -and [int]::TryParse([string]$Control.Text,[ref]$v)){return $v}
    return $Default
}

function Update-EffectsValidation {
    if($null-eq$script:EffectsInspectorData){return $false}
    $issues=New-Object System.Collections.Generic.List[string]
    $d=Get-EffectsInt $script:EchoDelayBox 250; $f=Get-EffectsInt $script:EchoFeedbackBox 35; $m=Get-EffectsInt $script:EchoMixBox 20
    $rs=Get-EffectsInt $script:ReverbSizeBox 55; $rd=Get-EffectsInt $script:ReverbDecayBox 55; $rp=Get-EffectsInt $script:ReverbDampBox 45; $rm=Get-EffectsInt $script:ReverbMixBox 20
    if($d-lt50-or$d-gt2000){$issues.Add('Echo Time muss zwischen 50 und 2000 ms liegen.')}
    if($f-lt0-or$f-gt90){$issues.Add('Feedback muss zwischen 0 und 90 % liegen.')}
    if($m-lt0-or$m-gt100){$issues.Add('Echo Mix muss zwischen 0 und 100 % liegen.')}
    if($rs-lt0-or$rs-gt100){$issues.Add('Reverb Size muss zwischen 0 und 100 % liegen.')}
    if($rd-lt0-or$rd-gt100){$issues.Add('Reverb Decay muss zwischen 0 und 100 % liegen.')}
    if($rp-lt0-or$rp-gt100){$issues.Add('Reverb Damp muss zwischen 0 und 100 % liegen.')}
    if($rm-lt0-or$rm-gt100){$issues.Add('Reverb Mix muss zwischen 0 und 100 % liegen.')}
    foreach($r in $script:EffectsInspectorData.Slots){
        foreach($spec in @(@('EchoSend',0,100),@('ReverbSend',0,100),@('FilterCutoff',0,100),@('Resonance',0,100),@('FilterEnv',-100,100),@('FilterVelocity',0,100),@('FilterKeytrack',0,100),@('VintagePreset',0,15),@('VintageRate',0,100),@('VintageBits',0,100),@('VintageFilter',0,100),@('VintageJitter',0,100))){
            $name=$spec[0];$v=[int]$r.$name;if($v-lt[int]$spec[1]-or$v-gt[int]$spec[2]){$issues.Add("$($r.Slot): $name außerhalb $($spec[1])..$($spec[2]).")}
        }
    }
    if($issues.Count-eq0){$script:EffectsValidationText.Text='Werteprüfung: OK';$script:EffectsValidationText.Foreground='#87C58B';return $true}
    $script:EffectsValidationText.Text=[string]::Join('  |  ',$issues);$script:EffectsValidationText.Foreground='#F0A060';return $false
}

function Commit-EffectsGridEdits {
    if($script:EffectsGrid){$script:EffectsGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell,$true)|Out-Null;$script:EffectsGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row,$true)|Out-Null}
}

function Update-EffectsInspector {
    if($null -eq $script:CurrentBank -or $null -eq $script:CurrentBank.Config){return}
    $script:EffectsSyncing=$true
    try{
        $script:EffectsInspectorData=Read-PhoenixEffects $script:CurrentBank
        $script:EchoDelayBox.Text=[string]$script:EffectsInspectorData.EchoDelay
        $script:EchoFeedbackBox.Text=[string]$script:EffectsInspectorData.EchoFeedback
        $script:EchoMixBox.Text=[string]$script:EffectsInspectorData.EchoMix
        $script:ReverbSizeBox.Text=[string]$script:EffectsInspectorData.ReverbSize
        $script:ReverbDecayBox.Text=[string]$script:EffectsInspectorData.ReverbDecay
        $script:ReverbDampBox.Text=[string]$script:EffectsInspectorData.ReverbDamp
        $script:ReverbMixBox.Text=[string]$script:EffectsInspectorData.ReverbMix
        $script:EffectsGrid.ItemsSource=$null;$script:EffectsGrid.ItemsSource=$script:EffectsInspectorData.Slots
        if($script:EffectsGrid.Items.Count-gt0){$script:EffectsGrid.SelectedIndex=0}
        Set-EffectsDirty $false;[void](Update-EffectsValidation)
    }finally{$script:EffectsSyncing=$false}
}

function Copy-EffectsSlot {
    Commit-EffectsGridEdits
    if($null-eq$script:EffectsGrid.SelectedItem){return}
    $r=$script:EffectsGrid.SelectedItem;$script:EffectsClipboard=@{}
    foreach($n in @('EchoSend','ReverbSend','FilterCutoff','Resonance','FilterEnv','FilterVelocity','FilterKeytrack','VintagePreset','VintageRate','VintageBits','VintageFilter','VintageJitter')){$script:EffectsClipboard[$n]=[int]$r.$n}
    $script:StatusText.Text="$($r.Slot): Effektwerte kopiert"
}
function Paste-EffectsSlot {
    if($null-eq$script:EffectsGrid.SelectedItem-or$null-eq$script:EffectsClipboard){return}
    $r=$script:EffectsGrid.SelectedItem;foreach($n in $script:EffectsClipboard.Keys){$r.$n=$script:EffectsClipboard[$n]}
    $script:EffectsGrid.Items.Refresh();Set-EffectsDirty;[void](Update-EffectsValidation)
}
function Reset-EffectsSlot {
    if($null-eq$script:EffectsGrid.SelectedItem){return};$r=$script:EffectsGrid.SelectedItem
    $r.EchoSend=0;$r.ReverbSend=0;$r.FilterCutoff=100;$r.Resonance=0;$r.FilterEnv=0;$r.FilterVelocity=0;$r.FilterKeytrack=0;$r.VintagePreset=0;$r.VintageRate=0;$r.VintageBits=0;$r.VintageFilter=0;$r.VintageJitter=0
    $script:EffectsGrid.Items.Refresh();Set-EffectsDirty;[void](Update-EffectsValidation)
}
function Play-EffectsSlotPreview {
    if($null-eq$script:CurrentBank -or $null-eq$script:EffectsInspectorData){return}
    Commit-EffectsGridEdits
    if(-not(Update-EffectsValidation)){return}
    $idx=[Math]::Max(0,$script:EffectsPreviewSlotCombo.SelectedIndex)
    $slot=$script:CurrentBank.Slots[$idx]
    if($null-eq$slot -or -not(Test-Path -LiteralPath $slot.FilePath)){[Windows.MessageBox]::Show('Der gewählte Slot enthält kein abspielbares WAV-Sample.','Effektvorschau','OK','Information')|Out-Null;return}
    Preload-TransportAudioSamples;[PhoenixOfflineRenderer]::ClearEvents();Set-OfflinePreviewEffects
    $root=[int](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'ROOT' 60) 60);$level=[double](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'LEVEL' 100) 100);$pan=[double](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'PAN' 0) 0);$fx=$script:EffectsInspectorData.Slots[$idx]
    [PhoenixOfflineRenderer]::AddEvent($idx,0,132300,$root,$root,110,$level,$pan,[int]$fx.EchoSend,[int]$fx.FilterCutoff,[int]$fx.Resonance,[int]$fx.FilterEnv,[int]$fx.FilterVelocity,[int]$fx.FilterKeytrack,[int]$fx.VintagePreset,[int]$fx.VintageRate,[int]$fx.VintageBits,[int]$fx.VintageFilter,[int]$fx.VintageJitter)
    try {
        $renderPath=New-TransportRenderPath
        $info=[PhoenixOfflineRenderer]::Render($renderPath,132300);Add-Log ('Effektvorschau S'+($idx+1)+': '+$info)
        $script:TransportMediaPlayer.Open((New-Object System.Uri -ArgumentList $renderPath));$script:TransportMediaPlayer.Play()
    } catch {
        Add-Log ('Effektvorschau Fehler: '+$_.Exception.Message)
        [Windows.MessageBox]::Show(('Die Effektvorschau konnte nicht erzeugt werden.`n`n'+$_.Exception.Message),'Effektvorschau','OK','Error')|Out-Null
    }
}
function Play-EffectsPatternPreview {
    if($null-eq$script:PatternInspectorData){return};Preload-TransportAudioSamples
    $forceRoot=($null-ne$script:EffectsPitchModeCombo -and $script:EffectsPitchModeCombo.SelectedIndex -eq 0)
    $fullSample=($null-ne$script:EffectsDurationModeCombo -and $script:EffectsDurationModeCombo.SelectedIndex -eq 0)
    $bpm=[Math]::Max(40,[Math]::Min(240,[int]$script:PatternInspectorData.Bpm));$stepMs=60000.0/$bpm/4.0
    Render-TransportAudio 'PATTERN' $stepMs ([Math]::Max(0,$script:PatternSelectCombo.SelectedIndex)) $forceRoot $fullSample
    Add-Log ('Effekt-Pattern-Vorschau: Tonhöhe=' + $(if($forceRoot){'Original'}else{'Step-Note'}) + ', Dauer=' + $(if($fullSample){'vollständig'}else{'Gate'}))
}

function Save-EffectsChanges {
    if($null-eq$script:CurrentBank-or$null-eq$script:EffectsInspectorData){return};Commit-EffectsGridEdits
    if(-not(Update-EffectsValidation)){[Windows.MessageBox]::Show('Bitte zuerst die markierten Effektwerte korrigieren.','Effekte speichern','OK','Warning')|Out-Null;return}
    try{
        [void](Test-PhoenixWriteAccess);$cfg=Join-Path $script:CurrentBank.Path 'BANK.CFG';$stamp=Get-Date -Format 'yyyyMMdd_HHmmss';Copy-Item $cfg ($cfg+'.bak_'+$stamp) -Force
        $tmp=$cfg+'.fx_global';Write-ConfigWithGlobalUpdates $cfg $tmp @{'ECHO_DELAY_MS'=[string](Get-EffectsInt $script:EchoDelayBox 250);'ECHO_FEEDBACK'=[string](Get-EffectsInt $script:EchoFeedbackBox 35);'ECHO_MIX'=[string](Get-EffectsInt $script:EchoMixBox 20);'REVERB_SIZE'=[string](Get-EffectsInt $script:ReverbSizeBox 55);'REVERB_DECAY'=[string](Get-EffectsInt $script:ReverbDecayBox 55);'REVERB_DAMP'=[string](Get-EffectsInt $script:ReverbDampBox 45);'REVERB_MIX'=[string](Get-EffectsInt $script:ReverbMixBox 20)};Move-Item $tmp $cfg -Force
        for($i=0;$i-lt4;$i++){$r=$script:EffectsInspectorData.Slots[$i];$u=@{'ECHO_SEND'=[string]$r.EchoSend;'REVERB_SEND'=[string]$r.ReverbSend;'FILTER_CUTOFF'=[string]$r.FilterCutoff;'FILTER_RESONANCE'=[string]$r.Resonance;'FILTER_ENV_AMOUNT'=[string]$r.FilterEnv;'FILTER_VELOCITY'=[string]$r.FilterVelocity;'FILTER_KEYTRACK'=[string]$r.FilterKeytrack;'VINTAGE_PRESET'=[string]$r.VintagePreset;'VINTAGE_SAMPLE_RATE'=[string]$r.VintageRate;'VINTAGE_BIT_DEPTH'=[string]$r.VintageBits;'VINTAGE_FILTER'=[string]$r.VintageFilter;'VINTAGE_JITTER'=[string]$r.VintageJitter};$tmp=$cfg+'.fx_slot';Write-ConfigWithSlotUpdates $cfg $tmp ($i+1) $u;Move-Item $tmp $cfg -Force}
        $tmp=$cfg+'.bank16';Write-ConfigWithBankVersion $cfg $tmp 16;Move-Item $tmp $cfg -Force
        $name=$script:CurrentBank.Name;Add-Log "${name}: BANK16 Echo/Reverb- und Effektparameter gespeichert.";Refresh-And-SelectBank $name;$script:StatusText.Text='BANK16 Echo/Reverb- und Effektparameter gespeichert'
    }catch{[Windows.MessageBox]::Show($_.Exception.Message,'Effekte speichern','OK','Error')|Out-Null}
}


# -----------------------------------------------------------------------------
# v1.0.0 RC4a Phase 24a: Full RAM Pitch Prewarm & Zero-File Note-On
# Live MIDI/keyboard playback no longer uses WPF MediaPlayer. Pattern/song and
# editor previews intentionally keep the proven offline renderer/MediaPlayer.
# -----------------------------------------------------------------------------
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Diagnostics;

public static class PhoenixWasapiLiveEngine
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject { }

    private enum EDataFlow { eRender=0, eCapture=1, eAll=2 }
    private enum ERole { eConsole=0, eMultimedia=1, eCommunications=2 }
    private enum CLSCTX : uint { ALL=23 }
    private enum AudioClientShareMode { Shared=0, Exclusive=1 }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    private interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(EDataFlow dataFlow, uint dwStateMask, out object ppDevices);
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppEndpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
        int RegisterEndpointNotificationCallback(IntPtr pClient);
        int UnregisterEndpointNotificationCallback(IntPtr pClient);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    private interface IMMDevice
    {
        int Activate([In] ref Guid iid, CLSCTX dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        int OpenPropertyStore(uint stgmAccess, out IntPtr ppProperties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        int GetState(out uint pdwState);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")]
    private interface IAudioClient
    {
        int Initialize(AudioClientShareMode ShareMode, uint StreamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, IntPtr AudioSessionGuid);
        int GetBufferSize(out uint pNumBufferFrames);
        int GetStreamLatency(out long phnsLatency);
        int GetCurrentPadding(out uint pNumPaddingFrames);
        int IsFormatSupported(AudioClientShareMode ShareMode, IntPtr pFormat, out IntPtr ppClosestMatch);
        int GetMixFormat(out IntPtr ppDeviceFormat);
        int GetDevicePeriod(out long phnsDefaultDevicePeriod, out long phnsMinimumDevicePeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr eventHandle);
        int GetService([In] ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("7ED4EE07-8E67-4CD4-8C1A-2B7A5987AD42")]
    private interface IAudioClient3
    {
        // IAudioClient
        int Initialize(AudioClientShareMode ShareMode, uint StreamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, IntPtr AudioSessionGuid);
        int GetBufferSize(out uint pNumBufferFrames);
        int GetStreamLatency(out long phnsLatency);
        int GetCurrentPadding(out uint pNumPaddingFrames);
        int IsFormatSupported(AudioClientShareMode ShareMode, IntPtr pFormat, out IntPtr ppClosestMatch);
        int GetMixFormat(out IntPtr ppDeviceFormat);
        int GetDevicePeriod(out long phnsDefaultDevicePeriod, out long phnsMinimumDevicePeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr eventHandle);
        int GetService([In] ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        // IAudioClient2
        int IsOffloadCapable(int Category, [MarshalAs(UnmanagedType.Bool)] out bool pbOffloadCapable);
        int SetClientProperties(IntPtr pProperties);
        int GetBufferSizeLimits(IntPtr pFormat, [MarshalAs(UnmanagedType.Bool)] bool bEventDriven, out long phnsMinBufferDuration, out long phnsMaxBufferDuration);
        // IAudioClient3
        int GetSharedModeEnginePeriod(IntPtr pFormat, out uint pDefaultPeriodInFrames, out uint pFundamentalPeriodInFrames, out uint pMinPeriodInFrames, out uint pMaxPeriodInFrames);
        int GetCurrentSharedModeEnginePeriod(out IntPtr ppFormat, out uint pCurrentPeriodInFrames);
        int InitializeSharedAudioStream(uint StreamFlags, uint PeriodInFrames, IntPtr pFormat, IntPtr AudioSessionGuid);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2")]
    private interface IAudioRenderClient
    {
        int GetBuffer(uint NumFramesRequested, out IntPtr ppData);
        int ReleaseBuffer(uint NumFramesWritten, uint dwFlags);
    }

    private sealed class Sample
    {
        public float[] L;
        public float[] R;
        public int Rate;
        public int Frames;
    }

    private sealed class Voice
    {
        public int Id;
        public Sample S;
        public double Pos;
        public double BaseStep;
        public int SampleStart;
        public int LoopStart;
        public int LoopEnd;
        public int SampleEnd;
        public int LoopMode;
        public int XFadeFrames;
        public int Direction;
        public long LoopTurns;
        public float GL;
        public float GR;
        public int Channel;
        public volatile bool Release;
        public int FadeFrames;
        public int FadeLeft;
        public long Seq;
        public long EnqueueTick;
        public bool FirstMixSeen;
    }

    private sealed class AudioCommand
    {
        public int Kind; // 1=AddVoice, 2=StopVoice, 3=StopAll, 4=PitchBend, 5=ClearVoices
        public int VoiceId;
        public Sample S;
        public double Pos;
        public double BaseStep;
        public int SampleStart;
        public int LoopStart;
        public int LoopEnd;
        public int SampleEnd;
        public int LoopMode;
        public int XFadeFrames;
        public int Direction;
        public float GL;
        public float GR;
        public int Channel;
        public int FadeFrames;
        public long Seq;
        public long EnqueueTick;
        public double Value;
    }

    private const int MaxVoices = 16;
    private const int CommandCapacity = 256;
    private static readonly object Sync = new object(); // sample-cache only; never entered by the render thread
    private static readonly Dictionary<string, Sample> Samples = new Dictionary<string, Sample>(StringComparer.OrdinalIgnoreCase);
    private static readonly List<Voice> Voices = new List<Voice>(MaxVoices); // audio-thread owned, capacity fixed
    private static readonly Voice[] VoicePool = CreateVoicePool();
    private static readonly AudioCommand[] CommandRing = CreateCommandRing();
    private static readonly object CommandWriteSync = new object(); // producers only; render thread never enters
    private static int CommandWriteIndex = 0;
    private static int CommandReadIndex = 0;
    private static long CommandDrops = 0;
    private static readonly double[] BendRatio = new double[17];
    private static int ActiveVoiceCount = 0;
    private static Thread Thread;
    private static volatile bool Run;
    private static IAudioClient Client;
    private static IAudioClient3 Client3;
    private static IAudioRenderClient Render;
    private static IntPtr MixFmt = IntPtr.Zero;
    private static uint BufferFrames;
    private static int OutRate = 48000;
    private static int OutChannels = 2;
    private static int Bits = 32;
    private static bool FloatOut = true;
    private static long Sequence;
    private static string LastError = "";
    private static AutoResetEvent AudioEvent;
    private static bool EventDriven = false;
    private static bool UsingAudioClient3 = false;
    private static bool ExclusiveMode = false;
    private static int ExclusiveRequestedFrames = 0;
    private static int ExclusiveActualFrames = 0;
    private static string ExclusiveFallbackReason = "";
    private static string ExclusiveProbeDiagnostics = "";
    private static long DeviceDefaultPeriodHns = 0;
    private static long DeviceMinimumPeriodHns = 0;
    private static int TargetFrames = 480;
    private static uint PeriodDefault = 0;
    private static uint PeriodFundamental = 0;
    private static uint PeriodMin = 0;
    private static uint PeriodMax = 0;
    private static uint PeriodChosen = 0;
    private static uint PeriodCurrent = 0;
    private static string Client3FallbackReason = "";
    private static long StreamLatencyHns = 0;
    private static double LastFirstMixMs = -1.0;
    private static int LastFirstMixVoiceId = -1;
    private static long EventWakeups = 0;
    private static long EventTimeouts = 0;
    private static long BufferWrites = 0;
    private static long AudioLoopErrors = 0;
    private static long LastAudioWriteTick = 0;
    private static long LastEventTick = 0;
    private static long LateWakeups = 0;
    private static long UnderrunRiskEvents = 0;
    private static long SevereWakeups = 0;
    private static long DropoutCount = 0;
    private static long AlternateLoopTurns = 0;
    private static long AlternateBoundaryCorrections = 0;
    private static long ConsecutiveLateWakeups = 0;
    private static long LateWindowStartTick = 0;
    private static int LateWakeupsInWindow = 0;
    private static double LastWakeIntervalMs = 0.0;
    private static double WorstWakeIntervalMs = 0.0;
    private static volatile bool AdaptiveSwitchPending = false;
    private static int PreferredExclusiveFrames = 480;
    private static string AudioProfile = "LIVE-10ms";
    private static int AdaptiveSafetyFrames = 0;
    private static bool MmcssActive = false;
    private static string MmcssStatus = "not started";
    // RC5l: primitive timing counters only; no formatting/logging occurs on the audio thread.
    private static long EventIntervalCount = 0;
    private static double EventIntervalSumMs = 0.0;
    private static long MixTimingCount = 0;
    private static double MixTimingSumMs = 0.0;
    private static double LastMixTimeMs = 0.0;
    private static double WorstMixTimeMs = 0.0;
    private static long WriteTimingCount = 0;
    private static double WriteTimingSumMs = 0.0;
    private static double LastWriteTimeMs = 0.0;
    private static double WorstWriteTimeMs = 0.0;
    private static long DeadlineMissCount = 0;
    private static double LastDeadlineExpectedMs = 0.0;
    private static double LastDeadlineActualMs = 0.0;
    private static double LastDeadlineLateByMs = 0.0;
    private static double LastDeadlineVoicePos = -1.0;
    private static long RenderLoopTimingCount = 0;
    private static double RenderLoopTimingSumMs = 0.0;
    private static double LastRenderLoopTimeMs = 0.0;
    private static double WorstRenderLoopTimeMs = 0.0;
    private static long CommandsProcessed = 0;

    [DllImport("avrt.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr AvSetMmThreadCharacteristics(string TaskName, out uint TaskIndex);
    [DllImport("avrt.dll", SetLastError=true)]
    private static extern bool AvRevertMmThreadCharacteristics(IntPtr AvrtHandle);

    private static Voice[] CreateVoicePool()
    {
        Voice[] a=new Voice[MaxVoices];
        for(int i=0;i<a.Length;i++) a[i]=new Voice();
        return a;
    }
    private static AudioCommand[] CreateCommandRing()
    {
        AudioCommand[] a=new AudioCommand[CommandCapacity];
        for(int i=0;i<a.Length;i++) a[i]=new AudioCommand();
        return a;
    }
    private static int CommandCountUnsafe()
    {
        int w=Interlocked.CompareExchange(ref CommandWriteIndex,0,0);
        int r=Interlocked.CompareExchange(ref CommandReadIndex,0,0);
        return w>=r ? (w-r) : (CommandCapacity-r+w);
    }
    private static bool EnqueueCommand(int kind, int voiceId, Sample sm, double pos, double baseStep,
        int sampleStart, int loopStart, int loopEnd, int sampleEnd, int loopMode, int xfadeFrames,
        int direction, float gl, float gr, int channel, int fadeFrames, long seq, long enqueueTick, double value)
    {
        lock(CommandWriteSync)
        {
            int w=CommandWriteIndex;
            int next=(w+1)%CommandCapacity;
            if(next==Interlocked.CompareExchange(ref CommandReadIndex,0,0)) { Interlocked.Increment(ref CommandDrops); return false; }
            AudioCommand c=CommandRing[w];
            c.Kind=kind; c.VoiceId=voiceId; c.S=sm; c.Pos=pos; c.BaseStep=baseStep;
            c.SampleStart=sampleStart; c.LoopStart=loopStart; c.LoopEnd=loopEnd; c.SampleEnd=sampleEnd;
            c.LoopMode=loopMode; c.XFadeFrames=xfadeFrames; c.Direction=direction; c.GL=gl; c.GR=gr;
            c.Channel=channel; c.FadeFrames=fadeFrames; c.Seq=seq; c.EnqueueTick=enqueueTick; c.Value=value;
            Thread.MemoryBarrier(); Interlocked.Exchange(ref CommandWriteIndex,next); return true;
        }
    }
    private static bool TryDequeueCommand(out AudioCommand c)
    {
        int r=CommandReadIndex;
        if(r==Interlocked.CompareExchange(ref CommandWriteIndex,0,0)) { c=null; return false; }
        c=CommandRing[r]; Thread.MemoryBarrier(); Interlocked.Exchange(ref CommandReadIndex,(r+1)%CommandCapacity); return true;
    }
    private static Voice AcquireVoice(int voiceId)
    {
        for(int i=Voices.Count-1;i>=0;i--) if(Voices[i].Id==voiceId){Voice same=Voices[i];Voices.RemoveAt(i);return same;}
        if(Voices.Count>=MaxVoices)
        {
            int oldest=0; long seq=Voices[0].Seq;
            for(int i=1;i<Voices.Count;i++) if(Voices[i].Seq<seq){seq=Voices[i].Seq;oldest=i;}
            Voice steal=Voices[oldest]; Voices.RemoveAt(oldest); return steal;
        }
        for(int p=0;p<VoicePool.Length;p++)
        {
            bool used=false; for(int i=0;i<Voices.Count;i++) if(Object.ReferenceEquals(Voices[i],VoicePool[p])){used=true;break;}
            if(!used) return VoicePool[p];
        }
        return VoicePool[0];
    }

    private static volatile bool NoGcPreviewActive=false;
    private static string NoGcPreviewStatus="inactive";
    private static int NoGcStart0=0, NoGcStart1=0, NoGcStart2=0;
    private static int NoGcEnd0=0, NoGcEnd1=0, NoGcEnd2=0;
    public static string BeginNoGcPreview()
    {
        try
        {
            if(NoGcPreviewActive) return "UNCHANGED: active";
            GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
            NoGcStart0=GC.CollectionCount(0); NoGcStart1=GC.CollectionCount(1); NoGcStart2=GC.CollectionCount(2);
            bool ok=false;
            try { ok=GC.TryStartNoGCRegion(268435456L); } catch(Exception ex) { NoGcPreviewStatus="UNAVAILABLE("+ex.GetType().Name+")"; return NoGcPreviewStatus; }
            NoGcPreviewActive=ok; NoGcPreviewStatus=ok?"ACTIVE-256MB":"FAILED"; return NoGcPreviewStatus;
        }
        catch(Exception ex){NoGcPreviewActive=false;NoGcPreviewStatus="ERROR("+ex.GetType().Name+")";return NoGcPreviewStatus;}
    }
    public static string EndNoGcPreview()
    {
        try
        {
            if(NoGcPreviewActive){try{GC.EndNoGCRegion();}catch(Exception ex){NoGcPreviewStatus="END-WARN("+ex.GetType().Name+")";}finally{NoGcPreviewActive=false;}}
            NoGcEnd0=GC.CollectionCount(0); NoGcEnd1=GC.CollectionCount(1); NoGcEnd2=GC.CollectionCount(2);
            if(!NoGcPreviewStatus.StartsWith("END-WARN")) NoGcPreviewStatus="ENDED";
            return GCDiagnostics;
        }
        catch(Exception ex){NoGcPreviewActive=false;NoGcPreviewStatus="END-ERROR("+ex.GetType().Name+")";return GCDiagnostics;}
    }
    public static string GCDiagnostics { get { return "NoGC="+NoGcPreviewStatus+", Active="+NoGcPreviewActive+", GC0="+(GC.CollectionCount(0)-NoGcStart0)+", GC1="+(GC.CollectionCount(1)-NoGcStart1)+", GC2="+(GC.CollectionCount(2)-NoGcStart2)+", CommandDrops="+CommandDrops; } }

    public static bool IsRunning { get { return Run; } }
    public static double LastMixLatencyMs { get { return LastFirstMixMs; } }
    public static int ActualBufferFrames { get { return (int)BufferFrames; } }
    public static double ActualBufferMs { get { return OutRate>0 ? (1000.0*BufferFrames/OutRate) : 0.0; } }
    public static double StreamLatencyMs { get { return StreamLatencyHns/10000.0; } }
    public static string Mode { get { return ExclusiveMode ? "exclusive/event" : (UsingAudioClient3 ? "IAudioClient3/event" : (EventDriven ? "event-fallback" : "poll")); } }
    private static string Fms(uint f) { return OutRate>0 ? (f + "f/" + (1000.0*f/OutRate).ToString("F2") + "ms") : (f+"f"); }
    public static string Status { get { return Run ? ("WASAPI " + Mode + " " + OutRate + " Hz / " + Bits + " Bit / " + OutChannels + " ch, Buffer=" + BufferFrames + " Frames (" + ActualBufferMs.ToString("F2") + " ms)" + (ExclusiveMode ? ", ExclusiveRequest="+ExclusiveRequestedFrames+"f" : ", EnginePeriod=" + Fms(PeriodCurrent>0?PeriodCurrent:PeriodChosen)) + ", Stream=" + StreamLatencyMs.ToString("F2") + " ms") : ("WASAPI aus" + (LastError.Length>0 ? ": "+LastError : "")); } }
    public static string PeriodDiagnostics { get { return "Default="+Fms(PeriodDefault)+", Fundamental="+Fms(PeriodFundamental)+", Min="+Fms(PeriodMin)+", Max="+Fms(PeriodMax)+", Chosen="+Fms(PeriodChosen)+", Current="+Fms(PeriodCurrent); } }
    public static string ExclusiveDiagnostics { get { return "Mode="+(ExclusiveMode?"ACTIVE":"FALLBACK")+", Requested="+ExclusiveRequestedFrames+"f, Actual="+ExclusiveActualFrames+"f/"+(OutRate>0?(1000.0*ExclusiveActualFrames/OutRate):0.0).ToString("F2")+"ms, DeviceDefault="+(DeviceDefaultPeriodHns/10000.0).ToString("F2")+"ms, DeviceMin="+(DeviceMinimumPeriodHns/10000.0).ToString("F2")+"ms"+(ExclusiveProbeDiagnostics.Length>0?", Probe={"+ExclusiveProbeDiagnostics+"}":"")+(ExclusiveFallbackReason.Length>0?", Reason="+ExclusiveFallbackReason:""); } }
    public static bool AdaptiveRecoveryPending { get { return AdaptiveSwitchPending; } }
    public static string HealthDiagnostics { get { double idleMs=LastAudioWriteTick>0 ? (1000.0*(Stopwatch.GetTimestamp()-LastAudioWriteTick)/Stopwatch.Frequency) : -1.0; return "Running="+Run+", Wakeups="+EventWakeups+", Writes="+BufferWrites+", EventTimeouts="+EventTimeouts+", LateWakeups="+LateWakeups+", LastWake="+LastWakeIntervalMs.ToString("F2")+"ms, WorstWake="+WorstWakeIntervalMs.ToString("F2")+"ms, AudioErrors="+AudioLoopErrors+", ActiveVoices="+ActiveVoices+", AltTurns="+AlternateLoopTurns+", AltBoundaryFixes="+AlternateBoundaryCorrections+", MMCSS="+MmcssStatus+", Profile="+AudioProfile+", DropoutCount="+DropoutCount+", UnderrunRisk="+UnderrunRiskEvents+", SevereWakeups="+SevereWakeups+", Queue="+CommandCountUnsafe()+", CommandDrops="+CommandDrops+", AudioThread=GC-ISOLATED, SinceWrite="+(idleMs<0?"n/a":idleMs.ToString("F1")+"ms")+(LastError.Length>0?", LastError="+LastError:""); } }
    public static long DiagnosticDeadlineMissCount { get { return DeadlineMissCount; } }
    public static string TimingDiagnostics { get {
        double eventAvg=EventIntervalCount>0 ? EventIntervalSumMs/EventIntervalCount : 0.0;
        double mixAvg=MixTimingCount>0 ? MixTimingSumMs/MixTimingCount : 0.0;
        double writeAvg=WriteTimingCount>0 ? WriteTimingSumMs/WriteTimingCount : 0.0;
        double renderAvg=RenderLoopTimingCount>0 ? RenderLoopTimingSumMs/RenderLoopTimingCount : 0.0;
        return "Profile="+AudioProfile+", BufferFrames="+BufferFrames+", EventAvg="+eventAvg.ToString("F2")+"ms, EventLast="+LastWakeIntervalMs.ToString("F2")+"ms, EventWorst="+WorstWakeIntervalMs.ToString("F2")+"ms, MixAvg="+mixAvg.ToString("F3")+"ms, MixLast="+LastMixTimeMs.ToString("F3")+"ms, MixWorst="+WorstMixTimeMs.ToString("F3")+"ms, WriteAvg="+writeAvg.ToString("F3")+"ms, WriteLast="+LastWriteTimeMs.ToString("F3")+"ms, WriteWorst="+WorstWriteTimeMs.ToString("F3")+"ms, RenderAvg="+renderAvg.ToString("F3")+"ms, RenderLast="+LastRenderLoopTimeMs.ToString("F3")+"ms, RenderWorst="+WorstRenderLoopTimeMs.ToString("F3")+"ms, Commands="+CommandsProcessed+", LateWakeups="+LateWakeups+", SevereWakeups="+SevereWakeups+", DropoutCount="+DropoutCount+", ActiveVoices="+ActiveVoices+", DeadlineMisses="+DeadlineMissCount;
    } }
    public static string LastDeadlineMissDiagnostics { get { return "Expected="+LastDeadlineExpectedMs.ToString("F2")+"ms, Actual="+LastDeadlineActualMs.ToString("F2")+"ms, LateBy="+LastDeadlineLateByMs.ToString("F2")+"ms, VoicePos="+LastDeadlineVoicePos.ToString("F2")+", Profile="+AudioProfile+", BufferFrames="+BufferFrames; } }

    private static long FramesToHns(int frames, int rate)
    {
        return (long)Math.Round(10000000.0 * Math.Max(1,frames) / Math.Max(1,rate));
    }

    private static IntPtr AllocSimpleWaveFormat(int tag, int rate, int channels, int bits)
    {
        int bytesPerSample=bits/8; int block=channels*bytesPerSample;
        IntPtr p=Marshal.AllocCoTaskMem(18);
        for(int i=0;i<18;i++) Marshal.WriteByte(p,i,0);
        Marshal.WriteInt16(p,0,(short)tag);
        Marshal.WriteInt16(p,2,(short)channels);
        Marshal.WriteInt32(p,4,rate);
        Marshal.WriteInt32(p,8,rate*block);
        Marshal.WriteInt16(p,12,(short)block);
        Marshal.WriteInt16(p,14,(short)bits);
        Marshal.WriteInt16(p,16,(short)0);
        return p;
    }

    private const int AUDCLNT_E_UNSUPPORTED_FORMAT = unchecked((int)0x88890008);
    private const int AUDCLNT_E_DEVICE_IN_USE = unchecked((int)0x8889000A);
    private const int AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED = unchecked((int)0x88890019);

    private static bool ExclusiveFormatSupported(IAudioClient c, IntPtr fmt, string label)
    {
        IntPtr closest=IntPtr.Zero;
        try
        {
            int hr;
            try { hr=c.IsFormatSupported(AudioClientShareMode.Exclusive,fmt,out closest); }
            catch(COMException ex) { hr=ex.ErrorCode; }
            if(hr>=0) { ExclusiveProbeDiagnostics += (ExclusiveProbeDiagnostics.Length>0?"; ":"")+label+"=SUPPORTED"; return true; }
            if(hr==AUDCLNT_E_UNSUPPORTED_FORMAT) { ExclusiveProbeDiagnostics += (ExclusiveProbeDiagnostics.Length>0?"; ":"")+label+"=UNSUPPORTED(0x88890008)"; return false; }
            throw new COMException("Exclusive IsFormatSupported "+label+" HRESULT=0x"+hr.ToString("X8"),hr);
        }
        finally { if(closest!=IntPtr.Zero){try{Marshal.FreeCoTaskMem(closest);}catch{}} }
    }

    private static int InitializeExclusiveSafe(IAudioClient c, uint streamFlags, long hns, IntPtr fmt)
    {
        try { return c.Initialize(AudioClientShareMode.Exclusive,streamFlags,hns,hns,fmt,IntPtr.Zero); }
        catch(COMException ex) { return ex.ErrorCode; }
    }

    private static IAudioClient ActivateBaseClient(IMMDevice dev)
    {
        Guid iid = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"); object o;
        Check(dev.Activate(ref iid, CLSCTX.ALL, IntPtr.Zero, out o), "IMMDevice.Activate(IAudioClient)");
        return (IAudioClient)o;
    }

    private static void ReleaseClientOnly(ref IAudioClient c)
    {
        if(c!=null){ try{Marshal.ReleaseComObject(c);}catch{} c=null; }
    }

    private static bool TryInitializeExclusive(IMMDevice dev, uint streamFlags)
    {
        IAudioClient probe=null;
        string selectedFormat="";
        try
        {
            ExclusiveProbeDiagnostics="";
            probe=ActivateBaseClient(dev);
            Check(probe.GetMixFormat(out MixFmt), "Exclusive.GetMixFormat");
            ParseFormat(MixFmt);
            try{probe.GetDevicePeriod(out DeviceDefaultPeriodHns,out DeviceMinimumPeriodHns);}catch{DeviceDefaultPeriodHns=DeviceMinimumPeriodHns=0;}
            if(ExclusiveFormatSupported(probe,MixFmt,"MixFormat")) selectedFormat="MixFormat";
            else
            {
                int rate=OutRate; int ch=Math.Max(1,Math.Min(2,OutChannels));
                if(MixFmt!=IntPtr.Zero){try{Marshal.FreeCoTaskMem(MixFmt);}catch{} MixFmt=IntPtr.Zero;}
                MixFmt=AllocSimpleWaveFormat(3,rate,ch,32);
                if(ExclusiveFormatSupported(probe,MixFmt,"Float32")) selectedFormat="Float32";
                else
                {
                    try{Marshal.FreeCoTaskMem(MixFmt);}catch{} MixFmt=AllocSimpleWaveFormat(1,rate,ch,16);
                    if(ExclusiveFormatSupported(probe,MixFmt,"PCM16")) selectedFormat="PCM16";
                    else { ExclusiveFallbackReason="Exclusive formats unsupported (MixFormat/Float32/PCM16)"; return false; }
                }
                ParseFormat(MixFmt);
            }
            ExclusiveProbeDiagnostics += "; Selected="+selectedFormat;
        }
        catch(Exception ex){ExclusiveFallbackReason="Exclusive probe: "+ex.Message;return false;}
        finally{ReleaseClientOnly(ref probe);}

        // RC4h: test the endpoint's own minimum period first. 3.00 ms at
        // 48 kHz becomes 144 frames. Then keep conservative fallbacks.
        int deviceMinFrames=0;
        if(DeviceMinimumPeriodHns>0 && OutRate>0) deviceMinFrames=(int)Math.Ceiling(DeviceMinimumPeriodHns*OutRate/10000000.0);
        int[] raw = PreferredExclusiveFrames>=900 ? new int[]{PreferredExclusiveFrames,1024,960,768,512,480} : new int[]{PreferredExclusiveFrames,512,480,384,288,256,192,144,deviceMinFrames};
        System.Collections.Generic.List<int> candidates=new System.Collections.Generic.List<int>();
        for(int ri=0;ri<raw.Length;ri++) if(raw[ri]>0 && !candidates.Contains(raw[ri])) candidates.Add(raw[ri]);
        for(int ci=0;ci<candidates.Count;ci++)
        {
            int requested=candidates[ci];
            IAudioClient c=null;
            try
            {
                c=ActivateBaseClient(dev);
                long hns=FramesToHns(requested,OutRate);
                int hr=InitializeExclusiveSafe(c,streamFlags,hns,MixFmt);
                ExclusiveProbeDiagnostics += "; "+requested+"f=0x"+hr.ToString("X8");
                if(hr==AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED)
                {
                    uint aligned=0;
                    try{c.GetBufferSize(out aligned);}catch{}
                    ReleaseClientOnly(ref c);
                    if(aligned>0)
                    {
                        c=ActivateBaseClient(dev);
                        long ahns=FramesToHns((int)aligned,OutRate);
                        hr=InitializeExclusiveSafe(c,streamFlags,ahns,MixFmt);
                        ExclusiveProbeDiagnostics += "->aligned "+aligned+"f=0x"+hr.ToString("X8");
                        if(hr>=0) requested=(int)aligned;
                    }
                }
                if(hr==AUDCLNT_E_DEVICE_IN_USE)
                {
                    ExclusiveFallbackReason="AUDCLNT_E_DEVICE_IN_USE (0x8889000A): Exclusive endpoint is busy; switching to Shared fallback";
                    break;
                }
                if(hr>=0)
                {
                    Client=c; c=null; ExclusiveMode=true; EventDriven=true; UsingAudioClient3=false;
                    ExclusiveRequestedFrames=requested;
                    if(PreferredExclusiveFrames>0) AdaptiveSafetyFrames=requested; else AdaptiveSafetyFrames=0;
                    Check(Client.GetBufferSize(out BufferFrames),"Exclusive.GetBufferSize");
                    ExclusiveActualFrames=(int)BufferFrames;
                    PeriodChosen=PeriodCurrent=BufferFrames;
                    ExclusiveFallbackReason="";
                    return true;
                }
                ExclusiveFallbackReason="Exclusive candidates rejected; last HRESULT=0x"+hr.ToString("X8");
            }
            catch(Exception ex){ExclusiveFallbackReason="Exclusive "+requested+"f: "+ex.Message;}
            finally{ReleaseClientOnly(ref c);}
        }
        return false;
    }

    public static bool Start()
    {
        if (Run) return true;
        // RC5d: a previous failed/restarted stream must not leave COM references
        // or an event handle owning the endpoint. Clean stale state first.
        if(Client!=null || Render!=null || AudioEvent!=null || Thread!=null) ShutdownInternal();
        IMMDevice dev = null;
        IMMDeviceEnumerator en = null;
        try
        {
            en = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            Check(en.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out dev), "GetDefaultAudioEndpoint");
            const uint AUDCLNT_STREAMFLAGS_EVENTCALLBACK = 0x00040000;
            UsingAudioClient3=false; ExclusiveMode=false; ExclusiveRequestedFrames=ExclusiveActualFrames=0; ExclusiveFallbackReason=""; ExclusiveProbeDiagnostics=""; Client3FallbackReason=""; PeriodDefault=PeriodFundamental=PeriodMin=PeriodMax=PeriodChosen=PeriodCurrent=0; DeviceDefaultPeriodHns=DeviceMinimumPeriodHns=0;

            bool exclusiveOk=TryInitializeExclusive(dev,AUDCLNT_STREAMFLAGS_EVENTCALLBACK);
            if(!exclusiveOk && MixFmt!=IntPtr.Zero){try{Marshal.FreeCoTaskMem(MixFmt);}catch{} MixFmt=IntPtr.Zero;}
            if(!exclusiveOk)
            try
            {
                Guid iid3 = new Guid("7ED4EE07-8E67-4CD4-8C1A-2B7A5987AD42"); object o3;
                Check(dev.Activate(ref iid3, CLSCTX.ALL, IntPtr.Zero, out o3), "IMMDevice.Activate(IAudioClient3)");
                Client3=(IAudioClient3)o3; Client=(IAudioClient)o3;
                Check(Client3.GetMixFormat(out MixFmt), "IAudioClient3.GetMixFormat");
                ParseFormat(MixFmt);
                Check(Client3.GetSharedModeEnginePeriod(MixFmt,out PeriodDefault,out PeriodFundamental,out PeriodMin,out PeriodMax), "GetSharedModeEnginePeriod");
                if(PeriodFundamental==0) PeriodFundamental=1;
                // Minimum engine period is the low-latency target. Normalize upward
                // to a legal fundamental multiple defensively, even though Windows
                // normally returns an already-valid minimum.
                uint chosen=PeriodMin;
                uint rem=chosen%PeriodFundamental; if(rem!=0) chosen += PeriodFundamental-rem;
                if(chosen<PeriodMin) chosen=PeriodMin;
                if(chosen>PeriodMax) chosen=PeriodDefault;
                PeriodChosen=chosen;
                int hr3=Client3.InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK,PeriodChosen,MixFmt,IntPtr.Zero);
                if(hr3<0) throw new COMException("InitializeSharedAudioStream Period="+PeriodChosen+"f",hr3);
                UsingAudioClient3=true; EventDriven=true;
            }
            catch(Exception ex3)
            {
                Client3FallbackReason=ex3.Message;
                try { if(MixFmt!=IntPtr.Zero){Marshal.FreeCoTaskMem(MixFmt);MixFmt=IntPtr.Zero;} } catch {}
                try { if(Client!=null){Marshal.ReleaseComObject(Client);Client=null;} } catch {}
                Client3=null;
                // Fresh base client for the proven RC4e event-driven fallback.
                Guid iid = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"); object o;
                Check(dev.Activate(ref iid, CLSCTX.ALL, IntPtr.Zero, out o), "IMMDevice.Activate(IAudioClient fallback)");
                Client=(IAudioClient)o;
                Check(Client.GetMixFormat(out MixFmt), "GetMixFormat fallback");
                ParseFormat(MixFmt);
                long requestedHns=(long)Math.Max(1.0,Math.Round(10000000.0*TargetFrames/Math.Max(1,OutRate)));
                Check(Client.Initialize(AudioClientShareMode.Shared,AUDCLNT_STREAMFLAGS_EVENTCALLBACK,requestedHns,0,MixFmt,IntPtr.Zero), "IAudioClient.Initialize(event fallback)");
                EventDriven=true; UsingAudioClient3=false;
            }

            Check(Client.GetBufferSize(out BufferFrames), "GetBufferSize");
            try { Client.GetStreamLatency(out StreamLatencyHns); } catch { StreamLatencyHns=0; }
            if(UsingAudioClient3)
            {
                IntPtr curFmt=IntPtr.Zero; uint cur=0;
                try { if(Client3.GetCurrentSharedModeEnginePeriod(out curFmt,out cur)>=0) PeriodCurrent=cur; } catch {}
                finally { if(curFmt!=IntPtr.Zero) try { Marshal.FreeCoTaskMem(curFmt); } catch {} }
            }
            if(PeriodCurrent==0) PeriodCurrent=UsingAudioClient3?PeriodChosen:BufferFrames;
            Guid rid = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"); object ro;
            Check(Client.GetService(ref rid,out ro), "GetService(IAudioRenderClient)");
            Render=(IAudioRenderClient)ro;
            AudioEvent=new AutoResetEvent(false);
            Check(Client.SetEventHandle(AudioEvent.SafeWaitHandle.DangerousGetHandle()), "IAudioClient.SetEventHandle");
            PrimeSilence(BufferFrames);
            Check(Client.Start(), "IAudioClient.Start");
            for(int bi=0;bi<BendRatio.Length;bi++) BendRatio[bi]=1.0;
            Run=true; LastError=""; EventWakeups=0; EventTimeouts=0; BufferWrites=0; AudioLoopErrors=0; LateWakeups=0; UnderrunRiskEvents=0; SevereWakeups=0; DropoutCount=0; AlternateLoopTurns=0; AlternateBoundaryCorrections=0; ConsecutiveLateWakeups=0; LateWakeupsInWindow=0; LastWakeIntervalMs=0.0; WorstWakeIntervalMs=0.0; LastEventTick=0; LateWindowStartTick=Stopwatch.GetTimestamp(); LastAudioWriteTick=Stopwatch.GetTimestamp(); LastFirstMixMs=-1.0; LastFirstMixVoiceId=-1; MmcssActive=false; MmcssStatus="starting"; EventIntervalCount=0; EventIntervalSumMs=0.0; MixTimingCount=0; MixTimingSumMs=0.0; LastMixTimeMs=0.0; WorstMixTimeMs=0.0; WriteTimingCount=0; WriteTimingSumMs=0.0; LastWriteTimeMs=0.0; WorstWriteTimeMs=0.0; DeadlineMissCount=0; LastDeadlineExpectedMs=0.0; LastDeadlineActualMs=0.0; LastDeadlineLateByMs=0.0; LastDeadlineVoicePos=-1.0; RenderLoopTimingCount=0; RenderLoopTimingSumMs=0.0; LastRenderLoopTimeMs=0.0; WorstRenderLoopTimeMs=0.0; CommandsProcessed=0; Interlocked.Exchange(ref CommandWriteIndex,0); Interlocked.Exchange(ref CommandReadIndex,0); CommandDrops=0;
            Thread=new Thread(AudioLoop); Thread.IsBackground=true; Thread.Name="Phoenix WASAPI GC-Isolated RC5l"; Thread.Priority=ThreadPriority.Highest; Thread.Start();
            return true;
        }
        catch(Exception ex){ LastError=ex.Message; ShutdownInternal(); return false; }
        finally
        {
            // Client/Render remain valid after releasing the activation helpers.
            // Not releasing these objects was one source of sticky Exclusive locks
            // when the window/audio engine was reopened.
            if(dev!=null){try{Marshal.ReleaseComObject(dev);}catch{} dev=null;}
            if(en!=null){try{Marshal.ReleaseComObject(en);}catch{} en=null;}
        }
    }

    public static void Shutdown()
    {
        Run = false;
        try { if (AudioEvent != null) AudioEvent.Set(); } catch { }
        try { if (Thread != null && Thread.IsAlive) Thread.Join(800); } catch { }
        ShutdownInternal();
    }

    private static void ShutdownInternal()
    {
        Run=false;
        // RC5d clean teardown order: stop stream -> release render service ->
        // release audio client -> close event -> free format.
        try { if (Client != null) Client.Stop(); } catch { }
        try { if (Render != null) { Marshal.FinalReleaseComObject(Render); Render = null; } } catch { Render=null; }
        // Client3 and Client refer to the same COM identity in shared IAudioClient3
        // mode. Release through Client exactly once, then clear both references.
        Client3=null;
        try { if (Client != null) { Marshal.FinalReleaseComObject(Client); Client = null; } } catch { Client=null; }
        try { if (AudioEvent != null) { AudioEvent.Close(); AudioEvent=null; } } catch { AudioEvent=null; }
        if (MixFmt != IntPtr.Zero) { try { Marshal.FreeCoTaskMem(MixFmt); } catch { } MixFmt = IntPtr.Zero; }
        EventDriven=false; UsingAudioClient3=false; ExclusiveMode=false;
        ExclusiveRequestedFrames=ExclusiveActualFrames=0;
        BufferFrames=0; StreamLatencyHns=0; PeriodCurrent=0;
        // RC5e: keep decoded source samples across an adaptive audio-client restart.
        // Bank changes still call ClearSamples() explicitly.
        Voices.Clear();
        for(int i=0;i<BendRatio.Length;i++) BendRatio[i]=1.0;
        Interlocked.Exchange(ref ActiveVoiceCount,0);
        Interlocked.Exchange(ref CommandReadIndex,Interlocked.CompareExchange(ref CommandWriteIndex,0,0));
        Thread = null;
    }

    public static string ApplyAdaptiveSafetyIfIdle()
    {
        AdaptiveSwitchPending=false;
        return "RC5l GC-isolated audio active; fixed LIVE/EDITOR profiles";
    }

    public static string SetAudioProfile(int frames)
    {
        int wanted = frames>=900 ? 960 : 480;
        string wantedName = wanted>=900 ? "EDITOR-20ms" : "LIVE-10ms";
        PreferredExclusiveFrames=wanted; AudioProfile=wantedName;
        // RC5l: when audio is idle/stopped, only arm the profile. Do NOT acquire
        // the Windows endpoint until real playback starts.
        if(!Run) return "ARMED: "+AudioProfile+" (Audiogeraet frei)";
        if(ExclusiveMode && ExclusiveRequestedFrames==wanted) return "UNCHANGED: "+Status;
        StopAll();
        Shutdown();
        bool ok=Start();
        return (ok?"APPLIED: ":"FAILED: ")+AudioProfile+", "+Status;
    }

    public static string CurrentAudioProfile { get { return AudioProfile; } }

    public static bool Preload(string path)
    {
        // RC5l: decoding/RAM caching is independent of WASAPI ownership.
        // This permits bank loading and SD browsing while the sound device remains free.
        try { GetSample(path); return true; } catch(Exception ex){ LastError=ex.Message; return false; }
    }

    public static bool IsPreloaded(string path)
    {
        if (String.IsNullOrEmpty(path)) return false;
        lock(Sync) { return Samples.ContainsKey(path); }
    }

    public static void UnloadSample(string path)
    {
        if(String.IsNullOrEmpty(path)) return;
        lock(Sync) { Samples.Remove(path); }
    }

    public static void ClearSamples()
    {
        EnqueueCommand(5,0,null,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);
        lock(Sync) { Samples.Clear(); }
    }

    public static bool PlayNativePreloaded(int voiceId, string path, float gain, float pan, int channel, double pitchRatio,
        int sampleStart, int loopStart, int loopEnd, int sampleEnd, int loopMode, int xfadeMs)
    {
        if (!Run && !Start()) return false;
        try
        {
            Sample sm;
            lock(Sync) { if(!Samples.TryGetValue(path,out sm)) { LastError="RAM Sample fehlt: "+path; return false; } }
            int ss=Math.Max(0,Math.Min(sm.Frames-1,sampleStart));
            int se=Math.Max(ss+1,Math.Min(sm.Frames,sampleEnd<=0?sm.Frames:sampleEnd));
            int ls=Math.Max(ss,Math.Min(se-1,loopStart));
            int le=Math.Max(ls+1,Math.Min(se,loopEnd));
            int lm=(loopMode>=1 && loopMode<=2 && le>ls+1)?loopMode:0;
            int xf=Math.Max(0,Math.Min((le-ls)/2,(int)Math.Round(sm.Rate*Math.Max(0,xfadeMs)/1000.0)));
            double step=((double)sm.Rate/(double)OutRate)*Math.Max(0.0001,pitchRatio);
            int ff=Math.Max(32,OutRate/200); long seq=Interlocked.Increment(ref Sequence); long tick=Stopwatch.GetTimestamp();
            float p=Math.Max(-1f,Math.Min(1f,pan)); float gl=gain*(p>0f?(1f-p):1f); float gr=gain*(p<0f?(1f+p):1f);
            if(!EnqueueCommand(1,voiceId,sm,ss,step,ss,ls,le,se,lm,xf,1,gl,gr,channel,ff,seq,tick,0.0)){LastError="Audio command ring full";return false;}
            return true;
        }
        catch(Exception ex){ LastError=ex.Message; return false; }
    }

    public static bool PlayPreloaded(int voiceId, string path, float gain, float pan, int channel)
    {
        if (!Run && !Start()) return false;
        try
        {
            Sample sm;
            lock(Sync) { if(!Samples.TryGetValue(path,out sm)) { LastError="RAM Pitch Buffer fehlt: "+path; return false; } }
            return AddVoice(voiceId,sm,gain,pan,channel);
        }
        catch(Exception ex){ LastError=ex.Message; return false; }
    }

    public static bool Play(int voiceId, string path, float gain, float pan, int channel)
    {
        if (!Run && !Start()) return false;
        try
        {
            Sample sm = GetSample(path);
            return AddVoice(voiceId,sm,gain,pan,channel);
        }
        catch(Exception ex){ LastError=ex.Message; return false; }
    }

    private static bool AddVoice(int voiceId, Sample sm, float gain, float pan, int channel)
    {
        try
        {
            double step=(double)sm.Rate/(double)OutRate; int ff=Math.Max(32,OutRate/200); long seq=Interlocked.Increment(ref Sequence); long tick=Stopwatch.GetTimestamp();
            float p=Math.Max(-1f,Math.Min(1f,pan));
            float gl=gain*(p>0f?(1f-p):1f); float gr=gain*(p<0f?(1f+p):1f);
            if(!EnqueueCommand(1,voiceId,sm,0.0,step,0,0,sm.Frames,sm.Frames,0,0,1,gl,gr,channel,ff,seq,tick,0.0)){LastError="Audio command ring full";return false;}
            return true;
        }
        catch(Exception ex){ LastError=ex.Message; return false; }
    }

    public static void StopVoice(int voiceId)
    {
        EnqueueCommand(2,voiceId,null,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);
    }
    public static void StopAll()
    {
        EnqueueCommand(3,0,null,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);
    }
    public static void SetPitchBend(int channel, double semitones)
    {
        EnqueueCommand(4,0,null,0,0,0,0,0,0,0,0,0,0,0,channel,0,0,0,Math.Pow(2.0,semitones/12.0));
    }
    public static int ActiveVoices { get { return Interlocked.CompareExchange(ref ActiveVoiceCount,0,0); } }
    public static string Diagnostics { get { return "Mode="+Mode+", Target="+TargetFrames+"f, Buffer="+BufferFrames+"f/"+ActualBufferMs.ToString("F2")+"ms"+(ExclusiveMode?", ExclusiveRequest="+ExclusiveRequestedFrames+"f, DevicePeriod{Default="+(DeviceDefaultPeriodHns/10000.0).ToString("F2")+"ms, Min="+(DeviceMinimumPeriodHns/10000.0).ToString("F2")+"ms}":", Engine{"+PeriodDiagnostics+"}")+", Stream="+StreamLatencyMs.ToString("F2")+"ms, LastVoiceToMix="+(LastFirstMixMs<0?"n/a":LastFirstMixMs.ToString("F3")+"ms")+(ExclusiveFallbackReason.Length>0?", ExclusiveFallback="+ExclusiveFallbackReason:"")+(Client3FallbackReason.Length>0?", Client3Fallback="+Client3FallbackReason:""); } }

    private static void PrimeSilence(uint frames)
    {
        if(frames==0 || Render==null) return;
        IntPtr p; Check(Render.GetBuffer(frames,out p),"Render.GetBuffer(prime)");
        int byteCount=(int)frames*OutChannels*(Bits/8);
        byte[] zero=new byte[byteCount]; Marshal.Copy(zero,0,p,byteCount);
        Check(Render.ReleaseBuffer(frames,0),"Render.ReleaseBuffer(prime)");
    }

    private static void ProcessAudioCommands()
    {
        AudioCommand c; int guard=0;
        while(guard++<128 && TryDequeueCommand(out c))
        {
            if(c==null) continue;
            if(c.Kind==1 && c.S!=null)
            {
                Voice v=AcquireVoice(c.VoiceId);
                v.Id=c.VoiceId; v.S=c.S; v.Pos=c.Pos; v.BaseStep=c.BaseStep;
                v.SampleStart=c.SampleStart; v.LoopStart=c.LoopStart; v.LoopEnd=c.LoopEnd; v.SampleEnd=c.SampleEnd;
                v.LoopMode=c.LoopMode; v.XFadeFrames=c.XFadeFrames; v.Direction=c.Direction; v.LoopTurns=0;
                v.GL=c.GL; v.GR=c.GR; v.Channel=c.Channel; v.Release=false; v.FadeFrames=c.FadeFrames; v.FadeLeft=c.FadeFrames;
                v.Seq=c.Seq; v.EnqueueTick=c.EnqueueTick; v.FirstMixSeen=false; Voices.Add(v);
            }
            else if(c.Kind==2)
            {
                for(int i=0;i<Voices.Count;i++) if(Voices[i].Id==c.VoiceId){Voices[i].Release=true;Voices[i].FadeLeft=Voices[i].FadeFrames;}
            }
            else if(c.Kind==3)
            {
                for(int i=0;i<Voices.Count;i++){Voices[i].Release=true;Voices[i].FadeLeft=Voices[i].FadeFrames;}
            }
            else if(c.Kind==4)
            {
                if(c.Channel>=0 && c.Channel<BendRatio.Length) BendRatio[c.Channel]=c.Value;
            }
            else if(c.Kind==5)
            {
                Voices.Clear(); for(int i=0;i<BendRatio.Length;i++) BendRatio[i]=1.0;
            }
            Interlocked.Increment(ref CommandsProcessed);
        }
        Interlocked.Exchange(ref ActiveVoiceCount,Voices.Count);
    }

    private static void AudioLoop()
    {
        float[] floats = new float[4096]; short[] shorts = new short[4096];
        IntPtr mmcss=IntPtr.Zero; uint mmTask=0;
        try
        {
            try
            {
                mmcss=AvSetMmThreadCharacteristics("Pro Audio",out mmTask);
                MmcssActive=(mmcss!=IntPtr.Zero);
                MmcssStatus=MmcssActive ? "Pro Audio" : ("FAILED("+Marshal.GetLastWin32Error()+")");
            }
            catch(Exception ex){MmcssActive=false;MmcssStatus="UNAVAILABLE("+ex.GetType().Name+")";}
            while(Run)
            {
                try
                {
                    if(AudioEvent==null){Thread.Sleep(1);continue;}
                    if(!AudioEvent.WaitOne(200)){Interlocked.Increment(ref EventTimeouts);Interlocked.Increment(ref DropoutCount);continue;}
                    if(!Run) break;
                    long eventNow=Stopwatch.GetTimestamp();
                    if(LastEventTick>0)
                    {
                        double dt=(eventNow-LastEventTick)*1000.0/Stopwatch.Frequency;
                        LastWakeIntervalMs=dt; if(dt>WorstWakeIntervalMs) WorstWakeIntervalMs=dt;
                        EventIntervalSumMs += dt; EventIntervalCount++;
                        double expected=OutRate>0 ? (1000.0*Math.Max(1,BufferFrames)/OutRate) : 3.0;
                        double lateThreshold=Math.Max(expected+2.0,expected*1.70);
                        if(EventWakeups>20 && dt>lateThreshold)
                        {
                            Interlocked.Increment(ref LateWakeups); ConsecutiveLateWakeups++; LateWakeupsInWindow++;
                            long nowTick=eventNow;
                            if(LateWindowStartTick==0) LateWindowStartTick=nowTick;
                            double win=(nowTick-LateWindowStartTick)*1000.0/Stopwatch.Frequency;
                            if(win>2000.0){LateWakeupsInWindow=1;LateWindowStartTick=nowTick;}
                            Interlocked.Increment(ref UnderrunRiskEvents);
                            if(dt>Math.Max(expected+8.0,expected*2.0)){
                                Interlocked.Increment(ref SevereWakeups); Interlocked.Increment(ref DropoutCount); Interlocked.Increment(ref DeadlineMissCount);
                                LastDeadlineExpectedMs=expected; LastDeadlineActualMs=dt; LastDeadlineLateByMs=Math.Max(0.0,dt-expected);
                                LastDeadlineVoicePos=Voices.Count>0 ? Voices[0].Pos : -1.0;
                            }
                        }
                        else { ConsecutiveLateWakeups=0; if((eventNow-LateWindowStartTick)*1000.0/Stopwatch.Frequency>2000.0){LateWakeupsInWindow=0;LateWindowStartTick=eventNow;} }
                    }
                    LastEventTick=eventNow;
                    Interlocked.Increment(ref EventWakeups);
                    uint frames;
                    if(ExclusiveMode) frames=BufferFrames;
                    else
                    {
                        uint pad; int hr=Client.GetCurrentPadding(out pad); if(hr<0) throw new COMException("GetCurrentPadding",hr);
                        frames = BufferFrames>pad ? BufferFrames-pad : 0;
                        if(frames==0) continue;
                    }
                    int samples=(int)frames*OutChannels;
                    long renderStart=Stopwatch.GetTimestamp();
                    ProcessAudioCommands();
                    long mixStart=Stopwatch.GetTimestamp();
                    if(FloatOut)
                    {
                        if(samples>floats.Length) throw new InvalidOperationException("Audio buffer exceeds preallocated float capacity"); Array.Clear(floats,0,samples); Mix(floats,null,(int)frames);
                    }
                    else
                    {
                        if(samples>shorts.Length) throw new InvalidOperationException("Audio buffer exceeds preallocated PCM16 capacity"); Array.Clear(shorts,0,samples); Mix(null,shorts,(int)frames);
                    }
                    long mixEnd=Stopwatch.GetTimestamp();
                    double mixMs=(mixEnd-mixStart)*1000.0/Stopwatch.Frequency; LastMixTimeMs=mixMs; if(mixMs>WorstMixTimeMs)WorstMixTimeMs=mixMs; MixTimingSumMs+=mixMs; MixTimingCount++;
                    long writeStart=Stopwatch.GetTimestamp();
                    IntPtr p; Check(Render.GetBuffer(frames,out p),"Render.GetBuffer");
                    if(FloatOut) Marshal.Copy(floats,0,p,samples); else Marshal.Copy(shorts,0,p,samples);
                    Check(Render.ReleaseBuffer(frames,0),"Render.ReleaseBuffer");
                    long writeEnd=Stopwatch.GetTimestamp();
                    double writeMs=(writeEnd-writeStart)*1000.0/Stopwatch.Frequency; LastWriteTimeMs=writeMs; if(writeMs>WorstWriteTimeMs)WorstWriteTimeMs=writeMs; WriteTimingSumMs+=writeMs; WriteTimingCount++;
                    Interlocked.Increment(ref BufferWrites); LastAudioWriteTick=writeEnd;
                    long renderEnd=Stopwatch.GetTimestamp();
                    double renderMs=(renderEnd-renderStart)*1000.0/Stopwatch.Frequency;
                    LastRenderLoopTimeMs=renderMs; if(renderMs>WorstRenderLoopTimeMs)WorstRenderLoopTimeMs=renderMs; RenderLoopTimingSumMs+=renderMs; RenderLoopTimingCount++;
                }
                catch(Exception ex){Interlocked.Increment(ref AudioLoopErrors);Interlocked.Increment(ref DropoutCount);LastError=ex.Message;Run=false;break;}
            }
        }
        finally
        {
            if(mmcss!=IntPtr.Zero){try{AvRevertMmThreadCharacteristics(mmcss);}catch{}}
            MmcssActive=false; if(MmcssStatus=="Pro Audio") MmcssStatus="stopped";
        }
    }

    private static void Mix(float[] fout, short[] sout, int frames)
    {
            for(int f=0;f<frames;f++)
            {
                double l=0.0,r=0.0;
                for(int vi=Voices.Count-1;vi>=0;vi--)
                {
                    Voice v=Voices[vi];
                    if(!v.FirstMixSeen)
                    {
                        v.FirstMixSeen=true;
                        long now=Stopwatch.GetTimestamp();
                        LastFirstMixMs=(now-v.EnqueueTick)*1000.0/Stopwatch.Frequency;
                        LastFirstMixVoiceId=v.Id;
                    }
                    if(v.LoopMode==0 && v.Pos>=v.SampleEnd-1){Voices.RemoveAt(vi);continue;}
                    if(v.LoopMode==1 && v.Pos>=v.LoopEnd)
                    {
                        double len=Math.Max(1.0,v.LoopEnd-v.LoopStart);
                        while(v.Pos>=v.LoopEnd) v.Pos-=len;
                        while(v.Pos<v.LoopStart) v.Pos+=len;
                    }
                    // RC5h ALTERNATE: reflect the exact overshoot at both loop boundaries.
                    // Do not clamp to the endpoint and do not emit a boundary sample twice.
                    // This keeps the fractional phase continuous for non-integer pitch steps.
                    if(v.LoopMode==2)
                    {
                        double lo=v.LoopStart;
                        double hi=Math.Max(lo+1.0,v.LoopEnd-1.0);
                        int guard=0;
                        while((v.Pos>hi || v.Pos<lo) && guard++<8)
                        {
                            if(v.Pos>hi)
                            {
                                v.Pos=hi-(v.Pos-hi);
                                v.Direction=-1; v.LoopTurns++; Interlocked.Increment(ref AlternateLoopTurns); Interlocked.Increment(ref AlternateBoundaryCorrections);
                            }
                            else if(v.Pos<lo)
                            {
                                v.Pos=lo+(lo-v.Pos);
                                v.Direction=1; v.LoopTurns++; Interlocked.Increment(ref AlternateLoopTurns); Interlocked.Increment(ref AlternateBoundaryCorrections);
                            }
                        }
                        if(v.Pos<lo){v.Pos=lo;Interlocked.Increment(ref AlternateBoundaryCorrections);}
                        if(v.Pos>hi){v.Pos=hi;Interlocked.Increment(ref AlternateBoundaryCorrections);}
                    }
                    int i=(int)Math.Floor(v.Pos); if(i<0)i=0; if(i>=v.S.Frames-1)i=v.S.Frames-2;
                    double frac=v.Pos-i; float sl=(float)(v.S.L[i]+(v.S.L[i+1]-v.S.L[i])*frac); float sr=(float)(v.S.R[i]+(v.S.R[i+1]-v.S.R[i])*frac);
                    if(v.LoopMode==1 && v.XFadeFrames>0 && v.Direction>0 && v.Pos>=v.LoopEnd-v.XFadeFrames && v.Pos<v.LoopEnd)
                    {
                        double rel=v.Pos-(v.LoopEnd-v.XFadeFrames); double t=rel/v.XFadeFrames; double hp=v.LoopStart+rel;
                        int hi=(int)Math.Floor(hp); if(hi<0)hi=0; if(hi>=v.S.Frames-1)hi=v.S.Frames-2; double hf=hp-hi;
                        float hl=(float)(v.S.L[hi]+(v.S.L[hi+1]-v.S.L[hi])*hf); float hr=(float)(v.S.R[hi]+(v.S.R[hi+1]-v.S.R[hi])*hf);
                        sl=(float)(sl*(1.0-t)+hl*t); sr=(float)(sr*(1.0-t)+hr*t);
                    }
                    float env=1f; if(v.Release){ if(v.FadeLeft<=0){Voices.RemoveAt(vi);continue;} env=(float)v.FadeLeft/(float)v.FadeFrames; v.FadeLeft--; }
                    l+=sl*v.GL*env; r+=sr*v.GR*env;
                    double bend=(v.Channel>=0 && v.Channel<BendRatio.Length)?BendRatio[v.Channel]:1.0;
                    double advance=v.BaseStep*bend*v.Direction;
                    v.Pos+=advance;
                    if(v.LoopMode==2)
                    {
                        double lo=v.LoopStart; double hi=Math.Max(lo+1.0,v.LoopEnd-1.0); int guard=0;
                        while((v.Pos>hi || v.Pos<lo) && guard++<8)
                        {
                            if(v.Pos>hi){v.Pos=hi-(v.Pos-hi);v.Direction=-1;v.LoopTurns++;Interlocked.Increment(ref AlternateLoopTurns);Interlocked.Increment(ref AlternateBoundaryCorrections);}
                            else if(v.Pos<lo){v.Pos=lo+(lo-v.Pos);v.Direction=1;v.LoopTurns++;Interlocked.Increment(ref AlternateLoopTurns);Interlocked.Increment(ref AlternateBoundaryCorrections);}
                        }
                    }
                }
                // gentle hard safety clamp only; no normal-operation gain reduction
                l=Math.Max(-0.999,Math.Min(0.999,l)); r=Math.Max(-0.999,Math.Min(0.999,r));
                if(FloatOut){fout[f*OutChannels]=(float)l;if(OutChannels>1)fout[f*OutChannels+1]=(float)r;for(int c=2;c<OutChannels;c++)fout[f*OutChannels+c]=0f;}
                else {sout[f*OutChannels]=(short)Math.Round(l*32767.0);if(OutChannels>1)sout[f*OutChannels+1]=(short)Math.Round(r*32767.0);for(int c=2;c<OutChannels;c++)sout[f*OutChannels+c]=0;}
            }
            Interlocked.Exchange(ref ActiveVoiceCount,Voices.Count);
    }

    private static Sample GetSample(string path)
    {
        Sample s; lock(Sync){if(Samples.TryGetValue(path,out s))return s;}
        s=ReadWav(path); lock(Sync){Samples[path]=s;} return s;
    }

    private static Sample ReadWav(string path)
    {
        using(BinaryReader br=new BinaryReader(File.Open(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)))
        {
            if(new string(br.ReadChars(4))!="RIFF") throw new InvalidDataException("Keine RIFF-WAV"); br.ReadInt32(); if(new string(br.ReadChars(4))!="WAVE")throw new InvalidDataException("Keine WAVE-Datei");
            short fmt=0,ch=0,bits=0; int rate=0,align=0; byte[] data=null;
            while(br.BaseStream.Position+8<=br.BaseStream.Length){string id=new string(br.ReadChars(4));int n=br.ReadInt32();long next=br.BaseStream.Position+n+(n&1);if(id=="fmt "){fmt=br.ReadInt16();ch=br.ReadInt16();rate=br.ReadInt32();br.ReadInt32();align=br.ReadInt16();bits=br.ReadInt16();}else if(id=="data"){data=br.ReadBytes(n);}br.BaseStream.Position=Math.Min(next,br.BaseStream.Length);}
            if(data==null||rate<=0||ch<1)throw new InvalidDataException("WAV ohne PCM-Daten"); if(fmt!=1||bits!=16)throw new InvalidDataException("Live-WASAPI erwartet 16-Bit PCM Cache-WAV");
            int frames=data.Length/align; Sample s=new Sample();s.Rate=rate;s.Frames=frames;s.L=new float[frames];s.R=new float[frames];
            for(int i=0;i<frames;i++){int o=i*align;short a=(short)(data[o]|(data[o+1]<<8));short b=a;if(ch>1)b=(short)(data[o+2]|(data[o+3]<<8));s.L[i]=a/32768f;s.R[i]=b/32768f;}return s;
        }
    }

    private static void ParseFormat(IntPtr p)
    {
        int tag=Marshal.ReadInt16(p,0)&0xFFFF; OutChannels=Marshal.ReadInt16(p,2)&0xFFFF; OutRate=Marshal.ReadInt32(p,4); Bits=Marshal.ReadInt16(p,14)&0xFFFF;
        FloatOut=(tag==3)||(tag==0xFFFE&&Bits==32); if(!FloatOut && !(tag==1&&Bits==16)) throw new NotSupportedException("WASAPI Mixformat nicht unterstützt: tag="+tag+", bits="+Bits);
        if(OutChannels<1)throw new NotSupportedException("WASAPI: keine Ausgabekanäle");
    }
    private static void Check(int hr,string where){if(hr<0)throw new COMException(where+" fehlgeschlagen",hr);}
}
'@


# -----------------------------------------------------------------------------
# v0.9.12c Phase 17c: MIDI sustain, Phoenix loop and keyboard hold
# -----------------------------------------------------------------------------
$script:MidiInputOpen=$false
$script:MidiInputDeviceId=-1
$script:MidiInputTimer=New-Object System.Windows.Threading.DispatcherTimer
$script:MidiInputTimer.Interval=[TimeSpan]::FromMilliseconds(15)
$script:KeyboardVelocity=127
$script:KeyboardOctave=0
$script:KeyboardNoteTimers=New-Object System.Collections.ArrayList
$script:LiveMediaPlayer = New-Object System.Windows.Media.MediaPlayer
$script:LiveRenderPath = $null
$script:LivePendingPlay = $false
$script:ActiveLivePcNote = $null
$script:LivePendingSpeed = 1.0
$script:LivePendingGain = 1.0
$script:LivePendingBalance = 0.0
$script:LivePreviewCache = @{}
$script:LivePreviewCacheBank = ''
$script:LiveCacheWarmupInProgress = $false
$script:LivePreloadedPlayers = @{}
$script:LiveVoicePools = @{}
$script:ActiveLivePcVoices = New-Object System.Collections.ArrayList
$script:LiveVoiceSequence = 0L
$script:LiveVoicesPerSlot = 4
$script:LiveSustainByChannel = @{}
$script:LivePitchBendByChannel = @{}
$script:LivePersistentCacheRoot = Join-Path $env:LOCALAPPDATA 'PhoenixLibrarian\PreviewCache_RC4d'
$script:LivePrewarmSemitones = 24
$script:LiveContinuousHoldSeconds = 30.0
$script:LivePrewarmQueue = New-Object System.Collections.Queue
$script:LivePrewarmTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:LivePrewarmTimer.Interval = [TimeSpan]::FromMilliseconds(15)
$script:LivePrewarmGeneration = 0
$script:LiveRamPitchMap = @{}
$script:LiveRamPitchReady = 0
$script:LiveRamPitchTarget = 0
$script:LiveFullPathPrimed = $false
$script:LiveFullPathPrimeInProgress = $false

$script:LiveMediaPlayer.Add_MediaOpened({
    try {
        if($script:LivePendingPlay){
            $script:LiveMediaPlayer.Volume=$script:LivePendingGain
            $script:LiveMediaPlayer.Balance=$script:LivePendingBalance
            $script:LiveMediaPlayer.SpeedRatio=$script:LivePendingSpeed
            $script:LiveMediaPlayer.Play()
            Add-Log ('Live PC: Media geöffnet, Wiedergabe gestartet.')
        }
    } catch { Add-Log ('Live-PC MediaOpened Fehler: '+$_.Exception.Message) }
})
$script:LiveMediaPlayer.Add_MediaFailed({ param($sender,$e)
    $script:LivePendingPlay=$false
    Add-Log ('Live-PC MediaFailed: '+$e.ErrorException.Message)
})

function Update-LiveVoiceStatus {
    $count=0
    if($null-ne$script:ActiveLivePcVoices){$count=@($script:ActiveLivePcVoices|Where-Object{$null-ne$_ -and $_.Active}).Count}
    if($null-ne$script:ActiveVoicesText){$script:ActiveVoicesText.Text=('Stimmen aktiv: {0} / 16' -f $count)}
}
function Clear-LivePreviewCache {
    param([bool]$KeepPersistent=$true)
    try { if($script:LivePrewarmTimer){$script:LivePrewarmTimer.Stop()} } catch {}
    $script:LivePrewarmQueue=New-Object System.Collections.Queue
    try {
        if($null-ne$script:LiveMediaPlayer){$script:LivePendingPlay=$false;$script:LiveMediaPlayer.Stop();$script:LiveMediaPlayer.Close()}
    } catch {}
    if($null-ne$script:LiveVoicePools){
        foreach($pool in @($script:LiveVoicePools.Values)){
            foreach($voice in @($pool.Voices)){
                try { if($null-ne$voice.PrimeTimer){$voice.PrimeTimer.Stop()} } catch {}
                foreach($prop in @('Player','AttackPlayer','LoopPlayer','ReleasePlayer')){
                    try { $pl=$voice.$prop; if($null-ne$pl){$pl.Stop();$pl.Close()} } catch {}
                }
            }
        }
    }
    $script:LiveVoicePools=@{}
    $script:LivePreloadedPlayers=@{}
    $script:ActiveLivePcVoices=New-Object System.Collections.ArrayList
    # RC2 persistent cache files deliberately survive bank changes and application restarts.
    if(-not $KeepPersistent -and $null-ne$script:LivePreviewCache){
        foreach($entry in @($script:LivePreviewCache.Values)){
            if($null-ne$entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.Path) -and (Test-Path -LiteralPath $entry.Path)){
                try { Remove-Item -LiteralPath $entry.Path -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    }
    $script:LivePreviewCache=@{}
    $script:LivePreviewCacheBank=''
    Update-LiveVoiceStatus
}
function Initialize-LivePersistentCache {
    try {
        if(-not(Test-Path -LiteralPath $script:LivePersistentCacheRoot)){[void](New-Item -ItemType Directory -Path $script:LivePersistentCacheRoot -Force)}
        # Opportunistic cleanup of cache files not touched for 45 days.
        Get-ChildItem -LiteralPath $script:LivePersistentCacheRoot -File -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-45)} | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { Add-Log ('Persistent Cache Init Warnung: '+$_.Exception.Message) }
}
function Get-LiveCacheHash {
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $bytes=[Text.Encoding]::UTF8.GetBytes($Text); return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-LivePersistentPath {
    param([string]$Key,[string]$Suffix='full')
    Initialize-LivePersistentCache
    return (Join-Path $script:LivePersistentCacheRoot ((Get-LiveCacheHash ($Key+'|SEG='+$Suffix))+'.wav'))
}
function Get-LivePreviewCacheKey {
    param($Slot,[int]$LoopMode,[int]$XFadeMs,[bool]$Hold,[int]$Note=-1,[int]$Root=-1)
    $stamp='0'
    try { if(Test-Path -LiteralPath $Slot.FilePath){$stamp=(Get-Item -LiteralPath $Slot.FilePath).LastWriteTimeUtc.Ticks} } catch {}
    $parts=@(
        [string]$Slot.FilePath,[string]$stamp,[string][long]$Slot.SampleStart,[string][long]$Slot.LoopStart,
        [string][long]$Slot.LoopEnd,[string][long]$Slot.SampleEnd,[string]$LoopMode,[string]$XFadeMs,
        [string][bool]$Slot.DC,[string][bool]$Slot.Normalize,[string]$Hold,[string]$script:CurrentBank.Name,
        ('NOTE='+$Note),('ROOT='+$Root))
    return ($parts -join '|')
}
function Get-OrBuildLivePreview {
    param([int]$SlotIndex,[int]$LoopMode,[int]$XFadeMs,[bool]$Hold,[double]$Seconds=60.0,[int]$Note=-1,[int]$Root=-1)
    if($null-eq$script:CurrentBank -or $SlotIndex-lt0 -or $SlotIndex-ge4){return $null}
    $slot=$script:CurrentBank.Slots[$SlotIndex]
    if($null-eq$slot -or -not(Test-Path -LiteralPath $slot.FilePath)){return $null}
    $key=Get-LivePreviewCacheKey $slot $LoopMode $XFadeMs $Hold $Note $Root
    if($script:LivePreviewCache.ContainsKey($key)){
        $entry=$script:LivePreviewCache[$key]
        if($null-ne$entry -and (Test-Path -LiteralPath $entry.Path)){ Add-Log ('Live-Pitch-Cache HIT: S{0}, {1}, Note {2}' -f ($SlotIndex+1),$(if($Hold){'HOLD'}else{'ONE SHOT'}),$(if($Note-ge0){(Get-MidiNoteName $Note)}else{'RAW'})); return $entry.Path }
        [void]$script:LivePreviewCache.Remove($key)
    }
    $path=Get-LivePersistentPath $key 'full'
    if(Test-Path -LiteralPath $path){
        $script:LivePreviewCache[$key]=[pscustomobject]@{Path=$path;Slot=$SlotIndex;Hold=$Hold;Note=$Note;Root=$Root;Created=Get-Date;Persistent=$true}
        try{(Get-Item -LiteralPath $path).LastWriteTimeUtc=[DateTime]::UtcNow}catch{}
        Add-Log ('Live-Persistent-Cache HIT: S{0}, {1}, Note {2}' -f ($SlotIndex+1),$(if($Hold){'HOLD'}else{'ONE SHOT'}),(Get-MidiNoteName $Note))
        return $path
    }
    if($Note-ge0 -and $Root-ge0){
        [void][PhoenixLoopPreviewRenderer]::RenderPitched($slot.FilePath,$path,[long]$slot.SampleStart,[long]$slot.LoopStart,[long]$slot.LoopEnd,[long]$slot.SampleEnd,$LoopMode,$XFadeMs,[bool]$slot.DC,[bool]$slot.Normalize,$Hold,$Seconds,$Note,$Root)
    } else {
        [void][PhoenixLoopPreviewRenderer]::Render($slot.FilePath,$path,[long]$slot.SampleStart,[long]$slot.LoopStart,[long]$slot.LoopEnd,[long]$slot.SampleEnd,$LoopMode,$XFadeMs,[bool]$slot.DC,[bool]$slot.Normalize,$Hold,$Seconds)
    }
    $script:LivePreviewCache[$key]=[pscustomobject]@{Path=$path;Slot=$SlotIndex;Hold=$Hold;Note=$Note;Root=$Root;Created=Get-Date;Persistent=$true}
    Add-Log ('Live-Persistent-Cache MISS/erstellt: S{0}, {1}, Note {2}, Root {3}, {4:N1} s' -f ($SlotIndex+1),$(if($Hold){'HOLD'}else{'ONE SHOT'}),$(if($Note-ge0){(Get-MidiNoteName $Note)}else{'RAW'}),$(if($Root-ge0){(Get-MidiNoteName $Root)}else{'-'}),$Seconds)
    return $path
}
function Get-OrBuildLiveSegments {
    param([int]$SlotIndex,[int]$LoopMode,[int]$XFadeMs,[int]$Note,[int]$Root)
    if($null-eq$script:CurrentBank -or $SlotIndex-lt0 -or $SlotIndex-ge4){return $null}
    $slot=$script:CurrentBank.Slots[$SlotIndex]; if($null-eq$slot -or -not(Test-Path -LiteralPath $slot.FilePath)){return $null}
    $baseKey=Get-LivePreviewCacheKey $slot $LoopMode $XFadeMs $true $Note $Root
    $paths=@{}
    foreach($seg in @(@('attack',0),@('loop',1),@('release',2))){
        $name=[string]$seg[0];$kind=[int]$seg[1];$p=Get-LivePersistentPath $baseKey $name
        if(-not(Test-Path -LiteralPath $p)){
            [void][PhoenixLoopPreviewRenderer]::RenderPitchedSegment($slot.FilePath,$p,[long]$slot.SampleStart,[long]$slot.LoopStart,[long]$slot.LoopEnd,[long]$slot.SampleEnd,$LoopMode,$XFadeMs,[bool]$slot.DC,[bool]$slot.Normalize,$Note,$Root,$kind)
            Add-Log ('Live-Segment MISS/erstellt: S{0}, {1}, {2}' -f ($SlotIndex+1),(Get-MidiNoteName $Note),$name)
        }
        $paths[$name]=$p
    }
    return [pscustomobject]@{Key=$baseKey;Attack=$paths.attack;Loop=$paths.loop;Release=$paths.release;Slot=$SlotIndex;Note=$Note;Root=$Root}
}
function New-LiveVoiceEntry {
    param([string]$Key,[string]$Path,[int]$SlotIndex,[bool]$Hold,[int]$VoiceIndex)
    $player=New-Object System.Windows.Media.MediaPlayer
    $voice=[pscustomobject]@{
        Key=$Key;Path=$Path;Slot=$SlotIndex;Hold=$Hold;VoiceIndex=$VoiceIndex;Player=$player;
        Ready=$false;Priming=$false;Primed=$false;PrimeTimer=$null;Failed=$false;Pending=$false;Active=$false;Released=$false;SustainDeferred=$false;OneShot=$false;
        Note=-1;Channel=1;Sequence=0L;Gain=1.0;Balance=0.0;BaseSpeed=1.0
    }
    # RC3a: WPF MediaPlayer tends to ramp the first audible Play() of a newly opened
    # source. Prime every voice once at zero volume, then rewind it. The real first
    # MIDI note can then start with the intended level immediately.
    $primeTimer=New-Object System.Windows.Threading.DispatcherTimer
    $primeTimer.Interval=[TimeSpan]::FromMilliseconds(80)
    $voice.PrimeTimer=$primeTimer
    $primeTick={
        try {
            $primeTimer.Stop()
            if($voice.Failed){return}
            $voice.Player.Stop();$voice.Player.Position=[TimeSpan]::Zero
            $voice.Player.Volume=1.0;$voice.Player.Balance=0.0;$voice.Player.SpeedRatio=1.0
            $voice.Priming=$false;$voice.Primed=$true;$voice.Ready=$true
            Add-Log ('Live-Player READY: S{0} V{1}' -f ($voice.Slot+1),($voice.VoiceIndex+1))
            if($voice.Pending){
                $voice.Player.Volume=$voice.Gain;$voice.Player.Balance=$voice.Balance
                $voice.Player.SpeedRatio=$voice.BaseSpeed;$voice.Player.Position=[TimeSpan]::Zero
                $voice.Player.Play();$voice.Pending=$false
                Add-Log ('Live-PC Voice nach Priming gestartet: S{0} V{1}' -f ($voice.Slot+1),($voice.VoiceIndex+1))
            }
        } catch { Add-Log ('Live-PC Voice Priming Fehler: '+$_.Exception.Message) }
    }.GetNewClosure()
    $primeTimer.Add_Tick($primeTick)
    $opened={
        try {
            $voice.Ready=$false;$voice.Priming=$true;$voice.Primed=$false
            $voice.Player.Stop();$voice.Player.Position=[TimeSpan]::Zero
            $voice.Player.SpeedRatio=1.0;$voice.Player.Balance=0.0;$voice.Player.Volume=0.0
            $voice.Player.Play()
            Add-Log ('Live-Player PRIME: S{0} V{1}' -f ($voice.Slot+1),($voice.VoiceIndex+1))
            $primeTimer.Start()
        } catch { Add-Log ('Live-PC Voice MediaOpened/Prime Fehler: '+$_.Exception.Message) }
    }.GetNewClosure()
    $failed={ param($sender,$e)
        $voice.Failed=$true;$voice.Ready=$false;$voice.Pending=$false;$voice.Active=$false
        Add-Log ('Live-PC Voice MediaFailed S{0}/V{1}: {2}' -f ($voice.Slot+1),($voice.VoiceIndex+1),$e.ErrorException.Message)
        Update-LiveVoiceStatus
    }.GetNewClosure()
    $ended={
        if(-not$voice.Hold){$voice.Active=$false;$voice.Note=-1;$voice.SustainDeferred=$false;Update-LiveVoiceStatus}
    }.GetNewClosure()
    $player.Add_MediaOpened($opened);$player.Add_MediaFailed($failed);$player.Add_MediaEnded($ended)
    $player.Open((New-Object System.Uri -ArgumentList $Path))
    return $voice
}
function Get-OrCreatePreloadedLivePool {
    param([string]$Key,[string]$Path,[int]$SlotIndex,[bool]$Hold,[int]$DesiredVoices=1)
    if([string]::IsNullOrWhiteSpace($Key)-or[string]::IsNullOrWhiteSpace($Path)){return $null}
    $DesiredVoices=[Math]::Max(1,[Math]::Min($script:LiveVoicesPerSlot,$DesiredVoices))
    if($script:LiveVoicePools.ContainsKey($Key)){
        $pool=$script:LiveVoicePools[$Key]
        if(($null -eq $pool) -or ([string]$pool.Path -ne $Path)){
            if($null-ne$pool){foreach($v in @($pool.Voices)){try{$v.Player.Stop();$v.Player.Close()}catch{}}}
            [void]$script:LiveVoicePools.Remove($Key);$pool=$null
        }
    } else {$pool=$null}
    if($null-eq$pool){$voices=New-Object System.Collections.ArrayList;$pool=[pscustomobject]@{Key=$Key;Path=$Path;Slot=$SlotIndex;Hold=$Hold;Voices=$voices};$script:LiveVoicePools[$Key]=$pool}
    while($pool.Voices.Count-lt$DesiredVoices){[void]$pool.Voices.Add((New-LiveVoiceEntry $Key $Path $SlotIndex $Hold $pool.Voices.Count))}
    return $pool
}
function New-LiveSegmentPlayer {
    param([string]$Path,$Voice,[string]$Kind)
    $pl=New-Object System.Windows.Media.MediaPlayer
    $pl.Open((New-Object System.Uri -ArgumentList $Path))
    if($Kind-eq'attack'){
        $pl.Add_MediaEnded({ if($Voice.Active -and -not $Voice.Released){ try{$Voice.LoopPlayer.Position=[TimeSpan]::Zero;$Voice.LoopPlayer.Play()}catch{} } }.GetNewClosure())
    } elseif($Kind-eq'loop'){
        $pl.Add_MediaEnded({ if($Voice.Active -and -not $Voice.Released){ try{$Voice.LoopPlayer.Position=[TimeSpan]::Zero;$Voice.LoopPlayer.Play()}catch{} } }.GetNewClosure())
    } else {
        $pl.Add_MediaEnded({ $Voice.Active=$false;$Voice.Note=-1;$Voice.SustainDeferred=$false;Update-LiveVoiceStatus }.GetNewClosure())
    }
    return $pl
}
function New-LiveSegmentVoiceEntry {
    param($Segments,[int]$VoiceIndex)
    $voice=[pscustomobject]@{Segmented=$true;Key=$Segments.Key;Slot=$Segments.Slot;VoiceIndex=$VoiceIndex;Active=$false;Released=$false;SustainDeferred=$false;OneShot=$false;Note=-1;Channel=1;Sequence=0L;Gain=1.0;Balance=0.0;BaseSpeed=1.0;Player=$null;AttackPlayer=$null;LoopPlayer=$null;ReleasePlayer=$null}
    $voice.AttackPlayer=New-LiveSegmentPlayer $Segments.Attack $voice 'attack'
    $voice.LoopPlayer=New-LiveSegmentPlayer $Segments.Loop $voice 'loop'
    $voice.ReleasePlayer=New-LiveSegmentPlayer $Segments.Release $voice 'release'
    return $voice
}
function Get-OrCreateSegmentedLivePool {
    param($Segments,[int]$DesiredVoices=1)
    $poolKey='SEG|'+$Segments.Key;$DesiredVoices=[Math]::Max(1,[Math]::Min($script:LiveVoicesPerSlot,$DesiredVoices))
    if($script:LiveVoicePools.ContainsKey($poolKey)){$pool=$script:LiveVoicePools[$poolKey]}
    else{$voices=New-Object System.Collections.ArrayList;$pool=[pscustomobject]@{Key=$poolKey;Path=$Segments.Loop;Slot=$Segments.Slot;Hold=$true;Segmented=$true;Voices=$voices};$script:LiveVoicePools[$poolKey]=$pool}
    while($pool.Voices.Count-lt$DesiredVoices){[void]$pool.Voices.Add((New-LiveSegmentVoiceEntry $Segments $pool.Voices.Count))}
    return $pool
}
function Get-LivePitchFactor {
    param([int]$Channel)
    $bend=8192
    if($script:LivePitchBendByChannel.ContainsKey($Channel)){$bend=[int]$script:LivePitchBendByChannel[$Channel]}
    $semi=(($bend-8192)/8192.0)*24.0
    return [Math]::Pow(2.0,$semi/12.0)
}
function Set-LivePitchBend {
    param([int]$Channel,[int]$Value14)
    $Value14=[Math]::Max(0,[Math]::Min(16383,$Value14));$script:LivePitchBendByChannel[$Channel]=$Value14
    $semi=(($Value14-8192)/8192.0)*24.0
    try { if('PhoenixWasapiLiveEngine' -as [type]){[PhoenixWasapiLiveEngine]::SetPitchBend($Channel,$semi)} } catch { Add-Log ('WASAPI Pitch Bend Warnung: '+$_.Exception.Message) }
    if($null-ne$script:PitchBendText){$script:PitchBendText.Text=('Pitch Bend: {0:+0.00;-0.00;0.00} st' -f $semi)}
}
function Release-LiveVoice {
    param($Voice)
    if($null-eq$Voice){return}
    try { if($null-ne$Voice.WasapiId -and ('PhoenixWasapiLiveEngine' -as [type])){[PhoenixWasapiLiveEngine]::StopVoice([int]$Voice.WasapiId)} } catch {}
    Touch-LiveAudioActivity
    $Voice.Active=$false;$Voice.Released=$true;$Voice.SustainDeferred=$false;$Voice.Note=-1
    Update-LiveVoiceStatus
}
function Release-SustainVoices {
    param([int]$Channel)
    foreach($v in @($script:ActiveLivePcVoices|Where-Object { $_.Active -and $_.SustainDeferred -and ([int]$_.Channel -eq $Channel) })){Release-LiveVoice $v}
}
function Set-LiveSustain {
    param([int]$Channel,[bool]$On)
    $script:LiveSustainByChannel[$Channel]=$On
    if(-not$On){Release-SustainVoices $Channel}
    if($null-ne$script:SustainStatusText){$script:SustainStatusText.Text=$(if($On){'Sustain: EIN'}else{'Sustain: AUS'})}
}

function Get-LiveRamPitchKey {
    param([int]$Slot,[int]$Note,[bool]$Hold,[int]$LoopMode,[int]$XFade)
    # RC4d: one source sample per slot/mode. Note is intentionally not part of the key.
    return ('S{0}|H{1}|L{2}|X{3}' -f $Slot,$([int]$Hold),$LoopMode,$XFade)
}
function Register-LiveRamPitch {
    param([int]$Slot,[int]$Note,[bool]$Hold,[int]$LoopMode,[int]$XFade,[string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){return $false}
    try {
        if(-not [PhoenixWasapiLiveEngine]::IsPreloaded($Path)){
            if(-not [PhoenixWasapiLiveEngine]::Preload($Path)){return $false}
        }
        $k=Get-LiveRamPitchKey $Slot $Note $Hold $LoopMode $XFade
        $script:LiveRamPitchMap[$k]=$Path
        return $true
    } catch { Add-Log ('Single-Sample RAM Preload Warnung: '+$_.Exception.Message); return $false }
}
function Get-LiveRamPitchPath {
    param([int]$Slot,[int]$Note,[bool]$Hold,[int]$LoopMode,[int]$XFade)
    $k=Get-LiveRamPitchKey $Slot $Note $Hold $LoopMode $XFade
    if($script:LiveRamPitchMap.ContainsKey($k)){
        $p=[string]$script:LiveRamPitchMap[$k]
        if([PhoenixWasapiLiveEngine]::IsPreloaded($p)){return $p}
        [void]$script:LiveRamPitchMap.Remove($k)
    }
    return $null
}
function Start-LiveBackgroundPrewarm {
    # RC4d: deliberately no pitch prewarm. Pitch is calculated natively per WASAPI voice.
    $script:LivePrewarmQueue=New-Object System.Collections.Queue
    try{$script:LivePrewarmTimer.Stop()}catch{}
}
function Warm-LivePreviewCache {
    if($script:LiveCacheWarmupInProgress -or $null-eq$script:CurrentBank){return}
    $script:LiveCacheWarmupInProgress=$true
    try {
        # RC5l: bank/cache warmup must never acquire the audio endpoint. Samples are decoded
        # into RAM only. WASAPI is started on the first real note or waveform preview.
        Add-Log 'Audio RC5l: ON-DEMAND - Audiogeraet bleibt beim Bankladen frei.'
        if($script:LivePreviewCacheBank-ne$script:CurrentBank.Name){
            Clear-LivePreviewCache $true
            try {[PhoenixWasapiLiveEngine]::ClearSamples()} catch {}
            $script:LivePreviewCacheBank=$script:CurrentBank.Name;$script:LiveRamPitchMap=@{};$script:LiveFullPathPrimed=$false
        }
        $loaded=0
        $useLoop=Get-LiveUsePhoenixLoop
        for($i=0;$i-lt4;$i++){
            $slot=$script:CurrentBank.Slots[$i];if($null-eq$slot-or-not(Test-Path -LiteralPath $slot.FilePath)){continue}
            $loopMode=0;$loopText=([string]$slot.LoopMode).Trim().ToUpperInvariant();switch($loopText){'FORWARD'{$loopMode=1};'ALTERNATE'{$loopMode=2};default{$parsed=0;if([int]::TryParse($loopText,[ref]$parsed)){$loopMode=[Math]::Max(0,[Math]::Min(2,$parsed))}}};if(-not$useLoop){$loopMode=0}
            $xf=Convert-LiveXFadeToInt $slot.XFade;$hold=($loopMode-ne0)
            if(Register-LiveRamPitch $i 0 $hold $loopMode $xf ([string]$slot.FilePath)){$loaded++}
        }
        Add-Log ('Live Single-Sample RAM Cache bereit: {0} Original-Sample(s), keine Pitch-Kopien.' -f $loaded)
        # RC5l: no silent PRIME here; it would acquire Exclusive WASAPI during ordinary browsing.
    } catch { Add-Log ('Live Single-Sample Warmup Fehler: '+$_.Exception.Message) }
    finally { $script:LiveCacheWarmupInProgress=$false }
}
function New-LiveRenderPath {
    $old=$script:LiveRenderPath
    $script:LiveRenderPath=Join-Path ([IO.Path]::GetTempPath()) ('Phoenix_LivePreview_'+[Guid]::NewGuid().ToString('N')+'.wav')
    if(-not [string]::IsNullOrWhiteSpace([string]$old) -and (Test-Path -LiteralPath $old)){
        try { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue } catch {}
    }
    return $script:LiveRenderPath
}

# RC5l on-demand audio ownership -------------------------------------------------
$script:LastLiveAudioActivity=[datetime]::MinValue
$script:LiveAudioIdleReleaseMs=1500
function Touch-LiveAudioActivity { $script:LastLiveAudioActivity=[datetime]::Now }
function Release-LiveAudioIfIdle {
    try {
        if($script:MediaPlaying){return}
        if(-not [PhoenixWasapiLiveEngine]::IsRunning){return}
        if([PhoenixWasapiLiveEngine]::ActiveVoices -gt 0){Touch-LiveAudioActivity;return}
        if($script:LastLiveAudioActivity -eq [datetime]::MinValue){$script:LastLiveAudioActivity=[datetime]::Now;return}
        if((([datetime]::Now-$script:LastLiveAudioActivity).TotalMilliseconds) -lt $script:LiveAudioIdleReleaseMs){return}
        [PhoenixWasapiLiveEngine]::Shutdown()
        [void][PhoenixWasapiLiveEngine]::SetAudioProfile(480)
        $script:LastLiveAudioActivity=[datetime]::MinValue
        Add-Log 'WASAPI RC5l AUTO-RELEASE: Live/MIDI idle - Audio-Endpoint freigegeben.'
    } catch { Add-Log ('WASAPI RC5l Auto-Release Warnung: '+$_.Exception.Message) }
}
$script:AudioIdleReleaseTimer=New-Object Windows.Threading.DispatcherTimer
$script:AudioIdleReleaseTimer.Interval=[TimeSpan]::FromMilliseconds(250)
$script:AudioIdleReleaseTimer.Add_Tick({Release-LiveAudioIfIdle})
$script:AudioIdleReleaseTimer.Start()

function Refresh-MidiInputs {
    if(-not $script:MidiInputCombo){return}
    $script:MidiInputCombo.Items.Clear()
    [void]$script:MidiInputCombo.Items.Add([pscustomobject]@{Id=-1;Name='Kein MIDI-Eingang'})
    try{
        $n=[PhoenixMidiIn]::midiInGetNumDevs()
        for($i=0;$i-lt$n;$i++){$caps=New-Object PhoenixMidiIn+MIDIINCAPS;$rc=[PhoenixMidiIn]::midiInGetDevCaps([uint32]$i,[ref]$caps,[uint32][Runtime.InteropServices.Marshal]::SizeOf([type]'PhoenixMidiIn+MIDIINCAPS'));if($rc-eq0){[void]$script:MidiInputCombo.Items.Add([pscustomobject]@{Id=$i;Name=$caps.szPname})}}
    }catch{Add-Log ('MIDI-Eingänge konnten nicht gelesen werden: '+$_.Exception.Message)}
    $script:MidiInputCombo.DisplayMemberPath='Name';$script:MidiInputCombo.SelectedIndex=0
}
function Close-MidiInput { try{[PhoenixMidiIn]::Close()}catch{};$script:MidiInputOpen=$false;$script:MidiInputDeviceId=-1;if($script:MidiInputActiveCheck){$script:MidiInputActiveCheck.IsChecked=$false};if($script:MidiInputStatusText){$script:MidiInputStatusText.Text='MIDI IN: AUS'} }
function Open-MidiInput {
    if($null-eq$script:MidiInputCombo.SelectedItem -or [int]$script:MidiInputCombo.SelectedItem.Id-lt0){Close-MidiInput;return $false}
    $id=[int]$script:MidiInputCombo.SelectedItem.Id;$rc=[PhoenixMidiIn]::Open([uint32]$id)
    if($rc-ne0){Close-MidiInput;[Windows.MessageBox]::Show("MIDI-Eingang konnte nicht geöffnet werden (Fehler $rc).",'MIDI Input','OK','Error')|Out-Null;return $false}
    $script:MidiInputOpen=$true;$script:MidiInputDeviceId=$id;$script:MidiInputStatusText.Text='MIDI IN: AKTIV';Add-Log ('MIDI-Eingang geöffnet: '+$script:MidiInputCombo.SelectedItem.Name);return $true
}
function Get-LiveOutputMode { if(-not $script:LiveOutputCombo){return 'PC'};switch($script:LiveOutputCombo.SelectedIndex){1{'MIDI'};2{'BOTH'};default{'PC'}} }
function Get-RoutedSlots {
    param([int]$Note,[int]$Channel)
    $result=New-Object System.Collections.ArrayList
    if($null-eq$script:CurrentBank){return $result}
    $multi=($script:QuattroModeCombo.SelectedIndex-eq1)
    for($i=0;$i-lt4;$i++){$raw=$script:CurrentBank.Slots[$i].Raw;if($multi){$ch=[int](Convert-ToInt64Safe (Get-ValueOrDefault $raw 'MIDI_CHANNEL' ($i+1)) ($i+1));if($ch-eq$Channel){[void]$result.Add($i)}}else{$lo=[int](Convert-ToInt64Safe (Get-ValueOrDefault $raw 'KEY_LOW' 0) 0);$hi=[int](Convert-ToInt64Safe (Get-ValueOrDefault $raw 'KEY_HIGH' 127) 127);if($Note-ge$lo-and$Note-le$hi){[void]$result.Add($i)}}}
    return $result
}
function Get-LivePlaybackMode {
    if($null-eq$script:LivePlaybackModeCombo){return 'HOLD'}
    if($script:LivePlaybackModeCombo.SelectedIndex-eq1){return 'ONESHOT'}
    return 'HOLD'
}
function Get-LiveUsePhoenixLoop {
    return ($null-ne$script:LiveLoopCheck -and [bool]$script:LiveLoopCheck.IsChecked)
}
function Convert-LiveXFadeToInt {
    param($Value)
    if($null-eq$Value){return 0}
    $text=([string]$Value).Trim().ToUpperInvariant()
    if($text-eq'OFF' -or [string]::IsNullOrWhiteSpace($text)){return 0}
    $parsed=0
    if([int]::TryParse($text,[ref]$parsed)){
        return [Math]::Max(0,[Math]::Min(32,$parsed))
    }
    if($text-match '(\d+)'){
        return [Math]::Max(0,[Math]::Min(32,[int]$Matches[1]))
    }
    return 0
}
function Play-LivePcNote {
    param([int]$SlotIndex,[int]$Note,[int]$Velocity,[int]$Channel=1)
    try {
        if($null-eq$script:CurrentBank-or$SlotIndex-lt0-or$SlotIndex-ge4){return}
        $slot=$script:CurrentBank.Slots[$SlotIndex]
        if($null-eq$slot-or[string]::IsNullOrWhiteSpace([string]$slot.FilePath)-or-not(Test-Path -LiteralPath $slot.FilePath)){Add-Log ('Live PC: S{0} besitzt keine gültige WAV-Datei.' -f ($SlotIndex+1));return}
        $wasRunning=[PhoenixWasapiLiveEngine]::IsRunning
        if(-not ([PhoenixWasapiLiveEngine]::Start())){throw ('WASAPI konnte nicht gestartet werden: '+[PhoenixWasapiLiveEngine]::Status)}
        if(-not $wasRunning){Add-Log ('WASAPI RC5l ON-DEMAND OPEN: '+[PhoenixWasapiLiveEngine]::Status)}
        Touch-LiveAudioActivity
        $playMode=Get-LivePlaybackMode;$useLoop=Get-LiveUsePhoenixLoop;$loopMode=0;$loopText=([string]$slot.LoopMode).Trim().ToUpperInvariant();switch($loopText){'FORWARD'{$loopMode=1};'ALTERNATE'{$loopMode=2};default{$parsed=0;if([int]::TryParse($loopText,[ref]$parsed)){$loopMode=[Math]::Max(0,[Math]::Min(2,$parsed))}}};if(-not$useLoop-or$playMode-eq'ONESHOT'){$loopMode=0};$hold=($loopMode-ne0);$xFadeMs=Convert-LiveXFadeToInt $slot.XFade
        $root=[int](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'ROOT' 60) 60);$level=[double](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'LEVEL' 100) 100);$pan=[double](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'PAN' 0) 0);$pitchRatio=[Math]::Pow(2.0,(($Note-$root)/12.0));$gain=[Math]::Max(0.0,[Math]::Min(1.0,($Velocity/127.0)*($level/100.0)))
        $path=Get-LiveRamPitchPath $SlotIndex $Note $hold $loopMode $xFadeMs
        if([string]::IsNullOrWhiteSpace([string]$path)){
            if(-not(Register-LiveRamPitch $SlotIndex $Note $hold $loopMode $xFadeMs ([string]$slot.FilePath))){throw 'Original-Sample konnte nicht in den RAM geladen werden.'}
            $path=[string]$slot.FilePath;Add-Log ('Live Single-Sample RAM MISS/Fallback: S{0}' -f ($SlotIndex+1))
        } else { Add-Log ('Live Single-Sample RAM HIT: S{0}' -f ($SlotIndex+1)) }
        $sameSlot=@($script:ActiveLivePcVoices|Where-Object{$_.Active -and [int]$_.Slot-eq$SlotIndex})
        if($sameSlot.Count-ge$script:LiveVoicesPerSlot){$old=@($sameSlot|Sort-Object Sequence|Select-Object -First 1)[0];if($old){Release-LiveVoice $old;Add-Log ('Voice Steal: S{0}' -f ($SlotIndex+1))}}
        $script:LiveVoiceSequence++;$id=[int]($script:LiveVoiceSequence -band 0x7FFFFFFF)
        $balance=[Math]::Max(-1.0,[Math]::Min(1.0,$pan/100.0))
        $ss=[int][Math]::Max(0,[long]$slot.SampleStart);$ls=[int][Math]::Max($ss,[long]$slot.LoopStart);$le=[int][Math]::Max($ls+1,[long]$slot.LoopEnd);$rawSe=[long]$slot.SampleEnd;$se=if($rawSe-gt0){[int][Math]::Min([int]::MaxValue,[Math]::Max($le,$rawSe))}else{[int]::MaxValue}
        $voice=[pscustomobject]@{WasapiId=$id;Slot=$SlotIndex;VoiceIndex=0;Active=$true;Released=$false;SustainDeferred=$false;OneShot=($playMode-eq'ONESHOT');Note=$Note;Channel=$Channel;Sequence=$script:LiveVoiceSequence;Gain=$gain;Balance=$balance;Path=$path}
        $ok=[PhoenixWasapiLiveEngine]::PlayNativePreloaded($id,$path,[single]$gain,[single]$balance,$Channel,[double]$pitchRatio,$ss,$ls,$le,$se,$loopMode,$xFadeMs)
        if(-not$ok){throw ('WASAPI Native Play fehlgeschlagen: '+[PhoenixWasapiLiveEngine]::Status)}
        Touch-LiveAudioActivity
        [void]$script:ActiveLivePcVoices.Add($voice);Update-LiveVoiceStatus
        Add-Log ('Live-WASAPI NATIVE PLAY: S{0}, {1}, Root {2}, Ch {3}, Gain={4:N2}, PitchStep={5:N3}, Loop={6}, RAM=SOURCE' -f ($SlotIndex+1),(Get-MidiNoteName $Note),(Get-MidiNoteName $root),$Channel,$gain,$pitchRatio,$loopMode)
    } catch {Add-Log ('Live-PC-Audio Fehler: '+$_.Exception.Message)}
}

function Invoke-LiveFullPathPrime {
    # RC4b: Execute the real live-note path once, silently, before the musician's
    # first note. This intentionally exercises Play-LivePcNote -> PlayNativePreloaded ->
    # AddVoice -> Mix -> WASAPI instead of using a separate synthetic test path.
    if($script:LiveFullPathPrimed -or $script:LiveFullPathPrimeInProgress -or $null-eq$script:CurrentBank){return}
    $script:LiveFullPathPrimeInProgress=$true
    try {
        $primeSlot=-1;$primeNote=60
        $useLoop=Get-LiveUsePhoenixLoop
        for($i=0;$i-lt4;$i++){
            $slot=$script:CurrentBank.Slots[$i]
            if($null-eq$slot -or [string]::IsNullOrWhiteSpace([string]$slot.FilePath) -or -not(Test-Path -LiteralPath $slot.FilePath)){continue}
            $root=[int](Convert-ToInt64Safe (Get-ValueOrDefault $slot.Raw 'ROOT' 60) 60)
            $loopMode=0;$loopText=([string]$slot.LoopMode).Trim().ToUpperInvariant()
            switch($loopText){'FORWARD'{$loopMode=1};'ALTERNATE'{$loopMode=2};default{$parsed=0;if([int]::TryParse($loopText,[ref]$parsed)){$loopMode=[Math]::Max(0,[Math]::Min(2,$parsed))}}}
            if(-not$useLoop){$loopMode=0}
            $xf=Convert-LiveXFadeToInt $slot.XFade
            $hold=((Get-LivePlaybackMode)-eq'HOLD' -and $loopMode-ne0)
            $path=Get-LiveRamPitchPath $i $root $hold $loopMode $xf
            if(-not [string]::IsNullOrWhiteSpace([string]$path)){$primeSlot=$i;$primeNote=$root;break}
        }
        if($primeSlot-lt0){Add-Log 'Live-Engine PRIME übersprungen: kein vorbereitetes Source-Sample.';return}
        Add-Log ('Live-Engine PRIME START: S{0}, {1}, echter Live-Pfad, stumm.' -f ($primeSlot+1),(Get-MidiNoteName $primeNote))
        # Velocity 0 keeps the complete live path inaudible while still creating a
        # real WASAPI voice and forcing AddVoice/Mix/JIT initialization.
        Play-LivePcNote $primeSlot $primeNote 0 1
        # Give the event-driven WASAPI thread enough time to consume several
        # endpoint periods, so Mix() is definitely JITted and executed.
        [Threading.Thread]::Sleep(90)
        Stop-LivePcNote -Note $primeNote -Channel 1 -SlotIndex $primeSlot -Force $true
        [Threading.Thread]::Sleep(20)
        Add-Log ('Live-Engine PRIME Messung: '+[PhoenixWasapiLiveEngine]::Diagnostics); Add-Log ('Live-Engine PRIME Health: '+[PhoenixWasapiLiveEngine]::HealthDiagnostics)
        # Ensure no dummy entry remains in the PowerShell voice tracker.
        foreach($v in @($script:ActiveLivePcVoices|Where-Object { $_.Slot-eq$primeSlot -and $_.Note-eq-1 })){$v.Active=$false;$v.Released=$true}
        [PhoenixWasapiLiveEngine]::StopAll()
        Update-LiveVoiceStatus
        $script:LiveFullPathPrimed=$true
        Add-Log ('Live-Engine PRIME READY: erster realer Note-On nutzt bereits initialisierten Voice/Mixer/WASAPI-Pfad.')
    } catch {
        Add-Log ('Live-Engine PRIME Warnung: '+$_.Exception.Message)
    } finally {
        $script:LiveFullPathPrimeInProgress=$false
    }
}

function Stop-LivePcNote {
    param([int]$Note=-1,[int]$Channel=-1,[int]$SlotIndex=-1,[bool]$Force=$false)
    try {
        $targets=@($script:ActiveLivePcVoices | Where-Object { $_.Active -and ($Force -or (($Note -lt 0 -or [int]$_.Note -eq $Note) -and ($Channel -lt 0 -or [int]$_.Channel -eq $Channel) -and ($SlotIndex -lt 0 -or [int]$_.Slot -eq $SlotIndex))) })
        Add-Log ('Live Note-Off Suche: Note={0}, Ch={1}, Slot={2}, Treffer={3}' -f $Note,$Channel,$SlotIndex,$targets.Count)
        foreach($v in $targets){
            if((-not $Force) -and $v.OneShot){continue}
            $sustain=$false
            if($script:LiveSustainByChannel.ContainsKey([int]$v.Channel)){$sustain=[bool]$script:LiveSustainByChannel[[int]$v.Channel]}
            if((-not $Force)-and$sustain){$v.SustainDeferred=$true;Add-Log ('Live-Voice Sustain gehalten: S{0} V{1}' -f ($v.Slot+1),($v.VoiceIndex+1));continue}
            Add-Log ('Live-Voice STOP: S{0} V{1}, Note {2}, Ch {3}' -f ($v.Slot+1),($v.VoiceIndex+1),$v.Note,$v.Channel)
            Release-LiveVoice $v
        }
    } catch {Add-Log ('Live-PC Note-Off Fehler: '+$_.Exception.Message)}
}
function Stop-AllLivePcVoices {try{if('PhoenixWasapiLiveEngine' -as [type]){[PhoenixWasapiLiveEngine]::StopAll()}}catch{};Touch-LiveAudioActivity;foreach($v in @($script:ActiveLivePcVoices|Where-Object { $_.Active })){$v.Active=$false;$v.Released=$true;$v.Note=-1};$script:LiveSustainByChannel=@{};Update-LiveVoiceStatus}
function Send-LiveMidi {param([int]$Status,[int]$Data1,[int]$Data2);if(-not(Open-MidiOutput)){return};Send-MidiShort $Status $Data1 $Data2}
function Handle-LiveNote {
    param([bool]$On,[int]$Note,[int]$Velocity,[int]$Channel,[string]$Source='MIDI IN')
    $filter=$script:MidiInputChannelCombo.SelectedIndex;if($Source-eq'MIDI IN'-and$filter-gt0-and$Channel-ne$filter){return}
    $slots=@(Get-RoutedSlots $Note $Channel);$slotText=if($slots.Count-gt0){(@($slots|ForEach-Object{'S'+($_+1)})-join', ')}else{'kein Slot'}
    $script:MidiMonitorText.Text=('{0}: {1} {2}  Vel {3}  Ch {4}  -> {5}' -f $Source,$(if($On){'Note On'}else{'Note Off'}),(Get-MidiNoteName $Note),$Velocity,$Channel,$slotText);Add-Log $script:MidiMonitorText.Text
    $mode=Get-LiveOutputMode
    if($On){foreach($si in $slots){if($mode-eq'PC'-or$mode-eq'BOTH'){Play-LivePcNote $si $Note $Velocity $Channel};if($mode-eq'MIDI'-or$mode-eq'BOTH'){$outCh=[int](Convert-ToInt64Safe (Get-ValueOrDefault $script:CurrentBank.Slots[$si].Raw 'MIDI_CHANNEL' ($si+1)) ($si+1));Send-LiveMidi (0x90+(($outCh-1)-band15)) $Note $Velocity}}}
    else{
        # Note-Off muss die beim Note-On angelegte Stimme beenden. Dafür nicht erneut
        # vom aktuellen Routing abhängig machen: Bank-/Mode-Wechsel oder mehrere
        # überlappende Zonen dürfen kein hängendes Loop erzeugen.
        if($mode-eq'PC'-or$mode-eq'BOTH'){Stop-LivePcNote -Note $Note -Channel $Channel -SlotIndex -1}
        if($mode-eq'MIDI'-or$mode-eq'BOTH'){for($ch=0;$ch-lt16;$ch++){Send-LiveMidi (0x80+$ch) $Note 0}}
    }
}
function Poll-MidiInput {
    if(-not$script:MidiInputOpen){return}
    foreach($msg in [PhoenixMidiIn]::Poll()){
        $status=[int]($msg-band0xFF);$d1=[int](($msg-shr8)-band0x7F);$d2=[int](($msg-shr16)-band0x7F);$type=$status-band0xF0;$ch=($status-band0x0F)+1
        if($type-eq0x90){Handle-LiveNote ($d2-gt0) $d1 $d2 $ch 'MIDI IN'}
        elseif($type-eq0x80){Handle-LiveNote $false $d1 0 $ch 'MIDI IN'}
        elseif($type-eq0xB0){
            if($d1-eq64){Set-LiveSustain $ch ($d2-ge64);Add-Log ('MIDI IN: Sustain {0} Ch {1}' -f $(if($d2-ge64){'EIN'}else{'AUS'}),$ch)}
            $script:MidiMonitorText.Text=('MIDI IN: CC {0} = {1}  Ch {2}' -f $d1,$d2,$ch)
            $mode=Get-LiveOutputMode;if($mode-eq'MIDI'-or$mode-eq'BOTH'){Send-LiveMidi (0xB0+(($ch-1)-band15)) $d1 $d2}
        }
        elseif($type-eq0xE0){
            $bend=$d1+($d2-shl7);Set-LivePitchBend $ch $bend;$script:MidiMonitorText.Text=('MIDI IN: Pitch Bend {0}  Ch {1}' -f $bend,$ch)
            $mode=Get-LiveOutputMode;if($mode-eq'MIDI'-or$mode-eq'BOTH'){Send-LiveMidi (0xE0+(($ch-1)-band15)) $d1 $d2}
        }
    }
}
function Trigger-ScreenKeyboardNoteOn {
    param([int]$Note)
    try { Handle-LiveNote $true $Note $script:KeyboardVelocity 1 'Tastatur' }
    catch { Add-Log ('Bildschirmtastatur Note-On Fehler: '+$_.Exception.Message) }
}
function Trigger-ScreenKeyboardNoteOff {
    param([int]$Note)
    try { Handle-LiveNote $false $Note 0 1 'Tastatur' }
    catch { Add-Log ('Bildschirmtastatur Note-Off Fehler: '+$_.Exception.Message) }
}
function Build-ScreenKeyboard {
    if(-not$script:KeyboardPanel){return};$script:KeyboardPanel.Children.Clear();$base=48+($script:KeyboardOctave*12)
    for($i=0;$i-lt25;$i++){
        $note=$base+$i;if($note-lt0-or$note-gt127){continue}
        $b=New-Object Windows.Controls.Button;$b.Content=(Get-MidiNoteName $note);$b.Tag=$note;$b.MinWidth=58;$b.MinHeight=54;$b.Margin='2'
        if(@(1,3,6,8,10)-contains($note%12)){$b.Background='#303944'}else{$b.Background='#E8EDF2';$b.Foreground='#111111'}
        $b.Add_PreviewMouseLeftButtonDown({param($sender,$e);$sender.CaptureMouse()|Out-Null;Trigger-ScreenKeyboardNoteOn ([int]$sender.Tag);$e.Handled=$true}.GetNewClosure())
        $b.Add_PreviewMouseLeftButtonUp({param($sender,$e);Trigger-ScreenKeyboardNoteOff ([int]$sender.Tag);$sender.ReleaseMouseCapture();$e.Handled=$true}.GetNewClosure())
        $b.Add_LostMouseCapture({param($sender,$e);if((Get-LivePlaybackMode)-eq'HOLD'){Trigger-ScreenKeyboardNoteOff ([int]$sender.Tag)}}.GetNewClosure())
        [void]$script:KeyboardPanel.Children.Add($b)
    }
}

function Update-AllInspectors {
    if($null -eq $script:CurrentBank){return}
    Update-PatternInspector; Update-SongInspector; Update-EffectsInspector; Update-InitSoundEditor
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Phoenix Librarian" Height="900" Width="1450" MinHeight="720" MinWidth="1120"
        WindowStartupLocation="CenterScreen" Background="#10141A" Foreground="#E8EDF2">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Margin" Value="4"/><Setter Property="Padding" Value="11,7"/>
            <Setter Property="Background" Value="#263241"/><Setter Property="Foreground" Value="#F2F5F8"/>
            <Setter Property="BorderBrush" Value="#52657A"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}" CornerRadius="2">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True" TextElement.Foreground="{TemplateBinding Foreground}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#A9D8F5"/>
                                <Setter Property="Foreground" Value="#101010"/>
                                <Setter Property="BorderBrush" Value="#D7EEFC"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#245D87"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                                <Setter Property="BorderBrush" Value="#8DC9F0"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#151B23"/><Setter Property="Foreground" Value="#EDF2F6"/>
            <Setter Property="BorderBrush" Value="#45576A"/><Setter Property="Padding" Value="5"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Margin" Value="3"/><Setter Property="Padding" Value="4"/>
            <Setter Property="Background" Value="#F8F8F8"/><Setter Property="Foreground" Value="#111111"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Margin" Value="7,5"/><Setter Property="Foreground" Value="#E8EDF2"/>
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#151B23"/><Setter Property="Foreground" Value="#E8EDF2"/>
            <Setter Property="RowBackground" Value="#151B23"/><Setter Property="AlternatingRowBackground" Value="#1B2430"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/><Setter Property="HorizontalGridLinesBrush" Value="#344252"/>
            <Setter Property="BorderBrush" Value="#45576A"/><Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="SelectionMode" Value="Single"/><Setter Property="SelectionUnit" Value="FullRow"/>
            <Setter Property="CanUserAddRows" Value="False"/><Setter Property="CanUserDeleteRows" Value="False"/>
            <Setter Property="IsReadOnly" Value="True"/><Setter Property="AutoGenerateColumns" Value="False"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#263241"/><Setter Property="Foreground" Value="#F3F6F8"/>
            <Setter Property="BorderBrush" Value="#45576A"/><Setter Property="Padding" Value="6"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#111111"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Margin" Value="1,0,1,0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="TabBorder" Background="{TemplateBinding Background}" BorderBrush="#6B7885" BorderThickness="1" Padding="{TemplateBinding Padding}">
                            <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True" TextElement.Foreground="{TemplateBinding Foreground}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="TabBorder" Property="Background" Value="#050505"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                                <Setter TargetName="TabBorder" Property="BorderBrush" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="#151B23"/><Setter Property="Foreground" Value="#E8EDF2"/>
            <Setter Property="BorderBrush" Value="#45576A"/>
        </Style>
    </Window.Resources>

    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#19222D" BorderBrush="#415368" BorderThickness="1" Padding="12" CornerRadius="4">
            <DockPanel>
                <StackPanel DockPanel.Dock="Left">
                    <TextBlock Text="PHOENIX LIBRARIAN" FontSize="24" FontWeight="Bold"/>
                    <TextBlock Text="Project Phoenix Bank Manager &amp; PC Editor - Samples, Routing, Sequencer, Song, MIDI &amp; Effects" Foreground="#9EB0C3"/>
                </StackPanel>
                <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center">
                    <TextBlock Name="VersionText" HorizontalAlignment="Right" Foreground="#9EB0C3" FontSize="14"/>
                    <Border Name="AccessModeBorder" HorizontalAlignment="Right" Margin="0,4,0,0" Padding="7,2" Background="#303944" BorderBrush="#596777" BorderThickness="1" CornerRadius="3">
                        <TextBlock Name="AccessModeText" Text="ZUGRIFF: NICHT VERBUNDEN" Foreground="#D7DEE5" FontSize="11" FontWeight="SemiBold"/>
                    </Border>
                </StackPanel>
            </DockPanel>
        </Border>

        <Grid Grid.Row="1" Margin="0,10,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal">
                <Button Name="AutoDetectButton" Content="Phoenix automatisch finden"/>
                <Button Name="BrowseButton" Content="Ordner wählen ..."/>
                <Button Name="RefreshButton" Content="Neu einlesen"/>
            </StackPanel>
            <Grid Grid.Column="1" Margin="8,0">
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="180"/></Grid.ColumnDefinitions>
                <TextBox Name="PathBox" Margin="0,4,8,4" IsReadOnly="True" VerticalContentAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="Suche:" VerticalAlignment="Center" Foreground="#9EB0C3" Margin="0,0,5,0"/>
                <TextBox Grid.Column="2" Name="BankFilterBox" Margin="0,4" VerticalContentAlignment="Center" ToolTip="Bankname, Anzeigename, Kategorie, Tags, Autor, Status oder Hinweis durchsuchen"/>
                <WrapPanel Grid.Row="1" Grid.ColumnSpan="3" VerticalAlignment="Center">
                    <TextBlock Text="Kategorie" Foreground="#9EB0C3" VerticalAlignment="Center" Margin="2,0,4,0"/>
                    <ComboBox Name="CategoryFilterCombo" Width="125" SelectedIndex="0"><ComboBoxItem Content="Alle"/><ComboBoxItem Content="Drums"/><ComboBoxItem Content="Synth Waves"/><ComboBoxItem Content="Loops"/><ComboBoxItem Content="Multisample"/><ComboBoxItem Content="SFX"/><ComboBoxItem Content="Other"/><ComboBoxItem Content="Uncategorized"/></ComboBox>
                    <TextBlock Text="Routing" Foreground="#9EB0C3" VerticalAlignment="Center" Margin="10,0,4,0"/>
                    <ComboBox Name="RoutingFilterCombo" Width="105" SelectedIndex="0"><ComboBoxItem Content="Alle"/><ComboBoxItem Content="KEYZONE"/><ComboBoxItem Content="MULTI"/></ComboBox>
                    <TextBlock Text="Status" Foreground="#9EB0C3" VerticalAlignment="Center" Margin="10,0,4,0"/>
                    <ComboBox Name="StatusFilterCombo" Width="110" SelectedIndex="0"><ComboBoxItem Content="Alle"/><ComboBoxItem Content="OK"/><ComboBoxItem Content="Hinweise"/><ComboBoxItem Content="Fehler"/><ComboBoxItem Content="Belegt"/><ComboBoxItem Content="Leer"/></ComboBox>
                    <Button Name="ClearFiltersButton" Content="Filter löschen" Padding="8,3" Margin="8,2,0,2"/>
                </WrapPanel>
            </Grid>
            <StackPanel Grid.Column="2" Orientation="Horizontal">
                <Button Name="NewBankButton" Content="Neue Bank"/><Button Name="ImportBankButton" Content="Bank importieren"/><Button Name="ImportFourWavsButton" Content="4 WAVs importieren"/><Button Name="FactoryExportButton" Content="Factory Library"/><Button Name="ReportButton" Content="Report"/><Button Name="BackupAllButton" Content="Alle Bänke sichern"/>
            </StackPanel>
        </Grid>

        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions><ColumnDefinition Width="410"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="#151B23" BorderBrush="#45576A" BorderThickness="1" Padding="8">
                <Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <TextBlock Text="BANKEN" FontSize="15" FontWeight="Bold" Margin="4,2,4,8"/>
                    <DataGrid Name="BankGrid" Grid.Row="1" AlternationCount="2">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Bank" Binding="{Binding Name}" Width="90"/><DataGridTextColumn Header="Slots" Binding="{Binding RecordedSlots}" Width="50"/>
                            <DataGridTextColumn Header="Größe" Binding="{Binding SizeText}" Width="85"/><DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                    <StackPanel Grid.Row="2" Margin="0,8,0,0">
                        <WrapPanel HorizontalAlignment="Center">
                            <Button Name="OpenFolderButton" Content="Ordner öffnen"/><Button Name="BackupBankButton" Content="Bank sichern"/><Button Name="ExportZipButton" Content="Als ZIP exportieren"/>
                        </WrapPanel>
                        <WrapPanel HorizontalAlignment="Center">
                            <Button Name="CopyBankButton" Content="Bank kopieren"/><Button Name="MoveBankButton" Content="Bank verschieben"/><Button Name="DeleteBankButton" Content="Bank löschen"/>
                        </WrapPanel>
                    </StackPanel>
                </Grid>
            </Border>

            <GridSplitter Grid.Column="1" Width="8" HorizontalAlignment="Stretch" Background="#263241"/>

            <Border Grid.Column="2" Background="#151B23" BorderBrush="#45576A" BorderThickness="1" Padding="10">
                <Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Name="BankTitle" FontSize="20" FontWeight="Bold" Text="Keine Bank ausgewählt"/>
                    <TextBlock Name="BankSummary" Grid.Row="1" Margin="0,3,0,10" Foreground="#9EB0C3"/>
                    <TabControl Grid.Row="2" Name="MainTabs">
                        <TabItem Header="Bank-Metadaten">
                            <ScrollViewer VerticalScrollBarVisibility="Auto"><Grid Margin="14"><Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="100"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <TextBlock Text="BANK.NAME" Margin="0,7"/><TextBox Name="BankNameBox" Grid.Column="1" Margin="0,4"/>
                            <TextBlock Grid.Row="1" Text="KATEGORIE" Margin="0,7"/><TextBox Name="BankCategoryBox" Grid.Row="1" Grid.Column="1" Margin="0,4"/>
                            <TextBlock Grid.Row="2" Text="AUTOR" Margin="0,7"/><TextBox Name="BankAuthorBox" Grid.Row="2" Grid.Column="1" Margin="0,4"/>
                            <TextBlock Grid.Row="3" Text="BESCHREIBUNG" Margin="0,7"/><TextBox Name="BankDescriptionBox" Grid.Row="3" Grid.Column="1" Margin="0,4" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                            <TextBlock Grid.Row="4" Text="LIZENZ" Margin="0,7"/><TextBox Name="BankLicenseBox" Grid.Row="4" Grid.Column="1" Margin="0,4"/>
                            <TextBlock Grid.Row="5" Text="TAGS" Margin="0,7"/><TextBox Name="BankTagsBox" Grid.Row="5" Grid.Column="1" Margin="0,4" ToolTip="Kommagetrennt, z. B. analog, drums, percussion"/>
                            <TextBlock Grid.Row="6" Text="VORLAGE" Margin="0,7"/><TextBlock Name="BankTemplateText" Grid.Row="6" Grid.Column="1" Margin="0,7" FontWeight="SemiBold"/>
                            <TextBlock Grid.Row="7" Text="S1 NAME" Margin="0,7"/><TextBox Name="Slot1NameBox" Grid.Row="7" Grid.Column="1" Margin="0,4"/>
                            <TextBlock Grid.Row="8" Text="S2 NAME" Margin="0,7"/><TextBox Name="Slot2NameBox" Grid.Row="8" Grid.Column="1" Margin="0,4"/>
                            <TextBlock Grid.Row="9" Text="S3 NAME" Margin="0,7"/><TextBox Name="Slot3NameBox" Grid.Row="9" Grid.Column="1" Margin="0,4"/>
                            <TextBlock Grid.Row="10" Text="S4 NAME" Margin="0,7"/><TextBox Name="Slot4NameBox" Grid.Row="10" Grid.Column="1" Margin="0,4"/>
                            <Button Name="SaveBankInfoButton" Grid.Row="11" Grid.Column="1" Content="Bank-Metadaten speichern" HorizontalAlignment="Left" Margin="0,12,0,0"/>
                            </Grid></ScrollViewer>
                        </TabItem>
                        <TabItem Header="Bankübersicht">
                            <DataGrid Name="SlotGrid" AlternationCount="2" Margin="4">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Slot" Binding="{Binding Slot}" Width="45"/><DataGridTextColumn Header="Sample" Binding="{Binding SampleName}" Width="120"/><DataGridTextColumn Header="REC" Binding="{Binding Recorded}" Width="45"/>
                                    <DataGridTextColumn Header="Dauer" Binding="{Binding Duration}" Width="78"/><DataGridTextColumn Header="Root 0..127" Binding="{Binding Root}" Width="82"/>
                                    <DataGridTextColumn Header="Loop" Binding="{Binding LoopMode}" Width="80"/><DataGridTextColumn Header="XFade" Binding="{Binding XFade}" Width="55"/>
                                    <DataGridTextColumn Header="Trim" Binding="{Binding Trim}" Width="45"/><DataGridTextColumn Header="DC" Binding="{Binding DC}" Width="40"/>
                                    <DataGridTextColumn Header="Norm" Binding="{Binding Normalize}" Width="50"/><DataGridTextColumn Header="Status" Binding="{Binding Issue}" Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </TabItem>
                        <TabItem Name="WaveformEditorTab" Header="Waveform-Editor">
                            <Grid Margin="8">
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <DockPanel Margin="2,2,2,8">
                                    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                        <TextBlock Name="EditorStatusText" Text="Gespeichert" Foreground="#87C58B" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                        <Button Name="ImportWavButton" Content="WAV importieren ..." Padding="9,4" Margin="2"/><Button Name="CopySlotButton" Content="Slot kopieren" Padding="9,4" Margin="2"/><Button Name="MoveSlotButton" Content="Slot verschieben" Padding="9,4" Margin="2"/><Button Name="ClearSlotButton" Content="Slot leeren" Padding="9,4" Margin="2"/>
                                    </StackPanel>
                                    <TextBlock Name="WaveformInfo" Text="Kein Slot ausgewählt." Foreground="#B9C8D6" VerticalAlignment="Center"/>
                                </DockPanel>
                                <Border Grid.Row="1" Background="#0C1117" BorderBrush="#45576A" BorderThickness="1" Padding="3" ClipToBounds="True" MinHeight="120">
                                    <Canvas Name="WaveformCanvas" ClipToBounds="True" Cursor="SizeWE" HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
                                </Border>
                                <Grid Grid.Row="2" Name="EditorControlsPanel" Margin="0,8,0,0" IsEnabled="False">
                                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                    <DockPanel><TextBlock Name="EditorSlotText" DockPanel.Dock="Left" FontWeight="Bold" Foreground="#DDE7F0" Margin="3,0,12,5"/><TextBlock Name="LoopStatsText" Foreground="#9EB0C3" Margin="3,0,3,5" HorizontalAlignment="Right"/></DockPanel>
                                    <WrapPanel Grid.Row="1" VerticalAlignment="Top">
                                        <StackPanel Margin="4,0"><TextBlock Text="S.START" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><TextBox Name="SStartBox" Width="88"/></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="L.START" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><TextBox Name="LStartBox" Width="88"/></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="L.END" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><TextBox Name="LEndBox" Width="88"/></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="S.END" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><TextBox Name="SEndBox" Width="88"/></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="MARKER" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><ComboBox Name="MarkerSelectCombo" Width="92"><ComboBoxItem Content="S.START"/><ComboBoxItem Content="L.START"/><ComboBoxItem Content="L.END"/><ComboBoxItem Content="S.END"/></ComboBox></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="NULLDURCHGANG" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><Button Name="SnapButton" Content="Zero Crossing" Margin="0"/></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="FEIN" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><WrapPanel><Button Name="NudgeMinus100Button" Content="-100" Padding="6,4" Margin="0,0,2,0"/><Button Name="NudgeMinus10Button" Content="-10" Padding="6,4" Margin="0,0,2,0"/><Button Name="NudgeMinus1Button" Content="-1" Padding="6,4" Margin="0,0,2,0"/><Button Name="NudgePlus1Button" Content="+1" Padding="6,4" Margin="0,0,2,0"/><Button Name="NudgePlus10Button" Content="+10" Padding="6,4" Margin="0,0,2,0"/><Button Name="NudgePlus100Button" Content="+100" Padding="6,4" Margin="0"/></WrapPanel></StackPanel>
                                        <StackPanel Margin="8,0,4,0"><TextBlock Text="LOOP-WERKZEUGE" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><WrapPanel><CheckBox Name="LinkLoopCheck" Content="L.START/L.END gemeinsam" Foreground="#17212B" Margin="0,0,8,0"/><Button Name="SelectLoopButton" Content="Loop auswählen" Margin="0"/></WrapPanel></StackPanel>
                                    </WrapPanel>
                                    <WrapPanel Grid.Row="2" Margin="0,8,0,0" VerticalAlignment="Top">
                                        <StackPanel Margin="4,0"><TextBlock Text="LOOP" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><ComboBox Name="LoopModeCombo" Width="108"><ComboBoxItem Content="OFF"/><ComboBoxItem Content="FORWARD"/><ComboBoxItem Content="ALTERNATE"/></ComboBox></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="XFADE" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><ComboBox Name="XFadeCombo" Width="78"><ComboBoxItem Content="OFF"/><ComboBoxItem Content="2 ms"/><ComboBoxItem Content="4 ms"/><ComboBoxItem Content="8 ms"/><ComboBoxItem Content="16 ms"/><ComboBoxItem Content="32 ms"/></ComboBox></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="LOW NOTE" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><ComboBox Name="KeyLowCombo" Width="92"/></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="ROOT NOTE" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><ComboBox Name="RootCombo" Width="92"/></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="HIGH NOTE" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><ComboBox Name="KeyHighCombo" Width="92"/></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="LEVEL" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><TextBox Name="LevelBox" Width="48"/></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="PANORAMA" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><ComboBox Name="PanCombo" Width="100"/></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="VOICES" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><TextBox Name="VoicesBox" Width="58" Text="12" IsReadOnly="True" ToolTip="Phoenix 1.0 verwendet fest 12 Stimmen."/></StackPanel>
                                        <StackPanel Margin="8,0,4,0"><TextBlock Text="BEARBEITUNG" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><StackPanel Orientation="Horizontal" VerticalAlignment="Center"><CheckBox Name="TrimCheck" Content="Trim" Foreground="#17212B" VerticalAlignment="Center" Margin="0,0,10,0"/><CheckBox Name="DCCheck" Content="DC" Foreground="#17212B" VerticalAlignment="Center" Margin="0,0,10,0"/><CheckBox Name="NormCheck" Content="Normalize" Foreground="#17212B" VerticalAlignment="Center"/></StackPanel></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="LIVE-VORSCHAU" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><WrapPanel><Button Name="PlayLoopButton" Content="Loop halten" Margin="0,0,4,0"/><Button Name="PlayWavButton" Content="One Shot" Margin="0,0,4,0"/><Button Name="StopPreviewButton" Content="Stop" Margin="0,0,4,0"/><Button Name="OpenWavButton" Content="WAV öffnen" Margin="0"/></WrapPanel></StackPanel>
                                        <StackPanel Margin="4,0"><TextBlock Text="ÄNDERUNGEN" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/><WrapPanel><Button Name="ReloadEditorButton" Content="Zurücksetzen" Margin="0,0,4,0"/><Button Name="SaveEditorButton" Content="Speichern" IsEnabled="False" Margin="0"/></WrapPanel></StackPanel>
                                    </WrapPanel>
                                </Grid>
                            </Grid>
                        </TabItem>
                        <TabItem Name="KeyRangeTab" Header="Quattro-Routing">
                            <Grid Margin="8">
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <DockPanel Grid.Row="0" Margin="2,0,0,8">
                                    <TextBlock Text="QUATTRO MODE" Foreground="#DDE7F0" FontSize="16" FontWeight="Bold" Margin="0,0,14,0" VerticalAlignment="Center"/>
                                    <ComboBox Name="QuattroModeCombo" Width="150" SelectedIndex="0">
                                        <ComboBoxItem Content="KEYZONE"/><ComboBoxItem Content="MULTI"/>
                                    </ComboBox>
                                    <TextBlock Name="KeyRangeDescription" Foreground="#9EB0C3" Margin="16,0,0,0" VerticalAlignment="Center"/>
                                </DockPanel>
                                <Grid Name="KeyzonePanel" Grid.Row="2">
                                    <Grid.RowDefinitions><RowDefinition Height="210"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                                    <Border Background="#151D26" BorderBrush="#52657A" BorderThickness="1" Padding="6">
                                        <Canvas Name="KeyRangeCanvas" Background="#F5F7FA" Height="196"/>
                                    </Border>
                                    <WrapPanel Grid.Row="1" Margin="0,8,0,8">
                                        <Button Name="EqualZonesButton" Content="4 Zonen automatisch"/>
                                        <Button Name="DrumMapButton" Content="Vier Einzeltasten"/>
                                        <Button Name="FullRangeButton" Content="Alle Slots C-1 bis G9"/>
                                    </WrapPanel>
                                    <Grid Grid.Row="2">
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="210"/><ColumnDefinition Width="210"/><ColumnDefinition Width="210"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Grid.Column="0" Text="SLOT" FontWeight="Bold" Foreground="#DDE7F0" Margin="4"/><TextBlock Grid.Row="0" Grid.Column="1" Text="LOW NOTE" FontWeight="Bold" Foreground="#DDE7F0" Margin="4"/><TextBlock Grid.Row="0" Grid.Column="2" Text="ROOT NOTE" FontWeight="Bold" Foreground="#DDE7F0" Margin="4"/><TextBlock Grid.Row="0" Grid.Column="3" Text="HIGH NOTE" FontWeight="Bold" Foreground="#DDE7F0" Margin="4"/><TextBlock Grid.Row="0" Grid.Column="4" Text="BEREICH" FontWeight="Bold" Foreground="#DDE7F0" Margin="4"/>
                                        <TextBlock Grid.Row="1" Grid.Column="0" Text="S1" FontWeight="Bold" Foreground="#F3D05C" Margin="4"/><ComboBox Grid.Row="1" Grid.Column="1" Name="S1LowCombo" Margin="4"/><ComboBox Grid.Row="1" Grid.Column="2" Name="S1RootCombo" Margin="4"/><ComboBox Grid.Row="1" Grid.Column="3" Name="S1HighCombo" Margin="4"/><TextBlock Grid.Row="1" Grid.Column="4" Name="S1RangeText" Foreground="#DDE7F0" Margin="8,7"/>
                                        <TextBlock Grid.Row="2" Grid.Column="0" Text="S2" FontWeight="Bold" Foreground="#70D89A" Margin="4"/><ComboBox Grid.Row="2" Grid.Column="1" Name="S2LowCombo" Margin="4"/><ComboBox Grid.Row="2" Grid.Column="2" Name="S2RootCombo" Margin="4"/><ComboBox Grid.Row="2" Grid.Column="3" Name="S2HighCombo" Margin="4"/><TextBlock Grid.Row="2" Grid.Column="4" Name="S2RangeText" Foreground="#DDE7F0" Margin="8,7"/>
                                        <TextBlock Grid.Row="3" Grid.Column="0" Text="S3" FontWeight="Bold" Foreground="#EE8A5B" Margin="4"/><ComboBox Grid.Row="3" Grid.Column="1" Name="S3LowCombo" Margin="4"/><ComboBox Grid.Row="3" Grid.Column="2" Name="S3RootCombo" Margin="4"/><ComboBox Grid.Row="3" Grid.Column="3" Name="S3HighCombo" Margin="4"/><TextBlock Grid.Row="3" Grid.Column="4" Name="S3RangeText" Foreground="#DDE7F0" Margin="8,7"/>
                                        <TextBlock Grid.Row="4" Grid.Column="0" Text="S4" FontWeight="Bold" Foreground="#D77AE8" Margin="4"/><ComboBox Grid.Row="4" Grid.Column="1" Name="S4LowCombo" Margin="4"/><ComboBox Grid.Row="4" Grid.Column="2" Name="S4RootCombo" Margin="4"/><ComboBox Grid.Row="4" Grid.Column="3" Name="S4HighCombo" Margin="4"/><TextBlock Grid.Row="4" Grid.Column="4" Name="S4RangeText" Foreground="#DDE7F0" Margin="8,7"/>
                                    </Grid>
                                </Grid>
                                <Grid Name="MultiPanel" Grid.Row="2" Visibility="Collapsed">
                                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                                    <WrapPanel Margin="0,0,0,10"><Button Name="DefaultChannelsButton" Content="Kanäle 1-4 automatisch"/></WrapPanel>
                                    <Grid Grid.Row="1">
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="220"/><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Grid.Column="0" Text="SLOT" FontWeight="Bold" Foreground="#DDE7F0" Margin="4"/><TextBlock Grid.Row="0" Grid.Column="1" Text="MIDI-KANAL" FontWeight="Bold" Foreground="#DDE7F0" Margin="4"/><TextBlock Grid.Row="0" Grid.Column="2" Text="ROOT NOTE" FontWeight="Bold" Foreground="#DDE7F0" Margin="4"/><TextBlock Grid.Row="0" Grid.Column="3" Text="ROUTING" FontWeight="Bold" Foreground="#DDE7F0" Margin="4"/>
                                        <TextBlock Grid.Row="1" Grid.Column="0" Text="S1" FontWeight="Bold" Foreground="#F3D05C" Margin="4"/><ComboBox Grid.Row="1" Grid.Column="1" Name="S1ChannelCombo" Margin="4"/><ComboBox Grid.Row="1" Grid.Column="2" Name="S1MultiRootCombo" Margin="4"/><TextBlock Grid.Row="1" Grid.Column="3" Name="S1MultiText" Foreground="#DDE7F0" Margin="8,7"/>
                                        <TextBlock Grid.Row="2" Grid.Column="0" Text="S2" FontWeight="Bold" Foreground="#70D89A" Margin="4"/><ComboBox Grid.Row="2" Grid.Column="1" Name="S2ChannelCombo" Margin="4"/><ComboBox Grid.Row="2" Grid.Column="2" Name="S2MultiRootCombo" Margin="4"/><TextBlock Grid.Row="2" Grid.Column="3" Name="S2MultiText" Foreground="#DDE7F0" Margin="8,7"/>
                                        <TextBlock Grid.Row="3" Grid.Column="0" Text="S3" FontWeight="Bold" Foreground="#EE8A5B" Margin="4"/><ComboBox Grid.Row="3" Grid.Column="1" Name="S3ChannelCombo" Margin="4"/><ComboBox Grid.Row="3" Grid.Column="2" Name="S3MultiRootCombo" Margin="4"/><TextBlock Grid.Row="3" Grid.Column="3" Name="S3MultiText" Foreground="#DDE7F0" Margin="8,7"/>
                                        <TextBlock Grid.Row="4" Grid.Column="0" Text="S4" FontWeight="Bold" Foreground="#D77AE8" Margin="4"/><ComboBox Grid.Row="4" Grid.Column="1" Name="S4ChannelCombo" Margin="4"/><ComboBox Grid.Row="4" Grid.Column="2" Name="S4MultiRootCombo" Margin="4"/><TextBlock Grid.Row="4" Grid.Column="3" Name="S4MultiText" Foreground="#DDE7F0" Margin="8,7"/>
                                    </Grid>
                                </Grid>
                                <WrapPanel Grid.Row="3" HorizontalAlignment="Right" Margin="0,10,0,0"><Button Name="SaveKeyRangesButton" Content="Quattro-Routing speichern"/></WrapPanel>
                            </Grid>
                        </TabItem>
                        <TabItem Name="SequencerTab" Header="Sequencer &amp; Pattern">
                            <Grid Margin="10"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <DockPanel Margin="3,2,3,8"><TextBlock Name="PatternStatusText" Foreground="#9EB0C3" VerticalAlignment="Center"/><TextBlock Name="PatternDirtyText" DockPanel.Dock="Right" Foreground="#F3D05C" FontWeight="Bold" Text=""/></DockPanel>
                                <Grid Grid.Row="1" Margin="0,0,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="105"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="105"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="85"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="90"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <TextBlock Text="PATTERN" VerticalAlignment="Center" Margin="3"/><ComboBox Name="PatternSelectCombo" Grid.Column="1" Margin="3"><ComboBoxItem Content="P1"/><ComboBoxItem Content="P2"/><ComboBoxItem Content="P3"/><ComboBoxItem Content="P4"/></ComboBox>
                                    <TextBlock Grid.Column="2" Text="SPUR" VerticalAlignment="Center" Margin="10,3,3,3"/><ComboBox Name="PatternTrackCombo" Grid.Column="3" Margin="3"><ComboBoxItem Content="S1"/><ComboBoxItem Content="S2"/><ComboBoxItem Content="S3"/><ComboBoxItem Content="S4"/></ComboBox>
                                    <TextBlock Grid.Column="4" Text="LÄNGE" VerticalAlignment="Center" Margin="10,3,3,3"/><ComboBox Name="PatternLengthCombo" Grid.Column="5" Margin="3"/>
                                    <TextBlock Grid.Column="6" Text="BPM" VerticalAlignment="Center" Margin="10,3,3,3"/><TextBox Name="PatternBpmBox" Grid.Column="7" Margin="3" VerticalContentAlignment="Center"/>
                                    <TextBlock Grid.Column="8" Text="CLOCK" VerticalAlignment="Center" Margin="10,3,3,3"/><ComboBox Name="PatternClockCombo" Grid.Column="9" Margin="3"><ComboBoxItem Content="INT"/><ComboBoxItem Content="EXT"/></ComboBox>
                                    <TextBlock Grid.Column="10" Text=""/>
                                </Grid>
                                <WrapPanel Grid.Row="2" Margin="0,0,0,8">
                                    <Button Name="PatternPlayButton" Content="PLAY PATTERN"/><CheckBox Name="PatternRepeatCheck" Content="Pattern wiederholen" IsChecked="True" VerticalAlignment="Center" Foreground="#17212B" Background="#F5F7FA" Padding="7,4" Margin="6,2"/><Button Name="TransportStopButton" Content="STOP"/><Button Name="MidiPanicButton" Content="PANIC"/>
                                    <TextBlock Text="AUSGABE" VerticalAlignment="Center" Margin="12,0,3,0" Foreground="#DDE7F0"/><ComboBox Name="TransportOutputCombo" Width="150"><ComboBoxItem Content="PC-Audio"/><ComboBoxItem Content="MIDI"/><ComboBoxItem Content="PC-Audio + MIDI"/></ComboBox>
                                    <TextBlock Text="MIDI OUT" VerticalAlignment="Center" Margin="12,0,3,0" Foreground="#DDE7F0"/><ComboBox Name="MidiOutputCombo" Width="190"/><Button Name="MidiRefreshButton" Content="REFRESH" ToolTip="MIDI-Ausgänge neu einlesen"/>
                                    <CheckBox Name="MidiClockCheck" Content="MIDI Clock / Start / Stop" VerticalAlignment="Center" Foreground="#17212B" Background="#F5F7FA" Padding="7,4" Margin="6,2"/>
                                    <TextBlock Name="TransportStatusText" Text="STOP" VerticalAlignment="Center" Margin="12,0" Foreground="#87C58B" FontWeight="Bold"/>
                                    <Button Name="PatternAllOnButton" Content="Alle Steps an"/><Button Name="PatternAllOffButton" Content="Alle Steps aus"/><Button Name="PatternClearTrackButton" Content="Spur initialisieren"/>
                                    <Button Name="PatternCopyTrackButton" Content="Spur kopieren"/><Button Name="PatternPasteTrackButton" Content="Spur einfügen"/><Button Name="PatternCopyPatternButton" Content="Pattern kopieren"/><Button Name="PatternPastePatternButton" Content="Pattern einfügen"/>
                                </WrapPanel>
                                <Grid Grid.Row="3"><Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <DataGrid Name="PatternStepGrid" IsReadOnly="False" SelectionMode="Single" SelectionUnit="FullRow"><DataGrid.Columns>
                                        <DataGridTextColumn Header="Step" Binding="{Binding Step}" IsReadOnly="True" Width="55"/>
                                        <DataGridCheckBoxColumn Header="Aktiv" Binding="{Binding Active, UpdateSourceTrigger=PropertyChanged}" Width="60"/>
                                        <DataGridTextColumn Header="MIDI Note" Binding="{Binding Note, UpdateSourceTrigger=LostFocus}" Width="90"/>
                                        <DataGridTextColumn Header="Notenname" Binding="{Binding NoteText}" IsReadOnly="True" Width="90"/>
                                        <DataGridTextColumn Header="Velocity" Binding="{Binding Velocity, UpdateSourceTrigger=LostFocus}" Width="80"/>
                                        <DataGridTextColumn Header="Gate %" Binding="{Binding Gate, UpdateSourceTrigger=LostFocus}" Width="75"/>
                                        <DataGridTextColumn Header="Innerhalb Spurlänge" Binding="{Binding InLength}" IsReadOnly="True" Width="*"/>
                                    </DataGrid.Columns></DataGrid>
                                    <DataGrid Name="PatternSummaryGrid" Grid.Column="2" IsReadOnly="True"><DataGrid.Columns><DataGridTextColumn Header="Pattern" Binding="{Binding Pattern}" Width="70"/><DataGridTextColumn Header="Spur" Binding="{Binding Track}" Width="55"/><DataGridTextColumn Header="Länge" Binding="{Binding Length}" Width="65"/><DataGridTextColumn Header="Aktive Steps" Binding="{Binding ActiveSteps}" Width="*"/></DataGrid.Columns></DataGrid>
                                </Grid>
                                <DockPanel Grid.Row="4" Margin="0,10,0,0"><TextBlock Name="PatternValidationText" Foreground="#9EB0C3" VerticalAlignment="Center"/><WrapPanel DockPanel.Dock="Right"><Button Name="PatternReloadButton" Content="Zurücksetzen"/><Button Name="PatternSaveButton" Content="PATTERNS.CFG speichern" IsEnabled="False"/></WrapPanel></DockPanel>
                            </Grid>
                        </TabItem>
                        <TabItem Name="SongTab" Header="Song">
                            <Grid Margin="10">
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <DockPanel Grid.Row="0" Margin="3,2,3,8"><TextBlock Name="SongStatusText" Foreground="#9EB0C3"/><TextBlock Name="SongDirtyText" DockPanel.Dock="Right" Foreground="#F0B35A" FontWeight="Bold"/></DockPanel>
                                <WrapPanel Grid.Row="1" Margin="0,0,0,8">
                                    <StackPanel Margin="3"><TextBlock Text="LOOP-MODUS" Foreground="#DDE7F0"/><ComboBox Name="SongLoopModeCombo" Width="125"><ComboBoxItem Content="OFF"/><ComboBoxItem Content="SONG"/><ComboBoxItem Content="PATTERN"/></ComboBox></StackPanel>
                                    <StackPanel Margin="3"><TextBlock Text="LOOP START" Foreground="#DDE7F0"/><ComboBox Name="SongLoopStartCombo" Width="100"/></StackPanel>
                                    <StackPanel Margin="3"><TextBlock Text="LOOP END" Foreground="#DDE7F0"/><ComboBox Name="SongLoopEndCombo" Width="100"/></StackPanel>
                                    <StackPanel Margin="18,3,3,3"><TextBlock Text="POSITIONEN" Foreground="#DDE7F0"/><WrapPanel><Button Name="SongInsertButton" Content="Einfügen"/><Button Name="SongDeleteButton" Content="Löschen"/><Button Name="SongMoveUpButton" Content="Nach oben"/><Button Name="SongMoveDownButton" Content="Nach unten"/></WrapPanel></StackPanel>
                                    <StackPanel Margin="18,3,3,3"><TextBlock Text="TRANSPORT" Foreground="#DDE7F0"/><WrapPanel><Button Name="SongPlayButton" Content="PLAY SONG"/><Button Name="SongStopButton" Content="STOP"/></WrapPanel></StackPanel>
                                    <StackPanel Margin="18,3,3,3"><TextBlock Text="SONG" Foreground="#DDE7F0"/><Button Name="SongInitializeButton" Content="Initialisieren"/></StackPanel>
                                </WrapPanel>
                                <TextBlock Name="SongDurationText" Grid.Row="2" Foreground="#DDE7F0" Margin="3,0,3,8" FontWeight="SemiBold"/>
                                <DataGrid Name="SongGrid" Grid.Row="3" IsReadOnly="False" SelectionMode="Single" SelectionUnit="FullRow">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Position" Binding="{Binding Position}" IsReadOnly="True" Width="90"/>
                                        <DataGridTextColumn Header="Pattern (P1-P4/END)" Binding="{Binding Pattern, UpdateSourceTrigger=LostFocus}" Width="180"/>
                                        <DataGridTextColumn Header="Wiederholungen 1-16" Binding="{Binding Repeats, UpdateSourceTrigger=LostFocus}" Width="180"/>
                                        <DataGridCheckBoxColumn Header="END" Binding="{Binding End, UpdateSourceTrigger=PropertyChanged}" Width="90"/>
                                        <DataGridTextColumn Header="Hinweis" Binding="{Binding SongHint}" IsReadOnly="True" Width="*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                                <DockPanel Grid.Row="4" Margin="0,10,0,0"><TextBlock Name="SongValidationText" Foreground="#9EB0C3" VerticalAlignment="Center"/><WrapPanel DockPanel.Dock="Right"><Button Name="SongReloadButton" Content="Zurücksetzen"/><Button Name="SongSaveButton" Content="SONG.CFG speichern" IsEnabled="False"/></WrapPanel></DockPanel>
                            </Grid>
                        </TabItem>
                        <TabItem Name="EffectsTab" Header="Echo / Reverb &amp; Effekte">
                            <Grid Margin="10"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <DockPanel Margin="0,0,0,8"><TextBlock Text="GLOBAL ECHO / REVERB" FontSize="16" FontWeight="Bold"/><TextBlock Name="EffectsDirtyText" DockPanel.Dock="Right" Foreground="#F0A060" FontWeight="Bold"/></DockPanel>
                                <Border Grid.Row="1" Background="#19222D" BorderBrush="#45576A" BorderThickness="1" Padding="10" Margin="0,0,0,10"><WrapPanel>
                                    <StackPanel Margin="5"><TextBlock Text="ECHO TIME (50-2000 ms)"/><TextBox Name="EchoDelayBox" Width="120"/></StackPanel><StackPanel Margin="5"><TextBlock Text="FEEDBACK (0-90 %)"/><TextBox Name="EchoFeedbackBox" Width="120"/></StackPanel><StackPanel Margin="5"><TextBlock Text="MIX (0-100 %)"/><TextBox Name="EchoMixBox" Width="120"/></StackPanel><StackPanel Margin="5"><TextBlock Text="REVERB SIZE (0-100 %)"/><TextBox Name="ReverbSizeBox" Width="90"/></StackPanel><StackPanel Margin="5"><TextBlock Text="REV DECAY (0-100 %)"/><TextBox Name="ReverbDecayBox" Width="80"/></StackPanel><StackPanel Margin="5"><TextBlock Text="REV DAMP (0-100 %)"/><TextBox Name="ReverbDampBox" Width="80"/></StackPanel><StackPanel Margin="5"><TextBlock Text="REV MIX (0-100 %)"/><TextBox Name="ReverbMixBox" Width="80"/></StackPanel>
                                </WrapPanel></Border>
                                <Border Grid.Row="2" Background="#19222D" BorderBrush="#45576A" BorderThickness="1" Padding="8" Margin="0,0,0,10"><WrapPanel VerticalAlignment="Center"><CheckBox Name="EffectsPreviewCheck" Content="B: Effekte" IsChecked="True" VerticalAlignment="Center" ToolTip="Aus = A: Original, Ein = B: Effekte"/><CheckBox Name="EffectsFilterCheck" Content="Filter" IsChecked="True" VerticalAlignment="Center"/><CheckBox Name="EffectsVintageCheck" Content="Vintage" IsChecked="True" VerticalAlignment="Center"/><CheckBox Name="EffectsEchoCheck" Content="Echo" IsChecked="True" VerticalAlignment="Center"/><TextBlock Text="VORSCHAU SLOT" Margin="14,0,4,0" VerticalAlignment="Center"/><ComboBox Name="EffectsPreviewSlotCombo" Width="72" SelectedIndex="0"><ComboBoxItem Content="S1"/><ComboBoxItem Content="S2"/><ComboBoxItem Content="S3"/><ComboBoxItem Content="S4"/></ComboBox><TextBlock Text="TONHÖHE" Margin="14,0,4,0" VerticalAlignment="Center"/><ComboBox Name="EffectsPitchModeCombo" Width="175" SelectedIndex="0"><ComboBoxItem Content="Originaltonhöhe"/><ComboBoxItem Content="Step-Note verwenden"/></ComboBox><TextBlock Text="DAUER" Margin="14,0,4,0" VerticalAlignment="Center"/><ComboBox Name="EffectsDurationModeCombo" Width="185" SelectedIndex="0"><ComboBoxItem Content="Sample vollständig"/><ComboBoxItem Content="Step-Gate verwenden"/></ComboBox><Button Name="EffectsPlaySlotButton" Content="PLAY SLOT"/><Button Name="EffectsPlayPatternButton" Content="PLAY PATTERN"/><Button Name="EffectsStopButton" Content="STOP"/></WrapPanel></Border>
                                <DataGrid Name="EffectsGrid" Grid.Row="3" IsReadOnly="False"><DataGrid.Columns><DataGridTextColumn Header="Slot" Binding="{Binding Slot}" IsReadOnly="True" Width="55"/><DataGridTextColumn Header="Echo Send" Binding="{Binding EchoSend}" Width="85"/><DataGridTextColumn Header="Reverb Send" Binding="{Binding ReverbSend}" Width="90"/><DataGridTextColumn Header="Cutoff 0..100" Binding="{Binding FilterCutoff}" Width="70"/><DataGridTextColumn Header="Resonance" Binding="{Binding Resonance}" Width="85"/><DataGridTextColumn Header="Filter Env" Binding="{Binding FilterEnv}" Width="80"/><DataGridTextColumn Header="Velocity" Binding="{Binding FilterVelocity}" Width="70"/><DataGridTextColumn Header="Keytrack" Binding="{Binding FilterKeytrack}" Width="70"/><DataGridTextColumn Header="Vintage Preset" Binding="{Binding VintagePreset}" Width="95"/><DataGridTextColumn Header="Rate" Binding="{Binding VintageRate}" Width="65"/><DataGridTextColumn Header="Bits" Binding="{Binding VintageBits}" Width="55"/><DataGridTextColumn Header="Filter" Binding="{Binding VintageFilter}" Width="60"/><DataGridTextColumn Header="Jitter" Binding="{Binding VintageJitter}" Width="*"/></DataGrid.Columns></DataGrid>
                                <Grid Grid.Row="4" Margin="0,10,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Name="EffectsValidationText" Foreground="#87C58B" TextWrapping="Wrap"/><TextBlock Text="Vorschau: Filter, Echo und Vintage werden offline angenähert. Reverb-Parameter und Reverb-Sends werden BANK16-kompatibel gelesen/geschrieben; der Phoenix-v1.1.0-Reverb wird in der PC-Vorschau bewusst nicht emuliert. A = Original, B = Effekte." Foreground="#9EB0C3"/></StackPanel><WrapPanel Grid.Column="1"><Button Name="EffectsCopyButton" Content="Slot kopieren"/><Button Name="EffectsPasteButton" Content="Einfügen"/><Button Name="EffectsResetButton" Content="Slot zurücksetzen"/><Button Name="EffectsReloadButton" Content="Zurücksetzen"/><Button Name="EffectsSaveButton" Content="Effekte speichern" IsEnabled="False"/></WrapPanel></Grid>
                            </Grid>
                        </TabItem>
                        <TabItem Name="InitSoundTab" Header="INIT SOUND TEMPLATE">
                            <Grid Margin="10">
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <DockPanel Margin="0,0,0,8"><StackPanel><TextBlock Text="INIT SOUND TEMPLATE - /PHOENIX/INIT_SOUND.CFG" FontSize="16" FontWeight="Bold"/><TextBlock Name="InitSoundPathText" Foreground="#9EB0C3"/></StackPanel><TextBlock Name="InitSoundDirtyText" DockPanel.Dock="Right" Foreground="#F0A060" FontWeight="Bold"/></DockPanel>
                                <Border Grid.Row="1" Background="#19222D" BorderBrush="#45576A" BorderThickness="1" Padding="8" Margin="0,0,0,8"><WrapPanel>
                                    <StackPanel Margin="4"><TextBlock Text="QUATTRO MODE 0/1"/><TextBox Name="InitQuattroModeBox" Width="75"/></StackPanel>
                                    <StackPanel Margin="4"><TextBlock Text="ECHO TIME 50..2000"/><TextBox Name="InitEchoDelayBox" Width="75"/></StackPanel>
                                    <StackPanel Margin="4"><TextBlock Text="ECHO FB 0..90"/><TextBox Name="InitEchoFeedbackBox" Width="65"/></StackPanel>
                                    <StackPanel Margin="4"><TextBlock Text="ECHO MIX"/><TextBox Name="InitEchoMixBox" Width="65"/></StackPanel><StackPanel Margin="4"><TextBlock Text="REV SIZE"/><TextBox Name="InitReverbSizeBox" Width="65"/></StackPanel><StackPanel Margin="4"><TextBlock Text="REV DECAY"/><TextBox Name="InitReverbDecayBox" Width="65"/></StackPanel><StackPanel Margin="4"><TextBlock Text="REV DAMP"/><TextBox Name="InitReverbDampBox" Width="65"/></StackPanel><StackPanel Margin="4"><TextBlock Text="REV MIX"/><TextBox Name="InitReverbMixBox" Width="65"/></StackPanel>
                                </WrapPanel></Border>
                                <TextBlock Grid.Row="2" Text="NEW BANK remains sample-empty. This template contains sound/mapping parameters only and never WAV/sample paths." Foreground="#9EB0C3" Margin="2,0,2,7"/>
                                <DataGrid Name="InitSoundGrid" Grid.Row="3" IsReadOnly="False" FrozenColumnCount="1"><DataGrid.Columns>
                                    <DataGridTextColumn Header="Slot" Binding="{Binding Slot}" IsReadOnly="True" Width="48"/><DataGridCheckBoxColumn Header="MS" Binding="{Binding Multisample}" Width="45"/><DataGridTextColumn Header="Low 0..127" Binding="{Binding Low}" Width="48"/><DataGridTextColumn Header="High 0..127" Binding="{Binding High}" Width="48"/><DataGridTextColumn Header="Root" Binding="{Binding Root}" Width="48"/>
                                    <DataGridTextColumn Header="Coarse -24..24" Binding="{Binding Coarse}" Width="58"/><DataGridTextColumn Header="Fine -100..100" Binding="{Binding Fine}" Width="52"/><DataGridTextColumn Header="RootNote 0..127" Binding="{Binding RootNote}" Width="65"/><DataGridTextColumn Header="Oct" Binding="{Binding Octave}" Width="45"/><DataGridCheckBoxColumn Header="Track" Binding="{Binding PitchTrack}" Width="50"/><DataGridTextColumn Header="Bend 0..24" Binding="{Binding Bend}" Width="48"/>
                                    <DataGridTextColumn Header="A" Binding="{Binding Attack}" Width="55"/><DataGridTextColumn Header="D" Binding="{Binding Decay}" Width="55"/><DataGridTextColumn Header="S" Binding="{Binding Sustain}" Width="50"/><DataGridTextColumn Header="R" Binding="{Binding Release}" Width="55"/><DataGridTextColumn Header="Level 0..100" Binding="{Binding Level}" Width="52"/><DataGridTextColumn Header="Pan -100..100" Binding="{Binding Pan}" Width="52"/><DataGridTextColumn Header="Gain 0..200" Binding="{Binding SampleGain}" Width="52"/><DataGridTextColumn Header="Vel 0..100" Binding="{Binding Velocity}" Width="48"/>
                                    <DataGridTextColumn Header="Cutoff" Binding="{Binding Cutoff}" Width="58"/><DataGridTextColumn Header="Res 0..100" Binding="{Binding Resonance}" Width="48"/><DataGridTextColumn Header="FEnv -100..100" Binding="{Binding FilterEnv}" Width="55"/><DataGridTextColumn Header="FVel 0..100" Binding="{Binding FilterVelocity}" Width="52"/><DataGridTextColumn Header="Keytrk 0..100" Binding="{Binding Keytrack}" Width="55"/>
                                    <DataGridTextColumn Header="Vtg" Binding="{Binding VintagePreset}" Width="48"/><DataGridTextColumn Header="V Lim" Binding="{Binding VoiceLimit}" Width="52"/><DataGridTextColumn Header="Glide" Binding="{Binding Glide}" Width="55"/><DataGridTextColumn Header="Echo" Binding="{Binding EchoSend}" Width="52"/><DataGridTextColumn Header="Reverb" Binding="{Binding ReverbSend}" Width="58"/><DataGridTextColumn Header="QLow 0..127" Binding="{Binding QuattroLow}" Width="55"/><DataGridTextColumn Header="QHigh 0..127" Binding="{Binding QuattroHigh}" Width="58"/><DataGridTextColumn Header="MIDI" Binding="{Binding MidiChannel}" Width="50"/>
                                </DataGrid.Columns></DataGrid>
                                <Grid Grid.Row="4" Margin="0,8,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Name="InitSoundValidationText" Foreground="#87C58B" TextWrapping="Wrap"/><WrapPanel Grid.Column="1"><Button Name="InitSoundLoadButton" Content="Load INIT_SOUND.CFG"/><Button Name="InitSoundFactoryButton" Content="Restore Factory Defaults"/><Button Name="InitSoundSaveButton" Content="Save INIT_SOUND.CFG" IsEnabled="False"/></WrapPanel></Grid>
                            </Grid>
                        </TabItem>
                        <TabItem Name="MidiKeyboardTab" Header="MIDI &amp; Tastatur">
                            <Grid Margin="10"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                                <Border Background="#19222D" BorderBrush="#45576A" BorderThickness="1" Padding="10"><WrapPanel VerticalAlignment="Center">
                                    <TextBlock Text="MIDI INPUT" VerticalAlignment="Center" Margin="3"/><ComboBox Name="MidiInputCombo" Width="230" Margin="3"/><Button Name="MidiInputRefreshButton" Content="REFRESH"/><CheckBox Name="MidiInputActiveCheck" Content="Aktiv" VerticalAlignment="Center" Margin="10,2"/>
                                    <TextBlock Text="KANAL" VerticalAlignment="Center" Margin="12,3,3,3"/><ComboBox Name="MidiInputChannelCombo" Width="100" Margin="3"><ComboBoxItem Content="OMNI"/></ComboBox>
                                    <TextBlock Text="AUSGABE" VerticalAlignment="Center" Margin="12,3,3,3"/><ComboBox Name="LiveOutputCombo" Width="160" Margin="3"><ComboBoxItem Content="PC-Audio"/><ComboBoxItem Content="MIDI"/><ComboBoxItem Content="PC-Audio + MIDI"/></ComboBox>
                                    <TextBlock Name="MidiInputStatusText" Text="MIDI IN: AUS" Foreground="#9EB0C3" FontWeight="Bold" Margin="14,3" VerticalAlignment="Center"/>
                                </WrapPanel></Border>
                                <Border Grid.Row="1" Background="#F5F7FA" BorderBrush="#C5CED8" BorderThickness="1" Padding="8" Margin="0,10,0,10"><TextBlock Name="MidiMonitorText" Text="Noch keine MIDI-Daten empfangen." Foreground="#17212B" FontFamily="Consolas"/></Border>
                                <Border Grid.Row="2" Background="#F5F7FA" BorderBrush="#C5CED8" BorderThickness="1" Padding="8" Margin="0,0,0,8">
                                    <StackPanel>
                                        <WrapPanel VerticalAlignment="Center">
                                            <StackPanel Margin="4,0,10,0">
                                                <TextBlock Text="VELOCITY" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/>
                                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center"><Slider Name="KeyboardVelocitySlider" Minimum="1" Maximum="127" Value="127" Width="160" Margin="0,0,6,0"/><TextBlock Name="KeyboardVelocityText" Text="127" Foreground="#17212B" Width="38" VerticalAlignment="Center" FontWeight="SemiBold"/></StackPanel>
                                            </StackPanel>
                                            <StackPanel Margin="4,0,10,0">
                                                <TextBlock Text="OKTAVE" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/>
                                                <StackPanel Orientation="Horizontal"><Button Name="KeyboardOctaveDownButton" Content="-" ToolTip="Bildschirmtastatur eine Oktave tiefer"/><TextBlock Name="KeyboardOctaveText" Text="0" Foreground="#17212B" Width="35" TextAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/><Button Name="KeyboardOctaveUpButton" Content="+" ToolTip="Bildschirmtastatur eine Oktave höher"/></StackPanel>
                                            </StackPanel>
                                            <StackPanel Margin="4,0,10,0">
                                                <TextBlock Text="WIEDERGABE" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/>
                                                <ComboBox Name="LivePlaybackModeCombo" Width="125" SelectedIndex="0"><ComboBoxItem Content="NOTE HOLD"/><ComboBoxItem Content="ONE SHOT"/></ComboBox>
                                            </StackPanel>
                                            <StackPanel Margin="4,0,10,0">
                                                <TextBlock Text="LOOP" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/>
                                                <CheckBox Name="LiveLoopCheck" Content="Phoenix Loop" IsChecked="True" Foreground="#17212B" VerticalAlignment="Center" Margin="3,5" ToolTip="Verwendet Loop-Modus, Loop-Punkte und Crossfade aus BANK.CFG."/>
                                            </StackPanel>
                                            <StackPanel Margin="4,0,10,0">
                                                <TextBlock Text="SUSTAIN" Foreground="#17212B" FontWeight="SemiBold" Margin="2,0,2,3"/>
                                                <CheckBox Name="KeyboardSustainCheck" Content="Halten" Foreground="#17212B" VerticalAlignment="Center" Margin="3,5" ToolTip="Sustain für die Bildschirmtastatur (entspricht MIDI CC64)."/>
                                            </StackPanel>
                                            <StackPanel Margin="8,0,4,0" VerticalAlignment="Bottom"><Button Name="KeyboardPanicButton" Content="PANIC" ToolTip="Alle aktiven Vorschau- und MIDI-Noten sofort beenden"/></StackPanel>
                                        </WrapPanel>
                                        <WrapPanel Margin="4,7,0,0">
                                            <TextBlock Name="SustainStatusText" Text="Sustain: AUS" Foreground="#17212B" Margin="0,0,18,0" VerticalAlignment="Center"/>
                                            <TextBlock Name="PitchBendText" Text="Pitch Bend: 0,00 st" Foreground="#17212B" Margin="0,0,18,0" VerticalAlignment="Center"/>
                                            <TextBlock Name="ActiveVoicesText" Text="Stimmen aktiv: 0 / 16" Foreground="#17212B" VerticalAlignment="Center" FontWeight="Bold"/>
                                        </WrapPanel>
                                    </StackPanel>
                                </Border>
                                <ScrollViewer Grid.Row="3" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto"><WrapPanel Name="KeyboardPanel"/></ScrollViewer>
                            </Grid>
                        </TabItem>
                        <TabItem Header="Marker &amp; Parameter">
                            <DataGrid Name="MarkerGrid" Margin="4" AlternationCount="2">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Slot" Binding="{Binding Slot}" Width="50"/><DataGridTextColumn Header="S.START" Binding="{Binding SampleStart}" Width="90"/>
                                    <DataGridTextColumn Header="L.START" Binding="{Binding LoopStart}" Width="90"/><DataGridTextColumn Header="L.END" Binding="{Binding LoopEnd}" Width="90"/>
                                    <DataGridTextColumn Header="S.END" Binding="{Binding SampleEnd}" Width="90"/><DataGridTextColumn Header="Frames" Binding="{Binding Frames}" Width="90"/>
                                    <DataGridTextColumn Header="Rate" Binding="{Binding SampleRate}" Width="70"/><DataGridTextColumn Header="Key Range" Binding="{Binding KeyRange}" Width="120"/><DataGridTextColumn Header="Level" Binding="{Binding Level}" Width="55"/>
                                    <DataGridTextColumn Header="Pan" Binding="{Binding Pan}" Width="50"/><DataGridTextColumn Header="Voices" Binding="{Binding Voices}" Width="55"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </TabItem>
                        <TabItem Header="Prüfung">
                            <Border Margin="4" Padding="8" Background="#F5F7FA" BorderBrush="#C5CED8" BorderThickness="1">
                                <ListBox Name="IssueList" Background="Transparent" BorderThickness="0" Foreground="#17212B" HorizontalContentAlignment="Stretch" ScrollViewer.HorizontalScrollBarVisibility="Auto">
                                    <ListBox.ItemTemplate><DataTemplate><TextBlock Text="{Binding}" Foreground="#17212B" TextWrapping="NoWrap" Margin="2,3"/></DataTemplate></ListBox.ItemTemplate>
                                </ListBox>
                            </Border>
                        </TabItem>
                        <TabItem Header="BANK.CFG"><TextBox Name="RawConfigBox" Margin="4" Padding="8" FontFamily="Consolas" FontSize="12" IsReadOnly="True" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/></TabItem>
                        <TabItem Name="BackupRestoreTab" Header="Backup &amp; Restore">
                            <Grid Margin="10">
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <TextBlock Text="BACKUP-ORDNER" Foreground="#DDE7F0" FontWeight="Bold" VerticalAlignment="Center" Margin="3"/>
                                    <TextBox Name="BackupPathBox" Grid.Column="1" Margin="3" IsReadOnly="True"/>
                                    <Button Name="BackupChoosePathButton" Grid.Column="2" Content="Ordner wählen ..."/>
                                    <Button Name="BackupRefreshButton" Grid.Column="3" Content="Neu einlesen"/>
                                </Grid>
                                <Grid Grid.Row="1" Margin="0,8,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <TextBlock Text="KOMMENTAR" Foreground="#DDE7F0" FontWeight="Bold" VerticalAlignment="Center" Margin="3"/>
                                    <TextBox Name="BackupCommentBox" Grid.Column="1" Margin="3" ToolTip="Optionaler Kommentar für neu angelegte Backups"/>
                                    <Button Name="BackupCurrentBankButton" Grid.Column="2" Content="Aktuelle Bank sichern"/>
                                    <Button Name="BackupFullButton" Grid.Column="3" Content="Phoenix komplett sichern"/>
                                </Grid>
                                <DataGrid Name="BackupGrid" Grid.Row="2" IsReadOnly="True" AlternationCount="2">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Backup" Binding="{Binding Name}" Width="220"/><DataGridTextColumn Header="Typ" Binding="{Binding Type}" Width="70"/><DataGridTextColumn Header="Bank" Binding="{Binding Bank}" Width="75"/><DataGridTextColumn Header="Erstellt" Binding="{Binding Created}" Width="145"/><DataGridTextColumn Header="Kommentar" Binding="{Binding Comment}" Width="*"/><DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="130"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                                <DockPanel Grid.Row="3" Margin="0,9,0,0">
                                    <TextBlock Name="BackupStatusText" Text="Noch keine Backups eingelesen" Foreground="#9EB0C3" VerticalAlignment="Center"/>
                                    <WrapPanel DockPanel.Dock="Right"><Button Name="BackupCompareButton" Content="Vergleichen"/><Button Name="BackupOpenButton" Content="Ordner öffnen"/><Button Name="BackupRestoreBankButton" Content="Bank wiederherstellen"/><Button Name="BackupRestoreFullButton" Content="Komplett wiederherstellen"/></WrapPanel>
                                </DockPanel>
                            </Grid>
                        </TabItem>
                        <TabItem Name="SystemStatusTab" Header="Systemstatus &amp; Self Test">
                            <Grid Margin="12">
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                                <Border Background="#19222D" BorderBrush="#45576A" BorderThickness="1" Padding="12" CornerRadius="3">
                                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <StackPanel><TextBlock Text="SYSTEMSTATUS" FontSize="16" FontWeight="Bold"/><TextBlock Name="SystemStatusText" Margin="0,8,0,0" Foreground="#DDE7F0" FontFamily="Consolas" TextWrapping="Wrap"/></StackPanel>
                                        <StackPanel Grid.Column="1" Margin="16,0,0,0"><Button Name="SelfTestButton" Content="Self Test starten" MinWidth="150"/><Button Name="RefreshSystemStatusButton" Content="Status aktualisieren" MinWidth="150"/><Button Name="CopySelfTestButton" Content="Testbericht kopieren" MinWidth="150"/></StackPanel>
                                    </Grid>
                                </Border>
                                <DockPanel Grid.Row="1" Margin="0,10,0,6"><TextBlock Name="SelfTestLastRunText" Foreground="#9EB0C3"/><TextBlock Name="SelfTestSummaryText" DockPanel.Dock="Right" FontWeight="Bold" Foreground="#9EB0C3"/></DockPanel>
                                <TextBox Name="SelfTestResultsBox" Grid.Row="2" Background="#0C1117" Foreground="#E8EDF2" BorderBrush="#45576A" FontFamily="Consolas" FontSize="12" Padding="10" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
                            </Grid>
                        </TabItem>
                        <TabItem Header="Protokoll"><TextBox Name="LogBox" Margin="4" Padding="8" FontFamily="Consolas" FontSize="12" IsReadOnly="True" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/></TabItem>
                    </TabControl>
                </Grid>
            </Border>
        </Grid>

        <DockPanel Grid.Row="3" Margin="0,10,0,0" LastChildFill="True">
            <TextBlock DockPanel.Dock="Right" Text="RealTimeAudioLab - Phoenix" Foreground="#6F849A" Margin="18,0,0,0"/>
            <TextBlock Name="StatusText" Text="" Foreground="#9EB0C3" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
    </Grid>
</Window>
'@

[xml]$xamlDocument = $xaml
$reader = New-Object System.Xml.XmlNodeReader($xamlDocument)
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

$names = @(
    'VersionText','AccessModeBorder','AccessModeText','PathBox','StatusText','BankGrid','SlotGrid','MarkerGrid','IssueList','RawConfigBox','LogBox',
    'BankTitle','BankSummary','AutoDetectButton','BrowseButton','RefreshButton','ReportButton','MainTabs','BankFilterBox','CategoryFilterCombo','RoutingFilterCombo','StatusFilterCombo','ClearFiltersButton','FactoryExportButton',
    'BackupAllButton','OpenFolderButton','ImportFourWavsButton','BackupBankButton','NewBankButton','ImportBankButton','ExportZipButton','CopyBankButton','MoveBankButton','DeleteBankButton',
    'BackupRestoreTab','BackupPathBox','BackupChoosePathButton','BackupRefreshButton','BackupCommentBox','BackupCurrentBankButton','BackupFullButton','BackupGrid','BackupStatusText','BackupCompareButton','BackupOpenButton','BackupRestoreBankButton','BackupRestoreFullButton',
    'SystemStatusTab','SystemStatusText','SelfTestButton','RefreshSystemStatusButton','CopySelfTestButton','SelfTestLastRunText','SelfTestSummaryText','SelfTestResultsBox',
    'WaveformCanvas','WaveformInfo','OpenWavButton','WaveformEditorTab','EditorControlsPanel','EditorStatusText','EditorSlotText',
    'SStartBox','LStartBox','LEndBox','SEndBox','MarkerSelectCombo','SnapButton','NudgeMinus100Button','NudgeMinus10Button','NudgeMinus1Button','NudgePlus1Button','NudgePlus10Button','NudgePlus100Button','LinkLoopCheck','SelectLoopButton','LoopStatsText',
    'LoopModeCombo','XFadeCombo','KeyLowCombo','RootCombo','KeyHighCombo','LevelBox','PanCombo','VoicesBox','TrimCheck','DCCheck','NormCheck',
    'KeyRangeTab','QuattroModeCombo','KeyRangeDescription','KeyzonePanel','MultiPanel','KeyRangeCanvas','EqualZonesButton','DrumMapButton','FullRangeButton','DefaultChannelsButton','SaveKeyRangesButton',
    'S1LowCombo','S1RootCombo','S1HighCombo','S1RangeText','S1ChannelCombo','S1MultiRootCombo','S1MultiText','S2LowCombo','S2RootCombo','S2HighCombo','S2RangeText','S2ChannelCombo','S2MultiRootCombo','S2MultiText','S3LowCombo','S3RootCombo','S3HighCombo','S3RangeText','S3ChannelCombo','S3MultiRootCombo','S3MultiText','S4LowCombo','S4RootCombo','S4HighCombo','S4RangeText','S4ChannelCombo','S4MultiRootCombo','S4MultiText',
    'SequencerTab','PatternStatusText','PatternDirtyText','PatternSelectCombo','PatternTrackCombo','PatternLengthCombo','PatternBpmBox','PatternClockCombo','PatternPlayButton','PatternRepeatCheck','TransportStopButton','MidiPanicButton','TransportOutputCombo','MidiOutputCombo','MidiRefreshButton','MidiClockCheck','TransportStatusText','PatternStepGrid','PatternSummaryGrid','PatternValidationText','PatternAllOnButton','PatternAllOffButton','PatternClearTrackButton','PatternCopyTrackButton','PatternPasteTrackButton','PatternCopyPatternButton','PatternPastePatternButton','PatternReloadButton','PatternSaveButton','SongTab','SongStatusText','SongDirtyText','SongPlayButton','SongStopButton','SongGrid','SongLoopModeCombo','SongLoopStartCombo','SongLoopEndCombo','SongInsertButton','SongDeleteButton','SongMoveUpButton','SongMoveDownButton','SongInitializeButton','SongDurationText','SongValidationText','SongReloadButton','SongSaveButton','EffectsTab','EchoDelayBox','EchoFeedbackBox','EchoMixBox','ReverbSizeBox','ReverbDecayBox','ReverbDampBox','ReverbMixBox','EffectsPreviewCheck','EffectsFilterCheck','EffectsVintageCheck','EffectsEchoCheck','EffectsPreviewSlotCombo','EffectsPitchModeCombo','EffectsDurationModeCombo','EffectsPlaySlotButton','EffectsPlayPatternButton','EffectsStopButton','EffectsGrid','EffectsDirtyText','EffectsValidationText','EffectsCopyButton','EffectsPasteButton','EffectsResetButton','EffectsReloadButton','EffectsSaveButton','InitSoundTab','InitSoundPathText','InitSoundDirtyText','InitQuattroModeBox','InitEchoDelayBox','InitEchoFeedbackBox','InitEchoMixBox','InitReverbSizeBox','InitReverbDecayBox','InitReverbDampBox','InitReverbMixBox','InitSoundGrid','InitSoundValidationText','InitSoundLoadButton','InitSoundFactoryButton','InitSoundSaveButton','MidiKeyboardTab','MidiInputCombo','MidiInputRefreshButton','MidiInputActiveCheck','MidiInputChannelCombo','LiveOutputCombo','MidiInputStatusText','MidiMonitorText','KeyboardVelocitySlider','KeyboardVelocityText','LivePlaybackModeCombo','LiveLoopCheck','KeyboardSustainCheck','SustainStatusText','PitchBendText','ActiveVoicesText','KeyboardOctaveDownButton','KeyboardOctaveUpButton','KeyboardOctaveText','KeyboardPanicButton','KeyboardPanel',
    'PlayWavButton','PlayLoopButton','StopPreviewButton','ReloadEditorButton','BankNameBox','BankCategoryBox','BankAuthorBox','BankDescriptionBox','BankLicenseBox','BankTagsBox','BankTemplateText','Slot1NameBox','Slot2NameBox','Slot3NameBox','Slot4NameBox','SaveBankInfoButton','SaveEditorButton','ImportWavButton','CopySlotButton','MoveSlotButton','ClearSlotButton'
)
foreach ($name in $names) { Set-Variable -Scope Script -Name $name -Value $script:Window.FindName($name) }
$script:RootCombo.Items.Clear(); $script:KeyLowCombo.Items.Clear(); $script:KeyHighCombo.Items.Clear()
for ($note = 0; $note -le 127; $note++) {
    $label = Get-MidiNoteLabel $note
    [void]$script:RootCombo.Items.Add($label); [void]$script:KeyLowCombo.Items.Add($label); [void]$script:KeyHighCombo.Items.Add($label)
}
for ($slotNo=1; $slotNo -le 4; $slotNo++) {
    foreach ($part in @('Low','Root','High','MultiRoot')) {
        $combo = Get-Variable -Scope Script -Name ("S{0}{1}Combo" -f $slotNo,$part) -ValueOnly
        $combo.Items.Clear(); for ($note=0; $note -le 127; $note++) { [void]$combo.Items.Add((Get-MidiNoteLabel $note)) }
    }
    $channelCombo = Get-Variable -Scope Script -Name ("S{0}ChannelCombo" -f $slotNo) -ValueOnly
    $channelCombo.Items.Clear(); for ($ch=1; $ch -le 16; $ch++) { [void]$channelCombo.Items.Add(("Kanal {0}" -f $ch)) }
}
for($i=1;$i -le 16;$i++){[void]$script:PatternLengthCombo.Items.Add([string]$i);[void]$script:SongLoopStartCombo.Items.Add(('Position {0:D2}' -f $i));[void]$script:SongLoopEndCombo.Items.Add(('Position {0:D2}' -f $i))}
$script:PanCombo.Items.Clear()
for ($panValue = -100; $panValue -le 100; $panValue++) { [void]$script:PanCombo.Items.Add((Get-PanLabel $panValue)) }
for($ch=1;$ch-le16;$ch++){[void]$script:MidiInputChannelCombo.Items.Add(("Kanal {0}" -f $ch))}
$script:MidiInputChannelCombo.SelectedIndex=0;$script:LiveOutputCombo.SelectedIndex=0
Build-ScreenKeyboard
$script:MidiInputTimer.Add_Tick({Poll-MidiInput});$script:MidiInputTimer.Start()
$script:BackupRoot=Get-DefaultBackupRoot
Refresh-BackupCenter
$script:VersionText.Text = "Version $script:AppVersion"
Update-AccessModeIndicator

$script:RC5lLastDeadlineMissCount = 0L
$script:PreviewTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PreviewTimer.Interval = [TimeSpan]::FromMilliseconds(60)
$script:PreviewTimer.Add_Tick({ Update-PreviewPlayhead })
$script:PreviewRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PreviewRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$script:PreviewRefreshTimer.Add_Tick({
    $script:PreviewRefreshTimer.Stop()
    if($script:PreviewRefreshPending -and $script:MediaPlaying){$script:PreviewRefreshPending=$false;$m=$script:PreviewMode;Start-LoopPreview $m}
})

function Invoke-RC5eAdaptiveAudioRecovery {
    try {
        if(-not ('PhoenixWasapiLiveEngine' -as [type])){return}
        if(-not [PhoenixWasapiLiveEngine]::AdaptiveRecoveryPending){return}
        if([PhoenixWasapiLiveEngine]::ActiveVoices -gt 0){return}
        $result=[PhoenixWasapiLiveEngine]::ApplyAdaptiveSafetyIfIdle()
        if(-not [string]::IsNullOrWhiteSpace([string]$result)){
            Add-Log ('WASAPI RC5l Stable Guard: '+$result)
            Add-Log ('WASAPI RC5l Health nach Umschaltung: '+[PhoenixWasapiLiveEngine]::HealthDiagnostics)
        }
    } catch { Add-Log ('WASAPI RC5l Stable Guard Warnung: '+$_.Exception.Message) }
}

$script:SystemStatusTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SystemStatusTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:SystemStatusTimer.Add_Tick({
    if(-not $script:MediaPlaying){Update-SystemStatusView}
    # RC5l: while a preview is active the UI does NOT format or log audio diagnostics.
    # A single deferred summary is emitted by Stop-LoopPreview after the No-GC region ends.
})
$script:SystemStatusTimer.Start()

$script:AutoDetectButton.Add_Click({ Auto-Detect-Phoenix })
$script:BrowseButton.Add_Click({ Select-PhoenixFolder })
$script:RefreshButton.Add_Click({ Refresh-Banks; Apply-BankFilter })
$script:FactoryExportButton.Add_Click({ Export-FactoryLibrary })
$script:ReportButton.Add_Click({ Export-Report })
$script:BackupAllButton.Add_Click({ Backup-AllBanks })
$script:OpenFolderButton.Add_Click({ Open-SelectedBankFolder })
$script:BackupBankButton.Add_Click({ Backup-SelectedBank })
$script:BackupChoosePathButton.Add_Click({ Select-BackupRoot })
$script:BackupRefreshButton.Add_Click({ Refresh-BackupCenter })
$script:BackupCurrentBankButton.Add_Click({ New-CurrentBankBackup })
$script:BackupFullButton.Add_Click({ New-FullPhoenixBackup })
$script:BackupCompareButton.Add_Click({ Compare-SelectedBackup })
$script:BackupOpenButton.Add_Click({ Open-SelectedBackupFolder })
$script:BackupRestoreBankButton.Add_Click({ Restore-BankBackup })
$script:BackupRestoreFullButton.Add_Click({ Restore-FullBackup })
$script:SelfTestButton.Add_Click({ Invoke-PhoenixSelfTest })
$script:RefreshSystemStatusButton.Add_Click({ Update-SystemStatusView })
$script:CopySelfTestButton.Add_Click({ if($script:SelfTestResultsBox -and -not [string]::IsNullOrWhiteSpace($script:SelfTestResultsBox.Text)){[System.Windows.Clipboard]::SetText($script:SelfTestResultsBox.Text);$script:StatusText.Text='Self-Test-Bericht in Zwischenablage kopiert.'} })
$script:NewBankButton.Add_Click({ New-EmptyBank })
$script:ImportFourWavsButton.Add_Click({ Import-FourWavs })
$script:SaveBankInfoButton.Add_Click({ Save-CurrentBankInfo })
$script:ImportBankButton.Add_Click({ Import-Bank })
$script:ExportZipButton.Add_Click({ Export-SelectedBankZip })
$script:CopyBankButton.Add_Click({ Copy-Or-MoveSelectedBank $false })
$script:MoveBankButton.Add_Click({ Copy-Or-MoveSelectedBank $true })
$script:DeleteBankButton.Add_Click({ Delete-SelectedBank })
$script:OpenWavButton.Add_Click({ Open-SelectedWav })
$script:ImportWavButton.Add_Click({ Import-WavToCurrentSlot })
$script:CopySlotButton.Add_Click({ Copy-Or-MoveCurrentSlot $false })
$script:MoveSlotButton.Add_Click({ Copy-Or-MoveCurrentSlot $true })
$script:ClearSlotButton.Add_Click({ Clear-CurrentSlot })
$script:PlayWavButton.Add_Click({ Start-LoopPreview 'ONESHOT' })
$script:PlayLoopButton.Add_Click({ Start-LoopPreview 'HOLD' })
$script:StopPreviewButton.Add_Click({ Stop-LoopPreview })
$script:EffectsSaveButton.Add_Click({ Save-EffectsChanges })
$script:EffectsReloadButton.Add_Click({ Update-EffectsInspector })
$script:EffectsCopyButton.Add_Click({ Copy-EffectsSlot })
$script:EffectsPasteButton.Add_Click({ Paste-EffectsSlot })
$script:EffectsResetButton.Add_Click({ Reset-EffectsSlot })
foreach($c in @($script:EchoDelayBox,$script:EchoFeedbackBox,$script:EchoMixBox,$script:ReverbSizeBox,$script:ReverbDecayBox,$script:ReverbDampBox,$script:ReverbMixBox)){$c.Add_TextChanged({if(-not$script:EffectsSyncing){Set-EffectsDirty;[void](Update-EffectsValidation)}})}
$script:EffectsGrid.Add_CellEditEnding({if(-not$script:EffectsSyncing){$script:Window.Dispatcher.BeginInvoke([action]{Set-EffectsDirty;[void](Update-EffectsValidation)})|Out-Null}})
$script:InitSoundLoadButton.Add_Click({ Update-InitSoundEditor })
$script:InitSoundFactoryButton.Add_Click({ Restore-InitSoundFactory })
$script:InitSoundSaveButton.Add_Click({ Save-InitSoundTemplate })
foreach($c in @($script:InitQuattroModeBox,$script:InitEchoDelayBox,$script:InitEchoFeedbackBox,$script:InitEchoMixBox,$script:InitReverbSizeBox,$script:InitReverbDecayBox,$script:InitReverbDampBox,$script:InitReverbMixBox)){$c.Add_TextChanged({if(-not$script:InitSoundSyncing){Set-InitSoundDirty;[void](Update-InitSoundValidation)}})}
$script:InitSoundGrid.Add_CellEditEnding({if(-not$script:InitSoundSyncing){$script:Window.Dispatcher.BeginInvoke([action]{Set-InitSoundDirty;[void](Update-InitSoundValidation)})|Out-Null}})
$script:ReloadEditorButton.Add_Click({ Reload-EditorState })
$script:SaveEditorButton.Add_Click({ Save-EditorChanges })
$script:SnapButton.Add_Click({ Snap-SelectedMarker })
$script:NudgeMinus100Button.Add_Click({ Nudge-SelectedMarker -100 })
$script:NudgeMinus10Button.Add_Click({ Nudge-SelectedMarker -10 })
$script:NudgeMinus1Button.Add_Click({ Nudge-SelectedMarker -1 })
$script:NudgePlus1Button.Add_Click({ Nudge-SelectedMarker 1 })
$script:NudgePlus10Button.Add_Click({ Nudge-SelectedMarker 10 })
$script:NudgePlus100Button.Add_Click({ Nudge-SelectedMarker 100 })
$script:LinkLoopCheck.Add_Checked({ $script:LoopLinkEnabled = $true })
$script:LinkLoopCheck.Add_Unchecked({ $script:LoopLinkEnabled = $false })
$script:SelectLoopButton.Add_Click({ Select-LoopRegion })
$script:BankFilterBox.Add_TextChanged({ Apply-BankFilter })
$script:CategoryFilterCombo.Add_SelectionChanged({ Apply-BankFilter })
$script:RoutingFilterCombo.Add_SelectionChanged({ Apply-BankFilter })
$script:StatusFilterCombo.Add_SelectionChanged({ Apply-BankFilter })
$script:ClearFiltersButton.Add_Click({ $script:BankFilterBox.Text='';$script:CategoryFilterCombo.SelectedIndex=0;$script:RoutingFilterCombo.SelectedIndex=0;$script:StatusFilterCombo.SelectedIndex=0;Apply-BankFilter })
$script:BankGrid.Add_SelectionChanged({ Show-BankDetails $script:BankGrid.SelectedItem })
$script:SlotGrid.Add_SelectionChanged({ Update-WaveformSelection })
$script:WaveformCanvas.Add_SizeChanged({ if ($null -ne $script:CurrentSlot) { Draw-Waveform } })
# TabItem.Selected is a routed event and does not expose Add_Selected() in
# Windows PowerShell 5.1. Listen on the parent TabControl instead. The
# OriginalSource guard prevents SelectionChanged events from ComboBoxes and
# other selector controls inside the editor from triggering this handler.
$script:MainTabs.Add_SelectionChanged({ param($sender,$e)
    if ($e.OriginalSource -ne $sender) { return }
    if ($sender.SelectedItem -eq $script:WaveformEditorTab -and $null -ne $script:CurrentSlot) {
        $script:Window.Dispatcher.BeginInvoke([System.Action]{ Draw-Waveform },[System.Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
    } elseif ($sender.SelectedItem -eq $script:KeyRangeTab -and $null -ne $script:CurrentBank) {
        $script:Window.Dispatcher.BeginInvoke([System.Action]{ Sync-KeyRangeEditor },[System.Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
    }
})

$script:SStartBox.Add_GotFocus({ Set-EditorSelectedMarker 'S.START' })
$script:LStartBox.Add_GotFocus({ Set-EditorSelectedMarker 'L.START' })
$script:LEndBox.Add_GotFocus({ Set-EditorSelectedMarker 'L.END' })
$script:SEndBox.Add_GotFocus({ Set-EditorSelectedMarker 'S.END' })
$script:SStartBox.Add_LostFocus({ Update-MarkerFromTextBox 'S.START' $script:SStartBox })
$script:LStartBox.Add_LostFocus({ Update-MarkerFromTextBox 'L.START' $script:LStartBox })
$script:LEndBox.Add_LostFocus({ Update-MarkerFromTextBox 'L.END' $script:LEndBox })
$script:SEndBox.Add_LostFocus({ Update-MarkerFromTextBox 'S.END' $script:SEndBox })
$script:MarkerSelectCombo.Add_SelectionChanged({
    if (-not $script:EditorSyncing -and $null -ne $script:MarkerSelectCombo.SelectedItem) {
        Set-EditorSelectedMarker ([string]$script:MarkerSelectCombo.SelectedItem.Content)
    }
})
$script:LoopModeCombo.Add_SelectionChanged({ if (-not $script:EditorSyncing) { [void](Update-EditorParametersFromControls) } })
$script:XFadeCombo.Add_SelectionChanged({ if (-not $script:EditorSyncing) { [void](Update-EditorParametersFromControls) } })
$script:KeyLowCombo.Add_SelectionChanged({ if (-not $script:EditorSyncing) { [void](Update-EditorParametersFromControls) } })
$script:RootCombo.Add_SelectionChanged({ if (-not $script:EditorSyncing) { [void](Update-EditorParametersFromControls) } })
$script:KeyHighCombo.Add_SelectionChanged({ if (-not $script:EditorSyncing) { [void](Update-EditorParametersFromControls) } })
$script:PanCombo.Add_SelectionChanged({ if (-not $script:EditorSyncing) { [void](Update-EditorParametersFromControls) } })
$script:TrimCheck.Add_Click({ if (-not $script:EditorSyncing) { [void](Update-EditorParametersFromControls) } })
$script:DCCheck.Add_Click({ if (-not $script:EditorSyncing) { [void](Update-EditorParametersFromControls) } })
$script:NormCheck.Add_Click({ if (-not $script:EditorSyncing) { [void](Update-EditorParametersFromControls) } })
foreach ($box in @($script:LevelBox)) {
    $box.Add_LostFocus({ if (-not $script:EditorSyncing) { [void](Update-EditorParametersFromControls) } })
}

$script:WaveformCanvas.Add_MouseLeftButtonDown({ param($sender,$e)
    if ($null -eq $script:EditorState) { return }
    $pos = $e.GetPosition($script:WaveformCanvas)
    $marker = Find-NearestMarkerAtX $pos.X
    if ($null -ne $marker) {
        $script:EditorDraggingMarker = $marker
        Set-EditorSelectedMarker $marker
        [void]$script:WaveformCanvas.CaptureMouse()
        Update-DraggedMarker $pos.X
    }
})
$script:WaveformCanvas.Add_MouseMove({ param($sender,$e)
    if (-not [string]::IsNullOrWhiteSpace($script:EditorDraggingMarker) -and $e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        $pos = $e.GetPosition($script:WaveformCanvas); Update-DraggedMarker $pos.X
    }
})
$script:WaveformCanvas.Add_MouseLeftButtonUp({
    $script:EditorDraggingMarker = $null
    if ($script:WaveformCanvas.IsMouseCaptured) { $script:WaveformCanvas.ReleaseMouseCapture() }
})
$script:EqualZonesButton.Add_Click({ Set-KeyRangePreset 'EQUAL' })
$script:DrumMapButton.Add_Click({ Set-KeyRangePreset 'DRUM' })
$script:FullRangeButton.Add_Click({ Set-KeyRangePreset 'FULL' })
$script:DefaultChannelsButton.Add_Click({ Set-MultiChannelPreset })
$script:QuattroModeCombo.Add_SelectionChanged({ if (-not $script:KeyRangeSyncing) { Update-QuattroModeView } })
$script:SaveKeyRangesButton.Add_Click({ Save-QuattroRouting })
$script:KeyRangeCanvas.Add_SizeChanged({ Draw-KeyRangeKeyboard })
$script:PatternPlayButton.Add_Click({Start-PhoenixTransport 'PATTERN'})
$script:PatternRepeatCheck.Add_Click({if($script:TransportState){Stop-PhoenixTransport}})
$script:SongPlayButton.Add_Click({Start-PhoenixTransport 'SONG'})
$script:TransportStopButton.Add_Click({Stop-PhoenixTransport})
$script:SongStopButton.Add_Click({Stop-PhoenixTransport})
$script:MidiPanicButton.Add_Click({Send-TransportPanic;$script:TransportStatusText.Text='PANIC gesendet'})
$script:MidiRefreshButton.Add_Click({Stop-PhoenixTransport;Close-MidiOutput;Refresh-MidiOutputs})
$script:MidiOutputCombo.Add_SelectionChanged({if($script:TransportState){Stop-PhoenixTransport};Close-MidiOutput})
$script:TransportOutputCombo.Add_SelectionChanged({if($script:TransportState){Stop-PhoenixTransport};$m=Get-TransportOutputMode;$script:MidiOutputCombo.IsEnabled=($m-ne'PC');$script:MidiClockCheck.IsEnabled=($m-ne'PC')})
$script:PatternSelectCombo.Add_SelectionChanged({ if(-not $script:PatternSyncing -and $null -ne $script:PatternInspectorData){Commit-PatternGridEdits;Update-PatternStepGrid} })
$script:PatternTrackCombo.Add_SelectionChanged({ if(-not $script:PatternSyncing -and $null -ne $script:PatternInspectorData){Commit-PatternGridEdits;Update-PatternStepGrid} })
$script:PatternLengthCombo.Add_SelectionChanged({ if(-not $script:PatternSyncing -and $null -ne $script:PatternInspectorData){$pi=[Math]::Max(0,$script:PatternSelectCombo.SelectedIndex);$ti=[Math]::Max(0,$script:PatternTrackCombo.SelectedIndex);$script:PatternInspectorData.Patterns[$pi].Tracks[$ti].Length=$script:PatternLengthCombo.SelectedIndex+1;Update-PatternStepGrid;Update-PatternSummary;Set-PatternDirty} })
$script:PatternBpmBox.Add_LostFocus({ if(-not $script:PatternSyncing -and $null -ne $script:PatternInspectorData){$v=[Math]::Max(40,[Math]::Min(240,[int](Convert-ToInt64Safe $script:PatternBpmBox.Text 120)));$script:PatternBpmBox.Text=[string]$v;$script:PatternInspectorData.BPM=$v;Set-PatternDirty} })
$script:PatternClockCombo.Add_SelectionChanged({if(-not $script:PatternSyncing -and $null -ne $script:PatternInspectorData){$script:PatternInspectorData.ClockMode=$(if($script:PatternClockCombo.SelectedIndex-eq1){'EXT'}else{'INT'});Set-PatternDirty}})
$script:PatternStepGrid.Add_CellEditEnding({if(-not $script:PatternSyncing){$script:Window.Dispatcher.BeginInvoke([System.Action]{Commit-PatternGridEdits;Update-PatternStepGrid;Update-PatternSummary;Set-PatternDirty},[System.Windows.Threading.DispatcherPriority]::Background)|Out-Null}})
$script:PatternAllOnButton.Add_Click({if($null-ne$script:PatternInspectorData){foreach($st in @($script:PatternStepGrid.ItemsSource)){$st.Active=$true};$script:PatternStepGrid.Items.Refresh();Update-PatternSummary;Set-PatternDirty}})
$script:PatternAllOffButton.Add_Click({if($null-ne$script:PatternInspectorData){foreach($st in @($script:PatternStepGrid.ItemsSource)){$st.Active=$false};$script:PatternStepGrid.Items.Refresh();Update-PatternSummary;Set-PatternDirty}})
$script:PatternClearTrackButton.Add_Click({Initialize-PatternTrack})
$script:PatternCopyTrackButton.Add_Click({Copy-PatternTrack})
$script:PatternPasteTrackButton.Add_Click({Paste-PatternTrack})
$script:PatternCopyPatternButton.Add_Click({Copy-WholePattern})
$script:PatternPastePatternButton.Add_Click({Paste-WholePattern})
$script:PatternReloadButton.Add_Click({Update-PatternInspector})
$script:PatternSaveButton.Add_Click({Save-PhoenixPatterns})
$script:SongGrid.Add_CellEditEnding({if(-not $script:SongSyncing){$script:Window.Dispatcher.BeginInvoke([System.Action]{Commit-SongGridEdits;$script:SongGrid.Items.Refresh();Set-SongDirty;Update-SongValidation},[System.Windows.Threading.DispatcherPriority]::Background)|Out-Null}})
$script:SongLoopModeCombo.Add_SelectionChanged({if(-not $script:SongSyncing -and $null-ne$script:SongInspectorData){$script:SongInspectorData.LoopMode=[Math]::Max(0,$script:SongLoopModeCombo.SelectedIndex);Set-SongDirty;Update-SongValidation}})
$script:SongLoopStartCombo.Add_SelectionChanged({if(-not $script:SongSyncing -and $null-ne$script:SongInspectorData){$script:SongInspectorData.LoopStart=$script:SongLoopStartCombo.SelectedIndex+1;Set-SongDirty;Update-SongValidation}})
$script:SongLoopEndCombo.Add_SelectionChanged({if(-not $script:SongSyncing -and $null-ne$script:SongInspectorData){$script:SongInspectorData.LoopEnd=$script:SongLoopEndCombo.SelectedIndex+1;Set-SongDirty;Update-SongValidation}})
$script:SongInsertButton.Add_Click({Insert-SongEntry})
$script:SongDeleteButton.Add_Click({Delete-SongEntry})
$script:SongMoveUpButton.Add_Click({Move-SongEntry -1})
$script:SongMoveDownButton.Add_Click({Move-SongEntry 1})
$script:SongInitializeButton.Add_Click({Initialize-PhoenixSong})
$script:SongReloadButton.Add_Click({Update-SongInspector})
$script:SongSaveButton.Add_Click({Save-PhoenixSong})
for($slotNo=1;$slotNo -le 4;$slotNo++){
    $n=$slotNo
    $c=Get-KeyRangeControls $slotNo
    $c.Low.Add_SelectionChanged({ Update-KeyRangeText $n }.GetNewClosure())
    $c.Root.Add_SelectionChanged({ Update-KeyRangeText $n }.GetNewClosure())
    $c.High.Add_SelectionChanged({ Update-KeyRangeText $n }.GetNewClosure())
    $c.Channel.Add_SelectionChanged({ Update-MultiRoutingText $n }.GetNewClosure())
    $c.MultiRoot.Add_SelectionChanged({ Update-MultiRoutingText $n }.GetNewClosure())
}
$script:MidiInputRefreshButton.Add_Click({Close-MidiInput;Refresh-MidiInputs})
$script:MidiInputActiveCheck.Add_Click({if($script:MidiInputActiveCheck.IsChecked){if(-not(Open-MidiInput)){$script:MidiInputActiveCheck.IsChecked=$false}}else{Close-MidiInput}})
$script:MidiInputCombo.Add_SelectionChanged({if($script:MidiInputOpen){Close-MidiInput}})
$script:KeyboardVelocitySlider.Add_ValueChanged({$script:KeyboardVelocity=[int][Math]::Round($script:KeyboardVelocitySlider.Value);$script:KeyboardVelocityText.Text=[string]$script:KeyboardVelocity})
$script:KeyboardOctaveDownButton.Add_Click({$script:KeyboardOctave=[Math]::Max(-4,$script:KeyboardOctave-1);$script:KeyboardOctaveText.Text=[string]$script:KeyboardOctave;Build-ScreenKeyboard})
$script:KeyboardOctaveUpButton.Add_Click({$script:KeyboardOctave=[Math]::Min(4,$script:KeyboardOctave+1);$script:KeyboardOctaveText.Text=[string]$script:KeyboardOctave;Build-ScreenKeyboard})
$script:KeyboardSustainCheck.Add_Click({Set-LiveSustain 1 ([bool]$script:KeyboardSustainCheck.IsChecked)})
$script:KeyboardPanicButton.Add_Click({Stop-AllLivePcVoices;Send-TransportPanic;$script:KeyboardSustainCheck.IsChecked=$false;$script:MidiMonitorText.Text='PANIC: Alle Stimmen gestoppt und MIDI All Notes Off gesendet.'})
# RC5a: Waveform preview lifecycle is driven by WASAPI + PreviewTimer, not MediaPlayer.MediaEnded.
$script:Window.Add_Closing({
    param($sender,$e)
    if (Test-EditorHasChanges) {
        $answer = [System.Windows.MessageBox]::Show('Nicht gespeicherte PC-Änderungen verwerfen und Librarian schließen?', 'Phoenix Librarian', 'YesNo', 'Question')
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true; return }
    }
    try { Stop-PhoenixTransport -SendStop:$false } catch {}
    try { $script:MidiInputTimer.Stop(); Close-MidiInput } catch {}
    try { $script:SystemStatusTimer.Stop() } catch {}
    try { $script:AudioIdleReleaseTimer.Stop() } catch {}
    try { Stop-LoopPreview } catch {}
    try { Stop-AllLivePcVoices; Clear-LivePreviewCache } catch {}
    # RC5d: release Exclusive WASAPI before the WPF window/process tears down.
    try { [PhoenixWasapiLiveEngine]::Shutdown() } catch {}
    try { [PhoenixPcmMixer]::Shutdown() } catch {}
    if($script:PreviewTempFile){Remove-Item -LiteralPath $script:PreviewTempFile -Force -ErrorAction SilentlyContinue}
})

$script:EffectsPreviewSlotCombo.SelectedIndex=0
$script:EffectsPreviewCheck.IsChecked=$true
$script:EffectsFilterCheck.IsChecked=$true
$script:EffectsVintageCheck.IsChecked=$true
$script:EffectsEchoCheck.IsChecked=$true
$script:EffectsPlaySlotButton.Add_Click({Play-EffectsSlotPreview})
$script:EffectsPlayPatternButton.Add_Click({Play-EffectsPatternPreview})
$script:EffectsStopButton.Add_Click({ Stop-PhoenixTransport })

$script:Window.Add_ContentRendered({
    Add-Log "Phoenix Librarian v$script:AppVersion gestartet. FINAL: Phoenix BANK16/Reverb synchronisiert; On-Demand Exclusive Audio, GC-isolierter Audiokern, LIVE 10 ms / EDITOR 20 ms, MMCSS Pro Audio und Native Pitch bleiben unveraendert."
    Refresh-MidiOutputs
    Refresh-MidiInputs
if($script:TransportOutputCombo){$script:TransportOutputCombo.SelectedIndex=0}
    Auto-Detect-Phoenix
    Update-InitSoundEditor
    Update-SystemStatusView
})

[void]$script:Window.ShowDialog()
