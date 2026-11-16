@echo off
:: ===========================================================================
::  FYP-A  -  System Launcher (double-click me)
:: ---------------------------------------------------------------------------
::  One menu to start the whole system. "Dev" = OTP bypass (debug build, no
::  Docker). "Full" = Mailpit + OTP API + Forecasting + Dashboard.
::
::  Every supermarket dashboard shortcut also starts the local forecasting
::  service (hidden, reused if already running), so the Demand Forecast page
::  works in the browser without opening a second terminal. The hardware
::  dashboard [8] uses its own Firebase project and has no forecasting service.
::
::  This file only orchestrates; the real logic lives in:
::    admin_dashboard\scripts\start_dev.bat            (dashboard, OTP bypass)
::    admin_dashboard\scripts\start_admin_dashboard.bat (dashboard, full stack)
:: ===========================================================================
setlocal enableextensions
title FYP-A - System Launcher

set "ROOT=%~dp0"
set "ADMIN_SCRIPTS=%ROOT%admin_dashboard\scripts"

:menu
cls
echo ============================================================
echo    FYP-A  -  System Launcher
echo ============================================================
echo.
echo    DASHBOARD SHORTCUTS  (the signed-in role remains authoritative)
 echo      [1]  Admin Dashboard          Dev mode + forecast + quick sign-in
 echo      [2]  Supervisor Dashboard     Dev mode + forecast + quick sign-in
 echo      [3]  Branch Manager Dashboard Dev mode + forecast + quick sign-in
 echo      [4]  Dashboard - Full stack   Mailpit + OTP + forecast
echo.
echo    MOBILE  (sales rep app)
echo      [5]  Mobile app               OTP/email-link bypass + quick sign-in
echo.
echo    BOTH
echo      [6]  Both - Dev               Dashboard + Mobile, OTP bypass + quick sign-in
echo      [7]  Both - Full              Dashboard (Full) + Mobile
echo.
echo    HARDWARE CLIENT  (separate Firebase project: hardware-client-sales)
echo      [8]  Hardware Admin Dashboard Dev mode + quick sign-in (no forecast)
echo.
echo    PLATFORM  (Scoot Sales staff, local demo data)
echo      [9]  Master Admin Control Centre   Local test database: sign in with the accounts and code its window prints
echo.
echo      [Q]  Quit
echo.
 echo    Demand Forecast is a normal dashboard page in every option above.
 echo.
set "DASH_ROLE="
set "choice="
set /p "choice=Select an option: "

if /I "%choice%"=="1" (set "DASH_ROLE=admin" & goto dash_dev_role)
if /I "%choice%"=="2" (set "DASH_ROLE=supervisor" & goto dash_dev_role)
if /I "%choice%"=="3" (set "DASH_ROLE=branch_manager" & goto dash_dev_role)
if /I "%choice%"=="4" goto dash_full
if /I "%choice%"=="5" goto mobile_only
if /I "%choice%"=="6" goto both_dev
if /I "%choice%"=="7" goto both_full
if /I "%choice%"=="8" goto dash_hardware
if /I "%choice%"=="9" goto control_centre
if /I "%choice%"=="Q" goto end
echo.
echo  Invalid choice "%choice%". Try again.
timeout /t 2 >nul
goto menu

:dash_dev_role
echo Starting %DASH_ROLE% Dashboard (Dev - OTP bypass)...
start "Dashboard (%DASH_ROLE% Dev)" cmd /k "%ADMIN_SCRIPTS%\start_dev.bat" "%DASH_ROLE%"
goto started

:dash_hardware
echo Starting Hardware Admin Dashboard (Dev - OTP bypass)...
start "Dashboard (hardware admin Dev)" cmd /k "%ADMIN_SCRIPTS%\start_dev.bat" admin hardware
goto started

:control_centre
echo Starting Master Admin Control Centre (local demo)...
set "STAFF_EXTRA="
set /p "STAFF_EXTRA=Email domains you may invite as Control Centre staff, for example gmail.com (press Enter to skip): "
if defined STAFF_EXTRA set "PLATFORM_STAFF_DOMAINS=%STAFF_EXTRA%"
start "Control Centre (local demo)" cmd /k node "%ROOT%scripts\dev_control_centre.cjs"
goto started

:dash_full
echo Starting Dashboard (Full stack)...
start "Dashboard (Full)" cmd /k "%ADMIN_SCRIPTS%\start_admin_dashboard.bat"
goto started

:mobile_only
call :start_mobile
goto started

:both_dev
echo Starting Dashboard (Dev) + Mobile...
start "Dashboard (Dev)" cmd /k "%ADMIN_SCRIPTS%\start_dev.bat"
call :start_mobile
goto started

:both_full
echo Starting Dashboard (Full) + Mobile...
start "Dashboard (Full)" cmd /k "%ADMIN_SCRIPTS%\start_admin_dashboard.bat"
call :start_mobile
goto started

:start_mobile
if not exist "%ADMIN_SCRIPTS%\start_mobile_dev.bat" (
  echo   [X] Mobile launcher not found: %ADMIN_SCRIPTS%\start_mobile_dev.bat
  goto :eof
)
echo   Starting Mobile app in a new window...
start "Mobile App (Flutter)" cmd /k "%ADMIN_SCRIPTS%\start_mobile_dev.bat"
goto :eof

:started
echo.
echo ============================================================
echo   Launched. Each service runs in its own window.
echo   Close a service window to stop that service.
echo ============================================================
echo.
pause
goto end

:end
endlocal
exit /b 0
