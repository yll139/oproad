@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"

if exist "%REPO_ROOT%\.oproad-config" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%REPO_ROOT%\.oproad-config") do (
        if /I "%%A"=="OPROAD_IMAGE" if not defined OPROAD_IMAGE set "OPROAD_IMAGE=%%~B"
        if /I "%%A"=="OPROAD_ORFS_BASE_IMAGE" if not defined OPROAD_ORFS_BASE_IMAGE set "OPROAD_ORFS_BASE_IMAGE=%%~B"
        if /I "%%A"=="OPROAD_DOCKER_PLATFORM" if not defined OPROAD_DOCKER_PLATFORM set "OPROAD_DOCKER_PLATFORM=%%~B"
    )
)

if defined OPROAD_IMAGE (
    set "IMAGE=%OPROAD_IMAGE%"
) else (
    set "IMAGE=oproad:latest"
)

if defined OPROAD_DOCKER_PLATFORM (
    set "PLATFORM_SETTING=%OPROAD_DOCKER_PLATFORM%"
) else (
    set "PLATFORM_SETTING=auto"
)

if defined OPROAD_ORFS_BASE_IMAGE (
    set "ORFS_BASE_IMAGE=%OPROAD_ORFS_BASE_IMAGE%"
) else (
    set "ORFS_BASE_IMAGE=openroad/orfs:latest"
)

if defined OPROAD_FINISH_MODE (
    set "FINISH_MODE=%OPROAD_FINISH_MODE%"
) else (
    set "FINISH_MODE=auto"
)

set "CMD=%~1"
if "%CMD%"=="" goto :usage_ok
if "%CMD%"=="-h" goto :usage_ok
if "%CMD%"=="--help" goto :usage_ok
if "%CMD%"=="help" goto :usage_ok

call :require_docker || exit /b %ERRORLEVEL%

if "%CMD%"=="build-image" (
    call :normalize_orfs_image "%~2" "%ORFS_BASE_IMAGE%" BUILD_ORFS_IMAGE
    if "%~3"=="" (
        set "BUILD_PLATFORM_SETTING=%PLATFORM_SETTING%"
    ) else (
        set "BUILD_PLATFORM_SETTING=%~3"
    )
    call :detect_docker_platform "!BUILD_PLATFORM_SETTING!" BUILD_PLATFORM || exit /b %ERRORLEVEL%
    docker build --platform "!BUILD_PLATFORM!" ^
        --build-arg "ORFS_BASE_IMAGE=!BUILD_ORFS_IMAGE!" ^
        --build-arg "ORFS_BASE_PLATFORM=!BUILD_PLATFORM!" ^
        -t "%IMAGE%" "%REPO_ROOT%"
    if errorlevel 1 exit /b %ERRORLEVEL%
    call :write_config "!BUILD_ORFS_IMAGE!" "!BUILD_PLATFORM_SETTING!" "!BUILD_PLATFORM!"
    exit /b 0
)

if "%CMD%"=="new" (
    if "%~4"=="" goto :usage_error
    if "%~5"=="" (
        set "PARENT=."
    ) else (
        set "PARENT=%~5"
    )
    call :abs_create_dir "!PARENT!" PARENT_ABS || exit /b %ERRORLEVEL%
    call :detect_docker_platform "%PLATFORM_SETTING%" RESOLVED_PLATFORM || exit /b %ERRORLEVEL%
    docker run --rm -i --platform "!RESOLVED_PLATFORM!" ^
        -e "OPROAD_RUNNER=local" ^
        -e "OPROAD_DOCKER_TTY=0" ^
        -e "OPROAD_FINISH_MODE=%FINISH_MODE%" ^
        -v "!PARENT_ABS!:/workspace" ^
        "%IMAGE%" oproad-runner new "%~2" "%~3" "%~4" /workspace
    exit /b %ERRORLEVEL%
)

if "%CMD%"=="sim" goto :project_command
if "%CMD%"=="synth" goto :project_command
if "%CMD%"=="implement" goto :project_command
if "%CMD%"=="run" goto :project_command
if "%CMD%"=="report" goto :project_command
if "%CMD%"=="clean" goto :project_command

if "%CMD%"=="delete" (
    call :abs_existing_dir "%~2" PROJECT_ABS || exit /b %ERRORLEVEL%
    for %%I in ("!PROJECT_ABS!") do (
        set "PROJECT_PARENT=%%~dpI"
        set "PROJECT_NAME=%%~nxI"
    )
    if "!PROJECT_PARENT:~-1!"=="\" set "PROJECT_PARENT=!PROJECT_PARENT:~0,-1!"
    call :detect_docker_platform "%PLATFORM_SETTING%" RESOLVED_PLATFORM || exit /b %ERRORLEVEL%
    docker run --rm -i --platform "!RESOLVED_PLATFORM!" ^
        -e "OPROAD_RUNNER=local" ^
        -e "OPROAD_DOCKER_TTY=0" ^
        -e "OPROAD_FINISH_MODE=%FINISH_MODE%" ^
        -v "!PROJECT_PARENT!:/workspace" ^
        "%IMAGE%" oproad-runner delete "/workspace/!PROJECT_NAME!"
    exit /b %ERRORLEVEL%
)

if "%CMD%"=="shell" (
    call :abs_create_dir "%~2" WORK_ABS || exit /b %ERRORLEVEL%
    call :detect_docker_platform "%PLATFORM_SETTING%" RESOLVED_PLATFORM || exit /b %ERRORLEVEL%
    docker run --rm -it --platform "!RESOLVED_PLATFORM!" ^
        -e "OPROAD_RUNNER=local" ^
        -e "OPROAD_DOCKER_TTY=0" ^
        -e "OPROAD_FINISH_MODE=%FINISH_MODE%" ^
        -v "!WORK_ABS!:/workspace" ^
        "%IMAGE%" bash
    exit /b %ERRORLEVEL%
)

