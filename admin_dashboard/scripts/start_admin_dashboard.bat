@echo off
REM ===========================================================================
REM  Scoot Sales - Admin Dashboard one-click launcher
REM ---------------------------------------------------------------------------
REM  Starts everything needed to use the admin/supervisor web dashboard:
REM    1. Mailpit          (Docker)  - catches OTP login emails  -> :8025
REM    2. OTP Login API    (Node)    - sends/verifies OTP         -> :8080
REM    3. Forecasting API  (Python)  - the operational forecast   -> :8000
REM    4. Admin Dashboard  (Flutter) - the website, opens Chrome
REM
REM  It does NOT retrain the forecasting model on startup. Run a forecast from
REM  the dashboard (Demand Forecast page -> Run Forecast).
REM ===========================================================================
setlocal enableextensions
title Scoot Sales - Launcher

if /I "%~1"=="--quiet" set "QUIET=1"
set "DASH_ROLE=%~1"
if /I "%DASH_ROLE%"=="--quiet" set "DASH_ROLE=%~2"
set "ROLE_DEFINE="
if /I "%DASH_ROLE%"=="admin" set "ROLE_DEFINE= --dart-define=DASHBOARD_ROLE=admin"
if /I "%DASH_ROLE%"=="supervisor" set "ROLE_DEFINE= --dart-define=DASHBOARD_ROLE=supervisor"
if /I "%DASH_ROLE%"=="branch_manager" set "ROLE_DEFINE= --dart-define=DASHBOARD_ROLE=branch_manager"

for %%I in ("%~dp0..\..") do set "ROOT=%%~fI"
for %%I in ("%~dp0..")     do set "ADMIN_DIR=%%~fI"
set "GEOAPIFY_DEFINE="
if not defined GEOAPIFY_API_KEY if exist "%ADMIN_DIR%\.env.local" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%ADMIN_DIR%\.env.local") do if /I "%%A"=="GEOAPIFY_API_KEY" set "GEOAPIFY_API_KEY=%%B"
    if defined GEOAPIFY_API_KEY echo Geoapify key loaded from .env.local
)
if defined GEOAPIFY_API_KEY set "GEOAPIFY_DEFINE= --dart-define=GEOAPIFY_API_KEY=%GEOAPIFY_API_KEY%"
set "VENV=%ROOT%\forecasting\.venv"
set "VENV_PY=%VENV%\Scripts\python.exe"
set "NODE_ENV=development"
set "OTP_MODE=dev-mailpit"
set "OTP_DEV_ACKNOWLEDGED=1"
set "FORECAST_PUSH_FIRESTORE=0"
set "LAUNCH_LOG_DIR=%ROOT%\logs\launcher"
if not exist "%LAUNCH_LOG_DIR%" mkdir "%LAUNCH_LOG_DIR%" >nul 2>&1

echo.
echo ===========================================================================
echo   SCOOT SALES - ADMIN DASHBOARD LAUNCHER
echo   Project root: %ROOT%
echo ===========================================================================
echo.

REM ---------------------------------------------------------------------------
REM  1) Environment checks
REM ---------------------------------------------------------------------------
echo [1/6] Checking required tools...

set "PY=py"
where py >nul 2>&1 || set "PY=python"
where %PY% >nul 2>&1
if errorlevel 1 (
  echo   [X] Python not found. Install Python 3.10+ from https://python.org and tick "Add to PATH".
  goto :fail
)
echo   [OK] Python found.

where flutter >nul 2>&1
if errorlevel 1 (
  echo   [X] Flutter not found. Install Flutter and add it to PATH: https://docs.flutter.dev/get-started/install
  goto :fail
)
echo   [OK] Flutter found.

where node >nul 2>&1
if errorlevel 1 (
  echo   [!] Node.js not found - the OTP login service cannot start. Login will not work.
  echo       Install Node.js LTS from https://nodejs.org if you need to sign in.
  set "NO_NODE=1"
) else (
  echo   [OK] Node.js found.
)

set "NO_DOCKER="
docker info >nul 2>&1
if errorlevel 1 (
  echo   [!] Docker is not running - Mailpit ^(OTP email inbox^) cannot start.
  echo       Start Docker Desktop if you need to receive login OTP codes.
  set "NO_DOCKER=1"
) else (
  echo   [OK] Docker is running.
)
echo.

REM ---------------------------------------------------------------------------
REM  2) Mailpit (Docker) - catches OTP emails so you can read the login code
REM ---------------------------------------------------------------------------
echo [2/6] Starting Mailpit (OTP email inbox)...
if defined NO_DOCKER (
  echo   Skipped - Docker not running.
) else (
  pushd "%ROOT%"
  docker compose up -d mailpit
  popd
  echo   Mailpit web inbox: http://localhost:8025
)
echo.

