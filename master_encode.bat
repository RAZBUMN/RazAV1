@echo off
if /i "%~1"=="--audio-worker" goto :audio_worker
if /i "%~1"=="--install-sendto" goto :install_sendto
setlocal disabledelayedexpansion
title RazAV1
set "JOB_FILE="
if /i "%~1"=="--job" set "JOB_FILE=%~2"

REM NOTE: file names containing an exclamation mark are not supported. They are skipped with a message.
REM Drop files or folders on this script for the console menus, or use "RazAV1.cmd" for the window.
REM bin, tables and vs folders next to this script are used first [portable pack].
REM v7: KNLMeansCL calibrates itself against the hqdn3d levels, probes get a quality score, the window shows this output.

set "VER=v1.0.1"
set "SELF=%~f0"
set "HERE=%~dp0"
set "HELPER=%~dp0av1_helper.ps1"
set "PRESETS=%~dp0presets.ini"
set "LAST_INI=%~dp0last_settings.ini"
set "CONFIG=%~dp0av1_config.ini"
set "OLD_CP="
for /f "tokens=2 delims=:." %%c in ('chcp') do set "OLD_CP=%%c"
chcp 65001 >nul

REM ==================================================================
REM Settings: these are defaults. av1_config.ini next to this script overrides them,
REM and the GUI Settings window writes that file. Encode recipes live in the profiles folder.
REM ==================================================================
set "SVT_EXE=C:\GrainTables\SvtAv1EncApp.exe"
set "DIR_TABLES=C:\GrainTables"
set "VSPIPE=vspipe"
set "KNLM_DEVICE=0"
set "AUTO_WAIT=60"
set "PREF_LANG=eng"
set "DEFAULT_PROFILE=RAZ Triangle"
REM CPU mode: max = AboveNormal + EcoQoS off + all cores, normal = EcoQoS off, low = BelowNormal
set "CPU_MODE=max"
REM When the whole queue is done: none, sleep or shutdown
set "WHEN_DONE=none"
REM Extra helper options for the adaptive plan, for example: -Gain 4 -MinSeg 10
set "PLAN_EXTRA="
REM Score every probe against the source [VMAF, or SSIM when ffmpeg has no libvmaf]: 1 = on, 0 = off
set "QUALITY=1"

if exist "%CONFIG%" goto :config_ready
>"%CONFIG%" echo # RazAV1 settings. The GUI writes this file; the .bat reads it.
>>"%CONFIG%" echo SVT_EXE=%SVT_EXE%
>>"%CONFIG%" echo DIR_TABLES=%DIR_TABLES%
>>"%CONFIG%" echo VSPIPE=%VSPIPE%
>>"%CONFIG%" echo KNLM_DEVICE=%KNLM_DEVICE%
>>"%CONFIG%" echo PREF_LANG=%PREF_LANG%
>>"%CONFIG%" echo AUTO_WAIT=%AUTO_WAIT%
>>"%CONFIG%" echo DEFAULT_PROFILE=%DEFAULT_PROFILE%
>>"%CONFIG%" echo QUALITY=%QUALITY%
:config_ready
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%CONFIG%") do set "%%A=%%B"

REM Portable pack: bin, tables and vs folders next to this script win over the settings above,
REM so the whole folder can be copied to another PC and run as it is.
if exist "%HERE%bin\ffmpeg.exe" set "PATH=%HERE%bin;%PATH%"
if exist "%HERE%bin\SvtAv1EncApp.exe" set "SVT_EXE=%HERE%bin\SvtAv1EncApp.exe"
dir /s /b "%HERE%tables\*.tbl" >nul 2>&1 && set "DIR_TABLES=%HERE%tables"
REM v1: grain tables are generated when missing, so the tables folder next to the script is always usable
if not exist "%DIR_TABLES%\" set "DIR_TABLES=%HERE%tables"
if not exist "%DIR_TABLES%\" mkdir "%DIR_TABLES%" >nul 2>&1
if exist "%HERE%vs\vspipe.exe" set "VSPIPE=%HERE%vs\vspipe.exe"
if exist "%HERE%vs\vspipe.bat" set "VSPIPE=%HERE%vs\vspipe.bat"

REM ==================================================================
REM Collect the queue: every file or folder dropped on the script
REM ==================================================================
set /a QN=0
if defined JOB_FILE goto :collected
:collect
if "%~1"=="" goto :collected
set "QATTR=-"
for %%A in ("%~1") do set "QATTR=%%~aA-"
if /i "%QATTR:~0,1%"=="d" (
    for %%F in ("%~1\*.mkv" "%~1\*.mp4" "%~1\*.m4v" "%~1\*.m2ts" "%~1\*.ts" "%~1\*.mov" "%~1\*.avi" "%~1\*.webm") do call :queue_add "%%~fF" folder
) else (
    call :queue_add "%~f1" file
)
shift
goto :collect
:collected

setlocal enabledelayedexpansion
set "GUI_MODE=0"
if defined JOB_FILE call "%JOB_FILE%"

if %QN% GTR 0 goto :have_queue
cls
echo ====================================================================
echo           RAZAV1 %VER%
echo ====================================================================
echo No video files were given.
echo Drop one or more video files, or a whole folder, onto this script.
echo.
echo  [S] Add "RazAV1" to the right-click Send To menu
echo  [Q] Quit
choice /c SQ /n /m "Select: "
if errorlevel 2 exit /b 1
goto :install_sendto
:have_queue

REM ------------------------------------------------------------------
REM Pre-flight checks
REM ------------------------------------------------------------------
REM Jobs from the window name an encoder per file and are checked file by file
if defined JOB_FILE goto :svt_checked
if not exist "%SVT_EXE%" (
    echo [ERROR] SvtAv1EncApp.exe not found at: "%SVT_EXE%"
    pause
    exit /b 1
)
:svt_checked
if not exist "%HELPER%" (
    echo [ERROR] av1_helper.ps1 must sit next to this script:
    echo         "%HELPER%"
    pause
    exit /b 1
)
for %%X in (ffmpeg ffprobe powershell) do (
    where %%X >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] %%X was not found in PATH.
        pause
        exit /b 1
    )
)
set "HAS_ZSCALE=1"
ffmpeg -hide_banner -filters 2>nul | findstr /c:" zscale " >nul
if errorlevel 1 set "HAS_ZSCALE=0"

