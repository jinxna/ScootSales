@echo off
:: Optional local FunctionGemma page interpreter for the dashboard voice dock.
:: Sets VOICE_LLM_DEFINE for the caller's `flutter run`. Never fails the caller:
:: when the prerequisites are missing it prints one line and leaves the define
:: empty, so voice keeps its deterministic behaviour.
set "VOICE_LLM_DEFINE="
if not defined DASHBOARD_VOICE_MODEL_DIR set "DASHBOARD_VOICE_MODEL_DIR=D:\models\functiongemma-270m-it"
if not defined DASHBOARD_VOICE_PORT set "DASHBOARD_VOICE_PORT=8765"

if not exist "%DASHBOARD_VOICE_MODEL_DIR%\model.safetensors" (
    echo       Voice LLM: skipped - model not found in "%DASHBOARD_VOICE_MODEL_DIR%" ^(set DASHBOARD_VOICE_MODEL_DIR^).
    exit /b 0
)
python -c "import transformers, torch" >nul 2>&1
if errorlevel 1 (
    echo       Voice LLM: skipped - python cannot import transformers/torch ^(pip install -r tools\voice\dashboard_llm\requirements.txt^).
    exit /b 0
)
powershell -NoProfile -Command "try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 http://127.0.0.1:%DASHBOARD_VOICE_PORT%/health).StatusCode | Out-Null } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
    start "Dashboard Voice LLM (:%DASHBOARD_VOICE_PORT%)" /D "%~dp0..\.." cmd /k "python -m tools.voice.dashboard_llm.service"
    echo       Voice LLM: starting in a new window ^(warms up for about a minute^).
) else (
    echo       Voice LLM: already running on :%DASHBOARD_VOICE_PORT%.
)
set "VOICE_LLM_DEFINE= --dart-define=VOICE_LLM_URL=http://127.0.0.1:%DASHBOARD_VOICE_PORT%"
exit /b 0
