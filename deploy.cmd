@echo off
setlocal enabledelayedexpansion

set SSH_OPTS=-o ServerAliveInterval=15 -o ServerAliveCountMax=4

REM Load SERVER_USER, SERVER_IP, IMAGE, COMPOSE_FILE, STANDARD_DEPLOY from prod.env
for /f "usebackq tokens=1,* delims==" %%A in ("prod.env") do (
    if "%%A"=="SERVER_USER"      set SERVER_USER=%%B
    if "%%A"=="SERVER_IP"        set SERVER_IP=%%B
    if "%%A"=="IMAGE"            set IMAGE=%%B
    if "%%A"=="COMPOSE_FILE"     set COMPOSE_FILE=%%B
    if "%%A"=="STANDARD_DEPLOY"  set STANDARD_DEPLOY=%%B
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

REM CONFIG
set IMAGE_NAME=%IMAGE%:prod
set IMAGE_TAR=%IMAGE%-image.tar
set REMOTE_PATH=/%IMAGE%

REM Check if cancelling scheduled deploy: live.cmd stop at
if /i "%~1"=="stop" if /i "%~2"=="at" (
    echo Cancelling scheduled deploys for %IMAGE%...
    ssh %SSH_OPTS% %SERVER% "for job in $(atq | awk '{print $1}'); do at -c $job 2>/dev/null | grep -q 'cd %REMOTE_PATH%' && atrm $job && echo 'Removed job '$job; done"
    echo Done.
    pause
    exit /b 0
)

REM Check if scheduled deploy: live.cmd at <time>
set SCHEDULED=0
set DEPLOY_TIME=
if /i "%~1"=="at" (
    if "%~2"=="" (
        echo ERROR: Usage: live.cmd at ^<time^>
        echo    Examples: live.cmd at 2    ^(= 02:00^)
        echo             live.cmd at 02:00
        echo             live.cmd at 13:30
        echo             live.cmd at 2:15
        goto :error
    )
    set SCHEDULED=1
    call :parsetime "%~2"
    if "!DEPLOY_TIME!"=="" (
        echo ERROR: Invalid time format: %~2
        echo    Examples: 2, 02:00, 13, 13:30, 2:15
        goto :error
    )
    echo Scheduled deploy to %IMAGE% at !DEPLOY_TIME!
) else (
    echo Deploying %IMAGE% to production ^(immediate^)
)

REM Step 0: Ensure remote directory exists and sync files
echo Syncing files...
tar cf - prod.env %COMPOSE_FILE% | ssh %SSH_OPTS% %SERVER% "mkdir -p %REMOTE_PATH% && cd %REMOTE_PATH% && tar xf -"
IF ERRORLEVEL 1 GOTO :error

REM Step 3: Build image locally (no cache to ensure fresh TypeScript build)
if not "%STANDARD_DEPLOY%"=="" (
    echo Building Docker image from %STANDARD_DEPLOY%/...
    docker build --no-cache -t %IMAGE_NAME% -f %STANDARD_DEPLOY%/Dockerfile.prod .
) else (
    echo Building Docker image locally...
    docker build --no-cache -t %IMAGE_NAME% -f Dockerfile.prod .
)
IF ERRORLEVEL 1 GOTO :error

REM Step 4: Save image
echo Saving Docker image...
docker save %IMAGE_NAME% -o %IMAGE_TAR%
IF ERRORLEVEL 1 GOTO :error

REM Step 5: Upload image
echo Uploading image to server...
scp %IMAGE_TAR% %SERVER%:/root/
IF ERRORLEVEL 1 GOTO :error

REM Step 6: Load image on server and clean up tar
echo Loading image on server...
ssh %SSH_OPTS% %SERVER% "docker load -i /root/%IMAGE_TAR% && rm /root/%IMAGE_TAR%"
IF ERRORLEVEL 1 GOTO :error

if "%SCHEDULED%"=="1" goto :scheduled_deploy

REM === IMMEDIATE DEPLOY ===

REM Step 9: Stop, clean, and start containers
echo Restarting containers...
ssh %SSH_OPTS% %SERVER% "cd %REMOTE_PATH% && docker compose --env-file prod.env -f %COMPOSE_FILE% down; docker system prune -f; docker compose --env-file prod.env -f %COMPOSE_FILE% up -d"
IF ERRORLEVEL 1 GOTO :error

REM Step 11: Clean up local image tar
del %IMAGE_TAR%

echo.
echo %IMAGE% deployed successfully
pause
exit /b 0

REM === SCHEDULED DEPLOY ===
:scheduled_deploy

REM Cancel any existing at jobs for this project
echo Cancelling existing scheduled deploys for %IMAGE%...
ssh %SSH_OPTS% %SERVER% "for job in $(atq | awk '{print $1}'); do at -c $job 2>/dev/null | grep -q 'cd %REMOTE_PATH%' && atrm $job && echo 'Removed job '$job; done"

REM Schedule the swap with at (inline commands, no script needed)
echo Scheduling container swap at !DEPLOY_TIME!...
ssh %SSH_OPTS% %SERVER% "echo 'cd %REMOTE_PATH% && docker compose --env-file prod.env -f %COMPOSE_FILE% down && docker system prune -f && docker compose --env-file prod.env -f %COMPOSE_FILE% up -d' | at !DEPLOY_TIME!"
IF ERRORLEVEL 1 (
    echo ERROR: Failed to schedule with at. Is atd running? ^(systemctl start atd^)
    goto :error
)

REM Clean up local image tar
del %IMAGE_TAR%

echo.
echo Image uploaded and swap scheduled at !DEPLOY_TIME! ^(server time^)
pause
exit /b 0

:error
echo.
echo DEPLOY FAILED — see output above
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