REM ---------------------------------------------------------------------------
REM  3) OTP Login API (Node) on :8080
REM ---------------------------------------------------------------------------
echo [3/6] Starting OTP Login API (:8080)...
if defined NO_NODE (
  echo   Skipped - Node.js not installed.
) else (
  if not exist "%ROOT%\node_modules" (
    echo   First run: installing Node dependencies ^(nodemailer^)...
    pushd "%ROOT%"
    call npm install
    popd
  )
  if defined QUIET (
    powershell -NoProfile -Command "Start-Process -FilePath 'node.exe' -ArgumentList 'server.js' -WorkingDirectory '%ROOT%' -WindowStyle Hidden -RedirectStandardOutput '%LAUNCH_LOG_DIR%\otp.log' -RedirectStandardError '%LAUNCH_LOG_DIR%\otp-error.log'"
    echo   Started in the background.
  ) else (
    start "OTP Login API (:8080)" /D "%ROOT%" cmd /k "node server.js"
    echo   Started in a new window.
  )
)
echo.

REM ---------------------------------------------------------------------------
REM  4) Dashboard web port (needed before the forecasting service starts, so
REM     the service can allow exactly this browser origin)
REM ---------------------------------------------------------------------------
echo [4/6] Choosing the dashboard web port...
call "%~dp0find_available_dashboard_port.bat"
if errorlevel 1 goto :fail
echo   Dashboard web port: %DASHBOARD_PORT%
echo.

REM ---------------------------------------------------------------------------
REM  5) Forecasting API (Python/FastAPI) on :8000 - shared launcher, no retrain
REM ---------------------------------------------------------------------------
echo [5/6] Starting Forecasting Service (:8000)...
call "%~dp0start_forecast_service.bat" %DASHBOARD_PORT%
echo.

REM ---------------------------------------------------------------------------
REM  6) Admin Dashboard (Flutter web) - opens Chrome automatically
REM ---------------------------------------------------------------------------
echo [6/6] Starting Admin Dashboard (Flutter web -^> Chrome)...
if defined ROLE_DEFINE echo   Role shortcut: %DASH_ROLE%.
if defined GEOAPIFY_API_KEY echo   Geoapify map tiles and road matrix are enabled from GEOAPIFY_API_KEY.
call "%~dp0start_voice_llm.bat"
call "%~dp0write_dev_workspace.bat" supermarket advanced
if errorlevel 1 (
  pause
  exit /b 1
)
echo   The first build can take a couple of minutes. Chrome opens automatically.
echo   Without GEOAPIFY_API_KEY, the planner uses its local Haversine estimate.
if defined QUIET (
  powershell -NoProfile -Command "$flutterArguments = @('run','-d','chrome','--web-port=%DASHBOARD_PORT%'); if ($env:DASH_ROLE -in @('admin','supervisor','branch_manager')) { $flutterArguments += ('--dart-define=DASHBOARD_ROLE=' + $env:DASH_ROLE) }; if ($env:VOICE_LLM_DEFINE) { $flutterArguments += $env:VOICE_LLM_DEFINE.Trim() }; $flutterArguments += $env:WORKSPACE_DEFINE.Trim(); if (-not [string]::IsNullOrWhiteSpace($env:GEOAPIFY_API_KEY)) { $flutterArguments += ('--dart-define=GEOAPIFY_API_KEY=' + $env:GEOAPIFY_API_KEY) }; Start-Process -FilePath 'flutter.bat' -ArgumentList $flutterArguments -WorkingDirectory '%ADMIN_DIR%' -WindowStyle Hidden -RedirectStandardOutput '%LAUNCH_LOG_DIR%\dashboard.log' -RedirectStandardError '%LAUNCH_LOG_DIR%\dashboard-error.log'"
) else (
  start "Admin Dashboard (Flutter)" /D "%ADMIN_DIR%" cmd /k "flutter run -d chrome --web-port=%DASHBOARD_PORT%%ROLE_DEFINE%%GEOAPIFY_DEFINE%%VOICE_LLM_DEFINE%%WORKSPACE_DEFINE%"
)
echo.

echo ===========================================================================
echo   ALL SERVICES STARTING in separate windows:
echo     - Mailpit inbox      http://localhost:8025   (read your login OTP here)
echo     - OTP Login API      http://localhost:8080
echo     - Forecasting API    http://localhost:8000/health  (runs hidden)
echo     - Admin Dashboard    opens in Chrome automatically
echo.
echo   To generate a forecast: open the dashboard -^> Prediction page -^>
echo   Import Excel and/or Run Forecast. (The model is NOT retrained on startup.)
echo   Demand Forecast is now a normal dashboard page - no second terminal and
echo   no extra start button. To generate a forecast: Prediction page, then
echo   press Run Forecast. (The model is NOT retrained on startup.)
echo.
echo   Close the individual windows to stop each service.
echo   The forecasting service runs hidden; stop it with
echo   scripts\stop_forecast_service.bat if you need to restart it.
echo ===========================================================================
echo.
if defined QUIET exit /b 0
pause
exit /b 0

:fail
echo.
echo Launcher stopped. Fix the item marked [X] above and run this file again.
echo.
if defined QUIET exit /b 1
pause
exit /b 1
