@echo off
:: Select an available localhost port for the Flutter dashboard.
:: Keep 5000 as the normal port, but avoid failing when another local
:: dashboard/dev server is already running there.
set "DASHBOARD_PORT="

for /f "delims=" %%P in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$base=5000; $max=5100; for ($port=$base; $port -le $max; $port++) { $listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any,$port); try { $listener.Start(); $listener.Stop(); Write-Output $port; exit 0 } catch { try { $listener.Stop() } catch {} } }; exit 1"') do if not defined DASHBOARD_PORT set "DASHBOARD_PORT=%%P"

if not defined DASHBOARD_PORT (
  echo   [X] No available dashboard port was found between 5000 and 5100.
  exit /b 1
)
exit /b 0
