#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('SSD','NVMe','HDD')]
    [string]$DiskType,

    [Parameter(Mandatory=$true)]
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
function Write-Info([string]$Text) { Write-Host "  [INFO] $Text" -ForegroundColor Gray }

$profiles = @{
    SSD = @{ WarmupSec=30; Duration=30; Runs=3; FileSize='1G'; SeqBlock='128K'; QD=32; Threads=1; MinRead=400; MinWrite=300; MinIOPS=20000; MaxLat=0.5; ExpRead=550; ExpWrite=520; Name='SATA SSD' }
    NVMe = @{ WarmupSec=60; Duration=30; Runs=5; FileSize='4G'; SeqBlock='128K'; QD=32; Threads=4; MinRead=1500; MinWrite=1000; MinIOPS=100000; MaxLat=0.1; ExpRead=3500; ExpWrite=3000; Name='NVMe SSD (PCIe)' }
    HDD = @{ WarmupSec=15; Duration=30; Runs=3; FileSize='512M'; SeqBlock='64K'; QD=4; Threads=1; MinRead=80; MinWrite=60; MinIOPS=80; MaxLat=15; ExpRead=150; ExpWrite=130; Name='Mechanical HDD' }
}

$prof = $profiles[$DiskType]
$drivePath = "$DriveLetter`:"
$testFile = "$drivePath\_diskbench_temp_.dat"

function Get-DiskspdExe([string]$ManualPath) {
    if ($ManualPath -and (Test-Path $ManualPath)) { return $ManualPath }
    $candidates = @(
        "$PSScriptRoot\diskspd.exe",
        'diskspd.exe',
        "$env:USERPROFILE\Downloads\diskspd.exe",
        "$env:ProgramFiles\DiskSpd\diskspd.exe",
        'C:\Tools\diskspd.exe'
    )
    foreach ($c in $candidates) { if (Test-Path $c -ErrorAction SilentlyContinue) { return $c } }
    $cmd = Get-Command diskspd.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-Diskspd {
    Write-Warn 'DiskSpd not found. Downloading from Microsoft GitHub release...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/diskspd/releases/latest' -UseBasicParsing -Headers @{ 'User-Agent'='DiskBenchmark-Script/1.2' }
    $zip = $release.assets | Where-Object { $_.name -match '(?i)diskspd.*\.zip$' } | Select-Object -First 1
    if (-not $zip) { throw 'Could not find DiskSpd zip in latest release.' }

    $zipPath = Join-Path $env:TEMP 'diskspd_download.zip'
    $extractPath = Join-Path $env:TEMP 'diskspd_extract'
    (New-Object System.Net.WebClient).DownloadFile($zip.browser_download_url, $zipPath)

    if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'x86' }
    $exe = Get-ChildItem -Path $extractPath -Filter diskspd.exe -Recurse | Where-Object { $_.DirectoryName -match $arch } | Select-Object -First 1
    if (-not $exe) { $exe = Get-ChildItem -Path $extractPath -Filter diskspd.exe -Recurse | Select-Object -First 1 }
    if (-not $exe) { throw 'diskspd.exe not found after extraction.' }

    $target = Join-Path $PSScriptRoot 'diskspd.exe'
    Copy-Item $exe.FullName $target -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    return $target
}

function Parse-DiskspdOutput([string[]]$Lines) {
    $r = [ordered]@{ ReadMBs=0.0; WriteMBs=0.0; ReadIOPS=0.0; WriteIOPS=0.0; ReadLatMs=0.0; WriteLatMs=0.0; ReadLatP50Ms=0.0; ReadLatP95Ms=0.0; ReadLatP99Ms=0.0; WriteLatP50Ms=0.0; WriteLatP95Ms=0.0; WriteLatP99Ms=0.0 }
    foreach ($lineRaw in $Lines) {
        $line = $lineRaw.Trim()
        if ($line -match '^Read\s+\|\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)') { $r.ReadMBs=[double]$Matches[2]; $r.ReadIOPS=[double]$Matches[3] }
        if ($line -match '^Write\s+\|\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)') { $r.WriteMBs=[double]$Matches[2]; $r.WriteIOPS=[double]$Matches[3] }
        if ($line -match '^\s*50th\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)') { $r.ReadLatP50Ms=[double]$Matches[1]; $r.WriteLatP50Ms=[double]$Matches[2] }
        if ($line -match '^\s*95th\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)') { $r.ReadLatP95Ms=[double]$Matches[1]; $r.WriteLatP95Ms=[double]$Matches[2] }
        if ($line -match '^\s*99th\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)') { $r.ReadLatP99Ms=[double]$Matches[1]; $r.WriteLatP99Ms=[double]$Matches[2] }
        if ($line -match '^avg\.\s+\|.*?\|\s+([\d.]+)\s+\|' -and $r.ReadLatMs -eq 0) { $r.ReadLatMs=[double]$Matches[1] }
    }
    return [pscustomobject]$r
}

Write-Section "Disk Benchmark Tool - $DiskType ($($prof.Name))"

