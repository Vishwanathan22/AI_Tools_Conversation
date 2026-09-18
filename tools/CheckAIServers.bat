@echo off
setlocal enabledelayedexpansion
title Eros Realms - AI Server Connectivity Check
color 0B

REM Run this on the CLIENT PC (the one running UE) to test the server PC.
REM Usage:  CheckAIServers.bat [server-ip]
REM Default is the confirmed server host. Override with an argument.
set "SERVER=%~1"
if "%SERVER%"=="" set "SERVER=192.168.1.50"

set "MODEL=mistral:7b-instruct-q4_K_M"
set "SPEAKER=p248"
set "OUT=%TEMP%\erosrealm_check"
set PASS_N=0
set FAIL_N=0
set WARN_N=0

if not exist "%OUT%" mkdir "%OUT%"
del /q "%OUT%\*" >nul 2>&1

echo ============================================================
echo  EROS REALMS - AI SERVER CONNECTIVITY CHECK
echo ============================================================
echo   Client : %COMPUTERNAME%
echo   Server : %SERVER%
echo.
echo   Pass a different address as an argument if needed:
echo     CheckAIServers.bat 192.168.1.99
echo.

where curl >nul 2>&1
if errorlevel 1 (
    echo   [FAIL] curl not found. Needs Windows 10 1803 or newer.
    pause
    exit /b 1
)

REM ── PHASE 1: CAN WE REACH THE PORTS AT ALL ──────────────────
echo ============================================================
echo  PHASE 1 - TCP reachability
echo ============================================================
echo.
call :REACH 11435 "Tanu Proxy"
call :REACH 8080  "Whisper STT"
call :REACH 5002  "Coqui TTS "

if !FAIL_N! GTR 0 (
    echo.
    echo   Ports are unreachable - skipping the functional tests.
    goto SUMMARY
)

REM ── PHASE 2: DO THE SERVICES ANSWER CORRECTLY ───────────────
echo.
echo ============================================================
echo  PHASE 2 - Service responses
echo ============================================================
echo.

REM -- 2a. Proxy health. Proves the proxy is up AND reaching Ollama.
echo   [2a] Tanu Proxy /health
curl -s --connect-timeout 5 --max-time 15 -o "%OUT%\proxy_health.json" "http://%SERVER%:11435/health" >nul 2>&1
if errorlevel 1 (
    call :BAD "proxy /health did not respond"
) else (
    find /I "ok" "%OUT%\proxy_health.json" >nul 2>&1
    if errorlevel 1 (
        call :BAD "proxy /health returned unexpected content"
        type "%OUT%\proxy_health.json"
    ) else (
        call :GOOD "proxy healthy"
        echo        Reported:
        type "%OUT%\proxy_health.json"
        echo.
        REM The model the server actually loaded must match the UE config.
        find /I "%MODEL%" "%OUT%\proxy_health.json" >nul 2>&1
        if errorlevel 1 (
            call :WARN "server model differs from %MODEL% - update UE aiVoiceLLMModel"
        )
    )
)
echo.

REM -- 2b. Coqui health. Returns the plain string "ok".
echo   [2b] Coqui TTS /health
curl -s --connect-timeout 5 --max-time 15 -o "%OUT%\tts_health.txt" "http://%SERVER%:5002/health" >nul 2>&1
if errorlevel 1 (
    call :BAD "coqui /health did not respond"
) else (
    find /I "ok" "%OUT%\tts_health.txt" >nul 2>&1
    if errorlevel 1 ( call :BAD "coqui /health returned unexpected content" ) else ( call :GOOD "coqui healthy" )
)
echo.