REM VapourSynth with KNLMeansCL [GPU denoise]. Without it every encode uses hqdn3d, exactly like v4.3.
set "HAS_VS=0"
set "VS_EXE="
set "VS_NOTE=not checked"
for /f "usebackq tokens=1,* delims=|" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode vscheck -Vspipe "%VSPIPE%"`) do (
    if "%%A"=="OK" (
        set "HAS_VS=1"
        set "VS_EXE=%%B"
    ) else (
        set "VS_NOTE=%%B"
    )
)
call :load_profile "%DEFAULT_PROFILE%"

set "WFN_1=1080p Movie"
set "WFN_2=1080p TV Episode"
set "WFN_3=4K SDR to 1080p"
set "WFN_4=4K HDR to 1080p SDR"
set "WFN_5=Anime"
set "WFN_6=4K SDR to 4K SDR"
set "WFN_7=4K HDR to 4K HDR10"
set "GRN_S_1=Static, no grain"
set "GRN_S_2=Static, ISO200 grain"
set "GRN_S_3=Static, ISO400 grain"
set "GRN_S_4=Static, ISO800 grain"
set "GRN_A_1=Adaptive"
set "GRN_A_2=Adaptive, light grain"
set "GRN_A_3=Adaptive, medium grain"
set "GRN_A_4=Adaptive, heavy grain"

set "RUN_ID=%RANDOM%%RANDOM%"
set "RUN_FLAG=%TEMP%\av1_run_%RUN_ID%.flag"
set "WATCH_INFO=%TEMP%\av1_watch_%RUN_ID%.txt"
set "VID_PROG=%TEMP%\av1_vprog_%RUN_ID%.txt"
set "RESULTS=%TEMP%\av1_results_%RUN_ID%.txt"
set "STATUS_FILE="
set "STOP_FILE="
if not defined JOB_DIR goto :runfiles_done
set "RUN_FLAG=%JOB_DIR%\run.flag"
set "WATCH_INFO=%JOB_DIR%\watch.txt"
set "VID_PROG=%JOB_DIR%\vprog.txt"
set "RESULTS=%JOB_DIR%\results.txt"
set "STATUS_FILE=%JOB_DIR%\status.txt"
set "STOP_FILE=%JOB_DIR%\stop.flag"
:runfiles_done
set "UNATTENDED=0"
if %QN% GTR 1 set "UNATTENDED=1"
if "%GUI_MODE%"=="1" set "UNATTENDED=1"

REM ------------------------------------------------------------------
REM Presets and last settings
REM ------------------------------------------------------------------
if exist "%PRESETS%" goto :presets_ready
>"%PRESETS%" echo # One preset per line: name^|workflow^|mode^|grain^|crf^|subs      [up to 9 presets]
>>"%PRESETS%" echo # workflow: 1=1080p movie 2=1080p TV 3=4K SDR to 1080p 4=4K HDR to 1080p SDR 5=anime 6=4K SDR to 4K 7=4K HDR to 4K HDR10
>>"%PRESETS%" echo # mode: 1=static 2=adaptive     subs: 1=keep 0=drop
>>"%PRESETS%" echo # grain, static: 1=none 2=ISO200 3=ISO400 4=ISO800     grain, adaptive: 2=light 3=medium 4=heavy
>>"%PRESETS%" echo 35mm Movie, adaptive^|1^|2^|3^|30^|0
>>"%PRESETS%" echo TV Episode^|2^|1^|2^|26^|0
>>"%PRESETS%" echo Anime, subs kept^|5^|1^|1^|26^|1
>>"%PRESETS%" echo 4K HDR to 1080p SDR, adaptive^|4^|2^|3^|30^|0
>>"%PRESETS%" echo 4K HDR to 4K HDR10, adaptive^|7^|2^|3^|30^|0
:presets_ready

set /a PN=0
for /f "usebackq eol=# tokens=1-6 delims=|" %%A in ("%PRESETS%") do (
    if !PN! LSS 9 (
        set /a PN+=1
        set "P!PN!_NAME=%%A"
        set "P!PN!_SRC=%%B"
        set "P!PN!_MODE=%%C"
        set "P!PN!_GRAIN=%%D"
        set "P!PN!_CRF=%%E"
        set "P!PN!_SUBS=%%F"
    )
)

set "L_SRC="
if exist "%LAST_INI%" for /f "usebackq eol=# tokens=1-6 delims=|" %%A in ("%LAST_INI%") do (
    set "L_SRC=%%B"
    set "L_MODE=%%C"
    set "L_GRAIN=%%D"
    set "L_CRF=%%E"
    set "L_SUBS=%%F"
)

if "%GUI_MODE%"=="1" goto :run_queue

set "FIRST=!Q_1!"
for %%I in ("!FIRST!") do set "FIRST_NAME=%%~nI"
set "SI_SRC=!FIRST!"
call :srcinfo

REM ------------------------------------------------------------------
REM Start screen: last settings, presets or manual
REM ------------------------------------------------------------------
:start_screen
cls
echo ====================================================================
echo           RAZAV1 %VER%
echo ====================================================================
if %QN% EQU 1 (
    echo Input:    "!FIRST_NAME!"
) else (
    echo Queue:    %QN% files, first: "!FIRST_NAME!"
)
echo Source:   !SI_TEXT!
echo           suggested workflow: !SI_SUGGEST!. !WFN_%SI_SUGGEST%!
echo.
set "KEYS="
if defined L_SRC (
    call :describe !L_SRC! !L_MODE! !L_GRAIN! !L_CRF! !L_SUBS!
    echo  [R] Last settings
    echo        !DESC!
    set "KEYS=R"
)
for /l %%i in (1,1,%PN%) do (
    call :describe !P%%i_SRC! !P%%i_MODE! !P%%i_GRAIN! !P%%i_CRF! !P%%i_SUBS!
    echo  [%%i] !P%%i_NAME!
    echo        !DESC!
    set "KEYS=!KEYS!%%i"
)
echo  [M] Choose everything by hand
set "KEYS=!KEYS!M"
echo.
if defined L_SRC (
    choice /c !KEYS! /n /t %AUTO_WAIT% /d R /m "Select [R is picked in %AUTO_WAIT% s]: "
) else (
    choice /c !KEYS! /n /m "Select: "
)
set /a KI=%errorlevel%-1
if %KI% LSS 0 goto :start_screen
for %%i in (!KI!) do set "K=!KEYS:~%%i,1!"

if /i "!K!"=="M" (
    call :menu_defaults L
    call :menu_manual
    goto :settings_chosen
)
if /i "!K!"=="R" (
    set "S_SRC=!L_SRC!"
    set "S_MODE=!L_MODE!"
    set "S_GRAIN=!L_GRAIN!"
    set "S_CRF=!L_CRF!"
    set "S_SUBS=!L_SUBS!"
    goto :settings_chosen
)
set "S_SRC=!P%K%_SRC!"
set "S_MODE=!P%K%_MODE!"
set "S_GRAIN=!P%K%_GRAIN!"
set "S_CRF=!P%K%_CRF!"
set "S_SUBS=!P%K%_SUBS!"

:settings_chosen
call :validate

REM ------------------------------------------------------------------
REM Ready screen: one last look, then everything runs on its own
REM ------------------------------------------------------------------
:go_screen
call :describe %S_SRC% %S_MODE% %S_GRAIN% %S_CRF% %S_SUBS%
set "SI_SRC=!FIRST!"
set "SRC=%S_SRC%"
call :effective_wf
call :cpu_text
cls
echo ====================================================================
echo           RAZAV1 %VER% - READY
echo ====================================================================
echo Settings:   !DESC!
if %QN% EQU 1 (
    echo Input:      "!FIRST_NAME!"
) else (
    echo Queue:      %QN% files - each gets its own crop, plan and audio pick, no questions in between
)
echo Profile:    !PF_name!  [preset !PF_preset!, dark-scene QP bias !PF_luma_bias!, QM !PF_enable_qm!]
call :dn_text_global
echo Denoiser:   !DN_GLOBAL!
echo CPU mode:   !CPU_TEXT!
echo When done:  !WHEN_DONE!
if defined WF_FAIL echo [WARNING] First file: !WF_FAIL!
if defined WF_NOTE echo [NOTE] First file: !WF_NOTE!
echo.
echo  [G] Go   [M] Change settings   [P] CPU mode   [D] When done   [N] Denoiser
choice /c GMPDN /n /t %AUTO_WAIT% /d G /m "Select [G is picked in %AUTO_WAIT% s]: "
if errorlevel 5 goto :go_cycle_dn
if errorlevel 4 goto :go_cycle_done
if errorlevel 3 goto :go_cycle_cpu
if errorlevel 2 goto :go_manual
goto :go_start

:go_cycle_done
if /i "%WHEN_DONE%"=="none" (set "WHEN_DONE=sleep") else if /i "%WHEN_DONE%"=="sleep" (set "WHEN_DONE=shutdown") else (set "WHEN_DONE=none")
goto :go_screen

:go_cycle_dn
if /i "%PF_denoiser%"=="knlm" (set "PF_denoiser=hqdn3d") else (set "PF_denoiser=knlm")
goto :go_screen

:go_cycle_cpu
if /i "%CPU_MODE%"=="max" (set "CPU_MODE=normal") else if /i "%CPU_MODE%"=="normal" (set "CPU_MODE=low") else (set "CPU_MODE=max")
goto :go_screen

:go_manual
call :menu_defaults S
call :menu_manual
call :validate
goto :go_screen

:go_start
>"%LAST_INI%" echo Last^|%S_SRC%^|%S_MODE%^|%S_GRAIN%^|%S_CRF%^|%S_SUBS%

:run_queue
REM CPU enforcer and window-title progress run in the background for the whole queue
type nul >"%RUN_FLAG%"
start "" /b powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Mode watch -FlagFile "%RUN_FLAG%" -InfoFile "%WATCH_INFO%" -ProgressFile "%VID_PROG%" -CpuMode %CPU_MODE%

for /l %%N in (1,1,%QN%) do call :process_file %%N

REM ------------------------------------------------------------------
REM Queue finished
REM ------------------------------------------------------------------
del "%RUN_FLAG%" >nul 2>&1
if exist "%WATCH_INFO%" del "%WATCH_INFO%" >nul 2>&1
set "ST_STAGE=finished"
set "ST_DETAIL="
call :status
timeout /t 1 /nobreak >nul
title RazAV1 %VER% - finished
set /a N_OK=0, N_FAIL=0, N_SKIP=0
echo.
echo ====================================================================
echo QUEUE FINISHED
echo ====================================================================
if exist "%RESULTS%" for /f "usebackq tokens=1-4 delims=|" %%A in ("%RESULTS%") do (
    if "%%A"=="OK" (
        set /a N_OK+=1
        echo   [OK]   %%B  -  %%C, %%D
    )
    if "%%A"=="FAIL" (
        set /a N_FAIL+=1
        echo   [FAIL] %%B  -  %%C
    )
    if "%%A"=="SKIP" (
        set /a N_SKIP+=1
        echo   [SKIP] %%B  -  %%C
    )
    if "%%A"=="PLAN" (
        set /a N_OK+=1
        echo   [PLAN] %%B  -  %%C
    )
)
echo ====================================================================
if not "%GUI_MODE%"=="1" if exist "%RESULTS%" del "%RESULTS%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode notify -Title "RazAV1 %VER%" -Text "%N_OK% finished, %N_FAIL% failed, %N_SKIP% skipped" >nul 2>&1

if /i "%WHEN_DONE%"=="none" goto :run_end
echo.
choice /c YN /t %AUTO_WAIT% /d Y /m "%WHEN_DONE% in %AUTO_WAIT% s. Press N to cancel"
if errorlevel 2 goto :run_end
if /i "%WHEN_DONE%"=="shutdown" (
    shutdown /s /t 30 /c "RazAV1 finished. Run: shutdown /a to cancel."
    exit /b 0
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode power -Action sleep
:run_end
if defined OLD_CP chcp %OLD_CP% >nul
if "%GUI_MODE%"=="1" exit /b 0
pause
exit /b 0


REM ==================================================================
REM One file, start to finish
REM ==================================================================
:process_file
setlocal
set "QI=%~1"
set "INPUT=!Q_%QI%!"
if not defined STOP_FILE goto :pf_not_stopped
if not exist "%STOP_FILE%" goto :pf_not_stopped
>>"%RESULTS%" echo(SKIP^|!INPUT!^|stopped before it started
exit /b 0
:pf_not_stopped
if not defined JOB_DIR goto :pf_item_loaded
REM v1: never encode with blank settings. A missing or unreadable settings file stops this file.
set "S_SRC="
if not exist "%JOB_DIR%\item_%QI%.cmd" goto :pf_item_missing
call "%JOB_DIR%\item_%QI%.cmd"
if defined S_SRC goto :pf_item_loaded
:pf_item_missing
echo [ERROR] The settings for this file could not be read: "%JOB_DIR%\item_%QI%.cmd"
echo         Check that your antivirus did not block or remove it, then start again.
>>"%RESULTS%" echo(FAIL^|!INPUT!^|its settings file could not be read [antivirus?]: %JOB_DIR%\item_%QI%.cmd
exit /b 0
:pf_item_loaded
REM v1: every file can use its own encoder [SVT-AV1, -Essential or -HDR]
if defined S_SVT_EXE set "SVT_EXE=!S_SVT_EXE!"
if not defined S_ENC_NAME set "S_ENC_NAME=SVT-AV1"
if exist "!SVT_EXE!" goto :pf_enc_ok
>>"%RESULTS%" echo(FAIL^|!INPUT!^|!S_ENC_NAME! is not installed: open Setup and updates
exit /b 0
:pf_enc_ok
for %%I in ("!INPUT!") do (
    set "OUTDIR=%%~dpI"
    set "BASENAME=%%~nI"
    set "INEXT=%%~xI"
)
REM v1: output folder from the Output tab [blank = next to the source]. Work files go there too.
if not defined PF_out_dir goto :pf_outdir_done
set "OUTDIR=!PF_out_dir!"
if not "!OUTDIR:~-1!"=="\" set "OUTDIR=!OUTDIR!\"
if not exist "!OUTDIR!" mkdir "!OUTDIR!" >nul 2>&1
if exist "!OUTDIR!" goto :pf_outdir_done
>>"%RESULTS%" echo(FAIL^|!INPUT!^|cannot create the output folder !OUTDIR!
exit /b 0
:pf_outdir_done
set "RAW_VIDEO=!OUTDIR!!BASENAME!_temp_raw.ivf"
set "RAW_AUDIO=!OUTDIR!!BASENAME!_temp_audio.opus"
if /i "%PF_audio_format%"=="copy" set "RAW_AUDIO=!OUTDIR!!BASENAME!_temp_audio.mka"
set "PREVIEW_REEL=!OUTDIR!!BASENAME!_preview_reel.mkv"
set "AUDIO_STATUS=!OUTDIR!!BASENAME!_audio.status"
set "AUDIO_PROG=!OUTDIR!!BASENAME!_audio.progress"
set "RESUME_FILE=!OUTDIR!!BASENAME!_resume.txt"
set "ADAPT_DIR=!OUTDIR!!BASENAME!_plan"
if not exist "!ADAPT_DIR!\plan.csv" if exist "!OUTDIR!!BASENAME!_v4.2_plan\plan.csv" set "ADAPT_DIR=!OUTDIR!!BASENAME!_v4.2_plan"
set "FAIL_REASON="
set "PROBE_DIR="
set "LOG="
set "EST_TIME=N/A"
set "EST_GB=N/A"
set "SUB_RETRY=0"
set "SUBS_TEXT=dropped"
if "%S_SUBS%"=="1" set "SUBS_TEXT=all tracks kept, plus font attachments"
if defined SUB_SEL set "SUBS_TEXT=selected tracks kept, plus font attachments"
set "ST_STAGE=analysing"
set "ST_DETAIL="
set "ST_REEL="
set "DUR_CROP=-"
set "DUR_PLAN=-"
set "DUR_PROBES=-"
set "DUR_VIDEO=-"
set "DUR_FINISH=-"
call :now_unix TA0
call :cpu_text

title [!QI!/!QN!] Analysing - !BASENAME!
call :status
cls
echo ====================================================================
echo [!QI!/!QN!] Analysing: "!BASENAME!"
echo ====================================================================
if not exist "!INPUT!" (
    set "FAIL_REASON=Input file not found."
    goto :pf_fail
)

set "TOTAL_SEC="
for /f "tokens=*" %%a in ('ffprobe -v error -show_entries "format=duration" -of "default=nokey=1:noprint_wrappers=1" "%INPUT%" 2^>nul') do set "TOTAL_SEC=%%a"
echo %TOTAL_SEC%|findstr /r "^[0-9][0-9]*\.*[0-9]*$" >nul
if errorlevel 1 set "TOTAL_SEC=7200"

set "SI_SRC=!INPUT!"
call :srcinfo
set "SRC=%S_SRC%"
call :effective_wf
echo    - Source: !SI_TEXT!
if defined WF_FAIL (
    set "FAIL_REASON=!WF_FAIL!"
    goto :pf_fail
)
if defined WF_NOTE echo    - [NOTE] !WF_NOTE!
if "%SRC%"=="4" if "%HAS_ZSCALE%"=="0" (
    set "FAIL_REASON=This ffmpeg build has no zscale [libzimg] filter, which the HDR tonemap needs."
    goto :pf_fail
)

REM ------------------------------------------------------------------
REM Resume: a finished video stream from an earlier run
REM ------------------------------------------------------------------
set "RESUME=0"
if exist "!RESUME_FILE!" if exist "!RAW_VIDEO!" set "RESUME=1"
if "%RESUME%"=="0" goto :pf_fresh
echo.
echo A finished video stream from an earlier run was found:
echo    "!RAW_VIDEO!"
if "%UNATTENDED%"=="1" goto :pf_resume
choice /c YN /t %AUTO_WAIT% /d Y /m "Keep it and only redo audio and mux [Y], or start over [N]"
if errorlevel 2 goto :pf_fresh_clean
goto :pf_resume

:pf_fresh_clean
if exist "!RAW_VIDEO!" del "!RAW_VIDEO!" >nul 2>&1
:pf_fresh
if exist "!RESUME_FILE!" del "!RESUME_FILE!" >nul 2>&1
goto :pf_normal

:pf_resume
set "FINAL_OUTPUT="
< "%RESUME_FILE%" (
    set /p "FINAL_OUTPUT="
    set /p "FPS="
    set /p "AUD_IDX="
    set /p "AUD_LANG="
    set /p "ENC_NOTE="
)
if not defined FINAL_OUTPUT goto :pf_fresh_clean
set "LOG=!FINAL_OUTPUT:~0,-4!.log"
>>"%LOG%" echo(%DATE% %TIME%  Resumed: video stream reused, audio and mux redone
call :now_unix T0
set "TV=!T0!"
call :audio_topology
set "AUDIO_OK=0"
set "AST=1"
if exist "%AUDIO_STATUS%" if exist "%RAW_AUDIO%" set /p AST=<"%AUDIO_STATUS%"
if "!AST!"=="0" set "AUDIO_OK=1"
if "%AUDIO_OK%"=="1" (
    echo    - The audio from the earlier run is complete too.
    goto :pf_audio_check
)
echo.
echo [4/6] Encoding audio...
title [!QI!/!QN!] Audio - !BASENAME!
if exist "%RAW_AUDIO%" del "%RAW_AUDIO%" >nul 2>&1
call :audio_encode
goto :pf_audio_check

:pf_normal
REM ------------------------------------------------------------------
REM Audio track and topology
REM ------------------------------------------------------------------
if "%AUD_FIXED%"=="1" goto :pf_aud_fixed
call :pick_audio
:pf_aud_fixed
if "%AUD_IDX%"=="-1" (
    set "FAIL_REASON=The file has no audio track."
    goto :pf_fail
)
call :audio_topology

REM ------------------------------------------------------------------
REM Analysis: frame rate, letterbox crop
REM ------------------------------------------------------------------
echo.
echo [1/6] Reading media parameters and scanning the whole film for black bars...
set "FPS="
for /f "tokens=*" %%F in ('ffprobe -v error -select_streams v:0 -show_entries "stream=r_frame_rate" -of "default=nokey=1:noprint_wrappers=1" "%INPUT%" 2^>nul') do set "FPS=%%F"
if "%FPS%"=="" set "FPS=24000/1001"
if "%FPS%"=="0/0" set "FPS=24000/1001"
echo    - Source frame rate: %FPS%
set "FPSN=24000"
set "FPSD=1001"
for /f "tokens=1,2 delims=/" %%a in ("%FPS%") do (
    set "FPSN=%%a"
    set "FPSD=%%b"
)
if not defined FPSD set "FPSD=1"
for /f "tokens=1 delims=." %%a in ("%FPSN%") do set "FPSN=%%a"
for /f "tokens=1 delims=." %%a in ("%FPSD%") do set "FPSD=%%a"
set /a "P15=15*FPSN/FPSD"

REM Short clips across the whole film [40 per hour, 2 seconds each].
REM The crop is widened to cover every aspect ratio found, so mixed-ratio films keep their full picture.
set "CROP_LIST=%TEMP%\svt_crop_%RANDOM%%RANDOM%.txt"
set "CROP_PTS=%TEMP%\svt_croppts_%RANDOM%%RANDOM%.txt"
if exist "%CROP_LIST%" del "%CROP_LIST%" >nul 2>&1

set "SRC_W=0"
set "SRC_H=0"
for /f "tokens=1,2 delims=," %%W in ('ffprobe -v error -select_streams v:0 -show_entries "stream=width,height" -of "csv=p=0" "%INPUT%" 2^>nul') do (
    set "SRC_W=%%W"
    set "SRC_H=%%X"
)

set "DETECTED_CROP="
set "CROP_FILTER="
set "CROP_UNION="
if /i "%PF_crop%"=="off" (
    echo    - Crop: off [full frame kept, as set for this file]
    goto :pf_crop_done
)

powershell -NoProfile -Command ^
  "$dur = [double]('%TOTAL_SEC%');" ^
  "$count = [int][math]::Max(20, [math]::Round($dur / 3600.0 * 40));" ^
  "$start = $dur * 0.04;" ^
  "$step = ($dur * 0.90) / $count;" ^
  "for ($i = 0; $i -lt $count; $i++) { [math]::Floor($start + ($i + 0.5) * $step) }" > "%CROP_PTS%"

set "CROP_N=0"
for /f %%A in ('type "%CROP_PTS%" ^| find /c /v ""') do set "CROP_N=%%A"
echo    - Scanning %CROP_N% short clips for aspect ratio changes [source %SRC_W%x%SRC_H%]...
for /f "usebackq tokens=*" %%P in ("%CROP_PTS%") do call :cropscan %%P
echo.

REM Merge: ignore one-off outlier clips, widen to the bounding box of the rest, snap near-full edges to full frame
set "CROP_UNION="
set "CROP_TOP="
set "CROP_KINDS=0"
set "CROP_SEEN=0"
for /f "usebackq tokens=1-4 delims=|" %%A in (`powershell -NoProfile -Command ^
  "$srcW = [int]'%SRC_W%'; $srcH = [int]'%SRC_H%';" ^
  "function Snap($s) { $p = $s -split ':'; $w = [int]$p[0]; $h = [int]$p[1]; $x = [int]$p[2]; $y = [int]$p[3]; if ($srcW -gt 0 -and ($srcW - $w) -le 16) { $x = 0; $w = $srcW }; if ($srcH -gt 0 -and ($srcH - $h) -le 16) { $y = 0; $h = $srcH }; return ('{0}:{1}:{2}:{3}' -f $w, $h, $x, $y) };" ^
  "$c = @(Get-Content '%CROP_LIST%' -ErrorAction SilentlyContinue | Where-Object { $_ -match '^[0-9]+:[0-9]+:[0-9]+:[0-9]+$' } | ForEach-Object { Snap $_ });" ^
  "if ($c.Count -eq 0) { exit };" ^
  "$groups = @($c | Group-Object | Sort-Object Count -Descending);" ^
  "$min = 1; if ($c.Count -ge 10) { $min = 2 };" ^
  "$use = @($groups | Where-Object { $_.Count -ge $min });" ^
  "if ($use.Count -eq 0) { $use = $groups };" ^
  "$x1 = 99999; $y1 = 99999; $x2 = 0; $y2 = 0;" ^
  "foreach ($g in $use) { $p = $g.Name -split ':'; $w = [int]$p[0]; $h = [int]$p[1]; $x = [int]$p[2]; $y = [int]$p[3]; if ($x -lt $x1) { $x1 = $x }; if ($y -lt $y1) { $y1 = $y }; if (($x + $w) -gt $x2) { $x2 = $x + $w }; if (($y + $h) -gt $y2) { $y2 = $y + $h } };" ^
  "('{0}:{1}:{2}:{3}|{4}|{5}|{6}' -f ($x2 - $x1), ($y2 - $y1), $x1, $y1, $groups[0].Name, $groups.Count, $c.Count)"`) do (
    set "CROP_UNION=%%A"
    set "CROP_TOP=%%B"
    set "CROP_KINDS=%%C"
    set "CROP_SEEN=%%D"
)
if exist "%CROP_LIST%" del "%CROP_LIST%" >nul 2>&1
if exist "%CROP_PTS%" del "%CROP_PTS%" >nul 2>&1

set "DETECTED_CROP="
set "CROP_FILTER="
if not defined CROP_UNION goto :pf_crop_none
if not "!CROP_TOP!"=="!CROP_UNION!" echo    - [NOTE] Aspect ratio varies: most common area !CROP_TOP!, covering all scenes needs !CROP_UNION!.
if "!CROP_UNION!"=="!SRC_W!:!SRC_H!:0:0" goto :pf_crop_none
set "DETECTED_CROP=crop=!CROP_UNION!"
set "CROP_FILTER=!DETECTED_CROP!,"
echo    - Crop: !DETECTED_CROP! [from !CROP_SEEN! clips, !CROP_KINDS! distinct shapes]
goto :pf_crop_done
:pf_crop_none
echo    - Full frame [no black bars, or mixed aspect ratios that need the whole frame].
:pf_crop_done
set "CUT_CROP=%DETECTED_CROP%"
if not defined CUT_CROP set "CUT_CROP=null"
set "CROP_BOX="
if defined DETECTED_CROP set "CROP_BOX=!CROP_UNION!"
call :now_unix TA1
call :dur TA1 TA0 DUR_CROP

REM ------------------------------------------------------------------
REM Video pipeline
REM ------------------------------------------------------------------
set "KEYINT=120"
set "VB_STRENGTH=%PF_vb_strength%"
set "BASE_SCALE="
set "TABLE_HDR=0"
set "COLOR_OPTS=--color-primaries bt709 --transfer-characteristics bt709 --matrix-coefficients bt709 --color-range studio"
set "HDR_OPTS="
set "TAG_SRC=1080p"

if "%SRC%"=="2" set "TAG_SRC=TVShow"
if "%SRC%"=="3" (
    set "BASE_SCALE=scale=1920:-2:flags=lanczos,"
    set "TAG_SRC=4Kto1080p"
)
if "%SRC%"=="4" (
    set "BASE_SCALE=zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p10le,scale=1920:-2:flags=lanczos,"
    set "TAG_SRC=HDRtoSDR_4Kto1080p"
)
if "%SRC%"=="5" (
    set "TAG_SRC=Anime"
    set "KEYINT=240"
    set "VB_STRENGTH=1"
)
if "%SRC%"=="6" set "TAG_SRC=4K_SDR"
if "%SRC%"=="7" (
    set "TAG_SRC=4K_HDR10"
    set "TABLE_HDR=1"
)

REM v1: a smaller output size chosen in the window [only ever scales down; the tonemap workflow keeps its 1080p]
set "TARGET_W="
if defined PF_resize if not "%SRC%"=="4" if %SRC_W% GTR %PF_resize% set "TARGET_W=%PF_resize%"
if defined TARGET_W set "BASE_SCALE=scale=%TARGET_W%:-2:flags=lanczos,"
if "%TARGET_W%"=="1280" set "TAG_SRC=!TAG_SRC!_720p"
if "%TARGET_W%"=="1920" if not "%SRC%"=="3" set "TAG_SRC=!TAG_SRC!_1080p"

REM HDR passthrough: BT.2020 + PQ [or HLG] tags plus the source's mastering display and light levels
if not "%SRC%"=="7" goto :pf_color_done
set "HDR_TRC=16"
if /i "%SI_KIND%"=="HLG" set "HDR_TRC=18"
if /i "%SI_KIND%"=="HLG" set "TAG_SRC=4K_HLG"
if /i "%SI_KIND%"=="HLG" set "TABLE_HDR=2"
set "COLOR_OPTS=--color-primaries 9 --transfer-characteristics %HDR_TRC% --matrix-coefficients 9 --color-range studio"
REM --enable-hdr is only passed when this encoder build lists it in --help [newer builds may have dropped it;
REM the mastering display and light levels below write the HDR metadata either way]
set "HDR_OPTS="
"%SVT_EXE%" --help 2>&1 | findstr /c:"--enable-hdr" >nul && set "HDR_OPTS=--enable-hdr 1"
if not "!SI_MDCV!"=="-" set HDR_OPTS=!HDR_OPTS! --mastering-display "!SI_MDCV!"
if not "!SI_CLL!"=="-" set HDR_OPTS=!HDR_OPTS! --content-light !SI_CLL!
:pf_color_done

REM HQDN3D strength per grain profile [anime gets none, and so does denoiser=none]
set "DENOISE="
if /i "%PF_denoiser%"=="none" goto :pf_dn_none
if not "%SRC%"=="5" (
    if "%S_GRAIN%"=="1" set "DENOISE=,hqdn3d=1.5:1.2:2.5:2.0"
    if "%S_GRAIN%"=="2" set "DENOISE=,hqdn3d=2.2:1.8:3.5:2.7"
    if "%S_GRAIN%"=="3" set "DENOISE=,hqdn3d=3.0:2.5:4.5:3.5"
    if "%S_GRAIN%"=="4" set "DENOISE=,hqdn3d=5.0:4.0:7.0:5.5"
)
:pf_dn_none

set "VFILTER=%CROP_FILTER%%BASE_SCALE%format=yuv420p10le%DENOISE%"
set "VF_PRE=%CROP_FILTER%%BASE_SCALE%format=yuv420p10le"

REM Film grain: pick the table that matches the final canvas size [and HDR, for workflow 7]
set "TABLE="
set "TABLE_KIND="
set "TABLE_HDRMATCH=1"
set "ISO_NUM="
set "TAG_GRAIN=Digital"
set "GRAIN_OPTS=--film-grain 0"
if "%S_GRAIN%"=="2" (
    set "ISO_NUM=200"
    set "TAG_GRAIN=ISO200"
)
if "%S_GRAIN%"=="3" (
    set "ISO_NUM=400"
    set "TAG_GRAIN=ISO400"
)
if "%S_GRAIN%"=="4" (
    set "ISO_NUM=800"
    set "TAG_GRAIN=ISO800"
)
REM v1: a grain ISO chosen in the window [100 to 6400] replaces the 200/400/800 of the grain choice.
REM With the adaptive plan it is the ISO at the film's typical grain level.
if defined ISO_NUM if defined PF_grain_iso (
    set "ISO_NUM=%PF_grain_iso%"
    set "TAG_GRAIN=ISO%PF_grain_iso%"
)

set "OUT_W=%SRC_W%"
set "OUT_H=%SRC_H%"
if defined ISO_NUM call :pick_table
if defined ISO_NUM if not defined TABLE (
    set "FAIL_REASON=No ISO%ISO_NUM% grain table found in %DIR_TABLES%."
    goto :pf_fail
)
if defined TABLE set GRAIN_OPTS=--film-grain 1 --film-grain-denoise 0 --fgs-table "%TABLE%"
REM v1: SVT-AV1's own synthetic grain, only when no grain table is used
if not defined TABLE if defined PF_film_grain if not "%PF_film_grain%"=="0" (
    set "GRAIN_OPTS=--film-grain %PF_film_grain%"
    set "TAG_GRAIN=FG%PF_film_grain%"
)

REM ------------------------------------------------------------------
REM Adaptive plan [per-scene denoise level and grain ISO]
REM ------------------------------------------------------------------
set "ADAPT=0"
if "%S_MODE%"=="2" if defined ISO_NUM if not "%SRC%"=="5" if /i not "%PF_denoiser%"=="none" set "ADAPT=1"
if not "%ADAPT%"=="1" goto :pf_adapt_done

set /a BASE_LEVEL=S_GRAIN
set "PLAN_CSV=!ADAPT_DIR!\plan.csv"
set "PLAN_TABLE=!ADAPT_DIR!\grain_timed.tbl"
set "PRE_FILTER=%CROP_FILTER%%BASE_SCALE%null"
if not exist "!ADAPT_DIR!" mkdir "!ADAPT_DIR!" >nul 2>&1

echo.
echo ====================================================================
echo [1B/6] Adaptive plan: scene cuts, noise per scene, denoise level, grain ISO
echo ====================================================================
if not exist "!PLAN_CSV!" goto :pf_adapt_analyze
echo An earlier plan for this film exists:
echo    "!PLAN_CSV!"
if "%UNATTENDED%"=="1" goto :pf_adapt_review
choice /c YN /t %AUTO_WAIT% /d Y /m "Reuse it [Y] or analyse again [N] [Y is picked in %AUTO_WAIT% s]"
if errorlevel 2 goto :pf_adapt_analyze
goto :pf_adapt_review

:pf_adapt_analyze
title [!QI!/!QN!] Adaptive analysis - !BASENAME!
set "ST_STAGE=adaptive"
call :status
powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode analyze -Source "%INPUT%" -WorkDir "%ADAPT_DIR%" -Crop "%CUT_CROP%" -PreFilter "%PRE_FILTER%" -Duration %TOTAL_SEC% -BaseLevel %BASE_LEVEL% -BaseIso %ISO_NUM% %PLAN_EXTRA%
if errorlevel 1 goto :pf_adapt_failed

:pf_adapt_review
powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode summary -WorkDir "%ADAPT_DIR%"
if errorlevel 1 goto :pf_adapt_failed
if "%UNATTENDED%"=="1" goto :pf_adapt_accept
echo.
choice /c AES /t %AUTO_WAIT% /d A /m "[A]ccept the plan, [E]dit plan.csv in Notepad, or use [S]tatic settings [A is picked in %AUTO_WAIT% s]"
if errorlevel 3 goto :pf_adapt_static
if errorlevel 2 goto :pf_adapt_edit
goto :pf_adapt_accept

:pf_adapt_edit
start /wait notepad "%PLAN_CSV%"
goto :pf_adapt_review

:pf_adapt_accept
powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode build -WorkDir "%ADAPT_DIR%" -TableDir "%DIR_TABLES%" -OutW %OUT_W% -OutH %OUT_H% -Hdr %TABLE_HDR%
if errorlevel 1 goto :pf_adapt_failed
set "HQ0="
for /f "tokens=1,2,3*" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode lookup -WorkDir "%ADAPT_DIR%" -TableDir "%DIR_TABLES%" -OutW %OUT_W% -OutH %OUT_H% -Hdr %TABLE_HDR% -At 0 -Length 0') do set "HQ0=%%C"
if not defined HQ0 goto :pf_adapt_failed
set "TAG_GRAIN=%TAG_GRAIN%-Adaptive"
goto :pf_adapt_done

:pf_adapt_failed
echo.
echo [WARNING] The adaptive plan failed. Falling back to static settings.
:pf_adapt_static
set "ADAPT=0"
echo    - Using static denoise and grain settings.
:pf_adapt_done
call :now_unix TA2
call :dur TA2 TA1 DUR_PLAN

REM Analyse-only jobs from the window stop here, so the plan can be edited before the encode
if not "%ANALYSE_ONLY%"=="1" goto :pf_full_run
if "%ADAPT%"=="1" goto :pf_plan_only_ok
>>"%RESULTS%" echo(FAIL^|!BASENAME!^|no plan was made: adaptive mode needs a grain table and a non-anime workflow
goto :pf_end
:pf_plan_only_ok
echo    - Plan ready: "!PLAN_CSV!"
>>"%RESULTS%" echo(PLAN^|!BASENAME!^|plan ready^|!DUR_PLAN!
goto :pf_end
:pf_full_run

REM ------------------------------------------------------------------
REM Denoiser: KNLMeansCL on the GPU through VapourSynth, or hqdn3d in ffmpeg
REM ------------------------------------------------------------------
set "USE_VS=0"
if /i "%PF_denoiser%"=="knlm" if "%HAS_VS%"=="1" set "USE_VS=1"
if "%SRC%"=="4" set "USE_VS=0"
if "%SRC%"=="5" set "USE_VS=0"
set "DN_TEXT=hqdn3d [CPU]"
if /i "%PF_denoiser%"=="knlm" if "%HAS_VS%"=="0" set "DN_TEXT=hqdn3d [CPU] - KNLMeansCL wanted but VapourSynth is not ready: !VS_NOTE!"
if /i "%PF_denoiser%"=="knlm" if "%SRC%"=="4" set "DN_TEXT=hqdn3d [CPU] - the tonemap workflow uses hqdn3d"
if "%SRC%"=="5" set "DN_TEXT=none [anime]"
if /i "%PF_denoiser%"=="none" set "DN_TEXT=none"
if not "%USE_VS%"=="1" goto :pf_vpy_done
if not exist "!ADAPT_DIR!" mkdir "!ADAPT_DIR!" >nul 2>&1
set "VPY=!ADAPT_DIR!\encode.vpy"
set "SCALE_W=0"
if "%SRC%"=="3" set "SCALE_W=1920"
if defined TARGET_W set "SCALE_W=%TARGET_W%"
set "VPY_PLAN="
if "%ADAPT%"=="1" set "VPY_PLAN=-PlanDir "!ADAPT_DIR!""
set "KNLM_HLIST=%PF_knlm_h%"
set "CAL_TEXT=fixed strengths from the profile"
if /i "%PF_knlm_h%"=="auto" call :calibrate
powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode vpy -Source "%INPUT%" -OutFile "%VPY%" -Fps "%FPS%" -CropBox "%CROP_BOX%" -ScaleW %SCALE_W% -Denoiser knlm -HList "%KNLM_HLIST%" -ChromaH %PF_knlm_chroma% -KnlD %PF_knlm_d% -KnlA %PF_knlm_a% -DeviceId %KNLM_DEVICE% -Level %S_GRAIN% %VPY_PLAN% >nul
if errorlevel 1 goto :pf_vs_failed
echo.
echo    - Preparing VapourSynth [indexes the source the first time, starts KNLMeansCL on GPU %KNLM_DEVICE%]...
set "ST_STAGE=indexing"
call :status
call "%VS_EXE%" --info "%VPY%" >nul 2>"%ADAPT_DIR%\vs_error.txt"
if errorlevel 1 goto :pf_vs_failed
set "DN_TEXT=KNLMeansCL [GPU %KNLM_DEVICE%, d=%PF_knlm_d% a=%PF_knlm_a%, h !KNLM_HLIST!]"
goto :pf_vpy_done
:pf_vs_failed
set "USE_VS=0"
set "DN_TEXT=hqdn3d [CPU] - VapourSynth failed, see vs_error.txt in the plan folder"
echo [WARNING] VapourSynth could not run this film, falling back to hqdn3d:
if exist "!ADAPT_DIR!\vs_error.txt" type "!ADAPT_DIR!\vs_error.txt"
:pf_vpy_done

REM Dark-scene options from the profile [SVT-AV1 4.x]
set "SVT_EXTRA="
if not "%PF_luma_bias%"=="0" set "SVT_EXTRA=--luminance-qp-bias %PF_luma_bias%"
if "%PF_enable_qm%"=="1" set "SVT_EXTRA=!SVT_EXTRA! --enable-qm 1 --qm-min %PF_qm_min%"
if not "%PF_sharpness%"=="0" set "SVT_EXTRA=!SVT_EXTRA! --sharpness %PF_sharpness%"

REM v1: output name from the pattern [Output tab]: {name} {res} {grain} {encoder} {crf}
if not defined PF_out_name set "PF_out_name={name}_AV1_{res}_{grain}"
set "ONAME=!PF_out_name!"
set "ONAME=!ONAME:{name}=%BASENAME%!"
set "ONAME=!ONAME:{res}=%TAG_SRC%!"
set "ONAME=!ONAME:{grain}=%TAG_GRAIN%!"
set "ONAME=!ONAME:{encoder}=%S_ENC_NAME%!"
set "ONAME=!ONAME:{crf}=%S_CRF%!"
set "FINAL_OUTPUT=!OUTDIR!!ONAME!.mkv"
REM an output that already exists: number [default] adds " (2)", skip leaves it, replace overwrites it
if not exist "!FINAL_OUTPUT!" goto :pf_name_ok
if /i "%PF_out_exists%"=="replace" goto :pf_name_ok
if /i not "%PF_out_exists%"=="skip" goto :pf_name_number
echo.
echo [SKIP] "!FINAL_OUTPUT!" already exists [Output tab: skip].
>>"%RESULTS%" echo(SKIP^|!BASENAME!^|already exists: !FINAL_OUTPUT!
exit /b 0
:pf_name_number
set "ONUM=2"
:pf_name_loop
if exist "!OUTDIR!!ONAME! (!ONUM!).mkv" set /a ONUM+=1
if exist "!OUTDIR!!ONAME! (!ONUM!).mkv" goto :pf_name_loop
set "ONAME=!ONAME! (!ONUM!)"
set "FINAL_OUTPUT=!OUTDIR!!ONAME!.mkv"
:pf_name_ok
set "LOG=!OUTDIR!!ONAME!.log"

REM SVT-AV1 settings. A blank preset or CRF [CRF 0] leaves the encoder's own default.
REM stock=1 profiles pass only what was set by hand: the encoder [or its fork] decides everything else.
if defined PF_keyint set "KEYINT=%PF_keyint%"
set "SVT_RATE="
if defined PF_preset set "SVT_RATE=--preset %PF_preset%"
if not "%S_CRF%"=="0" if not "%S_CRF%"=="" set "SVT_RATE=!SVT_RATE! --crf %S_CRF%"
REM Tune and variance boost from the window [blank = profile or encoder default; boost 0 = off]
set "TUNE_OPT="
if defined PF_tune set "TUNE_OPT=--tune %PF_tune%"
set "VB_OPT="
if defined PF_vboost set "VB_OPT=--enable-variance-boost 1 --variance-boost-strength %PF_vboost%"
if "%PF_vboost%"=="0" set "VB_OPT=--enable-variance-boost 0"
if "%PF_stock%"=="1" goto :pf_svt_stock
if not defined TUNE_OPT set "TUNE_OPT=--tune 0"
if not defined VB_OPT set "VB_OPT=--enable-variance-boost 1 --variance-boost-strength %VB_STRENGTH%"
set SVT_BASE=!SVT_RATE! !TUNE_OPT! --keyint %KEYINT% --enable-overlays 1 !VB_OPT! --scd 1 --tile-columns 1 --tile-rows 0 --lp 0 %COLOR_OPTS% %HDR_OPTS% %SVT_EXTRA% %PF_svt_params%
goto :pf_svt_base_done
:pf_svt_stock
set "SVT_K="
if defined PF_keyint set "SVT_K=--keyint %PF_keyint%"
set SVT_BASE=!SVT_RATE! !SVT_K! !TUNE_OPT! !VB_OPT! %COLOR_OPTS% %HDR_OPTS% %SVT_EXTRA% %PF_svt_params%
:pf_svt_base_done
set SVT_OPTS=%SVT_BASE% %GRAIN_OPTS%

set "CROP_TEXT=no crop"
if defined DETECTED_CROP set "CROP_TEXT=!DETECTED_CROP!"
set "ENC_NOTE=RazAV1 %VER% / !S_ENC_NAME! / !PF_name! / !WFN_%SRC%! / !TAG_GRAIN! / CRF %S_CRF% / preset %PF_preset% / !CROP_TEXT! / denoise !DN_TEXT!"

cls
echo ====================================================================
echo [!QI!/!QN!] "!BASENAME!"
echo Source:   !SI_TEXT!
echo Encoder:  !S_ENC_NAME!  ["!SVT_EXE!"]
echo Profile:  !PF_name!: !WFN_%SRC%! / !TAG_GRAIN!
echo SVT-AV1:  !SVT_BASE!
echo Denoise:  !DN_TEXT!
echo Video:    %FPS% fps, crop: !CROP_TEXT!
echo Audio:    track %AUD_IDX% [!AUD_LANG!], !IN_CH! ch [!IN_LAYOUT!] to !AUDIO_LAYOUT!, !AUDIO_TEXT!
if "%SRC%"=="7" echo HDR:      kept as !SI_KIND!, mastering !SI_MDCV!, MaxCLL,MaxFALL !SI_CLL!
if "%ADAPT%"=="1" (
    echo Grain:    adaptive, grain ISO 100-6400 by scene [ISO %ISO_NUM% at the film's typical grain], denoise level 1-5 [baseline level %BASE_LEVEL%]
    echo Plan:     "!PLAN_CSV!"
) else if defined TABLE (
    echo Grain:    !TAG_GRAIN! table "!TABLE!" [!TABLE_KIND!, canvas !OUT_W!x!OUT_H!]
) else (
    echo Grain:    off
)
echo Subs:     !SUBS_TEXT!
echo CPU:      !CPU_TEXT!
echo Output:   "!FINAL_OUTPUT!"
echo ====================================================================
if "%ADAPT%"=="0" if defined TABLE if "!TABLE_KIND!"=="closest size" echo [WARNING] No exact table for !OUT_W!x!OUT_H! and none could be made, using the closest one.
if not "%TABLE_HDR%"=="0" if defined TABLE if "!TABLE_HDRMATCH!"=="0" echo [WARNING] No HDR grain table for ISO %ISO_NUM%, so an SDR one is used on HDR video. Grain strength across brightness will differ.

>"%LOG%" echo(RazAV1 %VER% - %DATE% %TIME%
>>"%LOG%" echo(Input:    !INPUT!
>>"%LOG%" echo(Source:   !SI_TEXT!
>>"%LOG%" echo(Encoder:  !S_ENC_NAME! ["!SVT_EXE!"]
>>"%LOG%" echo(Settings: !ENC_NOTE!
if "%USE_VS%"=="1" >>"%LOG%" echo(Filter:   VapourSynth script !VPY!
if not "%USE_VS%"=="1" >>"%LOG%" echo(Filter:   !VFILTER!
>>"%LOG%" echo(SVT:      !SVT_OPTS!
>>"%LOG%" echo(Audio:    track %AUD_IDX% [!AUD_LANG!], !IN_CH! ch [!IN_LAYOUT!] to !AUDIO_LAYOUT!, !AUDIO_TEXT!
>>"%LOG%" echo(Subs:     !SUBS_TEXT!
>>"%LOG%" echo(Denoise:  !DN_TEXT!
if "%USE_VS%"=="1" >>"%LOG%" echo(KNLM:     !CAL_TEXT!
if "%ADAPT%"=="1" >>"%LOG%" echo(Plan:     !PLAN_CSV!

REM ------------------------------------------------------------------
REM Sample probes [6 per hour, 15s each], placed by the helper:
REM no intro or end credits, starting on scene cuts, every denoise level covered
REM ------------------------------------------------------------------
echo [2/6] Choosing probe points...
title [!QI!/!QN!] Probes - !BASENAME!
set "ST_STAGE=probes"
set "ST_DETAIL=0/0"
call :status
set "PROBE_DIR=%TEMP%\svt_probe_%RANDOM%%RANDOM%"
mkdir "%PROBE_DIR%" >nul 2>&1
set "PTS_FILE=%PROBE_DIR%\sample_points.txt"
set "CONCAT_LIST=%PROBE_DIR%\concat_list.txt"
set "PLAN_ARG="
if "%ADAPT%"=="1" set "PLAN_ARG=-PlanDir "!ADAPT_DIR!""
if "%ADAPT%"=="0" if exist "!ADAPT_DIR!\cuts.txt" set "PLAN_ARG=-CutList "!ADAPT_DIR!\cuts.txt""
set "CREDITS_AT=%TOTAL_SEC%"
set "PROBE_INFO="
for /f "usebackq tokens=1-4* delims=|" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode probes -Source "%INPUT%" -WorkDir "%PROBE_DIR%" -Duration %TOTAL_SEC% -Crop "%CUT_CROP%" -Fps "%FPS%" -OutFile "%PTS_FILE%" %PLAN_ARG%`) do (
    if "%%A"=="INFO" (
        set "CREDITS_AT=%%D"
        set "PROBE_INFO=%%E"
    )
)
if exist "%PTS_FILE%" (
    echo    - !PROBE_INFO!
) else (
    echo    - [NOTE] Smart probe placement failed, using evenly spaced probes.
    powershell -NoProfile -Command ^
      "$dur = [double]('%TOTAL_SEC%');" ^
      "$hours = [math]::Max(1, [math]::Round($dur / 3600.0, 1));" ^
      "$count = [math]::Max(6, [math]::Round($hours * 6));" ^
      "$start = $dur * 0.05;" ^
      "$end = $dur * 0.92;" ^
      "$step = ($end - $start) / ($count + 1);" ^
      "for ($i = 1; $i -le $count; $i++) { [math]::Floor($start + ($i * $step)) }" > "%PTS_FILE%"
)
>>"%LOG%" echo(Probes:   !PROBE_INFO!

set "TOTAL_PROBES=0"
for /f %%A in ('type "%PTS_FILE%" ^| find /c /v ""') do set "TOTAL_PROBES=%%A"

set /a SAMPLE_COUNT=0
set /a PROBE_FAIL=0
set "PROBE_ERR=none"
set /a PROBE_CS=0
set /a PROBE_VOK=0
for /f "usebackq tokens=1,2" %%T in ("%PTS_FILE%") do (
    set /a SAMPLE_COUNT+=1
    call :probe !SAMPLE_COUNT! %%T %%U
)

REM v7: quality score of every probe against the source
set "Q_TEXT="
set "Q_SHORT="
if "%QUALITY%"=="1" if %PROBE_VOK% GTR 0 call :quality

REM Size estimate weighted by how much of the film each denoise level covers [end credits count as cheap];
REM time estimate from the probe encode speed, corrected for the start-up cost of short clips
set "EST_GB=N/A"
set "EST_TIME=N/A"
set "EST_METHOD=plain"
set "EST_PLAN="
if "%ADAPT%"=="1" set "EST_PLAN=-PlanDir "!ADAPT_DIR!""
for /f "usebackq tokens=1-3 delims=|" %%E in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode estimate -ProbeDir "%PROBE_DIR%" -PointsFile "%PTS_FILE%" -Duration %TOTAL_SEC% -CreditsAt %CREDITS_AT% -AudioKbps %AUDIO_KBPS% -Fps "%FPS%" -ProbeCs %PROBE_CS% -ProbeOk %PROBE_VOK% %EST_PLAN%`) do (
    set "EST_GB=%%E"
    set "EST_TIME=%%F"
    set "EST_METHOD=%%G"
)
call :now_unix TA3
call :dur TA3 TA2 DUR_PROBES

REM ------------------------------------------------------------------
REM Preview reel
REM ------------------------------------------------------------------
echo [3/6] Assembling preview reel...
if exist "%CONCAT_LIST%" (
    ffmpeg -y -nostdin -v error -f concat -safe 0 -i "%CONCAT_LIST%" -c copy "%PREVIEW_REEL%" >nul 2>&1
)
rmdir /s /q "%PROBE_DIR%" >nul 2>&1
set "PROBE_DIR="

echo --------------------------------------------------------------------
echo [ESTIMATE] Probes: %SAMPLE_COUNT% run, %PROBE_FAIL% failed
echo [ESTIMATE] Predicted final size: ~%EST_GB% GB [including the audio, !EST_METHOD!]
echo [ESTIMATE] Predicted encode time: ~%EST_TIME%
if defined Q_TEXT echo [QUALITY]  !Q_TEXT!
if exist "!PREVIEW_REEL!" echo [PREVIEW]  Playable reel: "!PREVIEW_REEL!"
if exist "!PREVIEW_REEL!" set "ST_REEL=!PREVIEW_REEL!"
echo --------------------------------------------------------------------
>>"%LOG%" echo(Estimate: ~%EST_GB% GB, ~%EST_TIME% [%SAMPLE_COUNT% probes, %PROBE_FAIL% failed]
if defined Q_TEXT >>"%LOG%" echo(Quality:  !Q_TEXT!

if %PROBE_FAIL% GEQ %SAMPLE_COUNT% (
    set "FAIL_REASON=Every probe failed, so the full encode was not started. Encoder message: !PROBE_ERR!"
    goto :pf_fail
)

if "%GUI_MODE%"=="1" goto :pf_gui_approve
if "%UNATTENDED%"=="1" goto :pf_encode
if exist "!PREVIEW_REEL!" start "" "!PREVIEW_REEL!"
echo.
choice /c YN /t %AUTO_WAIT% /d Y /m "Start the full encode now [auto-yes in %AUTO_WAIT% s]"
if errorlevel 2 (
    >>"%RESULTS%" echo(SKIP^|!BASENAME!^|cancelled after the preview
    >>"%LOG%" echo(Cancelled after the preview.
    echo Cancelled.
    goto :pf_end
)

goto :pf_encode

REM The GUI answers through a small file: Y encode, N skip, H hold [wait without a time limit]
:pf_gui_approve
if not "%APPROVE%"=="1" goto :pf_encode
set "ST_STAGE=approve"
set "ST_DETAIL="
call :status
set "ANS_FILE=%JOB_DIR%\answer_%QI%.txt"
if exist "%ANS_FILE%" del "%ANS_FILE%" >nul 2>&1
echo.
echo Waiting for your answer in the window [Encode, Wait or Skip]. Encoding starts by itself in %AUTO_WAIT% s.
set /a AW=0
set "HOLD=0"
:pf_gui_wait
if exist "%ANS_FILE%" goto :pf_gui_answer
if "%HOLD%"=="0" set /a AW+=1
if "%HOLD%"=="0" if !AW! GTR %AUTO_WAIT% goto :pf_encode
timeout /t 1 /nobreak >nul
goto :pf_gui_wait
:pf_gui_answer
set "ANS="
set /p ANS=<"%ANS_FILE%"
del "%ANS_FILE%" >nul 2>&1
if /i "%ANS%"=="H" set "HOLD=1"
if /i "%ANS%"=="H" goto :pf_gui_wait
if /i not "%ANS%"=="N" goto :pf_encode
>>"%RESULTS%" echo(SKIP^|!BASENAME!^|skipped after the preview
>>"%LOG%" echo(Skipped after the preview.
echo Skipped.
goto :pf_end

REM ------------------------------------------------------------------
REM Full encode
REM ------------------------------------------------------------------
:pf_encode
REM v1: keyframes on the main scene cuts [profile key scene_kf=1]
set "KF_OPT="
if not "%PF_scene_kf%"=="1" goto :pf_kf_done
echo.
echo Keyframes at scene cuts...
set "KF_FILE=!ADAPT_DIR!\keyframes.txt"
if exist "!KF_FILE!" del "!KF_FILE!" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode keyframes -Source "%INPUT%" -WorkDir "%ADAPT_DIR%" -Crop "%CUT_CROP%" -Duration %TOTAL_SEC% -Fps %FPS% -OutFile "!KF_FILE!"
if exist "!KF_FILE!" for /f "usebackq delims=" %%K in ("!KF_FILE!") do set "KF_OPT=--force-key-frames %%K"
if not defined KF_OPT echo [WARNING] No scene cuts found: the encoder places the keyframes on its own.
if defined KF_OPT >>"%LOG%" echo(Keyframes: on scene cuts, list in "!KF_FILE!"
:pf_kf_done
call :now_unix T0
>"%WATCH_INFO%" echo(!QI!/!QN!^|!BASENAME!^|%TOTAL_SEC%
if exist "%VID_PROG%" del "%VID_PROG%" >nul 2>&1

echo.
echo [4/6] Starting audio encode in the background...
if exist "%AUDIO_STATUS%" del "%AUDIO_STATUS%" >nul 2>&1
if exist "%RAW_AUDIO%" del "%RAW_AUDIO%" >nul 2>&1
if exist "%AUDIO_PROG%" del "%AUDIO_PROG%" >nul 2>&1
start "" /b cmd /c call "%SELF%" --audio-worker

echo.
echo [5/6] Encoding video with SVT-AV1 [audio runs in parallel, progress also in the window title]...
echo.
title [!QI!/!QN!] Encoding - !BASENAME!
set "ST_STAGE=encoding"
set "ST_DETAIL="
call :status
if "%ADAPT%"=="1" set SVT_OPTS=%SVT_BASE% --film-grain 1 --film-grain-denoise 0 --fgs-table "%PLAN_TABLE%"
if defined KF_OPT set "SVT_OPTS=!SVT_OPTS! !KF_OPT!"
if "%USE_VS%"=="1" goto :pf_encode_vs
if "%ADAPT%"=="1" set "VFILTER=%VF_PRE%,sendcmd=f=denoise.cmd,hqdn3d@dn=%HQ0%"
if "%ADAPT%"=="1" pushd "%ADAPT_DIR%"
ffmpeg -nostdin -threads 0 -v error -nostats -progress "%VID_PROG%" -i "%INPUT%" -map 0:v:0 -vf "%VFILTER%" -r %FPS% -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - | "%SVT_EXE%" -i stdin --progress 2 %SVT_OPTS% -b "%RAW_VIDEO%"
set "VRC=%errorlevel%"
if "%ADAPT%"=="1" popd
goto :pf_encode_done
:pf_encode_vs
"%VS_EXE%" -c y4m -a "progress=%VID_PROG%" "%VPY%" - | "%SVT_EXE%" -i stdin --progress 2 %SVT_OPTS% -b "%RAW_VIDEO%"
set "VRC=%errorlevel%"
:pf_encode_done
call :now_unix TV
call :dur TV T0 DUR_VIDEO
if exist "%VID_PROG%" del "%VID_PROG%" >nul 2>&1

if not "%VRC%"=="0" (
    set "FAIL_REASON=Video encoding failed with code %VRC%. Check the parameters."
    goto :pf_fail
)
if not exist "%RAW_VIDEO%" (
    set "FAIL_REASON=The video stream was not created."
    goto :pf_fail
)

REM The video stream is done: remember what is needed to resume after a crash
>"%RESUME_FILE%" echo(!FINAL_OUTPUT!
>>"%RESUME_FILE%" echo(%FPS%
>>"%RESUME_FILE%" echo(%AUD_IDX%
>>"%RESUME_FILE%" echo(!AUD_LANG!
>>"%RESUME_FILE%" echo(!ENC_NOTE!

echo.
if exist "%AUDIO_STATUS%" (
    echo Audio encode already finished.
) else (
    echo Waiting for the audio encode to finish...
)
set "ST_STAGE=audio"
call :status
set /a WAIT_TICKS=0
:pf_wait_audio
if exist "%AUDIO_STATUS%" goto :pf_audio_check
set /a WAIT_TICKS+=1
if %WAIT_TICKS% GTR 600 (
    set "FAIL_REASON=The audio encode timed out. The finished video stream was kept, so run the file again to resume."
    goto :pf_fail
)
set /a SHOW_TICK=WAIT_TICKS %% 5
if %SHOW_TICK%==1 call :audio_percent
timeout /t 2 /nobreak >nul
goto :pf_wait_audio

:pf_audio_check
set "AUDIO_RC=1"
if exist "%AUDIO_STATUS%" set /p AUDIO_RC=<"%AUDIO_STATUS%"
if not "%AUDIO_RC%"=="0" (
    set "FAIL_REASON=The audio encode failed for track %AUD_IDX%. The video stream was kept, so run the file again to resume."
    goto :pf_fail
)
if not exist "%RAW_AUDIO%" (
    set "FAIL_REASON=The audio stream was not created. The video stream was kept, so run the file again to resume."
    goto :pf_fail
)

set "OUT_CH=0"
for /f %%C in ('ffprobe -v error -select_streams a:0 -show_entries "stream=channels" -of "default=nokey=1:noprint_wrappers=1" "%RAW_AUDIO%" 2^>nul') do set "OUT_CH=%%C"
if "%OUT_CH%"=="%AUDIO_CH%" (
    echo    - Audio check OK: !IN_CH! ch [!IN_LAYOUT!] became %OUT_CH% ch [!AUDIO_LAYOUT!]
) else (
    echo [WARNING] Audio channel mismatch: expected %AUDIO_CH% ch, the file has %OUT_CH% ch. Listen to it before deleting the source.
    >>"%LOG%" echo(WARNING: audio channel mismatch, expected %AUDIO_CH% ch, got %OUT_CH% ch
)

REM ------------------------------------------------------------------
REM Mux
REM ------------------------------------------------------------------
:pf_mux
set "ST_STAGE=muxing"
call :status
echo.
echo ====================================================================
echo [6/6] Muxing final container [chapters kept, subtitles: !SUBS_TEXT!]...
echo ====================================================================
title [!QI!/!QN!] Muxing - !BASENAME!
set "SUB_MAP=-sn"
set "SUB_CODEC="
if "%S_SUBS%"=="1" if "%SUB_RETRY%"=="0" set "SUB_MAP=-map 2:s? -map 2:t?"
if defined SUB_SEL if "%SUB_RETRY%"=="0" set "SUB_MAP=!SUB_SEL!"
if "%S_SUBS%"=="1" for %%X in (.mp4 .m4v .mov) do if /i "%INEXT%"=="%%X" set "SUB_CODEC=-c:s srt"
if not defined AUD_LANG set "AUD_LANG=und"

ffmpeg -nostdin -y -v error -stats -fflags +genpts -r %FPS% -i "%RAW_VIDEO%" -i "%RAW_AUDIO%" -i "%INPUT%" ^
  -map 0:v:0 -map 1:a:0 %SUB_MAP% ^
  -c copy %SUB_CODEC% ^
  -map_chapters 2 ^
  -map_metadata -1 ^
  -metadata:s:a:0 language=%AUD_LANG% ^
  -metadata "comment=!ENC_NOTE!" ^
  -cues_to_front 1 -reserve_index_space 100k -max_interleave_delta 0 ^
  "%FINAL_OUTPUT%"
set "MRC=%errorlevel%"

if not "%MRC%"=="0" goto :pf_mux_failed
if not exist "%FINAL_OUTPUT%" goto :pf_mux_failed

del "%RAW_VIDEO%" >nul 2>&1
del "%RAW_AUDIO%" >nul 2>&1
del "%AUDIO_STATUS%" >nul 2>&1
del "%AUDIO_PROG%" >nul 2>&1
del "%RESUME_FILE%" >nul 2>&1

set "FSIZE=0"
for %%F in ("!FINAL_OUTPUT!") do set "FSIZE=%%~zF"
set "ACT_GB=N/A"
for /f %%G in ('powershell -NoProfile -Command "[math]::Round(%FSIZE% / 1GB, 2).ToString([Globalization.CultureInfo]::InvariantCulture)"') do set "ACT_GB=%%G"

set "T1=%T0%"
call :now_unix T1
set /a ELAPSED=T1-T0, EH=ELAPSED/3600, EM=ELAPSED%%3600/60
call :dur T1 TV DUR_FINISH

echo.
echo ====================================================================
echo SUCCESS  [file !QI! of !QN!]
echo Output:  "!FINAL_OUTPUT!"
echo Size:    %ACT_GB% GB [estimated %EST_GB% GB]
if defined Q_TEXT echo Quality: !Q_TEXT!
echo Time:    %EH%h %EM%m [estimated %EST_TIME%]
echo Steps:   crop !DUR_CROP!, plan !DUR_PLAN!, probes !DUR_PROBES!, video !DUR_VIDEO!, finish !DUR_FINISH!
echo ====================================================================
>>"%LOG%" echo(Result:   OK, %ACT_GB% GB in %EH%h %EM%m - %DATE% %TIME%
>>"%LOG%" echo(Timing:   crop scan !DUR_CROP!, adaptive plan !DUR_PLAN!, probes !DUR_PROBES!, video encode !DUR_VIDEO!, audio wait and mux !DUR_FINISH!
>>"%RESULTS%" echo(OK^|!BASENAME!^|%ACT_GB% GB^|%EH%h %EM%m^|!Q_SHORT!^|!FINAL_OUTPUT!
goto :pf_end

:pf_mux_failed
if "%S_SUBS%"=="1" if "%SUB_RETRY%"=="0" (
    echo [WARNING] The mux failed with subtitles. Trying again without them...
    >>"%LOG%" echo(WARNING: mux with subtitles failed, retried without subtitles
    set "SUB_RETRY=1"
    set "SUBS_TEXT=dropped after a failed first try"
    goto :pf_mux
)
set "FAIL_REASON=The final mux failed. The temporary streams were kept, so run the file again to resume."
goto :pf_fail

:pf_fail
echo.
echo [ERROR] !FAIL_REASON!
if defined LOG >>"%LOG%" echo(FAILED: !FAIL_REASON!
>>"%RESULTS%" echo(FAIL^|!BASENAME!^|!FAIL_REASON!
if defined PROBE_DIR if exist "%PROBE_DIR%" rmdir /s /q "%PROBE_DIR%" >nul 2>&1
if "%UNATTENDED%"=="1" timeout /t 5 /nobreak >nul

:pf_end
exit /b 0


REM ==================================================================
REM Settings subroutines
REM ==================================================================

:queue_add
REM %1 = full path, %2 = file or folder. Runs before delayed expansion is on.
set "QP=%~1"
if not "%QP:!=%"=="%QP%" (
    echo [SKIP] Exclamation marks in file names are not supported: "%QP%"
    exit /b 0
)
if /i not "%~2"=="folder" goto :queue_add_ok
if not "%QP:_preview_reel=%"=="%QP%" exit /b 0
if not "%QP:_temp_raw=%"=="%QP%" exit /b 0
if not "%QP:_v4.=%"=="%QP%" exit /b 0
:queue_add_ok
set /a QN+=1
set "Q_%QN%=%QP%"
exit /b 0

:describe
REM %1 workflow, %2 mode, %3 grain, %4 crf, %5 subs  ->  DESC
set "D_W=!WFN_%~1!"
if "%~2"=="2" (set "D_G=!GRN_A_%~3!") else (set "D_G=!GRN_S_%~3!")
if "%~5"=="1" (set "D_S=subs kept") else (set "D_S=no subs")
set "DESC=!D_W! / !D_G! / CRF %~4 / !D_S!"
exit /b 0

:validate
set "V_OK=0"
for %%v in (1 2 3 4 5 6 7) do if "%S_SRC%"=="%%v" set "V_OK=1"
if "%V_OK%"=="0" set "S_SRC=1"
if not "%S_MODE%"=="2" set "S_MODE=1"
set "V_OK=0"
for %%v in (1 2 3 4) do if "%S_GRAIN%"=="%%v" set "V_OK=1"
if "%V_OK%"=="0" set "S_GRAIN=3"
if "%S_SRC%"=="5" set "S_MODE=1"
if "%S_MODE%"=="2" if "%S_GRAIN%"=="1" set "S_MODE=1"
if not "%S_SUBS%"=="1" set "S_SUBS=0"
set "V_OK=1"
if not defined S_CRF set "V_OK=0"
if defined S_CRF for /f "delims=0123456789" %%x in ("!S_CRF!") do set "V_OK=0"
if "%V_OK%"=="1" if !S_CRF! GTR 63 set "V_OK=0"
if "%V_OK%"=="1" if !S_CRF! LSS 1 set "V_OK=0"
if "%V_OK%"=="0" set "S_CRF=30"
exit /b 0

:cpu_text
set "CPU_TEXT=max  [AboveNormal priority, EcoQoS off, all cores]"
if /i "%CPU_MODE%"=="normal" set "CPU_TEXT=normal  [EcoQoS off, normal priority]"
if /i "%CPU_MODE%"=="low" set "CPU_TEXT=low  [BelowNormal priority, the PC stays smooth]"
exit /b 0

:menu_defaults
REM %1 = L [last settings] or S [current settings]: which values become the Enter defaults
set "DEF_SRC=%SI_SUGGEST%"
if /i "%~1"=="S" set "DEF_SRC=%S_SRC%"
set "DEF_MODE=1"
set "DEF_GRAIN_S=3"
set "DEF_GRAIN_A=2"
set "DEF_SUBS=N"
set "D_MODE=!%~1_MODE!"
set "D_GRAIN=!%~1_GRAIN!"
set "D_SUBS=!%~1_SUBS!"
if "!D_MODE!"=="2" set "DEF_MODE=2"
for %%v in (1 2 3 4) do if "!D_GRAIN!"=="%%v" if not "!D_MODE!"=="2" set "DEF_GRAIN_S=%%v"
for %%v in (2 3 4) do if "!D_GRAIN!"=="%%v" if "!D_MODE!"=="2" set /a DEF_GRAIN_A=%%v-1
if "!D_SUBS!"=="1" set "DEF_SUBS=Y"
set "V_OK=0"
for %%v in (1 2 3 4 5 6 7) do if "!DEF_SRC!"=="%%v" set "V_OK=1"
if "%V_OK%"=="0" set "DEF_SRC=1"
exit /b 0

:menu_manual
cls
echo ====================================================================
echo           RAZAV1 %VER% - SETTINGS     [Enter keeps the default]
echo ====================================================================
echo First file: !SI_TEXT!
echo.
echo [1] SOURCE WORKFLOW:
echo      1. 1080p Standard Movie
echo      2. 1080p TV Show Episode
echo      3. 4K SDR to 1080p [Lanczos downscale]
echo      4. 4K HDR/DoVi to 1080p SDR [Hable tonemap]
echo      5. Anime Master [no denoise, 10s keyint, VB 1]
echo      6. 4K SDR to 4K SDR [native resolution]
echo      7. 4K HDR to 4K HDR10 [HDR10 metadata kept, Dolby Vision layer dropped]
call :ask S_SRC "Select [1-7]" %DEF_SRC% "1 2 3 4 5 6 7"
echo.
if "%S_SRC%"=="5" (
    set "S_MODE=1"
    goto :mm_static
)
echo [2] DENOISE AND GRAIN MODE:
echo      1. Static   [one denoise strength and one grain table for the whole film]
echo      2. Adaptive [per-scene denoise level 1-5 and grain ISO 100-6400]
call :ask S_MODE "Select [1-2]" %DEF_MODE% "1 2"
echo.
if "%S_MODE%"=="2" goto :mm_adaptive

:mm_static
echo [3] FILM GRAIN PROFILE:
echo      1. Digital Clean [film grain off]
echo      2. ISO 200 Table [clean digital sensor noise, banding help]
echo      3. ISO 400 Table [standard 35mm live action]
echo      4. ISO 800 Table [gritty 16mm / high noise]
if "%S_SRC%"=="5" echo      [Anime: grain table only, no denoise]
call :ask S_GRAIN "Select [1-4]" %DEF_GRAIN_S% "1 2 3 4"
goto :mm_crf

:mm_adaptive
echo [3] HOW GRAINY IS THIS FILM OVERALL? [the plan works up and down from this]
echo      1. Light  [modern digital, clean]  - baseline level 2
echo      2. Medium [typical 35mm]           - baseline level 3
echo      3. Heavy  [16mm, high ISO, old]    - baseline level 4
call :ask G_ADAPT "Select [1-3]" %DEF_GRAIN_A% "1 2 3"
set /a S_GRAIN=G_ADAPT+1

:mm_crf
echo.
set "DEF_CRF=1"
if "%S_SRC%"=="2" set "DEF_CRF=2"
if "%S_SRC%"=="5" set "DEF_CRF=2"
echo [4] ENCODING QUALITY [CRF]:
echo      1. CRF 30 [movies, storage saving]
echo      2. CRF 26 [TV shows, anime, more detail]
echo      3. Type your own value
call :ask C_SEL "Select [1-3]" %DEF_CRF% "1 2 3"
if "%C_SEL%"=="1" set "S_CRF=30"
if "%C_SEL%"=="2" set "S_CRF=26"
if "%C_SEL%"=="3" call :ask_crf
echo.
echo [5] SUBTITLES:
echo      Y. Keep all subtitle tracks [plus font attachments, for anime]
echo      N. Drop subtitles
call :ask SUBYN "Keep subtitles [Y/N]" %DEF_SUBS% "Y N"
if /i "%SUBYN%"=="Y" (set "S_SUBS=1") else (set "S_SUBS=0")
exit /b 0

:ask
REM %1 = variable, %2 = prompt, %3 = default, %4 = allowed answers
set "ANS="
set /p "ANS=%~2 [Enter = %~3]: "
if not defined ANS set "ANS=%~3"
set "ASK_OK="
for %%V in (%~4) do if /i "!ANS!"=="%%V" set "ASK_OK=%%V"
if not defined ASK_OK (
    echo    Please type one of: %~4
    goto :ask
)
set "%~1=!ASK_OK!"
exit /b 0

:ask_crf
set "CRF_IN="
set /p "CRF_IN=CRF value [1-63, Enter = 30]: "
if not defined CRF_IN set "CRF_IN=30"
for /f "delims=0123456789" %%x in ("!CRF_IN!") do goto :ask_crf
if !CRF_IN! LSS 1 goto :ask_crf
if !CRF_IN! GTR 63 goto :ask_crf
set "S_CRF=!CRF_IN!"
exit /b 0


REM ==================================================================
REM Per-file subroutines
REM ==================================================================

:srcinfo
REM Reads SI_SRC. Sets SI_W, SI_H, SI_KIND [SDR, HDR10, HLG, DV5], SI_DV, SI_DVC, SI_H10P, SI_SUGGEST, SI_DUR, SI_MDCV, SI_CLL, SI_TEXT
set "SI_W=0"
set "SI_H=0"
set "SI_KIND=SDR"
set "SI_DV=0"
set "SI_DVC=0"
set "SI_H10P=0"
set "SI_SUGGEST=1"
set "SI_DUR=0"
set "SI_MDCV=-"
set "SI_CLL=-"
set "SI_TEXT=unknown [the helper could not read the file]"
for /f "usebackq tokens=1-11 delims=|" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode srcinfo -Source "%SI_SRC%"`) do (
    set "SI_W=%%A"
    set "SI_H=%%B"
    set "SI_KIND=%%C"
    set "SI_DV=%%D"
    set "SI_DVC=%%E"
    set "SI_H10P=%%F"
    set "SI_SUGGEST=%%G"
    set "SI_DUR=%%H"
    set "SI_MDCV=%%I"
    set "SI_CLL=%%J"
    set "SI_TEXT=%%K"
)
exit /b 0

