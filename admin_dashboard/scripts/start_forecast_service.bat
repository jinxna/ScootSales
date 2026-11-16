@echo off
REM ===========================================================================
REM  Local forecasting service - shared launcher
REM ---------------------------------------------------------------------------
REM  Called by start_dev.bat and start_admin_dashboard.bat so that BOTH dashboard
REM  shortcuts bring the Demand Forecast page online. There is deliberately no
REM  separate "start forecast" button: this file is the single implementation and
REM  it is idempotent - an already-listening service is reused, not restarted.
REM
REM  Safety properties:
REM    * binds to loopback only (forecasting/service/config.py enforces it)
REM    * FORECAST_PUSH_FIRESTORE=0 - never mirrors to Firestore unless the
REM      operator opts in explicitly
REM    * CORS_ALLOWED_ORIGINS is set to the dashboard port actually chosen, plus
REM      the classic dev ports, so the browser request is not silently rejected
REM    * every request is still authorised by the caller Firebase ID token; the
REM      origin list is a second layer, never the only one
REM
REM  Usage:  start_forecast_service.bat [dashboard-port]
REM ===========================================================================
setlocal enableextensions

for %%I in ("%~dp0..\..") do set "ROOT=%%~fI"
set "VENV=%ROOT%\forecasting\.venv"
set "VENV_PY=%VENV%\Scripts\python.exe"
set "LAUNCH_LOG_DIR=%ROOT%\logs\launcher"
set "FORECAST_HOST=127.0.0.1"
set "FORECAST_PORT=8000"
set "FORECAST_PUSH_FIRESTORE=0"

set "DASH_PORT=%~1"
if not defined DASH_PORT set "DASH_PORT=%DASHBOARD_PORT%"

REM --- allowed browser origins ------------------------------------------------
set "CORS_ALLOWED_ORIGINS=http://localhost:3000,http://localhost:5000,http://localhost:8080,http://127.0.0.1:3000,http://127.0.0.1:5000,http://127.0.0.1:8080"
if defined DASH_PORT set "CORS_ALLOWED_ORIGINS=%CORS_ALLOWED_ORIGINS%,http://localhost:%DASH_PORT%,http://127.0.0.1:%DASH_PORT%"

if not exist "%LAUNCH_LOG_DIR%" mkdir "%LAUNCH_LOG_DIR%" >nul 2>&1

REM --- already running? -------------------------------------------------------
call :port_open %FORECAST_PORT%
if not errorlevel 1 (
  echo   [OK] Forecasting service already listening on %FORECAST_HOST%:%FORECAST_PORT% - reusing it.
  echo        If the Demand Forecast page still reports "Service offline", this
  echo        instance was started with a different origin list. Run
  echo        stop_forecast_service.bat once, then start the dashboard again.
  endlocal & exit /b 0
)

REM --- python + virtual environment -------------------------------------------
set "PY=py"
where py >nul 2>&1 || set "PY=python"
where %PY% >nul 2>&1
if errorlevel 1 (
  echo   [!] Python not found - the Demand Forecast page will stay offline.
  echo       Install Python 3.10+ and tick "Add to PATH".
  endlocal & exit /b 1
)

if not exist "%VENV_PY%" (
  echo   Creating the Python environment ^(first run only, this can take a minute^)...
  %PY% -m venv "%VENV%"
  if errorlevel 1 ( echo   [X] Could not create the forecasting virtual environment. & endlocal & exit /b 1 )
)

if not exist "%ROOT%\forecasting\.deps_installed" (
  echo   Installing forecasting requirements ^(first run only - please wait^)...
  "%VENV_PY%" -m pip install --upgrade pip >nul
  "%VENV_PY%" -m pip install -r "%ROOT%\forecasting\requirements.txt"
  if errorlevel 1 ( echo   [X] pip install failed. See the messages above. & endlocal & exit /b 1 )
  echo installed> "%ROOT%\forecasting\.deps_installed"
)

REM --- start hidden, then confirm it answers ----------------------------------
echo   Starting the forecasting service on %FORECAST_HOST%:%FORECAST_PORT% ...
powershell -NoProfile -Command "Start-Process -FilePath '%VENV_PY%' -ArgumentList '-m','forecasting.service.app' -WorkingDirectory '%ROOT%' -WindowStyle Hidden -RedirectStandardOutput '%LAUNCH_LOG_DIR%\forecast.log' -RedirectStandardError '%LAUNCH_LOG_DIR%\forecast-error.log'"

set /a FORECAST_WAIT=0
goto wait_forecast

:wait_forecast
set /a FORECAST_WAIT+=1
call :port_open %FORECAST_PORT%
if not errorlevel 1 (
  echo   [OK] Forecasting service is up. Health: http://%FORECAST_HOST%:%FORECAST_PORT%/health
  echo        Logs: %LAUNCH_LOG_DIR%\forecast.log
  endlocal & exit /b 0
)
if %FORECAST_WAIT% GEQ 20 (
  echo   [!] The forecasting service did not answer within 20 seconds.
  echo       Demand Forecast will show "Service offline". Check:
  echo         %LAUNCH_LOG_DIR%\forecast-error.log
  endlocal & exit /b 1
)
REM `timeout` fails when this script is called with redirected input (for
REM example from another launcher or a scripted check), so wait with ping.
ping -n 2 127.0.0.1 >nul
goto wait_forecast

:port_open
REM %1 = port. errorlevel 0 when something is listening on 127.0.0.1:%1.
powershell -NoProfile -Command "try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', %1); $c.Close(); exit 0 } catch { exit 1 }" >nul 2>&1
if errorlevel 1 exit /b 1
exit /b 0
