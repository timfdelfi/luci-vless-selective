@echo off
chcp 65001 >nul
title Установка VPN на роутер OpenWrt
echo.
echo  Установка VPN (luci-vless-selective) на роутер OpenWrt
echo  ------------------------------------------------
set "IP="
set /p IP=Адрес роутера [Enter = 192.168.1.1]: 
if "%IP%"=="" set "IP=192.168.1.1"
echo.
echo  Дальше роутер дважды спросит пароль root (при вводе символы не видны - это нормально).
echo.
pushd "%~dp0"
tar -czf "%TEMP%\vless-vpn.tar.gz" .
set "RC=%errorlevel%"
popd
if not "%RC%"=="0" goto fail
scp -O -o StrictHostKeyChecking=accept-new "%TEMP%\vless-vpn.tar.gz" root@%IP%:/tmp/vless-vpn.tar.gz
if errorlevel 1 goto fail
ssh root@%IP% "rm -rf /tmp/vless-vpn && mkdir -p /tmp/vless-vpn && tar xzf /tmp/vless-vpn.tar.gz -C /tmp/vless-vpn && find /tmp/vless-vpn -type f -exec sed -i 's/\r$//' {} + && sh /tmp/vless-vpn/install.sh"
if errorlevel 1 goto fail
del "%TEMP%\vless-vpn.tar.gz" >nul 2>&1
echo.
echo  Готово! Откройте веб-интерфейс роутера: Службы - VPN
pause
exit /b 0
:fail
echo.
echo  Что-то пошло не так. Проверьте адрес роутера и пароль и запустите файл ещё раз.
pause
exit /b 1