:effective_wf
REM In: SRC [chosen workflow] and SI_KIND. Out: SRC adjusted to the file, WF_NOTE, WF_FAIL.
set "WF_NOTE="
set "WF_FAIL="
if /i not "%SI_KIND%"=="SDR" goto :ewf_hdr
if "%SRC%"=="4" (
    set "SRC=3"
    set "WF_NOTE=The source is SDR, so workflow 4 [tonemap] runs as 3 [plain downscale]."
)
if "%SRC%"=="7" (
    set "SRC=6"
    set "WF_NOTE=The source is SDR, so workflow 7 [HDR10] runs as 6 [4K SDR]."
)
exit /b 0
:ewf_hdr
if "%SRC%"=="3" (
    set "SRC=4"
    set "WF_NOTE=The source is HDR, so workflow 3 runs as 4 [tonemap to SDR]."
)
if "%SRC%"=="6" (
    set "SRC=7"
    set "WF_NOTE=The source is HDR, so workflow 6 runs as 7 [HDR10 kept]."
)
for %%W in (1 2 5) do if "%SRC%"=="%%W" set "WF_NOTE=The source is HDR but workflow %%W is SDR, so colours will look washed out. Workflows 4 and 7 handle HDR."
if /i "%SI_KIND%"=="DV5" if "%SRC%"=="4" set "WF_NOTE=Dolby Vision profile 5 has no HDR10 base layer, so the tonemap may give a green or purple tint."
if /i "%SI_KIND%"=="DV5" if "%SRC%"=="7" set "WF_FAIL=Dolby Vision profile 5 has no HDR10 base layer, so it cannot be kept as HDR10. Use workflow 4."
exit /b 0

