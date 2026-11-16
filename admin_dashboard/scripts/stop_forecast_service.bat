@echo off
REM ===========================================================================
REM  Local forecasting service - stopper
REM ---------------------------------------------------------------------------
REM  Only needed when the forecasting service must be restarted (for example
REM  after changing its allowed origins). The normal flow never requires this:
REM  START.bat starts the service and reuses a running instance.
REM
REM  It stops only a python process that is listening on 127.0.0.1:8000.
REM ===========================================================================
setlocal enableextensions

set "FORECAST_PORT=8000"
set "FORECAST_PID="
for /f "delims=" %%P in ('powershell -NoProfile -Command "$c = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { Write-Output $c.OwningProcess }"') do if not defined FORECAST_PID set "FORECAST_PID=%%P"

if not defined FORECAST_PID (
  echo   Forecasting service is not listening on 127.0.0.1:%FORECAST_PORT% - nothing to stop.
  endlocal & exit /b 0
),

set "FORECAST_PROC="
for /f "delims=" %%N in ('powershell -NoProfile -Command "(Get-Process -Id %FORECAST_PID% -ErrorAction SilentlyContinue).ProcessName"') do if not defined FORECAST_PROC set "FORECAST_PROC=%%N"
echo %FORECAST_PROC% | findstr /I "python" >nul
if errorlevel 1 (
  echo   [!] The process listening on :%FORECAST_PORT% is "%FORECAST_PROC%", not a python
  echo       forecasting service. Refusing to stop it. Free the port yourself if it
  echo       is left over from another project.
  endlocal & exit /b 1
),

echo   Stopping forecasting service ^(PID %FORECAST_PID%, %FORECAST_PROC%^)...
taskkill /PID %FORECAST_PID% /F >nul 2>&1
echo   Done. START.bat will start a fresh instance next time.
endlocal & exit /b 0
