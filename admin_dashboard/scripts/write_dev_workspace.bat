@echo off
set "WORKSPACE_DEFINE="
set "WORKSPACE_CLIENT=%~1"
if "%WORKSPACE_CLIENT%"=="" set "WORKSPACE_CLIENT=supermarket"
set "WORKSPACE_EDITION=%~2"
if "%WORKSPACE_EDITION%"=="" set "WORKSPACE_EDITION=advanced"
set "PLATFORM_KEYS="
for /f "usebackq delims=" %%K in (`node "%~dp0..\..\scripts\dev_workspace.cjs" %WORKSPACE_CLIENT% %WORKSPACE_EDITION% "%~dp0..\web\workspace.json"`) do set "PLATFORM_KEYS=%%K"
if not defined PLATFORM_KEYS (
    echo ERROR: could not sign the local workspace record. Check that node and python are in PATH.
    exit /b 1
)
set "WORKSPACE_DEFINE= --dart-define=PLATFORM_PUBLIC_KEYS=%PLATFORM_KEYS%"
echo       Workspace: %WORKSPACE_CLIENT% %WORKSPACE_EDITION%, signed with the local dev key.
exit /b 0
