@echo off
chcp 65001 >nul
echo Обновляю «Пульт Claude» до версии 6...
set "APP=%LOCALAPPDATA%\ClaudePult"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop_pult.ps1"
timeout /t 1 /nobreak >nul
mkdir "%APP%" 2>nul
copy /y "%~dp0pult.ps1" "%APP%\pult.ps1" >nul
copy /y "%~dp0pult.ico" "%APP%\pult.ico" >nul
copy /y "%~dp0pult.png" "%APP%\pult.png" >nul
copy /y "%~dp0pult.wav" "%APP%\pult.wav" >nul
copy /y "%~dp0pult_alert.ico" "%APP%\pult_alert.ico" >nul
> "%APP%\start.vbs" echo CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%APP%\pult.ps1""", 0, False
copy /y "%APP%\start.vbs" "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ClaudePult.vbs" >nul
wscript.exe "%APP%\start.vbs"
echo Готово. В трее — значок со щитом (оранжевая точка = команда ждёт подтверждения).
timeout /t 4 >nul
