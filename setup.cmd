@echo off
setlocal enabledelayedexpansion
REM RazAV1 setup helper, started by the window: setup.cmd ffmpeg ^| vs ^| svt
REM Downloads with curl.exe and unpacks with tar.exe, both built into Windows. PowerShell is not used here.
REM The window passes the download links in AV1_* variables. Results go to logs\setup_result.txt and logs\setup.log.

set "HERE=%~dp0"
set "LOGDIR=%HERE%logs"
if not exist "%LOGDIR%" md "%LOGDIR%"
set "LOG=%LOGDIR%\setup.log"
set "RES=%LOGDIR%\setup_result.txt"
if exist "%RES%" del "%RES%" >nul 2>&1
set "CURL=%SystemRoot%\System32\curl.exe"
set "TAR=%SystemRoot%\System32\tar.exe"
set "BIN=%HERE%bin"
REM Work folder inside the program folder [compilers warn about building under Temp]; removed at the end
set "WORK=%HERE%_work\av1setup_%RANDOM%%RANDOM%"
set "STAMP=%DATE%_%TIME%"
set "STAMP=!STAMP:/=-!"
set "STAMP=!STAMP:.=-!"
set "STAMP=!STAMP::=-!"
set "STAMP=!STAMP:,=-!"
set "STAMP=!STAMP: =_!"
set "FAILMSG="
set "OKMSG="
title RazAV1 setup - %~1

if not exist "%CURL%" (
    set "FAILMSG=curl.exe is missing. Windows 10 1803 or newer has it."
    goto :fail
)
if not exist "%TAR%" (
    set "FAILMSG=tar.exe is missing. Windows 10 1803 or newer has it."
    goto :fail
)
md "%WORK%" >nul 2>&1
if /i "%~1"=="ffmpeg" goto :do_ffmpeg
if /i "%~1"=="vs" goto :do_vs
if /i "%~1"=="svt" goto :do_svt
set "FAILMSG=Unknown setup step: %~1"
goto :fail


REM ==================================================================
REM ffmpeg + ffprobe [BtbN build]
REM ==================================================================
:do_ffmpeg
if not defined AV1_FF_URL (
    set "FAILMSG=No ffmpeg download link was given."
    goto :fail
)
call :get "%AV1_FF_URL%" "%WORK%\ffmpeg.zip" "ffmpeg %AV1_FF_NAME%"
if errorlevel 1 (
    set "FAILMSG=The ffmpeg download failed."
    goto :fail
)
call :unpack "%WORK%\ffmpeg.zip" "%WORK%\ff"
if errorlevel 1 (
    set "FAILMSG=Unpacking ffmpeg failed."
    goto :fail
)
set "NFF="
set "NFP="
for /r "%WORK%\ff" %%f in (ffmpeg*.exe) do if /i "%%~nxf"=="ffmpeg.exe" set "NFF=%%f"
for /r "%WORK%\ff" %%f in (ffprobe*.exe) do if /i "%%~nxf"=="ffprobe.exe" set "NFP=%%f"
if not defined NFF (
    set "FAILMSG=The ffmpeg download has no ffmpeg.exe."
    goto :fail
)
if not defined NFP (
    set "FAILMSG=The ffmpeg download has no ffprobe.exe."
    goto :fail
)
"%NFF%" -hide_banner -version >nul 2>&1
if errorlevel 1 (
    set "FAILMSG=The new ffmpeg does not start."
    goto :fail
)
"%NFF%" -hide_banner -filters 2>nul | findstr /c:" zscale " >nul
if errorlevel 1 call :log "Warning: this ffmpeg has no zscale, so the HDR to SDR workflow will not work with it."
if not exist "%BIN%" md "%BIN%"
if not exist "%BIN%\ffmpeg.exe" goto :ff_copy
set "BK=%BIN%\backup\ffmpeg_%AV1_FF_OLD%_%STAMP%"
md "%BK%" >nul 2>&1
copy /y "%BIN%\ffmpeg.exe" "%BK%\" >nul
if exist "%BIN%\ffprobe.exe" copy /y "%BIN%\ffprobe.exe" "%BK%\" >nul
call :log "Old ffmpeg kept in %BK%"
:ff_copy
copy /y "%NFF%" "%BIN%\ffmpeg.exe" >nul
if errorlevel 1 (
    set "FAILMSG=Could not copy ffmpeg.exe into bin. Is an encode still running?"
    goto :fail
)
copy /y "%NFP%" "%BIN%\ffprobe.exe" >nul
set "OKMSG=ffmpeg %AV1_FF_NAME% installed in bin."
goto :ok


