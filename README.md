# Disk Benchmark Tool

A Windows disk benchmark utility for **SSD / NVMe / HDD** with an interactive launcher and JSON export compatible with viewer-style dashboards.

## Included Files

- `START_BENCHMARK.bat` → user launcher (double-click, menu flow, admin elevation).
- `DiskBenchmark.ps1` → benchmark engine (DiskSpd orchestration + JSON export).

## Key Features

- Automatic DiskSpd download/install when missing (to script directory).
- Works with Windows PowerShell 5.1 on Windows 10/11 (Home/Pro/LTSC) and Server editions, with a volume-info fallback for environments where `Get-Volume` is unavailable.
- Automatic elevation to Administrator (launcher + script safety check).
- Sequential + random 4K tests with latency percentiles.
- JSON output with stable schema (`meta`, `validity`, `profile`, `results`).
- Clear warning/issue reporting when benchmark validity is low.

## Quick Start

1. Keep both files in the same folder.
2. Double-click `START_BENCHMARK.bat`.
3. Select disk type and drive letter.
4. Enter an optional label.
5. JSON is exported to Desktop by default.

## PowerShell Direct Run

```powershell
.\DiskBenchmark.ps1 -DiskType NVMe -DriveLetter C -Label "Before"
```

Optional arguments:

- `-OutputPath "C:\BenchResults"`
- `-DiskspdPath "C:\Tools\diskspd.exe"`
- `-SkipWarmup`

## JSON Notes for Viewer Import

The output always includes:

- `meta` (run details and status)
- `validity` (score, labels, warnings, issues)
- `profile` (test settings and thresholds)
- `results.seqRead`, `results.seqWrite`, `results.rand4kRead`, `results.rand4kWrite`

This structure is designed to reduce missing-field errors during HTML viewer imports.
