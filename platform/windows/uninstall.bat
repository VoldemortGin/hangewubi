@echo off
setlocal

echo === Uninstalling HangeWubi Input Method ===
echo.

REM Check for admin privileges
net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: This script requires administrator privileges.
    echo Please right-click and select "Run as administrator".
    exit /b 1
)

set "INSTALL_DIR=%ProgramFiles%\HangeWubi"

REM Unregister COM component
if exist "%INSTALL_DIR%\hangewubi_tsf.dll" (
    echo Unregistering input method...
    regsvr32 /s /u "%INSTALL_DIR%\hangewubi_tsf.dll"
) else (
    echo WARNING: Installation not found at %INSTALL_DIR%
    echo Attempting to unregister from build directory...
    set "SCRIPT_DIR=%~dp0"
    if exist "%SCRIPT_DIR%build\hangewubi_tsf.dll" (
        regsvr32 /s /u "%SCRIPT_DIR%build\hangewubi_tsf.dll"
    )
)

REM Remove installed files
if exist "%INSTALL_DIR%" (
    echo Removing files...
    rmdir /S /Q "%INSTALL_DIR%"
)

echo.
echo === Uninstallation complete ===
echo.

endlocal
