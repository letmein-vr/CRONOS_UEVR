@echo off
rem Builds CronosAimFix.dll (VS 2026, x64 Release). Needs glm in dependencies\glm (see README.md).
call "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64 >nul
cd /d "%~dp0"
cmake -S . -B build -G "Visual Studio 18 2026" -A x64 -DCMAKE_BUILD_TYPE=Release || exit /b 1
cmake --build build --config Release --target CronosAimFix -- -m
