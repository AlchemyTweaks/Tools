@echo off
setlocal enabledelayedexpansion

echo Press a key when ready to start...
pause

echo .
echo Starting in 6 seconds...
for /L %%i in (6,-1,1) do (
    echo %%i
    timeout /t 1 >nul
)
echo 0
echo .


for /L %%n in (1,1,20) do (
    if exist drivers%%n.etl del drivers%%n.etl
    if exist report%%n.txt del report%%n.txt
)

REM 
for /L %%n in (1,1,20) do (
    echo Starting measurement %%n...

    
    xperf -stop >nul 2>&1


    xperf -on base+interrupt+dpc -stackwalk Profile -BufferSize 1024 -MinBuffers 256 -MaxBuffers 256 -MaxFile 256 -FileMode Circular

   
    timeout /t 10 >nul

   
    xperf -stop -d drivers%%n.etl

    
    echo Creating report for measurement %%n...
    xperf -i drivers%%n.etl -o report%%n.txt -a dpcisr

    echo Measurement %%n complete.
    echo .
)

echo All measurements complete.
pause
