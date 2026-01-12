@echo off
echo Building Rust encryption library...
cd native
cargo build --release
if %ERRORLEVEL% NEQ 0 (
    echo Failed to build Rust library
    exit /b 1
)
cd ..
echo Copying DLL to assets...
if not exist assets mkdir assets
copy native\target\release\cloud_nexus_encryption.dll assets\
if %ERRORLEVEL% NEQ 0 (
    echo Failed to copy DLL
    exit /b 1
)
echo Copying DLL to runner/Debug for local testing...
mkdir build\windows\x64\runner\Debug 2>nul
copy native\target\release\cloud_nexus_encryption.dll build\windows\x64\runner\Debug\
if %ERRORLEVEL% NEQ 0 (
    echo Failed to copy DLL to runner/Debug
    exit /b 1
)
echo Generating FFI bindings...
dart run ffigen
if %ERRORLEVEL% NEQ 0 (
    echo Failed to generate FFI bindings
    exit /b 1
)
echo Done!