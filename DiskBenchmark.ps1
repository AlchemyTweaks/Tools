#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('SSD','NVMe','HDD')]
    [string]$DiskType,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter,

    [string]$OutputPath = [Environment]::GetFolderPath('Desktop'),
    [string]$DiskspdPath = '',
    [switch]$SkipWarmup,
    [string]$Label = "Test_$(Get-Date -Format 'yyyyMMdd_HHmm')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section([string]$Text) {
    Write-Host "`n==============================================================" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
}
function Write-Ok([string]$Text) { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "  [INFO] $Text" -ForegroundColor Gray }

function Ensure-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) { return $true }

    Write-Warn 'Administrator privileges are required. Requesting elevation...'
    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy','Bypass',
        '-File',('"{0}"' -f $PSCommandPath),
        '-DiskType', $DiskType,
        '-DriveLetter', $DriveLetter,
        '-OutputPath', ('"{0}"' -f $OutputPath),
        '-Label', ('"{0}"' -f $Label)
    )
    if ($DiskspdPath) { $argList += @('-DiskspdPath', ('"{0}"' -f $DiskspdPath)) }
    if ($SkipWarmup) { $argList += '-SkipWarmup' }

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($argList -join ' ') | Out-Null
    return $false
}

if (-not (Ensure-Admin)) { exit 0 }

$profiles = @{
    SSD  = @{ WarmupSec = 30; Duration = 30; Runs = 3; FileSize = '1G';   SeqBlock = '128K'; QD = 32; Threads = 1; MinRead = 400;  MinWrite = 300;  MinIOPS = 20000;  MaxLat = 0.5;  ExpRead = 550;  ExpWrite = 520;  Name = 'SATA SSD' }
    NVMe = @{ WarmupSec = 60; Duration = 30; Runs = 5; FileSize = '4G';   SeqBlock = '128K'; QD = 32; Threads = 4; MinRead = 1500; MinWrite = 1000; MinIOPS = 100000; MaxLat = 0.1;  ExpRead = 3500; ExpWrite = 3000; Name = 'NVMe SSD (PCIe)' }
    HDD  = @{ WarmupSec = 15; Duration = 30; Runs = 3; FileSize = '512M'; SeqBlock = '64K';  QD = 4;  Threads = 1; MinRead = 80;   MinWrite = 60;   MinIOPS = 80;     MaxLat = 15.0; ExpRead = 150;  ExpWrite = 130;  Name = 'Mechanical HDD' }
}

$prof = $profiles[$DiskType]
$drivePath = "${DriveLetter}:\"
$runIssues = New-Object System.Collections.Generic.List[string]
$runWarnings = New-Object System.Collections.Generic.List[string]

function Get-DiskspdExe([string]$ManualPath) {
    if ($ManualPath -and (Test-Path $ManualPath)) { return (Resolve-Path $ManualPath).Path }

    $candidates = @(
        (Join-Path $PSScriptRoot 'diskspd.exe'),
        'diskspd.exe',
        (Join-Path $env:ProgramFiles 'DiskSpd\diskspd.exe'),
        (Join-Path $env:USERPROFILE 'Downloads\diskspd.exe'),
        'C:\Tools\diskspd.exe'
    )

    foreach ($c in $candidates) {
        if (Test-Path $c -ErrorAction SilentlyContinue) {
            return (Resolve-Path $c).Path
        }
    }

    $cmd = Get-Command diskspd.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-Diskspd {
    Write-Warn 'DiskSpd was not found. Downloading automatically...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $target = Join-Path $PSScriptRoot 'diskspd.exe'
    $zipPath = Join-Path $env:TEMP 'diskspd_download.zip'
    $extractPath = Join-Path $env:TEMP 'diskspd_extract'

    $downloadUrl = $null
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/diskspd/releases/latest' -Headers @{ 'User-Agent'='DiskBenchmark/2.0' }
        $asset = $release.assets | Where-Object { $_.name -match '(?i)diskspd.*\.zip$' } | Select-Object -First 1
        if ($asset) { $downloadUrl = $asset.browser_download_url }
    } catch {
        Write-Warn "GitHub API query failed: $($_.Exception.Message)"
    }

    if (-not $downloadUrl) {
        $downloadUrl = 'https://github.com/microsoft/diskspd/releases/latest/download/DiskSpd.zip'
        Write-Warn 'Falling back to static latest download URL.'
    }

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    } catch {
        throw "DiskSpd download failed. URL: $downloadUrl. Error: $($_.Exception.Message)"
    }

    if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'x86' }
    $exe = Get-ChildItem -Path $extractPath -Filter 'diskspd.exe' -Recurse |
        Where-Object { $_.DirectoryName -match [regex]::Escape($arch) } |
        Select-Object -First 1

    if (-not $exe) {
        $exe = Get-ChildItem -Path $extractPath -Filter 'diskspd.exe' -Recurse | Select-Object -First 1
    }
    if (-not $exe) { throw 'diskspd.exe was not found in the downloaded archive.' }

    Copy-Item -Path $exe.FullName -Destination $target -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "DiskSpd installed to: $target"
    return $target
}

