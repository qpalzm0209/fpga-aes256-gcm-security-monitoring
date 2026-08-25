@echo off
rem Copy this file to pc_rx_ui.env.cmd only when a machine needs overrides.

set PC_RX_UI_HOST=127.0.0.1
set PC_RX_UI_PORT=8765
set JETSON_DASHBOARD_URL=http://100.72.159.6:4173
rem Leave PC_RX_UART_PORT unset for RX role auto-detection.
rem set PC_RX_UART_PORT=COM12
set PC_RX_UART_BAUD=115200
set PC_RX_UART_PROBE_SECONDS=1.5
set PC_TELEMETRY_ONLINE_SECONDS=1.5
rem Gemini key stays in this local file and must not be committed or shared.
set "GEMINI_API_KEY=replace-with-local-key"
set "GEMINI_MODEL=gemini-3.6-flash"
set "GEMINI_BASE_URL=https://generativelanguage.googleapis.com/v1beta"
set "GEMINI_TIMEOUT_SECONDS=45"
