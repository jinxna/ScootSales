@echo off
REM ===========================================================================
REM  FYP-A - Mobile field app one-command dev launcher
REM ---------------------------------------------------------------------------
REM  Runs the sales-rep mobile app in Chrome debug mode against the existing
REM  Firebase configuration.
REM
REM  Usage: start_mobile_dev.bat [edition]
REM    edition = advanced (default) or basic. Basic leaves out visit briefs.
REM
REM  No Docker, no OTP/Forecast services, no cloud deploy - just the app.
REM  Naming and location match run_ai_insights_once.bat (admin_dashboard\scripts).
REM ===========================================================================
setlocal enableextensions
title FYP-A - Mobile Field App (Dev)

for %%I in ("%~dp0..\..") do set "ROOT=%%~fI"
set "MOBILE_DIR=%ROOT%\flutter_mobile_app"

where flutter >nul 2>&1
if errorlevel 1 (
  echo   [X] Flutter not found on PATH. Install Flutter and try again:
  echo       https://docs.flutter.dev/get-started/install
  goto :fail
)

set "EDITION=%~1"
set "EDITION_DEFINE="
if defined EDITION (
  if /I not "%EDITION%"=="basic" if /I not "%EDITION%"=="advanced" (
    echo   [X] Unknown edition "%EDITION%". Use basic or advanced.
    goto :fail
  )
  set "EDITION_DEFINE= --dart-define=EDITION=%EDITION%"
)

if not exist "%MOBILE_DIR%\pubspec.yaml" (
  echo   [X] Could not find flutter_mobile_app at "%MOBILE_DIR%".
  goto :fail
)

echo ===========================================================================
echo   FYP-A - Mobile Field App (Dev)
echo   App folder: %MOBILE_DIR%
echo ===========================================================================
echo.
echo [1/2] Fetching packages (flutter pub get)...
pushd "%MOBILE_DIR%"
call flutter pub get
if errorlevel 1 (
  popd
  echo   [X] flutter pub get failed. See the messages above.
  goto :fail
)
echo.
REM Load debug-only one-tap "Dev quick sign-in" accounts when the git-ignored
REM dev_accounts.local.json exists at the repo root (OTP/email-link bypass).
set "DEV_DEFINE="
if exist "%ROOT%\dev_accounts.local.json" set "DEV_DEFINE= --dart-define-from-file=..\dev_accounts.local.json"
echo [2/2] Launching the app on Chrome (debug)...
if defined DEV_DEFINE echo   Dev quick sign-in loaded from dev_accounts.local.json.
call flutter run -d chrome%EDITION_DEFINE%%DEV_DEFINE%
set "RUN_RC=%ERRORLEVEL%"
popd
exit /b %RUN_RC%

:fail
echo.
echo Mobile launcher stopped. Fix the item marked [X] above and run this file again.
echo.
pause
exit /b 1