REM ==================================================================
REM VapourSynth portable + KNLMeansCL + L-SMASH Works
REM ==================================================================
:do_vs
if not defined AV1_VS_URL (
    set "FAILMSG=No VapourSynth download link was given."
    goto :fail
)
set "STAGE=%HERE%vs_new"
if exist "%STAGE%" rd /s /q "%STAGE%"
md "%STAGE%"
call :get "%AV1_VS_URL%" "%WORK%\vs.zip" "VapourSynth portable %AV1_VS_TAG%"
if errorlevel 1 (
    set "FAILMSG=The VapourSynth download failed."
    goto :fail
)
call :unpack "%WORK%\vs.zip" "%WORK%\vsx"
if errorlevel 1 (
    set "FAILMSG=Unpacking VapourSynth failed."
    goto :fail
)
REM A zip with one top folder: use that folder
set "VSROOT=%WORK%\vsx"
set /a NF=0
set /a ND=0
for %%i in ("%WORK%\vsx\*") do set /a NF+=1
for /d %%i in ("%WORK%\vsx\*") do (
    set /a ND+=1
    set "ONE=%%i"
)
if %NF%==0 if %ND%==1 set "VSROOT=!ONE!"

if exist "%VSROOT%\python.exe" (
    call :log "The VapourSynth zip brings its own Python."
    goto :vs_merge
)
call :get "%AV1_PY_URL%" "%WORK%\py.zip" "Python embeddable"
if errorlevel 1 (
    set "FAILMSG=The Python download failed."
    goto :fail
)
call :unpack "%WORK%\py.zip" "%WORK%\py"
if errorlevel 1 (
    set "FAILMSG=Unpacking Python failed."
    goto :fail
)
robocopy "%WORK%\py" "%STAGE%" /E /NFL /NDL /NJH /NJS /NP >nul
:vs_merge
robocopy "%VSROOT%" "%STAGE%" /E /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 (
    set "FAILMSG=Copying the VapourSynth files failed."
    goto :fail
)
set "SP=%STAGE%\Lib\site-packages"
if not exist "%SP%" md "%SP%"
if not exist "%STAGE%\Scripts" md "%STAGE%\Scripts"

REM python3xx._pth: let the embedded Python see site-packages and Scripts
set "PTH="
for %%p in ("%STAGE%\python3*._pth") do (
    set "PTH=%%~fp"
    set "PTHN=%%~np"
)
if not defined PTH (
    set "FAILMSG=No python3xx._pth was found, so the Python part is incomplete."
    goto :fail
)
>"%PTH%" echo %PTHN%.zip
>>"%PTH%" echo .
>>"%PTH%" echo Lib\site-packages
>>"%PTH%" echo Scripts
>>"%PTH%" echo #import site
call :log "Python set up: %PTHN%"

REM The vapoursynth wheel is a zip: unpack it straight into site-packages
set "WHL="
for /r "%STAGE%" %%w in (vapoursynth-*.whl) do set "WHL=%%w"
for /r "%STAGE%" %%w in (vapoursynth-*abi3*.whl) do set "WHL=%%w"
if not defined WHL (
    call :log "No vapoursynth wheel in the zip, using its files as they are."
    goto :vs_plugins
)
"%TAR%" -xf "%WHL%" -C "%SP%"
if errorlevel 1 (
    set "FAILMSG=Unpacking the vapoursynth wheel failed."
    goto :fail
)
for /d %%d in ("%SP%\*.data") do (
    if exist "%%d\scripts" robocopy "%%d\scripts" "%STAGE%\Scripts" /E /NFL /NDL /NJH /NJS /NP >nul
    if exist "%%d\data" robocopy "%%d\data" "%STAGE%" /E /NFL /NDL /NJH /NJS /NP >nul
    if exist "%%d\purelib" robocopy "%%d\purelib" "%SP%" /E /NFL /NDL /NJH /NJS /NP >nul
    if exist "%%d\platlib" robocopy "%%d\platlib" "%SP%" /E /NFL /NDL /NJH /NJS /NP >nul
    rd /s /q "%%d"
)
for %%w in ("%WHL%") do call :log "Unpacked %%~nxw into site-packages"