echo ERROR: unknown command: %CMD% 1>&2
echo. 1>&2
goto :usage_error

:project_command
call :abs_existing_dir "%~2" PROJECT_ABS || exit /b %ERRORLEVEL%
call :detect_docker_platform "%PLATFORM_SETTING%" RESOLVED_PLATFORM || exit /b %ERRORLEVEL%
docker run --rm -i --platform "!RESOLVED_PLATFORM!" ^
    -e "OPROAD_RUNNER=local" ^
    -e "OPROAD_DOCKER_TTY=0" ^
    -e "OPROAD_FINISH_MODE=%FINISH_MODE%" ^
    -v "!PROJECT_ABS!:/project" ^
    "%IMAGE%" oproad-runner "%CMD%" /project
exit /b %ERRORLEVEL%

:require_docker
where docker >nul 2>nul
if errorlevel 1 (
    echo ERROR: Docker is required but was not found on PATH. 1>&2
    exit /b 127
)
exit /b 0

:abs_create_dir
set "DIR_IN=%~1"
if "%DIR_IN%"=="" set "DIR_IN=."
if not exist "%DIR_IN%" mkdir "%DIR_IN%"
if errorlevel 1 exit /b %ERRORLEVEL%
pushd "%DIR_IN%" >nul 2>nul || exit /b 1
set "%~2=%CD%"
popd >nul
exit /b 0

:abs_existing_dir
set "DIR_IN=%~1"
if "%DIR_IN%"=="" set "DIR_IN=."
pushd "%DIR_IN%" >nul 2>nul || (
    echo ERROR: directory not found: %DIR_IN% 1>&2
    exit /b 1
)
set "%~2=%CD%"
popd >nul
exit /b 0

:normalize_orfs_image
set "IMAGE_IN=%~1"
if "%IMAGE_IN%"=="" set "IMAGE_IN=%~2"
echo %IMAGE_IN% | findstr /c:"/" >nul
if errorlevel 1 (
    set "%~3=openroad/orfs:%IMAGE_IN%"
) else (
    set "%~3=%IMAGE_IN%"
)
exit /b 0

:write_config
> "%REPO_ROOT%\.oproad-config" echo OPROAD_IMAGE="%IMAGE%"
>> "%REPO_ROOT%\.oproad-config" echo OPROAD_ORFS_BASE_IMAGE="%~1"
>> "%REPO_ROOT%\.oproad-config" echo OPROAD_DOCKER_PLATFORM="%~2"
>> "%REPO_ROOT%\.oproad-config" echo OPROAD_RESOLVED_DOCKER_PLATFORM="%~3"
exit /b 0

:detect_docker_platform
set "REQUESTED_PLATFORM=%~1"
if "%REQUESTED_PLATFORM%"=="" set "REQUESTED_PLATFORM=auto"
if /I not "%REQUESTED_PLATFORM%"=="auto" (
    set "%~2=%REQUESTED_PLATFORM%"
    exit /b 0
)
for /f "usebackq delims=" %%A in (`docker version --format "{{.Server.Arch}}" 2^>nul`) do set "DOCKER_ARCH=%%A"
if not defined DOCKER_ARCH set "DOCKER_ARCH=%PROCESSOR_ARCHITECTURE%"
if /I "%DOCKER_ARCH%"=="AMD64" (
    set "%~2=linux/amd64"
    exit /b 0
)
if /I "%DOCKER_ARCH%"=="x86_64" (
    set "%~2=linux/amd64"
    exit /b 0
)
if /I "%DOCKER_ARCH%"=="ARM64" (
    set "%~2=linux/arm64"
    exit /b 0
)
if /I "%DOCKER_ARCH%"=="aarch64" (
    set "%~2=linux/arm64"
    exit /b 0
)
echo ERROR: cannot auto-detect Docker platform from architecture: %DOCKER_ARCH% 1>&2
echo Set OPROAD_DOCKER_PLATFORM to linux/amd64 or linux/arm64. 1>&2
exit /b 1

:usage_ok
call :usage
exit /b 0

:usage_error
call :usage 1>&2
exit /b 1

:usage
echo Usage:
echo   oproad.cmd build-image [orfs_version_or_image] [docker_platform]
echo   oproad.cmd new       ^<platform^> ^<design^> ^<freq_GHz^> [parent_dir]
echo   oproad.cmd sim       [project_dir]
echo   oproad.cmd synth     [project_dir]
echo   oproad.cmd implement [project_dir]
echo   oproad.cmd report    [project_dir]
echo   oproad.cmd clean     [project_dir]
echo   oproad.cmd delete    [project_dir]
echo   oproad.cmd shell     [work_dir]
echo.
echo Only 'oproad new' takes a platform/process argument. Other commands read the
echo project's .asic_project file.
echo.
echo Environment:
echo   OPROAD_IMAGE            Docker image tag, default: oproad:latest
echo   OPROAD_ORFS_BASE_IMAGE  ORFS base image, default: openroad/orfs:latest
echo   OPROAD_DOCKER_PLATFORM  Docker platform, default: auto
echo   OPROAD_FINISH_MODE      auto, light, full, or skip
echo.
echo Examples:
echo   oproad.cmd build-image latest auto
echo   oproad.cmd build-image v3.0-1305-g0aa3fe5d linux/amd64
echo   oproad.cmd build-image openroad/orfs:latest linux/arm64
exit /b 0
