@echo off
setlocal

echo === Building HangeWubi Windows TSF Input Method ===
echo.

REM Determine project root (two levels up from this script)
set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%..\.."

REM Build Rust engine DLL
echo [1/2] Building Rust engine (hangewubi.dll)...
pushd "%ROOT_DIR%"
cargo build --release --target x86_64-pc-windows-msvc
if errorlevel 1 (
    echo ERROR: Rust build failed
    popd
    exit /b 1
)
popd
echo       Rust engine built successfully.
echo.

REM Set up paths
set "RUST_LIB=%ROOT_DIR%\target\x86_64-pc-windows-msvc\release"
set "INCLUDE_DIR=%ROOT_DIR%\include"
set "SRC_DIR=%SCRIPT_DIR%src"
set "OUT_DIR=%SCRIPT_DIR%build"

REM Create output directory
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

REM Build TSF DLL
echo [2/2] Building TSF shell (hangewubi_tsf.dll)...
cl /nologo /EHsc /O2 /LD /std:c++17 ^
    /Fe:"%OUT_DIR%\hangewubi_tsf.dll" ^
    /Fo:"%OUT_DIR%\\" ^
    "%SRC_DIR%\register.cpp" ^
    "%SRC_DIR%\class_factory.cpp" ^
    "%SRC_DIR%\text_service.cpp" ^
    "%SRC_DIR%\candidate_list.cpp" ^
    "%SRC_DIR%\composition.cpp" ^
    /I "%INCLUDE_DIR%" ^
    /link /DEF:"%SCRIPT_DIR%hangewubi_tsf.def" ^
    "%RUST_LIB%\hangewubi.dll.lib" ^
    ole32.lib oleaut32.lib uuid.lib advapi32.lib user32.lib gdi32.lib
if errorlevel 1 (
    echo ERROR: TSF DLL build failed
    exit /b 1
)
echo       TSF shell built successfully.
echo.

REM Copy the Rust DLL alongside the TSF DLL
copy /Y "%RUST_LIB%\hangewubi.dll" "%OUT_DIR%\" >nul

REM Copy data directory if it exists
if exist "%ROOT_DIR%\data" (
    if not exist "%OUT_DIR%\data" mkdir "%OUT_DIR%\data"
    xcopy /Y /Q "%ROOT_DIR%\data\*" "%OUT_DIR%\data\" >nul
    echo       Data files copied.
)

echo.
echo === Build complete ===
echo Output: %OUT_DIR%\hangewubi_tsf.dll
echo         %OUT_DIR%\hangewubi.dll
echo.
echo To install, run: install.bat
echo To uninstall, run: uninstall.bat

endlocal