function Parse-DiskspdOutput([string[]]$Lines) {
    $r = [ordered]@{
        ReadMBs = 0.0; WriteMBs = 0.0; ReadIOPS = 0.0; WriteIOPS = 0.0
        ReadLatAvgMs = 0.0; WriteLatAvgMs = 0.0
        ReadLatP50Ms = 0.0; ReadLatP95Ms = 0.0; ReadLatP99Ms = 0.0
        WriteLatP50Ms = 0.0; WriteLatP95Ms = 0.0; WriteLatP99Ms = 0.0
        Errors = 0
    }

    foreach ($raw in $Lines) {
        $line = $raw.Trim()

        if ($line -match '^Read\s+\|\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)') {
            $r.ReadMBs = [double]$Matches[2]
            $r.ReadIOPS = [double]$Matches[3]
        }
        if ($line -match '^Write\s+\|\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)') {
            $r.WriteMBs = [double]$Matches[2]
            $r.WriteIOPS = [double]$Matches[3]
        }

        if ($line -match '^avg\.\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)') {
            $r.ReadLatAvgMs = [double]$Matches[1]
            $r.WriteLatAvgMs = [double]$Matches[2]
        }

        if ($line -match '^\s*50th\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)') {
            $r.ReadLatP50Ms = [double]$Matches[1]
            $r.WriteLatP50Ms = [double]$Matches[2]
        }
        if ($line -match '^\s*95th\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)') {
            $r.ReadLatP95Ms = [double]$Matches[1]
            $r.WriteLatP95Ms = [double]$Matches[2]
        }
        if ($line -match '^\s*99th\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)') {
            $r.ReadLatP99Ms = [double]$Matches[1]
            $r.WriteLatP99Ms = [double]$Matches[2]
        }

        if ($line -match '(\d+)\s+error') { $r.Errors += [int]$Matches[1] }
    }

    return [pscustomobject]$r
}

function Run-Phase([string]$Name, [string[]]$Args, [ValidateSet('read','write')][string]$Mode, [int]$Runs) {
    Write-Section $Name
    $samples = @()

    for ($i = 1; $i -le $Runs; $i++) {
        Write-Info "Run $i/$Runs"
        $output = & $script:diskspdExe @Args 2>&1
        $parsed = Parse-DiskspdOutput -Lines $output

        if ($parsed.Errors -gt 0) {
            $runIssues.Add("$Name run $i reported $($parsed.Errors) DiskSpd errors")
        }

        $samples += $parsed
        if ($i -lt $Runs) { Start-Sleep -Seconds 2 }
    }

    if ($Mode -eq 'read') {
        return [ordered]@{
            MBs = [math]::Round(($samples | Measure-Object ReadMBs -Average).Average, 2)
            IOPS = [math]::Round(($samples | Measure-Object ReadIOPS -Average).Average, 0)
            LatAvgMs = [math]::Round(($samples | Measure-Object ReadLatAvgMs -Average).Average, 3)
            LatP50Ms = [math]::Round(($samples | Measure-Object ReadLatP50Ms -Average).Average, 3)
            LatP95Ms = [math]::Round(($samples | Measure-Object ReadLatP95Ms -Average).Average, 3)
            LatP99Ms = [math]::Round(($samples | Measure-Object ReadLatP99Ms -Average).Average, 3)
            Runs = $Runs
        }
    }

    return [ordered]@{
        MBs = [math]::Round(($samples | Measure-Object WriteMBs -Average).Average, 2)
        IOPS = [math]::Round(($samples | Measure-Object WriteIOPS -Average).Average, 0)
        LatAvgMs = [math]::Round(($samples | Measure-Object WriteLatAvgMs -Average).Average, 3)
        LatP50Ms = [math]::Round(($samples | Measure-Object WriteLatP50Ms -Average).Average, 3)
        LatP95Ms = [math]::Round(($samples | Measure-Object WriteLatP95Ms -Average).Average, 3)
        LatP99Ms = [math]::Round(($samples | Measure-Object WriteLatP99Ms -Average).Average, 3)
        Runs = $Runs
    }
}

