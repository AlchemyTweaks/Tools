@echo off
setlocal EnableDelayedExpansion
title Disk Benchmark Tool v2.0

:: Disk Benchmark Tool - Launcher
:: Double-click this file to start. No manual PowerShell needed.

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%DiskBenchmark.ps1"

if not exist "%PS1%" (
    echo.
    echo [ERROR] DiskBenchmark.ps1 not found in: %SCRIPT_DIR%
    echo Make sure both files are in the same folder.
    echo.
    pause
    exit /b 1
)

:MENU_DISKTYPE
cls
echo.
echo +--------------------------------------------------+
echo ^|         DISK BENCHMARK TOOL  v2.0               ^|
echo ^|         Powered by Microsoft DiskSpd            ^|
echo +--------------------------------------------------+
echo.
echo Select the type of disk you want to benchmark:
echo.
echo   [1] NVMe  (PCIe SSD - the fastest type)
echo   [2] SSD   (SATA SSD - standard fast disk)
echo   [3] HDD   (Mechanical hard drive - older/slower)
echo.
set /p DISKTYPE_CHOICE="  Your choice (1/2/3): "

if "%DISKTYPE_CHOICE%"=="1" set "DISKTYPE=NVMe" & goto MENU_DRIVE
if "%DISKTYPE_CHOICE%"=="2" set "DISKTYPE=SSD"  & goto MENU_DRIVE
if "%DISKTYPE_CHOICE%"=="3" set "DISKTYPE=HDD"  & goto MENU_DRIVE

echo.
echo Invalid choice. Please enter 1, 2, or 3.
timeout /t 2 >nul
goto MENU_DISKTYPE

:MENU_DRIVE
cls
echo.
echo +--------------------------------------------------+
echo ^|  Disk Type: %DISKTYPE%                                ^|
echo +--------------------------------------------------+
echo.
echo Which drive letter do you want to test?
echo.
echo Examples: C (system drive), D (secondary), E (external)
echo.
set /p DRIVELETTER="  Enter drive letter (just the letter, e.g. C): "

set "DRIVELETTER=%DRIVELETTER::=%"
set "DRIVELETTER=%DRIVELETTER:\=%"
set "DRIVELETTER=%DRIVELETTER: =%"

if "%DRIVELETTER%"=="" (
    echo Drive letter cannot be empty.
    timeout /t 2 >nul
    goto MENU_DRIVE
)

if not exist "%DRIVELETTER%:\" (
    echo.
    echo [ERROR] Drive %DRIVELETTER%:\ does not exist or is not accessible.
    echo Check the drive letter and try again.
    echo.
    pause
    goto MENU_DRIVE
)

:MENU_LABEL
cls
echo.
echo +--------------------------------------------------+
echo ^|  Disk: %DISKTYPE%  on  %DRIVELETTER%:\                       ^|
echo +--------------------------------------------------+
echo.
echo Enter a short label for this test run.
echo Examples: Before_driver_update, After_format, Baseline
echo.
set /p LABEL="  Label (or press Enter for auto-date): "

if "%LABEL%"=="" (
    for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value') do set "DT=%%I"
    set "LABEL=Test_!DT:~0,8!_!DT:~8,4!"
)

:MENU_CONFIRM
cls
echo.
echo +--------------------------------------------------+
echo ^|  READY TO START                                  ^|
echo +--------------------------------------------------+
echo.
echo   Disk Type  : %DISKTYPE%
echo   Drive      : %DRIVELETTER%:\
echo   Label      : %LABEL%
echo.
echo The test will download DiskSpd if needed, ask for UAC,
echo run warmup + 4 benchmark phases, and save a JSON to Desktop.
echo.
set /p CONFIRM="  Start now? (Y/N): "
if /i "%CONFIRM%"=="Y" goto RUN
if /i "%CONFIRM%"=="N" goto MENU_DISKTYPE
goto MENU_CONFIRM

:RUN
cls
echo.
echo Starting benchmark... A UAC prompt may appear - click Yes.
echo.
timeout /t 2 >nul

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%PS1%" ^
    -DiskType "%DISKTYPE%" ^
    -DriveLetter "%DRIVELETTER%" ^
    -Label "%LABEL%"

if errorlevel 1 (
    echo.
    echo The script exited with an error.
    echo Common causes:
    echo - UAC was cancelled
    echo - No internet connection for DiskSpd download
    echo - Not enough free space on the drive
    echo.
    pause
)

exit /b 0
