@echo off
REM Double-clic : installe OB_CHoCH_M1 dans MetaTrader 5, compile, lance le backtest et rassemble les resultats.
REM Pour un autre symbole (ex. Exness XAUUSDm) : INSTALL_OB_CHoCH.bat -Symbol XAUUSDm
REM Pour installer sans backtest : INSTALL_OB_CHoCH.bat -NoTest
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_ob_choch.ps1" %*
echo.
pause
