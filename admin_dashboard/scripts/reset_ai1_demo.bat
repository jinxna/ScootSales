@echo off
setlocal
if "%~1"=="" (
  echo Usage: reset_ai1_demo.bat ^<serviceAccountKey.json^>
  echo Report-only: demo records are retained and are never deleted.
  exit /b 2
)
if not "%~2"=="" (
  echo This command is report-only; reset/apply arguments are unsupported.
  exit /b 2
)
cd /d "%~dp0.."
node scripts\maintenance\reset_demo_data.js "%~1"
exit /b %ERRORLEVEL%