:vs_plugins
set "PLUG=%SP%\vapoursynth\plugins"
if not exist "%PLUG%" md "%PLUG%"
call :get "%AV1_KN_URL%" "%WORK%\knlm.whl" "KNLMeansCL"
if errorlevel 1 (
    set "FAILMSG=The KNLMeansCL download failed."
    goto :fail
)
call :unpack "%WORK%\knlm.whl" "%WORK%\knlm"
if errorlevel 1 (
    set "FAILMSG=Unpacking KNLMeansCL failed."
    goto :fail
)
set /a NK=0
for /r "%WORK%\knlm" %%f in (*.dll) do (
    copy /y "%%f" "%PLUG%\" >nul
    set /a NK+=1
)
if %NK%==0 (
    set "FAILMSG=The KNLMeansCL download has no dll inside."
    goto :fail
)
call :get "%AV1_LS_URL%" "%WORK%\%AV1_LS_NAME%" "L-SMASH Works"
if errorlevel 1 (
    set "FAILMSG=The L-SMASH Works download failed."
    goto :fail
)
call :unpack "%WORK%\%AV1_LS_NAME%" "%WORK%\ls"
if errorlevel 1 (
    set "FAILMSG=Unpacking L-SMASH Works failed. If it is a .7z file, this Windows tar cannot open it."
    goto :fail
)
REM The release may hold an AviSynth and a VapourSynth LSMASHSource.dll: prefer VapourSynth, 64-bit
set "LSD="
for /r "%WORK%\ls" %%f in (LSMASHSource*.dll) do (
    if /i "%%~nxf"=="LSMASHSource.dll" if not defined LSD set "LSD=%%f"
)
for /r "%WORK%\ls" %%f in (LSMASHSource*.dll) do (
    set "P=%%~dpf"
    if /i "%%~nxf"=="LSMASHSource.dll" if not "!P:apour=!"=="!P!" set "LSD=%%f"
)
for /r "%WORK%\ls" %%f in (LSMASHSource*.dll) do (
    set "P=%%~dpf"
    if /i "%%~nxf"=="LSMASHSource.dll" if not "!P:apour=!"=="!P!" if not "!P:64=!"=="!P!" set "LSD=%%f"
)
call :log "L-SMASH Works: !LSD!"
if not defined LSD (
    set "FAILMSG=LSMASHSource.dll was not found in the L-SMASH Works download."
    goto :fail
)
copy /y "%LSD%" "%PLUG%\" >nul
call :log "KNLMeansCL and L-SMASH Works copied into the plugin folder."

REM vspipe: a native vspipe.exe when the files have one, else the Python entry point. Always a silent wrapper.
set "VX="
if exist "%STAGE%\vspipe.exe" set "VX=%STAGE%\vspipe.exe"
if not defined VX if exist "%STAGE%\Scripts\vspipe.exe" set "VX=%STAGE%\Scripts\vspipe.exe"
if not defined VX for /r "%STAGE%" %%f in (vspipe*.exe) do if /i "%%~nxf"=="vspipe.exe" set "VX=%%f"
>"%STAGE%\vspipe.bat" echo @echo off
>>"%STAGE%\vspipe.bat" echo set "PATH=%%~dp0;%%~dp0Scripts;%%PATH%%"
if not defined VX goto :vs_entry
set "VREL=!VX:%STAGE%\=!"
>>"%STAGE%\vspipe.bat" echo "%%~dp0!VREL!" %%*
call :log "vspipe: !VREL!"
goto :vs_test
:vs_entry
set "EP="
for /r "%SP%" %%e in (entry_points*.txt) do (
    for /f "usebackq tokens=1,* delims==" %%a in ("%%e") do (
        set "K=%%a"
        set "K=!K: =!"
        if /i "!K!"=="vspipe" set "EP=%%b"
    )
)
if not defined EP (
    set "FAILMSG=No vspipe was found in the VapourSynth files. Send logs\setup.log so the layout can be checked."
    goto :fail
)
set "EP=!EP: =!"
for /f "tokens=1,2 delims=:" %%a in ("!EP!") do (
    set "EPM=%%a"
    set "EPF=%%b"
)
>>"%STAGE%\vspipe.bat" echo "%%~dp0python.exe" -c "import sys; from !EPM! import !EPF! as m; sys.argv[0] = 'vspipe'; sys.exit(m())" %%*
call :log "vspipe runs through Python: !EPM!:!EPF!"

