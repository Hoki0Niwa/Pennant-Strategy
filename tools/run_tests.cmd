@echo off
REM Run GdUnit4 tests in headless mode.
REM   tools\run_tests.cmd
REM   tools\run_tests.cmd res://test/foo_test.gd
REM Extra arguments are passed through to GdUnitCmdTool.

setlocal
set "TARGET=%*"
if "%TARGET%"=="" set "TARGET=res://test"

godot --headless -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode -a %TARGET%
set "EXIT_CODE=%ERRORLEVEL%"

endlocal & exit /b %EXIT_CODE%
