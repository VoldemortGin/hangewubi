@echo off
setlocal

echo === Installing HangeWubi Input Method ===
echo.

REM Check for admin privileges
net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: This script requires administrator privileges.
    echo Please right-click and select "Run as administrator".
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "BUILD_DIR=%SCRIPT_DIR%build"
set "INSTALL_DIR=%ProgramFiles%\HangeWubi"

REM Check if build exists
if not exist "%BUILD_DIR%\hangewubi_tsf.dll" (
    echo ERROR: Build not found. Please run build.bat first.
    exit /b 1
)

REM Create install directory
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

REM Unregister old version if present
if exist "%INSTALL_DIR%\hangewubi_tsf.dll" (
    echo Unregistering previous installation...
    regsvr32 /s /u "%INSTALL_DIR%\hangewubi_tsf.dll"
)

REM Copy files
echo Copying files to %INSTALL_DIR%...
copy /Y "%BUILD_DIR%\hangewubi_tsf.dll" "%INSTALL_DIR%\" >nul
copy /Y "%BUILD_DIR%\hangewubi.dll" "%INSTALL_DIR%\" >nul

REM Copy data files
if exist "%BUILD_DIR%\data" (
    if not exist "%INSTALL_DIR%\data" mkdir "%INSTALL_DIR%\data"
    xcopy /Y /Q "%BUILD_DIR%\data\*" "%INSTALL_DIR%\data\" >nul
)

REM Register COM component
echo Registering input method...
regsvr32 /s "%INSTALL_DIR%\hangewubi_tsf.dll"
if errorlevel 1 (
    echo ERROR: Registration failed
    exit /b 1
)

echo.
echo === Installation complete ===
echo.
echo HangeWubi has been installed to: %INSTALL_DIR%
echo.
echo To use it:
echo   1. Open Windows Settings ^> Time ^& Language ^> Language ^& Region
echo   2. Under "Preferred languages", click your Chinese language
echo   3. Click "Language options" and find HangeWubi in the keyboard list
echo   4. Or press Win+Space to switch input methods
echo.

endlocal
