@echo off
REM GdUnit4 テストを headless で実行する。
REM   tools\run_tests.cmd                 … test/ 配下を全実行
REM   tools\run_tests.cmd res://test/foo_test.gd  … 個別実行
REM 追加引数はそのまま GdUnitCmdTool に渡る。
setlocal
set "TARGET=%*"
if "%TARGET%"=="" set "TARGET=res://test"
godot --headless -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode -a %TARGET%
endlocal