:pick_audio
REM Lists the audio tracks, picks one automatically [preferred language, not commentary, default flag, most channels]
set "AUD_PICK=0"
echo.
echo Audio tracks:
for /f "usebackq tokens=1-3 delims=|" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode audiolist -Source "%INPUT%" -PrefLang "%PREF_LANG%"`) do (
    if "%%A"=="L" echo      %%B
    if "%%A"=="T" set "AL_%%B=%%C"
    if "%%A"=="PICK" set "AUD_PICK=%%B"
)
set "AUD_IDX=%AUD_PICK%"
if "%AUD_PICK%"=="-1" exit /b 0
if "%UNATTENDED%"=="1" goto :pa_done
:pa_ask
set "AUD_IN="
set /p "AUD_IN=Audio track [Enter = %AUD_PICK%]: "
if not defined AUD_IN set "AUD_IN=%AUD_PICK%"
for /f "delims=0123456789" %%x in ("!AUD_IN!") do goto :pa_ask
if not defined AL_%AUD_IN% (
    echo    There is no track %AUD_IN%.
    goto :pa_ask
)
set "AUD_IDX=%AUD_IN%"
:pa_done
set "AUD_LANG=!AL_%AUD_IDX%!"
if not defined AUD_LANG set "AUD_LANG=und"
exit /b 0

:audio_topology
REM Reads the real channel layout and picks the target from the audio settings:
REM   PF_audio_format   opus [default] or copy [the original track, untouched]
REM   PF_audio_channels auto [default: 6 or more channels become 5.1], keep [7.1 stays 7.1], or stereo
REM   PF_audio_kbps     blank = by channel count, or a number
REM   PF_audio_norm     1 [default] = EBU R128 loudness, 0 = level untouched
set "IN_CH=0"
set "IN_LAYOUT=unknown"
for /f "tokens=1,2 delims=," %%A in ('ffprobe -v error -select_streams a:%AUD_IDX% -show_entries "stream=channels,channel_layout" -of "csv=p=0" "%INPUT%" 2^>nul') do (
    set "IN_CH=%%A"
    set "IN_LAYOUT=%%B"
)
if "%IN_CH%"=="0" set "IN_CH=6"
if not defined PF_audio_format set "PF_audio_format=opus"
if not defined PF_audio_channels set "PF_audio_channels=auto"
if not defined PF_audio_norm set "PF_audio_norm=1"
if /i "%PF_audio_format%"=="copy" goto :at_copy

REM auto: 6 or more channels [5.1, 6.1, 7.1] become 5.1, everything else keeps its own shape
set "AUDIO_LAYOUT=5.1"
set "AUDIO_CH=6"
set "AUDIO_KBPS=%PF_audio_51_kbps%"
if not defined AUDIO_KBPS set "AUDIO_KBPS=256"
set "AUDIO_GAIN=volume=1.4,"
if "%IN_CH%"=="5" (
    set "AUDIO_LAYOUT=5.0"
    set "AUDIO_CH=5"
    set "AUDIO_KBPS=224"
)
for %%N in (2 3 4) do if "%IN_CH%"=="%%N" (
    set "AUDIO_LAYOUT=stereo"
    set "AUDIO_CH=2"
    set "AUDIO_KBPS=160"
    set "AUDIO_GAIN="
)
if "%IN_CH%"=="1" (
    set "AUDIO_LAYOUT=mono"
    set "AUDIO_CH=1"
    set "AUDIO_KBPS=96"
    set "AUDIO_GAIN="
)
REM keep: the source's own channels [Opus can carry up to 7.1]
if /i not "%PF_audio_channels%"=="keep" goto :at_not_keep
if "%IN_CH%"=="8" set "AUDIO_LAYOUT=7.1"
if "%IN_CH%"=="8" set "AUDIO_CH=8"
if "%IN_CH%"=="8" set "AUDIO_KBPS=384"
if "%IN_CH%"=="7" set "AUDIO_LAYOUT=6.1"
if "%IN_CH%"=="7" set "AUDIO_CH=7"
if "%IN_CH%"=="7" set "AUDIO_KBPS=320"
if "%IN_CH%"=="4" set "AUDIO_LAYOUT=quad"
if "%IN_CH%"=="4" set "AUDIO_CH=4"
if "%IN_CH%"=="4" set "AUDIO_KBPS=224"
if "%IN_CH%"=="3" set "AUDIO_LAYOUT=3.0"
if "%IN_CH%"=="3" set "AUDIO_CH=3"
if "%IN_CH%"=="3" set "AUDIO_KBPS=192"
:at_not_keep
if /i not "%PF_audio_channels%"=="stereo" goto :at_not_stereo
if %IN_CH% LSS 2 goto :at_not_stereo
set "AUDIO_LAYOUT=stereo"
set "AUDIO_CH=2"
set "AUDIO_KBPS=160"
set "AUDIO_GAIN="
:at_not_stereo
if defined PF_audio_kbps set "AUDIO_KBPS=%PF_audio_kbps%"
set "AUDIO_BR=%AUDIO_KBPS%k"

REM aformat does the downmix first, so loudnorm measures the final mix.
REM It also relabels 5.1[side] to 5.1, which libopus requires.
set "AUDIO_FILTER=aformat=channel_layouts=%AUDIO_LAYOUT%,%AUDIO_GAIN%loudnorm=I=-16:LRA=11:TP=-1.5,aresample=48000"
set "AUDIO_TEXT=Opus %AUDIO_BR%, EBU R128 normalized"
if "%PF_audio_norm%"=="0" set "AUDIO_FILTER=aformat=channel_layouts=%AUDIO_LAYOUT%,aresample=48000"
if "%PF_audio_norm%"=="0" set "AUDIO_TEXT=Opus %AUDIO_BR%, level untouched"
exit /b 0

:at_copy
REM The original track goes into the file as it is. Its bitrate is only needed for the size estimate.
set "AUDIO_LAYOUT=%IN_LAYOUT%"
set "AUDIO_CH=%IN_CH%"
set "AUDIO_GAIN="
set "AUDIO_FILTER="
set "A_BPS="
for /f "tokens=*" %%B in ('ffprobe -v error -select_streams a:%AUD_IDX% -show_entries "stream=bit_rate:stream_tags=BPS,BPS-eng" -of "default=nokey=1:noprint_wrappers=1" "%INPUT%" 2^>nul') do call :at_bps "%%B"
set "AUDIO_KBPS=3500"
if %IN_CH% LEQ 2 set "AUDIO_KBPS=640"
if defined A_BPS set /a "AUDIO_KBPS=A_BPS/1000"
set "AUDIO_BR=copy"
set "AUDIO_TEXT=kept as it is [copy, about %AUDIO_KBPS% kb/s]"
exit /b 0

:at_bps
REM first plain number wins [bit_rate, then the BPS tag mkvmerge writes]
if defined A_BPS exit /b 0
echo(%~1| findstr /r "^[0-9][0-9]*$" >nul || exit /b 0
set "A_BPS=%~1"
exit /b 0

:cropscan
REM %1 = start second of a 2 second clip. The limit is a fraction so 8-bit and 10-bit sources both work.
set "LASTCROP="
for /f "tokens=2 delims==" %%K in ('ffmpeg -hide_banner -nostdin -ss %~1 -i "%INPUT%" -t 2 -an -sn -vf "cropdetect=limit=0.094:round=16:reset=0" -f null - 2^>^&1 ^| findstr /r "crop=[0-9]*:[0-9]*:[0-9]*:[0-9]*"') do set "LASTCROP=%%K"
if defined LASTCROP >>"%CROP_LIST%" echo %LASTCROP%
<nul set /p "=."
exit /b 0

:pick_table
REM Needs ISO_NUM. Works out the final canvas size, then asks the helper for the closest table.
if "%OUT_W%"=="0" set "OUT_W=1920"
if "%OUT_H%"=="0" set "OUT_H=1080"
if defined DETECTED_CROP for /f "tokens=1,2 delims=:" %%A in ("!CROP_UNION!") do (
    set "OUT_W=%%A"
    set "OUT_H=%%B"
)
set "SCALED=0"
set "SCALE_TO=1920"
if "%SRC%"=="3" set "SCALED=1"
if "%SRC%"=="4" set "SCALED=1"
if defined TARGET_W (
    set "SCALED=1"
    set "SCALE_TO=%TARGET_W%"
)
if "%SCALED%"=="1" for /f "tokens=1,2" %%A in ('powershell -NoProfile -Command "$w = [double]%OUT_W%; $h = [double]%OUT_H%; $t = [double]%SCALE_TO%; Write-Output ('%SCALE_TO% ' + ([math]::Round($h * $t / $w / 2) * 2))"') do (
    set "OUT_W=%%A"
    set "OUT_H=%%B"
)
set "TABLE="
set "TABLE_KIND="
set "TABLE_HDRMATCH=1"
for /f "usebackq tokens=1-3 delims=|" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode table -TableDir "%DIR_TABLES%" -Iso %ISO_NUM% -OutW %OUT_W% -OutH %OUT_H% -Hdr %TABLE_HDR% 2^>nul`) do (
    set "TABLE=%%A"
    set "TABLE_KIND=%%B"
    set "TABLE_HDRMATCH=%%C"
)
if "!TABLE_KIND!"=="exact" set "TABLE_KIND=exact size"
if "!TABLE_KIND!"=="made" set "TABLE_KIND=made for this size"
if "!TABLE_KIND!"=="nearest" set "TABLE_KIND=closest size"
exit /b 0

