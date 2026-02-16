@echo off
if "%~1"=="" (
    echo Usage: commit.cmd Your commit message here
    pause
    exit /b 1
)

git add .
git commit -m "%*"
git pull
git push