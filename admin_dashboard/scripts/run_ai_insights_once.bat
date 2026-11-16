@echo off
setlocal
cd /d "%~dp0\..\.."
python runner.py %*
exit /b %ERRORLEVEL%
