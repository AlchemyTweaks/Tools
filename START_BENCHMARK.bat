@echo off
setlocal EnableDelayedExpansion
title Disk Benchmark Tool v2.1

:: -------------------------------------------------------------
:: Disk Benchmark Tool Launcher (Windows 10/11/Home/Pro/LTSC/Server)
:: -------------------------------------------------------------

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%DiskBenchmark.ps1"

if not exist "%PS1%" (
    echo.
    echo [ERROR] DiskBenchmark.ps1 was not found in:
    echo         %SCRIPT_DIR%
    echo.
    pause
    exit /b 1
)

:: Ensure launcher runs elevated
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ""%~f0""' -Verb RunAs"
    exit /b
)

:MENU_DISKTYPE
cls
echo.
echo +--------------------------------------------------+
echo ^|             DISK BENCHMARK TOOL v2.1            ^|
echo ^|             Powered by Microsoft DiskSpd         ^|
echo +--------------------------------------------------+
echo.
echo Select the disk type:
echo   [1] NVMe (PCIe SSD)
echo   [2] SSD  (SATA SSD)
echo   [3] HDD  (Mechanical drive)
echo.
set /p DISKTYPE_CHOICE="Your choice (1/2/3): "

if "%DISKTYPE_CHOICE%"=="1" set "DISKTYPE=NVMe" & goto MENU_DRIVE
if "%DISKTYPE_CHOICE%"=="2" set "DISKTYPE=SSD"  & goto MENU_DRIVE
if "%DISKTYPE_CHOICE%"=="3" set "DISKTYPE=HDD"  & goto MENU_DRIVE

echo Invalid input. Please enter 1, 2, or 3.
timeout /t 2 >nul
goto MENU_DISKTYPE

:MENU_DRIVE
cls
echo.
echo Available fixed/removable drives:
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_LogicalDisk | Where-Object {$_.DriveType -in 2,3} | ForEach-Object { '{0,-4} {1,-20} {2}' -f $_.DeviceID, ($_.VolumeName -as [string]), $_.FileSystem }"
echo.
set /p DRIVELETTER="Enter drive letter (example: C): "

set "DRIVELETTER=%DRIVELETTER::=%"
set "DRIVELETTER=%DRIVELETTER:\=%"
set "DRIVELETTER=%DRIVELETTER: =%"

if "%DRIVELETTER%"=="" (
    echo Drive letter cannot be empty.
    timeout /t 2 >nul
    goto MENU_DRIVE
)

if not exist "%DRIVELETTER%:\" (
    echo [ERROR] Drive %DRIVELETTER%:\ does not exist.
    timeout /t 2 >nul
    goto MENU_DRIVE
)

:MENU_LABEL
cls
echo.
echo Disk Type : %DISKTYPE%
echo Drive     : %DRIVELETTER%:\
echo.
set /p LABEL="Test label (Enter for auto-generated label): "

if "%LABEL%"=="" (
    for /f %%I in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmm"') do set "LABEL=Test_%%I"
)

:MENU_CONFIRM
cls
echo.
echo Ready to start benchmark:
echo   Disk Type : %DISKTYPE%
echo   Drive     : %DRIVELETTER%:\
echo   Label     : %LABEL%
echo.
echo Actions:
echo   - Auto-download DiskSpd if missing
echo   - Run warmup and 4 test phases
echo   - Save JSON output to Desktop
set /p CONFIRM="Start now? (Y/N): "
if /i "%CONFIRM%"=="N" goto MENU_DISKTYPE
if /i not "%CONFIRM%"=="Y" goto MENU_CONFIRM

:RUN
cls
echo Starting benchmark...
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -DiskType "%DISKTYPE%" -DriveLetter "%DRIVELETTER%" -Label "%LABEL%"
set "EXITCODE=%ERRORLEVEL%"

echo.
if "%EXITCODE%"=="0" (
    echo [SUCCESS] Benchmark completed.
) else if "%EXITCODE%"=="10" (
    echo [INFO] Starting a new measurement...
    timeout /t 1 >nul
    goto MENU_DISKTYPE
) else (
    echo [ERROR] Benchmark failed with exit code %EXITCODE%.
    echo Check admin rights, drive availability, and network connectivity.
)

echo.
pause
exit /b %EXITCODE%
