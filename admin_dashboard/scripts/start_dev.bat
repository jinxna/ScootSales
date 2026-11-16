@echo off
:: start_dev.bat - Launch admin dashboard in debug mode (OTP skipped).
:: Uses flutter run -d chrome which sets kDebugMode=true, bypassing the
:: OTP step so you can sign in with email + password only.
:: No Docker / Mailpit / OTP server needed.
:: The local forecasting service IS started (hidden), so the Demand Forecast
:: page works straight from the browser without a second terminal.
::
:: Usage: start_dev.bat [role] [client] [edition]
::   edition = advanced (default) or basic. Basic hides the forecast-based pages.
::   client = supermarket (default) or hardware. Each client has its own
::   Firebase project. The hardware client loads dev_accounts.hardware.local.json
::   and does not start the forecasting service, which serves the supermarket
::   project only.

title Admin Dashboard (Dev — OTP bypass)
color 0A

echo.
echo  ============================================================
echo   Admin Dashboard — Dev Mode (OTP skipped)
echo  ============================================================
echo   Sign in with email + password only.
echo   OTP bypass is active because this is a debug build.
echo.
echo   To start the FULL stack (OTP + forecasting), use:
echo     start_admin_dashboard.bat
echo  ============================================================
echo.

cd /d "%~dp0..\"

set "ADMIN_DIR=%CD%"
set "DASH_ROLE=%~1"
set "ROLE_DEFINE="
if /I "%DASH_ROLE%"=="admin" set "ROLE_DEFINE= --dart-define=DASHBOARD_ROLE=admin"
if /I "%DASH_ROLE%"=="supervisor" set "ROLE_DEFINE= --dart-define=DASHBOARD_ROLE=supervisor"
if /I "%DASH_ROLE%"=="branch_manager" set "ROLE_DEFINE= --dart-define=DASHBOARD_ROLE=branch_manager"
set "CLIENT=%~2"
if "%CLIENT%"=="" set "CLIENT=supermarket"
if /I not "%CLIENT%"=="supermarket" if /I not "%CLIENT%"=="hardware" (
    echo ERROR: unknown client "%CLIENT%". Use supermarket or hardware.
    pause
    exit /b 1
)
set "CLIENT_DEFINE= --dart-define=FIREBASE_TARGET=%CLIENT%"
set "EDITION=%~3"
set "EDITION_DEFINE="
if defined EDITION (
    if /I not "%EDITION%"=="basic" if /I not "%EDITION%"=="advanced" (
        echo ERROR: unknown edition "%EDITION%". Use basic or advanced.
        pause
        exit /b 1
    )
    set "EDITION_DEFINE= --dart-define=EDITION=%EDITION%"
)
set "ACCOUNTS_FILE=dev_accounts.local.json"
if /I "%CLIENT%"=="hardware" set "ACCOUNTS_FILE=dev_accounts.hardware.local.json"
set "GEOAPIFY_DEFINE="
if not defined GEOAPIFY_API_KEY if exist "%ADMIN_DIR%\.env.local" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%ADMIN_DIR%\.env.local") do if /I "%%A"=="GEOAPIFY_API_KEY" set "GEOAPIFY_API_KEY=%%B"
    if defined GEOAPIFY_API_KEY echo Geoapify key loaded from .env.local
)
if defined GEOAPIFY_API_KEY set "GEOAPIFY_DEFINE= --dart-define=GEOAPIFY_API_KEY=%GEOAPIFY_API_KEY%"

echo [1/3] Fetching packages...
call flutter pub get
if errorlevel 1 (
    echo ERROR: flutter pub get failed. Is Flutter in your PATH?
    pause
    exit /b 1
)

call "%~dp0find_available_dashboard_port.bat"
if errorlevel 1 (
    pause
    exit /b 1
)

echo.
echo       Client: %CLIENT%   Dashboard web port: %DASHBOARD_PORT%
if /I "%CLIENT%"=="hardware" (
    echo [2/3] Forecasting service skipped: it serves the supermarket project only.
) else (
    echo [2/3] Starting the local forecasting service ^(powers the Demand Forecast page^)...
    call "%~dp0start_forecast_service.bat" %DASHBOARD_PORT%
)

echo.
echo [3/3] Starting admin dashboard in Chrome...
echo       Button will say "Sign In (Dev - OTP skipped)"
echo.

:: Load debug-only one-tap "Dev quick sign-in" accounts when the git-ignored
:: accounts file for this client exists at the repo root (OTP skipped).
set "DEV_DEFINE="
if exist "%ADMIN_DIR%\..\%ACCOUNTS_FILE%" set "DEV_DEFINE= --dart-define-from-file=..\%ACCOUNTS_FILE%"
if defined DEV_DEFINE echo       Dev quick sign-in loaded from %ACCOUNTS_FILE%.
if defined ROLE_DEFINE echo       Role shortcut: %DASH_ROLE%.

if defined GEOAPIFY_API_KEY echo       Geoapify maps and road matrix use GEOAPIFY_API_KEY.
echo       Without it, route ordering uses the local Haversine estimate.
call "%~dp0start_voice_llm.bat"
call "%~dp0write_dev_workspace.bat" %CLIENT% %EDITION%
if errorlevel 1 (
    pause
    exit /b 1
)
call flutter run -d chrome --web-port=%DASHBOARD_PORT%%CLIENT_DEFINE%%EDITION_DEFINE%%DEV_DEFINE%%ROLE_DEFINE%%GEOAPIFY_DEFINE%%VOICE_LLM_DEFINE%%WORKSPACE_DEFINE%
del "%ADMIN_DIR%\web\workspace.json" 2>nul