:vs_test
>"%WORK%\check.vpy" echo import vapoursynth as vs
>>"%WORK%\check.vpy" echo core = vs.core
>>"%WORK%\check.vpy" echo missing = [n for n in ('knlm', 'lsmas') if not hasattr(core, n)]
>>"%WORK%\check.vpy" echo if missing: raise vs.Error('Missing plugins: ' + ', '.join(missing))
>>"%WORK%\check.vpy" echo core.std.BlankClip(width=64, height=64, length=1).set_output()
call "%STAGE%\vspipe.bat" --info "%WORK%\check.vpy" >"%WORK%\vscheck.txt" 2>&1
if not errorlevel 1 goto :vs_swap
call :log "First check failed, running vapoursynth config and checking again."
"%STAGE%\python.exe" -m vapoursynth config >>"%WORK%\vscheck.txt" 2>&1
call "%STAGE%\vspipe.bat" --info "%WORK%\check.vpy" >>"%WORK%\vscheck.txt" 2>&1
if not errorlevel 1 goto :vs_swap
type "%WORK%\vscheck.txt"
type "%WORK%\vscheck.txt" >>"%LOG%"
set "FAILMSG=The new VapourSynth did not pass its check. Your current setup was not changed. Details are in logs\setup.log."
goto :fail
:vs_swap
if exist "%HERE%vs_old" rd /s /q "%HERE%vs_old"
if exist "%HERE%vs" ren "%HERE%vs" vs_old
ren "%STAGE%" vs
if errorlevel 1 (
    set "FAILMSG=Could not rename vs_new to vs. Close anything using the vs folder and try again."
    goto :fail
)
set "OKMSG=VapourSynth %AV1_VS_TAG% ready in vs with KNLMeansCL and L-SMASH Works."
goto :ok


