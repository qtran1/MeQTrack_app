@echo off
REM meqtrack.bat - Windows launcher for MeQTrack.
REM
REM Double-click this file in File Explorer to start the app. A command
REM window opens, this script runs, Shiny starts, and your default browser
REM opens to the app on http://127.0.0.1:<port>.
REM
REM Keep the window open while the app is running. Close it to stop the
REM app.
REM
REM NOTE: This launcher is authored in Wave 2 but will not be
REM smoke-tested on a real Windows 11 host until Wave 5. If you hit issues
REM before then, fall back to launching via PowerShell:
REM     Rscript -e "shiny::runApp('app', launch.browser = TRUE, host = '127.0.0.1')"

setlocal

REM Resolve the script's own directory so the launcher works regardless
REM of where the user placed MeQTrack_app.
cd /d "%~dp0"

echo ==============================================================
echo   MeQTrack - launching...
echo   Project: %CD%
echo ==============================================================

REM 1. Check Rscript is on PATH.
where Rscript >nul 2>&1
if errorlevel 1 (
  echo.
  echo   ERROR: Rscript not found on your PATH.
  echo.
  echo   MeQTrack needs R ^>= 4.4 installed. Install from:
  echo       https://cran.r-project.org/bin/windows/base/
  echo   and then re-run this launcher.
  echo.
  pause
  exit /b 1
)

REM 2. Check pandoc for the report generator.
where pandoc >nul 2>&1
if errorlevel 1 (
  echo.
  echo   WARNING: pandoc not found on your PATH.
  echo.
  echo   The HTML report generator falls back to a plain-text report when
  echo   pandoc is missing. Install from https://pandoc.org/installing.html
  echo   to enable the full report.
  echo.
  echo   Continuing anyway...
  echo.
)

REM 3. Start Shiny.
echo Starting Shiny server on http://127.0.0.1 ...
echo (Close this window to stop the app.)
echo.

Rscript -e "shiny::runApp('app', launch.browser = TRUE, host = '127.0.0.1')"

endlocal