REM -- 2c. Real TTS. First call loads the model, so allow generous time.
REM Checks the WAV AND the X-Phoneme-Alignment header, which carries the
REM lip-sync timings. Audio without that header means dead lip sync.
echo   [2c] Coqui TTS /api/tts  - generating speech
curl -s --connect-timeout 5 --max-time 180 -D "%OUT%\tts_headers.txt" -o "%OUT%\tts.wav" "http://%SERVER%:5002/api/tts?text=the%%20quick%%20brown%%20fox&speaker_id=%SPEAKER%" >nul 2>&1
if errorlevel 1 (
    call :BAD "TTS request failed or timed out"
) else (
    set "SZ=0"
    for %%A in ("%OUT%\tts.wav") do set "SZ=%%~zA"
    if !SZ! LSS 1000 (
        call :BAD "TTS returned only !SZ! bytes - not audio"
        type "%OUT%\tts.wav"
    ) else (
        call :GOOD "TTS returned !SZ! bytes of audio"
        find /I "X-Phoneme-Alignment" "%OUT%\tts_headers.txt" >nul 2>&1
        if errorlevel 1 (
            call :WARN "no X-Phoneme-Alignment header - lip sync will not work"
        ) else (
            call :GOOD "phoneme alignment header present - lip sync data OK"
        )
    )
)
echo.

REM -- 2d. Round trip: feed the generated speech back to Whisper.
REM This proves STT works on real audio, not just that the port is open.
echo   [2d] Whisper /inference - transcribing that audio back
if not exist "%OUT%\tts.wav" (
    call :WARN "no audio from step 2c - cannot test STT"
) else (
    curl -s --connect-timeout 5 --max-time 120 -o "%OUT%\stt.json" -F file=@"%OUT%\tts.wav" -F temperature=0.0 "http://%SERVER%:8080/inference" >nul 2>&1
    if errorlevel 1 (
        call :BAD "whisper request failed or timed out"
    ) else (
        call :GOOD "whisper responded"
        echo        Transcribed:
        type "%OUT%\stt.json"
        echo.
        REM Spoken phrase was "the quick brown fox".
        find /I "fox" "%OUT%\stt.json" >nul 2>&1
        if errorlevel 1 (
            call :WARN "transcript does not contain 'fox' - STT accuracy is off"
        ) else (
            call :GOOD "round trip verified - TTS audio transcribed correctly"
        )
    )
)
echo.

REM -- 2e. Real LLM call through the proxy. Slowest test: a cold model
REM load plus generation. Also proves Ollama behind the proxy works.
echo   [2e] Tanu Proxy /api/generate - asking the LLM
echo        (first call can take a minute while the model loads)
curl -s --connect-timeout 5 --max-time 240 -o "%OUT%\gen.json" -H "Content-Type: application/json" -d "{\"model\":\"%MODEL%\",\"prompt\":\"Say hello in a few words.\",\"session_id\":\"conncheck\",\"stream\":false}" "http://%SERVER%:11435/api/generate" >nul 2>&1
if errorlevel 1 (
    call :BAD "LLM request failed or timed out"
) else (
    REM findstr handles the \" escaping correctly. Plain find does not - it passes
    REM the backslashes through literally and never matches.
    findstr /I /C:"\"error\"" "%OUT%\gen.json" >nul 2>&1
    if errorlevel 1 (
        findstr /I /C:"\"response\"" "%OUT%\gen.json" >nul 2>&1
        if errorlevel 1 (
            call :BAD "reply missing the 'response' field"
            type "%OUT%\gen.json"
        ) else (
            call :GOOD "LLM replied"
            echo        Reply:
            type "%OUT%\gen.json"
            echo.
            REM UE parses emotion tags like ^<neutral^>...^</neutral^> from the reply.
            find "</" "%OUT%\gen.json" >nul 2>&1
            if errorlevel 1 (
                call :WARN "no emotion tags in reply - UE expects them"
            ) else (
                call :GOOD "emotion tags present"
            )
        )
    ) else (
        call :BAD "proxy returned an error"
        type "%OUT%\gen.json"
    )
)