if (-not (Test-Path "$drivePath\")) { throw "Drive $drivePath\ was not found." }
$diskspdExe = Get-DiskspdExe -ManualPath $DiskspdPath
if (-not $diskspdExe) { $diskspdExe = Install-Diskspd }
if (-not (Test-Path $diskspdExe)) { throw 'DiskSpd setup failed.' }
Write-Info "DiskSpd: $diskspdExe"

if (-not $SkipWarmup) {
    Write-Section 'Warmup'
    & $diskspdExe "-b$($prof.SeqBlock)" "-d$($prof.WarmupSec)" '-o8' '-t1' '-Sh' '-w100' "-c$($prof.FileSize)" '-D' $testFile | Out-Null
    Write-Ok 'Warmup complete.'
}

function Run-Phase($name, [string[]]$args, $mode) {
    Write-Section $name
    $runs = @()
    for ($i=1; $i -le $prof.Runs; $i++) {
        Write-Info "Run $i/$($prof.Runs)"
        $output = & $diskspdExe @args 2>&1
        $p = Parse-DiskspdOutput $output
        $runs += $p
    }
    if ($mode -eq 'read') {
        return [ordered]@{
            MBs=[math]::Round(($runs|Measure-Object ReadMBs -Average).Average,2)
            IOPS=[math]::Round(($runs|Measure-Object ReadIOPS -Average).Average,0)
            LatAvgMs=[math]::Round(($runs|Measure-Object ReadLatMs -Average).Average,3)
            LatP50Ms=[math]::Round(($runs|Measure-Object ReadLatP50Ms -Average).Average,3)
            LatP95Ms=[math]::Round(($runs|Measure-Object ReadLatP95Ms -Average).Average,3)
            LatP99Ms=[math]::Round(($runs|Measure-Object ReadLatP99Ms -Average).Average,3)
        }
    }
    return [ordered]@{
        MBs=[math]::Round(($runs|Measure-Object WriteMBs -Average).Average,2)
        IOPS=[math]::Round(($runs|Measure-Object WriteIOPS -Average).Average,0)
        LatAvgMs=[math]::Round(($runs|Measure-Object WriteLatMs -Average).Average,3)
        LatP50Ms=[math]::Round(($runs|Measure-Object WriteLatP50Ms -Average).Average,3)
        LatP95Ms=[math]::Round(($runs|Measure-Object WriteLatP95Ms -Average).Average,3)
        LatP99Ms=[math]::Round(($runs|Measure-Object WriteLatP99Ms -Average).Average,3)
    }
}

$seqRead = Run-Phase '[1/4] Sequential Read' @("-b$($prof.SeqBlock)","-d$($prof.Duration)","-o$($prof.QD)","-t$($prof.Threads)",'-Sh','-w0','-D','-L',"-c$($prof.FileSize)",$testFile) 'read'
$seqWrite = Run-Phase '[2/4] Sequential Write' @("-b$($prof.SeqBlock)","-d$($prof.Duration)","-o$($prof.QD)","-t$($prof.Threads)",'-Sh','-w100','-D','-L',"-c$($prof.FileSize)",$testFile) 'write'
$rand4kRead = Run-Phase '[3/4] Random 4K Read' @('-b4K',"-d$($prof.Duration)","-o$($prof.QD)","-t$($prof.Threads)",'-Sh','-w0','-r','-D','-L',"-c$($prof.FileSize)",$testFile) 'read'
$rand4kWrite = Run-Phase '[4/4] Random 4K Write' @('-b4K',"-d$($prof.Duration)","-o$($prof.QD)","-t$($prof.Threads)",'-Sh','-w100','-r','-D','-L',"-c$($prof.FileSize)",$testFile) 'write'

if (Test-Path $testFile) { Remove-Item $testFile -Force -ErrorAction SilentlyContinue }

$validityScore = 100
if ($seqRead.MBs -lt $prof.MinRead) { $validityScore -= 20 }
if ($seqWrite.MBs -lt $prof.MinWrite) { $validityScore -= 20 }
if ($rand4kRead.IOPS -lt $prof.MinIOPS) { $validityScore -= 15 }
if ($rand4kRead.LatAvgMs -gt ($prof.MaxLat*3)) { $validityScore -= 15 }
if ($SkipWarmup) { $validityScore -= 10 }

$validityLabel = if ($validityScore -ge 90) { 'EXCELLENT' } elseif ($validityScore -ge 70) { 'GOOD' } elseif ($validityScore -ge 50) { 'QUESTIONABLE' } else { 'UNRELIABLE' }

$data = [ordered]@{
    meta=[ordered]@{ version='1.2'; timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); label=$Label; diskType=$DiskType; driveLetter=$DriveLetter }
    profile=[ordered]@{ displayName=$prof.Name; runs=$prof.Runs; fileSize=$prof.FileSize; seqBlockSize=$prof.SeqBlock; queueDepth=$prof.QD; threadCount=$prof.Threads }
    validity=[ordered]@{ score=$validityScore; label=$validityLabel; warmupDone=(-not $SkipWarmup) }
    results=[ordered]@{ seqRead=$seqRead; seqWrite=$seqWrite; rand4kRead=$rand4kRead; rand4kWrite=$rand4kWrite }
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$safeLabel = $Label -replace '[^\w\-_]','_'
$outFile = Join-Path $OutputPath "DiskBench_${DiskType}_${safeLabel}.json"
$data | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding UTF8 -Force

Write-Section 'Summary'
Write-Host "  Sequential Read  : $($seqRead.MBs) MB/s"
Write-Host "  Sequential Write : $($seqWrite.MBs) MB/s"
Write-Host "  Random 4K Read   : $($rand4kRead.IOPS) IOPS"
Write-Host "  Random 4K Write  : $($rand4kWrite.IOPS) IOPS"
Write-Host "  Validity         : $validityScore/100 ($validityLabel)"
Write-Ok "Results saved to: $outFile"