try {
    Clear-Host
    Write-Section 'Disk Benchmark Tool'
    Write-Info "Disk Type : $DiskType ($($prof.Name))"
    Write-Info "Drive     : $drivePath"
    Write-Info "Label     : $Label"

    if (-not (Test-Path $drivePath)) {
        throw "Drive $drivePath does not exist or is not accessible."
    }

    $driveLabel = ''
    $driveFs = ''
    if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
        $driveInfo = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        if ($driveInfo) {
            $driveLabel = [string]$driveInfo.FileSystemLabel
            $driveFs = [string]$driveInfo.FileSystem
        }
    }
    if (-not $driveFs) {
        $ld = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $DriveLetter.ToUpper()) -ErrorAction SilentlyContinue
        if ($ld) {
            $driveLabel = [string]$ld.VolumeName
            $driveFs = [string]$ld.FileSystem
        }
    }
    if ($driveFs) {
        Write-Info "Volume    : $driveLabel [$driveFs]"
    }

    $diskspdExe = Get-DiskspdExe -ManualPath $DiskspdPath
    if (-not $diskspdExe) { $diskspdExe = Install-Diskspd }
    if (-not (Test-Path $diskspdExe)) { throw 'DiskSpd is missing and could not be installed.' }
    Write-Ok "DiskSpd ready: $diskspdExe"

    if (-not $SkipWarmup) {
        Write-Section 'Warmup'
        & $diskspdExe "-b$($prof.SeqBlock)" "-d$($prof.WarmupSec)" '-o8' '-t1' '-Sh' '-w100' "-c$($prof.FileSize)" '-D' (Join-Path $drivePath '_diskbench_temp_.dat') | Out-Null
        Write-Ok 'Warmup completed.'
    } else {
        $runWarnings.Add('Warmup was skipped; first-run latency may be less reliable.')
        Write-Warn 'Warmup skipped by user request.'
    }

    $testFile = Join-Path $drivePath '_diskbench_temp_.dat'

    $seqRead = Run-Phase -Name '[1/4] Sequential Read' -Args @("-b$($prof.SeqBlock)","-d$($prof.Duration)","-o$($prof.QD)","-t$($prof.Threads)",'-Sh','-w0','-D','-L',"-c$($prof.FileSize)",$testFile) -Mode 'read' -Runs $prof.Runs
    $seqWrite = Run-Phase -Name '[2/4] Sequential Write' -Args @("-b$($prof.SeqBlock)","-d$($prof.Duration)","-o$($prof.QD)","-t$($prof.Threads)",'-Sh','-w100','-D','-L',"-c$($prof.FileSize)",$testFile) -Mode 'write' -Runs $prof.Runs
    $rand4kRead = Run-Phase -Name '[3/4] Random 4K Read' -Args @('-b4K',"-d$($prof.Duration)","-o$($prof.QD)","-t$($prof.Threads)",'-Sh','-w0','-r','-D','-L',"-c$($prof.FileSize)",$testFile) -Mode 'read' -Runs $prof.Runs
    $rand4kWrite = Run-Phase -Name '[4/4] Random 4K Write' -Args @('-b4K',"-d$($prof.Duration)","-o$($prof.QD)","-t$($prof.Threads)",'-Sh','-w100','-r','-D','-L',"-c$($prof.FileSize)",$testFile) -Mode 'write' -Runs $prof.Runs

    if (Test-Path $testFile) {
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    }

    $validityScore = 100
    if ($seqRead.MBs -lt $prof.MinRead) { $validityScore -= 20; $runWarnings.Add("Sequential read below minimum threshold ($($prof.MinRead) MB/s)") }
    if ($seqWrite.MBs -lt $prof.MinWrite) { $validityScore -= 20; $runWarnings.Add("Sequential write below minimum threshold ($($prof.MinWrite) MB/s)") }
    if ($rand4kRead.IOPS -lt $prof.MinIOPS) { $validityScore -= 15; $runWarnings.Add("Random 4K read IOPS below minimum threshold ($($prof.MinIOPS))") }
    if ($rand4kRead.LatAvgMs -gt ($prof.MaxLat * 3)) { $validityScore -= 15; $runWarnings.Add("Random 4K read latency unusually high for $DiskType") }
    if ($validityScore -lt 0) { $validityScore = 0 }

    $validityLabel = if ($validityScore -ge 90) { 'EXCELLENT' }
        elseif ($validityScore -ge 70) { 'GOOD' }
        elseif ($validityScore -ge 50) { 'QUESTIONABLE' }
        else { 'UNRELIABLE' }

    $status = if ($runIssues.Count -eq 0) { 'SUCCESS' } else { 'COMPLETED_WITH_ERRORS' }

    $jsonData = [ordered]@{
        meta = [ordered]@{
            version = '2.0'
            tool = 'DiskBenchmark.ps1 + DiskSpd'
            timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            label = $Label
            diskType = $DiskType
            driveLetter = $DriveLetter
            drivePath = $drivePath
            driveLabel = $driveLabel
            fileSystem = $driveFs
            diskSpdPath = $diskspdExe
            status = $status
        }
        validity = [ordered]@{
            score = $validityScore
            label = $validityLabel
            isValid = ($validityScore -ge 70 -and $runIssues.Count -eq 0)
            warmupDone = (-not $SkipWarmup)
            warnings = @($runWarnings)
            issues = @($runIssues)
        }
        profile = [ordered]@{
            displayName = $prof.Name
            warmupSec = $prof.WarmupSec
            testDurationSec = $prof.Duration
            runs = $prof.Runs
            fileSize = $prof.FileSize
            seqBlockSize = $prof.SeqBlock
            queueDepth = $prof.QD
            threadCount = $prof.Threads
            thresholds = [ordered]@{
                minSeqReadMBs = $prof.MinRead
                minSeqWriteMBs = $prof.MinWrite
                minIOPS = $prof.MinIOPS
                maxLatencyMs = $prof.MaxLat
                expectedReadMBs = $prof.ExpRead
                expectedWriteMBs = $prof.ExpWrite
            }
        }
        results = [ordered]@{
            seqRead = $seqRead
            seqWrite = $seqWrite
            rand4kRead = $rand4kRead
            rand4kWrite = $rand4kWrite
        }
    }

    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }
    $safeLabel = $Label -replace '[^\w\-_]','_'
    $outputFile = Join-Path $OutputPath "DiskBench_${DiskType}_${safeLabel}.json"
    $jsonData | ConvertTo-Json -Depth 8 | Out-File -FilePath $outputFile -Encoding utf8 -Force

    Write-Section 'Summary'
    Write-Host "  Sequential Read  : $($seqRead.MBs) MB/s"
    Write-Host "  Sequential Write : $($seqWrite.MBs) MB/s"
    Write-Host "  Random 4K Read   : $($rand4kRead.IOPS) IOPS"
    Write-Host "  Random 4K Write  : $($rand4kWrite.IOPS) IOPS"
    Write-Host "  Validity         : $validityScore/100 ($validityLabel)"
    if ($runWarnings.Count -gt 0) { Write-Warn ("Warnings: " + ($runWarnings -join '; ')) }
    if ($runIssues.Count -gt 0) { Write-Fail ("Issues: " + ($runIssues -join '; ')) }
    Write-Ok "Results exported: $outputFile"
}
catch {
    Write-Section 'Benchmark Failed'
    Write-Fail $_.Exception.Message
    Write-Host "`nPlease verify: admin rights, drive letter, free disk space, and internet access for DiskSpd download." -ForegroundColor Yellow
    exit 1
}