REM ==================================================================
REM SVT-AV1: official source, compiled here
REM ==================================================================
:do_svt
if not defined AV1_SVT_TAG (
    set "FAILMSG=No SVT-AV1 version was given."
    goto :fail
)
REM v1: which encoder [mainline SVT-AV1 or a fork], where it goes, and the name of its backups
set "SVT_REPO=AOMediaCodec/SVT-AV1"
if defined AV1_SVT_REPO set "SVT_REPO=%AV1_SVT_REPO%"
set "SVT_DEST=%BIN%"
if defined AV1_SVT_DEST set "SVT_DEST=%AV1_SVT_DEST%"
set "SVT_BK=svt"
if defined AV1_SVT_BK set "SVT_BK=%AV1_SVT_BK%"
set "SVT_NAME=SVT-AV1"
if defined AV1_SVT_NAME set "SVT_NAME=%AV1_SVT_NAME%"
set "BLOG=%LOGDIR%\build_%SVT_BK%.log"
set "SVT_FEAT="
REM "Official build" button for the forks: skip compiling and take their own Windows build
if "%AV1_SVT_FORCEBIN%"=="1" if defined AV1_SVT_BINURL goto :svt_prebuilt
REM The official home is GitHub again since November 2026; GitLab is archived at 4.3.0 and only a fallback for mainline
call :get "https://github.com/%SVT_REPO%/archive/refs/tags/%AV1_SVT_TAG%.zip" "%WORK%\svt.zip" "%SVT_NAME% %AV1_SVT_TAG% source [GitHub %SVT_REPO%]"
if not errorlevel 1 goto :svt_have_src
if /i not "%SVT_REPO%"=="AOMediaCodec/SVT-AV1" (
    set "FAILMSG=The %SVT_NAME% source download failed."
    goto :fail
)
call :get "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/%AV1_SVT_TAG%/SVT-AV1-%AV1_SVT_TAG%.zip" "%WORK%\svt.zip" "SVT-AV1 %AV1_SVT_TAG% source [GitLab]"
if errorlevel 1 (
    set "FAILMSG=The SVT-AV1 source download failed."
    goto :fail
)
:svt_have_src
call :unpack "%WORK%\svt.zip" "%WORK%\src"
if errorlevel 1 (
    set "FAILMSG=Unpacking the SVT-AV1 source failed."
    goto :fail
)
set "SRC="
for /d %%d in ("%WORK%\src\*") do set "SRC=%%d"
for %%n in ("%AV1_NASM%") do set "PATH=%%~dpn;%PATH%"
for %%c in ("%AV1_CMAKE%") do set "PATH=%%~dpc;%PATH%"
call :log "Compiling %SVT_NAME% %AV1_SVT_TAG% with %AV1_GEN%%AV1_TOOLSET% - a few minutes. Full output: %BLOG%"
>"%BLOG%" echo %SVT_NAME% %AV1_SVT_TAG% build - %DATE% %TIME%
echo    1/3  Configuring...
cmake -S "%SRC%" -B "%SRC%\av1me_build" -G "%AV1_GEN%" -A x64%AV1_TOOLSET% "-DCMAKE_GENERATOR_INSTANCE=%AV1_VSPATH%" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_APPS=ON -DBUILD_TOOLS=ON %AV1_CMAKE_EXTRA% "-DCMAKE_ASM_NASM_COMPILER=%AV1_NASM_FWD%" >>"%BLOG%" 2>&1
if errorlevel 1 (
    if defined AV1_SVT_BINURL goto :svt_prebuilt
    set "FAILMSG=Configuring the %SVT_NAME% build failed. The build log opens in Notepad."
    start "" notepad "%BLOG%"
    goto :fail_pause
)
set "SVT_FEAT=Dolby Vision/HDR10+: no"
findstr /c:"dovi support - Yes" "%BLOG%" >nul 2>&1 && set "SVT_FEAT=Dolby Vision/HDR10+: yes"
echo    2/3  Compiling [only errors are shown here]...
cmake --build "%SRC%\av1me_build" --config Release --parallel -- /nologo /v:quiet "/clp:ErrorsOnly;Summary" "/flp:LogFile=%BLOG%;Append;Verbosity=normal"
if errorlevel 1 (
    if defined AV1_SVT_BINURL goto :svt_prebuilt
    set "FAILMSG=Compiling %SVT_NAME% failed. The build log opens in Notepad."
    start "" notepad "%BLOG%"
    goto :fail_pause
)
echo    3/3  Testing...
set "NSVT="
for /r "%SRC%" %%f in (SvtAv1EncApp*.exe) do if /i "%%~nxf"=="SvtAv1EncApp.exe" set "NSVT=%%f"
if not defined NSVT (
    set "FAILMSG=The build finished but SvtAv1EncApp.exe was not found."
    goto :fail
)
set "SVT_HOW=compiled"
:svt_test
call :log "Test encode with the new %SVT_NAME%..."
"%AV1_FFMPEG%" -v error -f lavfi -i testsrc2=s=640x360:d=2 -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - 2>nul | "%NSVT%" -i stdin --preset 12 --crf 40 -b "%WORK%\test.ivf" >nul 2>&1
set "TSZ=0"
if exist "%WORK%\test.ivf" for %%z in ("%WORK%\test.ivf") do set "TSZ=%%~zz"
if %TSZ% LSS 100 (
    set "FAILMSG=The new %SVT_NAME% failed its two second test encode, so nothing was changed."
    goto :fail
)
if not exist "%SVT_DEST%" md "%SVT_DEST%"
if not exist "%SVT_DEST%\SvtAv1EncApp.exe" goto :svt_copy
set "BK=%BIN%\backup\%SVT_BK%_%AV1_SVT_OLD%_%STAMP%"
md "%BK%" >nul 2>&1
copy /y "%SVT_DEST%\SvtAv1EncApp.exe" "%BK%\" >nul
for %%d in ("%SVT_DEST%\SvtAv1Enc*.dll") do copy /y "%%d" "%BK%\" >nul
call :log "Old %SVT_NAME% kept in %BK%"
:svt_copy
copy /y "%NSVT%" "%SVT_DEST%\SvtAv1EncApp.exe" >nul
if errorlevel 1 (
    set "FAILMSG=Could not copy SvtAv1EncApp.exe into bin. Is an encode still running?"
    goto :fail
)
set "OKMSG=%SVT_NAME% %AV1_SVT_TAG% %SVT_HOW% with %AV1_GEN%, tested and installed in %SVT_DEST%. %SVT_FEAT%"
goto :ok

