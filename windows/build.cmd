@echo off
setlocal
if "%~1"=="" (set "dst=%~dp0..\build-win") else (set "dst=%~f1")
if not exist "%dst%" mkdir "%dst%"
where cl.exe >nul 2>&1
if errorlevel 1 (
  for /f "usebackq delims=" %%V in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do call "%%V\VC\Auxiliary\Build\vcvars64.bat"
)
if /i not "%VSCMD_ARG_TGT_ARCH%"=="x64" exit /b 1
pushd "%dst%"
(for /f "usebackq tokens=2 delims=()" %%G in ("%~dp0..\adapters\catalog.def") do echo "%~dp0..\adapters\%%G\%%G.cpp") >games.rsp
cl /nologo /std:c++17 /O2 /MT /EHsc /utf-8 /DUNICODE /D_UNICODE /DNDEBUG /LD "%~dp0platform.cpp" "%~dp0..\core\*.cpp" "%~dp0..\adapters\catalog.cpp" @games.rsp "%~dp0..\app\runtime.cpp" "%~dp0..\vendor\puff.c" /Fe:BonfireCore.dll /link shell32.lib ole32.lib uuid.lib bcrypt.lib user32.lib
if errorlevel 1 exit /b 1
where py.exe >nul 2>&1
if errorlevel 1 (set "python=python") else (set "python=py -3")
%python% "%~dp0..\tools\resources.py" windows "%~dp0."
if errorlevel 1 exit /b 1
dotnet publish "%~dp0Bonfire.csproj" -c Release -p:Platform=x64 "-p:NativePath=%dst%" -o "%dst%\publish"
set result=%errorlevel%
popd
exit /b %result%