:probe
REM %1 = probe number, %2 = start second, %3 = start frame [empty for the fallback points]
set "PN=%~1"
set "PT=%~2"
set "PF0=%~3"
set "ST_DETAIL=%PN%/%TOTAL_PROBES%"
call :status
for /f "tokens=1 delims=." %%a in ("%PT%") do set /a "PTI=%%a"
if not defined PF0 set /a "PF0=PTI*FPSN/FPSD"
set /a "PF1=PF0+P15-1"
set /a "TH=PTI/3600, TM=(PTI%%3600)/60, TSS=PTI%%60"
set "TM=0%TM%"
set "TSS=0%TSS%"
set "TS=%TH%:%TM:~-2%:%TSS:~-2%"
title [!QI!/!QN!] Probe !PN!/!TOTAL_PROBES! - !BASENAME!
set "PVF=%VFILTER%"
set POPTS=%SVT_OPTS%
set "PINFO="
if "%ADAPT%"=="1" call :probe_adapt
echo    - Probe %PN% of %TOTAL_PROBES% at [%TS%]%PINFO%

call :now_cs
set /a "PT_A=NOW_CS"
if "%USE_VS%"=="1" goto :probe_vs
ffmpeg -nostdin -threads 0 -v error -ss %PT% -i "%INPUT%" -t 15 -map 0:v:0 -vf "%PVF%" -r %FPS% -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - 2>nul | "%SVT_EXE%" -i stdin --progress 0 %POPTS% -b "%PROBE_DIR%\p_%PN%.ivf" >nul 2>"%PROBE_DIR%\svt_%PN%.txt"
goto :probe_video_done
:probe_vs
"%VS_EXE%" -c y4m -s %PF0% -e %PF1% -a start=%PF0% -a end=%PF1% "%VPY%" - 2>nul | "%SVT_EXE%" -i stdin --progress 0 %POPTS% -b "%PROBE_DIR%\p_%PN%.ivf" >nul 2>"%PROBE_DIR%\svt_%PN%.txt"
:probe_video_done
call :now_cs
set /a "PT_D=NOW_CS-PT_A"
if %PT_D% LSS 0 set /a "PT_D+=8640000"
REM An .ivf with only its 32-byte header means the encoder stopped before the first frame
set "PV_OK=0"
if exist "%PROBE_DIR%\p_%PN%.ivf" for %%Z in ("%PROBE_DIR%\p_%PN%.ivf") do if %%~zZ GTR 1024 set "PV_OK=1"
if "%PV_OK%"=="0" goto :probe_no_video
set /a "PROBE_CS+=PT_D, PROBE_VOK+=1"