:svt_prebuilt
REM Forks only: if this PC cannot compile them, their own official Windows build is used instead
call :log "Compiling %SVT_NAME% did not work here, so its official Windows build is used instead."
call :get "%AV1_SVT_BINURL%" "%WORK%\svtbin.%AV1_SVT_BINEXT%" "%SVT_NAME% Windows build"
if errorlevel 1 (
    set "FAILMSG=Neither compiling nor downloading %SVT_NAME% worked."
    goto :fail_pause
)
call :unpack "%WORK%\svtbin.%AV1_SVT_BINEXT%" "%WORK%\svtbin"
if errorlevel 1 (
    set "FAILMSG=Unpacking the %SVT_NAME% Windows build failed."
    goto :fail
)
set "NSVT="
for /r "%WORK%\svtbin" %%f in (SvtAv1EncApp*.exe) do set "NSVT=%%f"
if not defined NSVT (
    set "FAILMSG=The %SVT_NAME% Windows build has no SvtAv1EncApp.exe in it."
    goto :fail
)
set "SVT_HOW=official Windows build"
set "AV1_GEN=its own toolchain"
set "SVT_FEAT=Dolby Vision/HDR10+: as its authors built it"
goto :svt_test


REM ==================================================================
REM Helpers
REM ==================================================================
:get
REM %1 = url, %2 = file, %3 = label
call :log "Downloading %~3"
"%CURL%" -L --fail --retry 3 --retry-delay 2 -A RazAV1 -o "%~2" "%~1"
if errorlevel 1 exit /b 1
if not exist "%~2" exit /b 1
for %%z in ("%~2") do if %%~zz LSS 1000 exit /b 1
exit /b 0

:unpack
REM %1 = archive, %2 = new folder. tar.exe first; 7-Zip for what tar cannot open [.7z]
if exist "%~2" rd /s /q "%~2"
md "%~2"
echo Unpacking %~nx1 ...
"%TAR%" -xf "%~1" -C "%~2" 2>nul
if not errorlevel 1 exit /b 0
set "SZ=%ProgramFiles%\7-Zip\7z.exe"
if not exist "%SZ%" exit /b 1
"%SZ%" x -y -o"%~2" "%~1" >nul
if errorlevel 1 exit /b 1
exit /b 0

:log
>>"%LOG%" echo(%DATE% %TIME%  %~1
echo %~1
exit /b 0

:ok
call :log "%OKMSG%"
>"%RES%" echo OK^|%OKMSG%
if exist "%WORK%" rd /s /q "%WORK%"
rd "%HERE%_work" >nul 2>&1
echo.
echo Done. This window closes by itself.
timeout /t 3 >nul
exit /b 0

:fail_pause
call :log "FAILED: %FAILMSG%"
>"%RES%" echo FAIL^|%FAILMSG%
echo.
echo The window stays open so you can read what went wrong.
pause
if exist "%WORK%" rd /s /q "%WORK%"
rd "%HERE%_work" >nul 2>&1
exit /b 1

:fail
call :log "FAILED: %FAILMSG%"
>"%RES%" echo FAIL^|%FAILMSG%
if exist "%WORK%" rd /s /q "%WORK%"
rd "%HERE%_work" >nul 2>&1
echo.
echo Setup step failed: %FAILMSG%
echo This window closes in 20 seconds.
timeout /t 20 >nul
exit /b 1
