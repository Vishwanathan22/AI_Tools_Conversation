@echo off
setlocal enabledelayedexpansion
title Eros Realms AI Voice Servers
color 0A

echo ============================================================
echo  EROS REALMS AI VOICE SERVER LAUNCHER
echo ============================================================
echo.

REM ── KILL EXISTING INSTANCES FIRST ───────────────────────────
echo Checking for existing server processes...
echo.

REM Kill Ollama
tasklist /FI "IMAGENAME eq ollama.exe" 2>nul | find /I "ollama.exe" >nul
if !errorlevel!==0 (
    echo   [Ollama]      Found running — stopping...
    taskkill /F /IM ollama.exe >nul 2>&1
    timeout /t 2 /nobreak >nul
    echo   [Ollama]      Stopped.
) else (
    echo   [Ollama]      Not running.
)

REM Kill whisper-server
tasklist /FI "IMAGENAME eq whisper-server.exe" 2>nul | find /I "whisper-server.exe" >nul
if !errorlevel!==0 (
    echo   [Whisper]     Found running — stopping...
    taskkill /F /IM whisper-server.exe >nul 2>&1
    timeout /t 2 /nobreak >nul
    echo   [Whisper]     Stopped.
) else (
    echo   [Whisper]     Not running.
)

REM Kill python (Coqui TTS runs as python.exe)
REM Only kill python processes on port 5002 to avoid killing unrelated python
echo   [Coqui TTS]   Checking port 5002...
for /f "tokens=5" %%a in ('netstat -ano ^| find ":5002" ^| find "LISTENING"') do (
    echo   [Coqui TTS]   Found on port 5002 PID %%a — stopping...
    taskkill /F /PID %%a >nul 2>&1
)
timeout /t 2 /nobreak >nul

REM Kill any whisper-server or server.exe on port 8080
echo   [Whisper]     Checking port 8080...
for /f "tokens=5" %%a in ('netstat -ano ^| find ":8080" ^| find "LISTENING"') do (
    echo   [Whisper]     Found on port 8080 PID %%a — stopping...
    taskkill /F /PID %%a >nul 2>&1
)
timeout /t 2 /nobreak >nul

REM Kill anything on port 11434 (Ollama)
echo   [Ollama]      Checking port 11434...
for /f "tokens=5" %%a in ('netstat -ano ^| find ":11434" ^| find "LISTENING"') do (
    echo   [Ollama]      Found on port 11434 PID %%a — stopping...
    taskkill /F /PID %%a >nul 2>&1
)
timeout /t 2 /nobreak >nul

REM Kill anything on port 11435 (Tanu persona/memory proxy)
echo   [Tanu Proxy]  Checking port 11435...
for /f "tokens=5" %%a in ('netstat -ano ^| find ":11435" ^| find "LISTENING"') do (
    echo   [Tanu Proxy]  Found on port 11435 PID %%a — stopping...
    taskkill /F /PID %%a >nul 2>&1
)
timeout /t 2 /nobreak >nul

echo.
echo   All existing instances cleared.
echo   Waiting 3 seconds before fresh start...
timeout /t 3 /nobreak >nul

echo.
echo ============================================================
echo  STARTING SERVERS
echo ============================================================
echo.

REM ── 1. OLLAMA ──────────────────────────────────────────────
echo [1/4] Starting Ollama...
REM OLLAMA_HOST is the only way to change the bind address - there is no --host flag.
start "Ollama" cmd /k "set OLLAMA_HOST=0.0.0.0:11434 && set OLLAMA_VULKAN=false && set CUDA_VISIBLE_DEVICES=-1 && set HIP_VISIBLE_DEVICES=-1 && set GGML_VK_VISIBLE_DEVICES=-1 && ollama serve"
timeout /t 3 /nobreak >nul

REM ── 2. WHISPER.CPP ─────────────────────────────────────────
echo [2/4] Starting whisper.cpp...
start "Whisper" cmd /k "cd /d E:\tools\whisper.cpp && build\bin\Release\whisper-server.exe --model models\ggml-small.en.bin --host 0.0.0.0 --port 8080"
timeout /t 3 /nobreak >nul

REM ── 3. COQUI TTS (aligned — returns phoneme timings for lip sync) ──
REM --length_scale 1.15 slows speech ~15%% so the UE lip-sync blend gets more
REM frames per phoneme (pitch preserved; alignment stretches to match). This is
REM the server-side fallback default — the UE client also sends its own
REM length_scale query param, which overrides this per request.
echo [3/4] Starting Coqui TTS (aligned)...
start "CoquiTTS" cmd /k "cd /d E:\tools && call coqui-tts\venv\Scripts\activate && python coqui_aligned_server.py --model_name tts_models/en/vctk/vits --host 0.0.0.0 --port 5002 --length_scale 1.15"
timeout /t 3 /nobreak >nul

REM ── 4. TANU PERSONA/MEMORY PROXY (wraps Ollama with persona + history) ──
echo [4/4] Starting Tanu persona/memory proxy...
REM Binds wide for the LAN client, but reaches Ollama over loopback - same box.
start "TanuProxy" cmd /k "cd /d E:\tools && python tanu_llm_proxy.py --host 0.0.0.0 --port 11435 --ollama_url http://localhost:11434"

echo.
echo   Waiting 10 seconds for servers to initialize...
timeout /t 10 /nobreak >nul

REM ── VERIFY FUNCTION (3 attempts x 10s) ─────────────────────
echo.
echo ============================================================
echo  Verifying servers (3 attempts, 10s apart)
echo ============================================================