if /i "%PF_audio_format%"=="copy" ffmpeg -y -nostdin -v error -ss %PT% -i "%INPUT%" -t 15 -map 0:a:%AUD_IDX% -c:a copy "%PROBE_DIR%\a_%PN%.mka" >nul 2>&1
if /i not "%PF_audio_format%"=="copy" ffmpeg -y -nostdin -v error -ss %PT% -i "%INPUT%" -t 15 -map 0:a:%AUD_IDX% -c:a libopus -b:a %AUDIO_BR% -vbr on -frame_duration:a 10 -af "%AUDIO_FILTER%" "%PROBE_DIR%\a_%PN%.mka" >nul 2>&1

ffmpeg -y -nostdin -v error -r %FPS% -i "%PROBE_DIR%\p_%PN%.ivf" -i "%PROBE_DIR%\a_%PN%.mka" -c copy "%PROBE_DIR%\chunk_%PN%.mkv" >nul 2>&1

if exist "%PROBE_DIR%\chunk_%PN%.mkv" >>"%CONCAT_LIST%" echo file '%PROBE_DIR%\chunk_%PN%.mkv'
if not exist "%PROBE_DIR%\chunk_%PN%.mkv" set /a PROBE_FAIL+=1
exit /b 0

:probe_no_video
set /a PROBE_FAIL+=1
set "SVT_ERR="
if exist "%PROBE_DIR%\svt_%PN%.txt" for /f "usebackq delims=" %%L in (`findstr /i /c:"error" "%PROBE_DIR%\svt_%PN%.txt"`) do if not defined SVT_ERR set "SVT_ERR=%%L"
if not defined SVT_ERR if exist "%PROBE_DIR%\svt_%PN%.txt" for /f "usebackq delims=" %%L in ("%PROBE_DIR%\svt_%PN%.txt") do set "SVT_ERR=%%L"
if not defined SVT_ERR set "SVT_ERR=the encoder stopped without a message"
set "PROBE_ERR=!SVT_ERR!"
echo      [FAIL] no video came out of the encoder: !SVT_ERR!
if defined LOG >>"%LOG%" echo(Probe %PN% failed: !SVT_ERR!
exit /b 0

:probe_adapt
REM Looks up denoise level, ISO tier and table for the segment in the middle of this probe
for /f "tokens=1,2,3*" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode lookup -WorkDir "%ADAPT_DIR%" -TableDir "%DIR_TABLES%" -OutW %OUT_W% -OutH %OUT_H% -Hdr %TABLE_HDR% -At %PT% -Length 15') do (
    set "PVF=%VF_PRE%,hqdn3d=%%C"
    set POPTS=%SVT_BASE% --film-grain 1 --film-grain-denoise 0 --fgs-table "%%D"
    set "PINFO=  [denoise level %%A, ISO%%B]"
)
exit /b 0

