@echo off
setlocal enabledelayedexpansion

set SSH_OPTS=-o ServerAliveInterval=15 -o ServerAliveCountMax=4

REM Load SERVER_USER, SERVER_IP, IMAGE, COMPOSE_FILE from prod.env
for /f "usebackq tokens=1,* delims==" %%A in ("prod.env") do (
    if "%%A"=="SERVER_USER"  set SERVER_USER=%%B
    if "%%A"=="SERVER_IP"    set SERVER_IP=%%B
    if "%%A"=="IMAGE"        set IMAGE=%%B
    if "%%A"=="COMPOSE_FILE" set COMPOSE_FILE=%%B
)

if "%SERVER_USER%"=="" (
    echo ERROR: SERVER_USER not set in prod.env
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

if "%COMPOSE_FILE%"=="" (
    echo ERROR: COMPOSE_FILE not set in prod.env
    goto :error
)

set SERVER=%SERVER_USER%@%SERVER_IP%
set REMOTE_PATH=/%IMAGE%

REM Check if cancelling scheduled down: down.cmd stop at
if /i "%~1"=="stop" if /i "%~2"=="at" (
    echo Cancelling scheduled downs for %IMAGE%...
    ssh %SSH_OPTS% %SERVER% "for job in $(atq | awk '{print $1}'); do at -c $job 2>/dev/null | grep -q 'cd %REMOTE_PATH%' && atrm $job && echo 'Removed job '$job; done"
    echo Done.
    pause
    exit /b 0
)

REM Check if scheduled down: down.cmd at <time>
set SCHEDULED=0
set DEPLOY_TIME=
if /i "%~1"=="at" (
    if "%~2"=="" (
        echo ERROR: Usage: down.cmd at ^<time^>
        echo    Examples: down.cmd at 2    ^(= 02:00^)
        echo             down.cmd at 02:00
        echo             down.cmd at 13:30
        echo             down.cmd at 2:15
        goto :error
    )
    set SCHEDULED=1
    call :parsetime "%~2"
    if "!DEPLOY_TIME!"=="" (
        echo ERROR: Invalid time format: %~2
        echo    Examples: 2, 02:00, 13, 13:30, 2:15
        goto :error
    )
    echo Scheduled down for %IMAGE% at !DEPLOY_TIME!
) else (
    echo Stopping %IMAGE% on production
)

if "%SCHEDULED%"=="1" goto :scheduled_down

REM === IMMEDIATE DOWN ===

REM Check if already down
echo Checking if containers are running...
for /f %%R in ('ssh %SSH_OPTS% %SERVER% "cd %REMOTE_PATH% 2>/dev/null && docker compose --env-file prod.env -f %COMPOSE_FILE% ps -q 2>/dev/null | wc -l"') do set RUNNING=%%R

if "%RUNNING%"=="0" (
    echo %IMAGE% is already down, nothing to do.
    pause
    exit /b 0
)

REM Stop existing containers
echo Stopping containers...
ssh %SSH_OPTS% %SERVER% "cd %REMOTE_PATH% && docker compose --env-file prod.env -f %COMPOSE_FILE% down"
IF ERRORLEVEL 1 GOTO :error

REM Clean up unused Docker resources
echo Cleaning up Docker...
ssh %SSH_OPTS% %SERVER% "docker system prune -f"

echo.
echo %IMAGE% stopped successfully
pause
exit /b 0

REM === SCHEDULED DOWN ===
:scheduled_down

REM Cancel any existing at jobs for this project
echo Cancelling existing scheduled jobs for %IMAGE%...
ssh %SSH_OPTS% %SERVER% "for job in $(atq | awk '{print $1}'); do at -c $job 2>/dev/null | grep -q 'cd %REMOTE_PATH%' && atrm $job && echo 'Removed job '$job; done"

REM Schedule the down with at
echo Scheduling container down at !DEPLOY_TIME!...
ssh %SSH_OPTS% %SERVER% "echo 'cd %REMOTE_PATH% && docker compose --env-file prod.env -f %COMPOSE_FILE% ps -q | grep -q . && docker compose --env-file prod.env -f %COMPOSE_FILE% down && docker system prune -f' | at !DEPLOY_TIME!"
IF ERRORLEVEL 1 (
    echo ERROR: Failed to schedule with at. Is atd running? ^(systemctl start atd^)
    goto :error
)

echo.
echo Container down scheduled at !DEPLOY_TIME! ^(server time^)
pause
exit /b 0

:error
echo.
echo DOWN FAILED — see output above
pause
exit /b 1

REM === TIME PARSER ===
REM Accepts: 2, 02, 13, 2:00, 02:00, 2:15, 13:30
:parsetime
set _INPUT=%~1
set _HOUR=
set _MIN=

REM Check if input contains a colon
echo %_INPUT% | findstr ":" > nul
if %errorlevel%==0 (
    REM Has colon — split on it
    for /f "tokens=1,2 delims=:" %%H in ("%_INPUT%") do (
        set _HOUR=%%H
        set _MIN=%%I
    )
) else (
    REM No colon — treat as hour only
    set _HOUR=%_INPUT%
    set _MIN=00
)

REM Validate hour is numeric and in range 0-23
set /a "_HNUM=_HOUR" 2>nul
if !_HNUM! LSS 0 (set DEPLOY_TIME=& goto :eof)
if !_HNUM! GTR 23 (set DEPLOY_TIME=& goto :eof)

REM Validate minute is numeric and in range 0-59
set /a "_MNUM=_MIN" 2>nul
if !_MNUM! LSS 0 (set DEPLOY_TIME=& goto :eof)
if !_MNUM! GTR 59 (set DEPLOY_TIME=& goto :eof)

REM Zero-pad hour and minute
if !_HNUM! LSS 10 (set _HOUR=0!_HNUM!) else (set _HOUR=!_HNUM!)
if !_MNUM! LSS 10 (set _MIN=0!_MNUM!) else (set _MIN=!_MNUM!)

set DEPLOY_TIME=!_HOUR!:!_MIN!
goto :eof