REM -- Clean up the test session so it leaves no history behind.
curl -s --max-time 15 -o nul -H "Content-Type: application/json" -d "{\"session_id\":\"conncheck\"}" "http://%SERVER%:11435/reset" >nul 2>&1

:SUMMARY
echo.
echo ============================================================
echo  RESULT
echo ============================================================
echo    Passed   : !PASS_N!
echo    Warnings : !WARN_N!
echo    Failed   : !FAIL_N!
echo.

if !FAIL_N! GTR 0 (
    echo   NOT READY. Fix the failures above.
    echo.
    echo   How to read them:
    echo     REFUSED  - the server is bound to 127.0.0.1, or is not running.
    echo                On the server PC run:  netstat -ano ^| findstr ":8080 :5002 :11435"
    echo                Every line must show 0.0.0.0, not 127.0.0.1.
    echo     TIMEOUT  - firewall is blocking the inbound connection.
    echo                First check the profile on the server PC:
    echo                  Get-NetConnectionProfile
    echo                A profile=private rule does NOT match a Public network.
    echo                Safest rule, works on any profile, LAN-scoped. Elevated:
    echo                netsh advfirewall firewall add rule name="ErosRealm AI Servers"
    echo                  dir=in action=allow protocol=TCP localport=8080,5002,11435
    echo                  profile=any remoteip=192.168.1.0/24
    echo.
    echo   Test files kept for inspection: %OUT%
    echo.
    pause
    exit /b 1
)

echo   ALL SERVERS REACHABLE AND RESPONDING CORRECTLY.
if !WARN_N! GTR 0 echo   Review the warnings above - not fatal, but check them.
echo.
echo   Play this to confirm the audio is real:
echo     %OUT%\tts.wav
echo.
echo ============================================================
echo  PUT THIS IN THE UE PROJECT ON THIS PC
echo ============================================================
echo.
echo   Config\DefaultErosRealmOnline.ini    (committed, team-wide)
echo   or Saved\Config\WindowsEditor\ErosRealmOnline.ini   (local only)
echo.
echo   [/Script/ErosRealmOnline.ErosRealmOnlineConfig]
echo   aiVoiceSTTURL="http://%SERVER%:8080/inference"
echo   aiVoiceLLMURL="http://%SERVER%:11435/api/generate"
echo   aiVoiceLLMResetURL="http://%SERVER%:11435/reset"
echo   aiVoiceTTSURL="http://%SERVER%:5002/api/tts"
echo.
pause
exit /b 0

REM ── SUBROUTINES ─────────────────────────────────────────────

REM Reach test. A 404 still counts as reachable - it proves TCP and HTTP
REM completed, which is all this phase is asking.
:REACH
curl -s -o nul --connect-timeout 5 "http://%SERVER%:%~1/" >nul 2>&1
set "EC=!errorlevel!"
if "!EC!"=="0" (
    echo   [PASS] %~2  port %~1  reachable
    set /a PASS_N+=1
    goto :eof
)
if "!EC!"=="7" (
    echo   [FAIL] %~2  port %~1  REFUSED  - bound to 127.0.0.1, or not running
    set /a FAIL_N+=1
    goto :eof
)
if "!EC!"=="28" (
    echo   [FAIL] %~2  port %~1  TIMEOUT  - firewall, or network set to Public
    set /a FAIL_N+=1
    goto :eof
)
if "!EC!"=="6" (
    echo   [FAIL] %~2  port %~1  host '%SERVER%' will not resolve
    set /a FAIL_N+=1
    goto :eof
)
echo   [FAIL] %~2  port %~1  curl error !EC!
set /a FAIL_N+=1
goto :eof

:GOOD
echo        [PASS] %~1
set /a PASS_N+=1
goto :eof

:BAD
echo        [FAIL] %~1
set /a FAIL_N+=1
goto :eof

:WARN
echo        [WARN] %~1
set /a WARN_N+=1
goto :eof
