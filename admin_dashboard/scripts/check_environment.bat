@echo off
REM ===========================================================================
REM  Check that everything the admin dashboard + forecasting service needs is
REM  installed and ready. Read-only - changes nothing.
REM ===========================================================================
setlocal enableextensions
title Environment Check

for %%I in ("%~dp0..\..") do set "ROOT=%%~fI"
set "VENV=%ROOT%\forecasting\.venv"

echo.
echo ===========================================================================
echo   ENVIRONMENT CHECK
echo   Project root: %ROOT%
echo ===========================================================================
echo.

echo -- Python ----------------------------------------------------------------
where py >nul 2>&1
if not errorlevel 1 (
  py --version
) else (
  where python >nul 2>&1
  if not errorlevel 1 ( python --version ) else ( echo   [X] Python NOT found )
)

echo.
echo -- Flutter ---------------------------------------------------------------
where flutter >nul 2>&1
if not errorlevel 1 ( flutter --version 2>nul | findstr /i "Flutter" ) else ( echo   [X] Flutter NOT found )

echo.
echo -- Node.js (OTP login) ---------------------------------------------------
where node >nul 2>&1
if not errorlevel 1 ( node --version ) else ( echo   [X] Node.js NOT found - login OTP service will not run )

echo.
echo -- Docker (Mailpit OTP inbox) --------------------------------------------
docker info >nul 2>&1
if not errorlevel 1 (
  docker --version
  echo   [OK] Docker daemon is running
) else (
  echo   [!] Docker not running - start Docker Desktop for OTP email
)

echo.
echo -- Forecasting environment ----------------------------------------------
if exist "%VENV%\Scripts\python.exe" ( echo   [OK] Python venv exists ) else ( echo   [!] venv missing - it is created on first launch )
if exist "%ROOT%\forecasting\.deps_installed" ( echo   [OK] Forecasting requirements installed ) else ( echo   [!] requirements not installed yet )
if exist "%ROOT%\forecasting\outputs\operational_forecasts.json" ( echo   [OK] A forecast output exists ) else ( echo   [!] No forecast yet - open the dashboard and press Run Forecast )
if exist "%ROOT%\serviceAccountKey.json" ( echo   [OK] Firebase service account present - Firestore mirror possible ) else ( echo   [!] No serviceAccountKey.json - forecasts stay local only )

echo.
echo ===========================================================================
echo   Done. Items marked [X] must be fixed; [!] are optional/automatic.
echo ===========================================================================
echo.
pause
exit /b 0