:audio_percent
REM Reads ffmpeg's progress file and prints how far the audio encode is
set "APCT="
for /f %%Q in ('powershell -NoProfile -Command "$l = Get-Content '%AUDIO_PROG%' -Tail 30 -ErrorAction SilentlyContinue | Where-Object { $_ -like 'out_time_us=*' } | Select-Object -Last 1; if ($l) { $v = $l.Split('=')[1]; if ($v -match '^[0-9]+$') { [math]::Min(99, [math]::Floor([double]$v / 1000000 / [double]%TOTAL_SEC% * 100)) } }"') do set "APCT=%%Q"
if defined APCT echo    - Audio encode: %APCT%%%
exit /b 0

:now_cs
REM Centiseconds since midnight, from %TIME% [any locale separator]
set "NOW_T=%time: =0%"
for /f "tokens=1-4 delims=:.," %%a in ("%NOW_T%") do set /a "NOW_CS=(((1%%a-100)*60+(1%%b-100))*60+(1%%c-100))*100+(1%%d-100)"
exit /b 0

:dur
REM %1 = end time variable, %2 = start time variable, %3 = result variable ["1h 02m 05s"]
set /a "DUR_S=!%~1!-!%~2!"
if !DUR_S! LSS 0 set "DUR_S=0"
set /a "DUR_H=DUR_S/3600, DUR_M=(DUR_S%%3600)/60, DUR_SS=DUR_S%%60"
set "%~3=!DUR_H!h !DUR_M!m !DUR_SS!s"
exit /b 0