set OLLAMA_OK=0
set WHISPER_OK=0
set COQUI_OK=0
set TANUPROXY_OK=0
set ATTEMPT=0

REM Generate test wav once for whisper check
curl -s "http://localhost:5002/api/tts?text=test&speaker_id=p248&style_wav=" --output "%TEMP%\tts_test.wav" >nul 2>&1

:ATTEMPT_LOOP
set /a ATTEMPT+=1
echo.
echo ── Attempt %ATTEMPT% of 3 ──────────────────────────────────

REM Check Ollama
if %OLLAMA_OK%==0 (
    curl -s --max-time 5 http://localhost:11434/api/generate -d "{\"model\":\"mistral:7b-instruct-q4_K_M\",\"prompt\":\"hi\",\"stream\":false}" >nul 2>&1
    if !errorlevel!==0 (
        set OLLAMA_OK=1
        echo   [Ollama]      OK
    ) else (
        echo   [Ollama]      waiting...
    )
) else (
    echo   [Ollama]      OK
)

REM Check Coqui TTS
if %COQUI_OK%==0 (
    curl -s --max-time 10 "http://localhost:5002/api/tts?text=test&speaker_id=p248&style_wav=" --output "%TEMP%\tts_test.wav" >nul 2>&1
    if !errorlevel!==0 (
        set COQUI_OK=1
        echo   [Coqui TTS]   OK
    ) else (
        echo   [Coqui TTS]   waiting...
    )
) else (
    echo   [Coqui TTS]   OK
)

REM Check Whisper
if %WHISPER_OK%==0 (
    curl -s --max-time 5 http://localhost:8080/inference -F file=@"%TEMP%\tts_test.wav" -F temperature=0.0 >nul 2>&1
    if !errorlevel!==0 (
        set WHISPER_OK=1
        echo   [Whisper]     OK
    ) else (
        echo   [Whisper]     waiting...
    )
) else (
    echo   [Whisper]     OK
)

REM Check Tanu proxy
if %TANUPROXY_OK%==0 (
    curl -s --max-time 5 http://localhost:11435/health >nul 2>&1
    if !errorlevel!==0 (
        set TANUPROXY_OK=1
        echo   [Tanu Proxy]  OK
    ) else (
        echo   [Tanu Proxy]  waiting...
    )
) else (
    echo   [Tanu Proxy]  OK
)

REM Check if all OK — exit early
if %OLLAMA_OK%==1 if %COQUI_OK%==1 if %WHISPER_OK%==1 if %TANUPROXY_OK%==1 goto ALL_OK

REM If not last attempt, wait and retry
if %ATTEMPT% LSS 3 (
    echo.
    echo   Not all servers ready. Waiting 10 seconds before next attempt...
    timeout /t 10 /nobreak >nul
    goto ATTEMPT_LOOP
)

REM ── FINAL RESULT AFTER 3 FAILED ATTEMPTS ───────────────────
echo.
echo ============================================================
echo  FINAL STATUS after 3 attempts:
echo ============================================================
if %OLLAMA_OK%==1 (
    echo   [Ollama]      ONLINE
) else (
    echo   [Ollama]      NOT RESPONDING — check the Ollama window for errors
)
if %COQUI_OK%==1 (
    echo   [Coqui TTS]   ONLINE
) else (
    echo   [Coqui TTS]   NOT RESPONDING — check the CoquiTTS window for errors
)
if %WHISPER_OK%==1 (
    echo   [Whisper]     ONLINE
) else (
    echo   [Whisper]     NOT RESPONDING — check the Whisper window for errors
)
if %TANUPROXY_OK%==1 (
    echo   [Tanu Proxy]  ONLINE
) else (
    echo   [Tanu Proxy]  NOT RESPONDING — check the TanuProxy window for errors
)
echo.
echo   Fix the failing servers above before launching UE editor.
echo ============================================================
echo.
pause
exit /b

:ALL_OK
echo.
echo ============================================================
echo   ALL SERVERS ONLINE
echo   Safe to launch UE editor and start PIE.
echo ============================================================
echo.

REM Snapshot all GPU-using PIDs once for all checks below
nvidia-smi --query-compute-apps=pid --format=csv,noheader > "%TEMP%\gpu_pids.txt" 2>nul

echo ============================================================
echo  AI MODEL PROCESSOR STATUS
echo ============================================================
echo.
echo [Ollama]  ────────────────────────────────────────────────
ollama ps
echo.

echo [Whisper.cpp]   ggml-small.en.bin   ^| port 8080
set WHISPER_PROC=CPU
for /f "tokens=2" %%p in ('tasklist /FI "IMAGENAME eq whisper-server.exe" /FO LIST 2^>nul ^| find "PID:"') do (
    find "%%p" "%TEMP%\gpu_pids.txt" >nul 2>&1
    if !errorlevel!==0 set WHISPER_PROC=GPU
)
echo   PROCESSOR : !WHISPER_PROC!
echo.

echo [Coqui TTS]     tts_models/en/vctk/vits   ^| port 5002
set COQUI_PROC=CPU
for /f "tokens=5" %%p in ('netstat -ano 2^>nul ^| find ":5002" ^| find "LISTENING"') do (
    find "%%p" "%TEMP%\gpu_pids.txt" >nul 2>&1
    if !errorlevel!==0 set COQUI_PROC=GPU
)
echo   PROCESSOR : !COQUI_PROC!
echo.

echo [Tanu Proxy]    persona + memory adapter   ^| port 11435
echo.
echo ============================================================
echo.
pause
exit /b