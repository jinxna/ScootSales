@echo off
setlocal
if "%~1"=="" (
  echo Preview only against the local demo emulator.
  call "%~dp0run_ai_insights_once.bat" --dry-run --seed-demo --project demo
  exit /b %ERRORLEVEL%
)
echo Forwarding explicit demo runner options. Live writes require:
echo   --apply --project demo --confirm APPLY-demo-fyp-a
call "%~dp0run_ai_insights_once.bat" --seed-demo %*
exit /b %ERRORLEVEL%