:status
REM Writes the progress file the GUI reads [only in GUI mode]
if not defined STATUS_FILE exit /b 0
>"%STATUS_FILE%" (
    echo(index=!QI!
    echo(total=!QN!
    echo(name=!BASENAME!
    echo(stage=!ST_STAGE!
    echo(detail=!ST_DETAIL!
    echo(estimate=!EST_GB!
    echo(eta=!EST_TIME!
    echo(reel=!ST_REEL!
    echo(duration=!TOTAL_SEC!
    echo(fps=!FPS!
    echo(audio_kbps=!AUDIO_KBPS!
    echo(quality=!Q_SHORT!
)
exit /b 0

:calibrate
REM v7: KNLMeansCL strengths that leave as much grain as the hqdn3d levels [cached in the plan folder]
set "KNLM_HLIST=0.70,1.00,1.30,1.70,2.20"
set "CAL_TEXT=calibration failed, so fixed strengths are used"
set "ST_STAGE=calibrating"
set "ST_DETAIL="
call :status
echo    - Calibrating KNLMeansCL against the hqdn3d levels on this film...
for /f "usebackq tokens=1-2* delims=|" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode calibrate -Source "%INPUT%" -WorkDir "%ADAPT_DIR%" -PreFilter "%VF_PRE%" -CropBox "%CROP_BOX%" -ScaleW %SCALE_W% -Fps "%FPS%" -Duration %TOTAL_SEC% -DeviceId %KNLM_DEVICE% -Vspipe "%VS_EXE%" -KnlD %PF_knlm_d% -KnlA %PF_knlm_a% -KnlScale %PF_knlm_scale%`) do (
    if "%%A"=="OK" (
        set "KNLM_HLIST=%%B"
        set "CAL_TEXT=%%C"
    )
)
echo    - KNLMeansCL strength per level: !KNLM_HLIST!
echo      !CAL_TEXT!
exit /b 0

:quality
REM v7: VMAF [or SSIM] of every probe against the source after the same crop and scale
set "ST_STAGE=quality"
set "ST_DETAIL="
call :status
echo [2/6] Scoring the probes against the source...
title [!QI!/!QN!] Quality - !BASENAME!
set "Q_VPY="
if "%USE_VS%"=="1" set "Q_VPY=%VPY%"
set "Q_W=1920"
if "%SRC%"=="6" set "Q_W=3840"
if "%SRC%"=="7" set "Q_W=3840"
for /f "usebackq tokens=1-5 delims=|" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -Mode quality -ProbeDir "%PROBE_DIR%" -PointsFile "%PTS_FILE%" -Source "%INPUT%" -PreFilter "%VF_PRE%" -Fps "%FPS%" -Vspipe "%VS_EXE%" -Vpy "%Q_VPY%" -OutW %Q_W%`) do (
    if "%%A"=="OK" (
        set "Q_TEXT=%%B %%C average, worst probe %%D [%%E probes, before grain synthesis]"
        set "Q_SHORT=%%B %%C / %%D"
    )
)
call :status
exit /b 0

:load_profile
REM %1 = profile name. Sets PF_* [defaults first, so a profile may leave keys out]
set "PF_name=%~1"
set "PF_stock=0"
set "PF_crop=auto"
set "PF_keyint="
set "PF_svt_params="
set "PF_resize="
set "PF_tune="
set "PF_vboost="
set "PF_film_grain="
set "PF_grain_iso="
set "PF_scene_kf=0"
set "PF_preset=5"
set "PF_crf=30"
set "PF_crf_tv=26"
set "PF_mode=2"
set "PF_grain=3"
set "PF_denoiser=hqdn3d"
set "PF_knlm_h=0.40,0.60,0.80,1.10,1.45"
set "PF_knlm_chroma=1.0"
set "PF_knlm_d=1"
set "PF_knlm_a=2"
set "PF_knlm_scale=1.0"
set "PF_luma_bias=0"
set "PF_enable_qm=0"
set "PF_qm_min=8"
set "PF_sharpness=0"
set "PF_vb_strength=2"
set "PF_audio_51_kbps=256"
set "PF_out_dir="
set "PF_out_name="
set "PF_out_exists=number"
set "PF_audio_format=opus"
set "PF_audio_channels=auto"
set "PF_audio_kbps="
set "PF_audio_norm=1"
set "PF_subs=0"
set "PF_FILE=%HERE%profiles\%~1.profile"
if not exist "%PF_FILE%" exit /b 0
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%PF_FILE%") do set "PF_%%A=%%B"
exit /b 0

:dn_text_global
set "DN_GLOBAL=hqdn3d [CPU]"
if /i "%PF_denoiser%"=="knlm" if "%HAS_VS%"=="1" set "DN_GLOBAL=KNLMeansCL [GPU %KNLM_DEVICE%, VapourSynth]  - workflow 4 and anime keep hqdn3d / none"
if /i "%PF_denoiser%"=="knlm" if "%HAS_VS%"=="0" set "DN_GLOBAL=hqdn3d [CPU] - VapourSynth is not ready: !VS_NOTE!"
exit /b 0

:now_unix
for /f %%t in ('powershell -NoProfile -Command "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()"') do set "%~1=%%t"
exit /b 0

:audio_encode
REM Shared by the background worker and by resume
if /i "%PF_audio_format%"=="copy" goto :audio_encode_copy
ffmpeg -nostdin -y -v error -nostats -progress "%AUDIO_PROG%" -i "%INPUT%" -map 0:a:%AUD_IDX% -c:a libopus -b:a %AUDIO_BR% -vbr on -frame_duration:a 10 -af "%AUDIO_FILTER%" "%RAW_AUDIO%"
goto :audio_encode_done
:audio_encode_copy
ffmpeg -nostdin -y -v error -nostats -progress "%AUDIO_PROG%" -i "%INPUT%" -map 0:a:%AUD_IDX% -c:a copy "%RAW_AUDIO%"
:audio_encode_done
set "ARC=%errorlevel%"
>"%AUDIO_STATUS%" echo %ARC%
exit /b %ARC%


REM ==================================================================
REM Entry points that do not run the main flow
REM ==================================================================

:audio_worker
REM Runs as a separate process started by the main script. Environment variables are inherited from it.
call :audio_encode
if "%ARC%"=="0" (
    echo [AUDIO] Audio encode finished.
) else (
    echo [AUDIO] Audio encode FAILED with code %ARC%.
)
exit

:install_sendto
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0av1_helper.ps1" -Mode sendto -Target "%~f0"
pause
exit /b 0
