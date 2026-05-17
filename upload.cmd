@echo off
setlocal enabledelayedexpansion

set SSH_OPTS=-o ServerAliveInterval=15 -o ServerAliveCountMax=4

REM ============================================================
REM  upload.cmd  -  Zet 1 bestand op het downloads-volume van de
REM  server, los van repo en deploy. Draai vanuit een projectmap
REM  die een prod.env heeft (zelfde als deploy.cmd).
REM
REM  Gebruik:
REM    upload.cmd "D:\Projects\website-downloader\dist\FramerDownloader.exe"
REM
REM  Bestand komt in  /<IMAGE>/downloads  op de server en is
REM  daarna te downloaden via  https://download.<DOMAIN>/<naam>.
REM ============================================================

REM Vaste prod.env (k00). Zo werkt upload.cmd vanuit ELKE map, bv.
REM rechtstreeks vanuit je build-output van een ander project.
set PROD_ENV=D:\Projects\k00\prod.env

if not exist "%PROD_ENV%" (
    echo ERROR: prod.env niet gevonden op: %PROD_ENV%
    goto :error
)

REM Load SERVER_USER, SERVER_IP, IMAGE, DOMAIN from the fixed prod.env
for /f "usebackq tokens=1,* delims==" %%A in ("%PROD_ENV%") do (
    if "%%A"=="SERVER_USER" set SERVER_USER=%%B
    if "%%A"=="SERVER_IP"   set SERVER_IP=%%B
    if "%%A"=="IMAGE"       set IMAGE=%%B
    if "%%A"=="DOMAIN"      set DOMAIN=%%B
)

if "%SERVER_USER%"=="" (
    echo ERROR: SERVER_USER not set in %PROD_ENV%
    goto :error
)
if "%SERVER_IP%"=="" (
    echo ERROR: SERVER_IP not set in prod.env
    goto :error
)
if "%IMAGE%"=="" (
    echo ERROR: IMAGE not set in prod.env
    goto :error
)

set SERVER=%SERVER_USER%@%SERVER_IP%
set REMOTE_DIR=/%IMAGE%/downloads

REM Argument check
if "%~1"=="" (
    echo ERROR: Usage: upload.cmd ^<pad-naar-bestand^>
    echo    Voorbeeld: upload.cmd "D:\Projects\website-downloader\dist\FramerDownloader.exe"
    goto :error
)

set LOCAL_FILE=%~1
set FILE_NAME=%~nx1

if not exist "%LOCAL_FILE%" (
    echo ERROR: Bestand niet gevonden: %LOCAL_FILE%
    goto :error
)

echo Uploading "%FILE_NAME%" naar %SERVER%:%REMOTE_DIR%/ ...

REM Zorg dat de downloads-map bestaat (wordt nooit geleegd door deploy)
ssh %SSH_OPTS% %SERVER% "mkdir -p %REMOTE_DIR%"
IF ERRORLEVEL 1 GOTO :error

REM Upload alleen dit ene bestand
scp "%LOCAL_FILE%" %SERVER%:%REMOTE_DIR%/"%FILE_NAME%"
IF ERRORLEVEL 1 GOTO :error

echo.
echo ============================================================
echo  Bestand gehost op het persistent downloads-volume.
echo  De server host het pad; het bestand staat los van
echo  repo en deploy.
echo ============================================================
echo.
if not "%DOMAIN%"=="" (
    echo Download-URL ^(klaar om te kopieren^):
    echo.
    echo https://download.%DOMAIN%/%FILE_NAME%
) else (
    echo DOMAIN niet in prod.env - URL niet bepaald. Serverpad:
    echo.
    echo %REMOTE_DIR%/%FILE_NAME%
)
echo.
pause
exit /b 0

:error
echo.
echo UPLOAD FAILED - zie output hierboven
pause
exit /b 1
