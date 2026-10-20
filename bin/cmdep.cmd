@echo off
rem cmake-dep command line -- see "cmdep help". Needs only CMake (%CMAKE% or cmake on PATH).
setlocal
if not defined CMAKE set "CMAKE=cmake"
set "CLI=%~dp0..\cmake\CmDepCli.cmake"
if not exist "%CLI%" set "CLI=%~dp0..\share\cmake-dep\cmake\CmDepCli.cmake"
"%CMAKE%" -P "%CLI%" -- %*
exit /b %ERRORLEVEL%
