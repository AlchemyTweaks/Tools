# Disk Benchmark Tool

Measures sequential throughput, random IOPS, latency percentiles, and result validity for SSD, NVMe, and HDD drives using Microsoft DiskSpd.

## Files

- `START_BENCHMARK.bat`: interactive launcher for end users.
- `DiskBenchmark.ps1`: benchmark engine that executes DiskSpd and exports JSON.

## Quick Start

1. Put `START_BENCHMARK.bat` and `DiskBenchmark.ps1` in the same folder.
2. Right-click `START_BENCHMARK.bat` and choose **Run as administrator**.
3. Choose disk type, drive letter, and label.
4. Wait for the benchmark to complete.
5. JSON output is saved on Desktop by default.

## PowerShell Direct Usage

```powershell
.\DiskBenchmark.ps1 -DiskType NVMe -DriveLetter C -Label "Before"
```

Optional parameters:

- `-OutputPath "C:\BenchResults"`
- `-DiskspdPath "C:\Tools\diskspd.exe"`
- `-SkipWarmup`

## Notes

- DiskSpd is auto-downloaded from the official Microsoft GitHub release API when missing.
- For reliable results, close heavy background apps and avoid active updates/sync jobs during tests.
