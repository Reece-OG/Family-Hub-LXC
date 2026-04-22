@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo ==========================================
echo   Family-Hub-LXC - push to GitHub
echo ==========================================
echo.
echo Remote : https://github.com/Reece-OG/Family-Hub-LXC.git
echo Local  : %cd%
echo Branch : main
echo.

where git >nul 2>nul
if errorlevel 1 (
  echo ERROR: git is not installed or not on PATH.
  echo Install Git for Windows: https://git-scm.com/download/win
  pause
  exit /b 1
)

if not exist ".git" (
  echo [1/5] Initialising local repo on branch main...
  git init -b main
  if errorlevel 1 (echo Init failed. & pause & exit /b 1)
) else (
  echo [1/5] Git repo already initialised - skipping init.
)

echo [2/5] Pointing 'origin' at GitHub repo...
git remote remove origin >nul 2>nul
git remote add origin https://github.com/Reece-OG/Family-Hub-LXC.git

echo [3/5] Staging files (respecting .gitignore)...
git add -A

echo [4/5] Committing...
git commit -m "Proxmox VE LXC installer for Family Hub"
if errorlevel 1 (
  echo No new changes to commit - proceeding to push existing HEAD.
)

echo [5/5] Pushing to origin/main...
git push -u origin main
if %errorlevel% neq 0 (
  echo.
  echo ------------------------------------------
  echo Push was rejected.
  echo The remote probably has commits your local
  echo copy does not.
  echo ------------------------------------------
  echo.
  set /p FORCE="Overwrite remote main with THIS local tree? (y/N): "
  if /i "!FORCE!"=="y" (
    git push -u origin main --force-with-lease
    if errorlevel 1 (
      echo Force push failed. See git output above.
      pause
      exit /b 1
    )
  ) else (
    echo Aborted. Reconcile with 'git pull --rebase origin main' then re-run.
    pause
    exit /b 1
  )
)

echo.
echo ==========================================
echo   Done. View repo:
echo   https://github.com/Reece-OG/Family-Hub-LXC
echo ==========================================
pause
