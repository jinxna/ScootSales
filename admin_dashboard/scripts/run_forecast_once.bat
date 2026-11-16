@echo off
REM ===========================================================================
REM  Superseded: a forecast run needs an administrator session.
REM ---------------------------------------------------------------------------
REM  The operational forecast reads the master product catalogue and the live
REM  order history with the token of the administrator who asked for it, so it
REM  cannot be started from a credential-free command line. Run it from the
REM  dashboard: START.bat, then Demand Forecast -> Run Forecast.
REM ===========================================================================
setlocal enableextensions
title Run Forecast
echo.
echo  A forecast run needs an administrator session.
echo.
echo  Start the dashboard with START.bat and press Run Forecast on the
echo  Demand Forecast page. That run reads the master product catalogue and
echo  the live order history as you, and the page then shows the period,
echo  the data cutoff and which products lack enough history.
echo.
pause
exit /b 0
