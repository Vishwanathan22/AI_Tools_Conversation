@echo off
setlocal enabledelayedexpansion
title Eros Realms AI Voice Servers - ONE TIME SETUP
color 0E

REM Short 8.3 path of this script's folder, so a path with spaces cannot
REM break the nested quoting in the venv and pip calls below.
set "TOOLS=%~sdp0"
set "OLLAMA_MODEL=mistral:7b-instruct-q4_K_M"
set "PYVER=3.10"
set "FWRULE=ErosRealm AI Servers"
REM profile=any because a private-profile rule never matches a Public network.
REM remoteip keeps it scoped to the LAN. Change if your subnet differs.
set "LANSCOPE=192.168.1.0/24"
set "TORCH_PIN=torch==2.12.1"
set "TORCH_INDEX=https://download.pytorch.org/whl/cpu"
set NEEDS_RESTART=0

echo ============================================================
echo  EROS REALMS AI VOICE SERVERS - ONE TIME SETUP
echo ============================================================
echo   Root : %TOOLS%
echo.
echo   Run this ONCE on a new machine. Afterwards use
echo   StartAIServers_LAN.bat for day to day launching.
echo.

REM ── ELEVATION ───────────────────────────────────────────────
REM winget installs and the firewall rule both require admin.
net session >nul 2>&1
if errorlevel 1 (
    echo   [FAIL] This window is not elevated.
    echo          Right-click SetupAIServers.bat and pick Run as administrator.
    echo.
    pause
    exit /b 1
)
echo   [ok]   Running elevated.

REM ── SOURCE FILES PRESENT? ───────────────────────────────────
echo.
echo Checking copied files...
set SRC_OK=1
for %%F in (coqui_aligned_server.py tanu_llm_proxy.py requirements-coqui.txt) do (
    if not exist "%TOOLS%%%F" (
        echo   [FAIL] missing %%F
        set SRC_OK=0
    ) else (
        echo   [ok]   %%F
    )
)
if not exist "%TOOLS%whisper.cpp\build\bin\Release\whisper-server.exe" (
    echo   [FAIL] missing whisper.cpp\build\bin\Release\whisper-server.exe
    set SRC_OK=0
) else (
    echo   [ok]   whisper-server.exe
)
if !SRC_OK!==0 (
    echo.
    echo   Copy the whole tools folder across first, then re-run.
    echo.
    pause
    exit /b 1
)

REM ── WINGET ──────────────────────────────────────────────────
where winget >nul 2>&1
if errorlevel 1 (
    set HAS_WINGET=0
    echo   [WARN] winget not found - Python and Ollama must be installed by hand.
) else (
    set HAS_WINGET=1
)

REM ── PYTHON 3.10 ─────────────────────────────────────────────
REM Pinned to 3.10: TTS 0.22.0 has no wheels for 3.12+ and will not build.
echo.
echo ============================================================
echo  [1/6] Python %PYVER%
echo ============================================================
py -%PYVER% --version >nul 2>&1
if errorlevel 1 (
    echo   Not found. Installing...
    if !HAS_WINGET!==1 (
        winget install -e --id Python.Python.%PYVER% --accept-source-agreements --accept-package-agreements
        py -%PYVER% --version >nul 2>&1
        if errorlevel 1 (
            echo   [WARN] Installed, but not visible in this shell yet.
            set NEEDS_RESTART=1
        ) else (
            echo   [ok]   Python %PYVER% ready.
        )
    ) else (
        echo   [FAIL] Install Python %PYVER% from https://www.python.org/downloads/
        echo          Tick "Add python.exe to PATH" during install.
        pause
        exit /b 1
    )
) else (
    for /f "tokens=*" %%v in ('py -%PYVER% --version 2^>^&1') do echo   [ok]   %%v
)
if !NEEDS_RESTART!==1 goto RESTART_NEEDED

REM ── OLLAMA ──────────────────────────────────────────────────
echo.
echo ============================================================
echo  [2/6] Ollama
echo ============================================================
where ollama >nul 2>&1
if errorlevel 1 (
    echo   Not found. Installing...
    if !HAS_WINGET!==1 (
        winget install -e --id Ollama.Ollama --accept-source-agreements --accept-package-agreements
        REM winget does not refresh PATH in an open shell; add the default dir.
        if exist "%LOCALAPPDATA%\Programs\Ollama\ollama.exe" set "PATH=%PATH%;%LOCALAPPDATA%\Programs\Ollama"
        where ollama >nul 2>&1
        if errorlevel 1 (
            echo   [WARN] Installed, but not visible in this shell yet.
            set NEEDS_RESTART=1
        ) else (
            echo   [ok]   Ollama ready.
        )
    ) else (
        echo   [FAIL] Install Ollama from https://ollama.com/download
        pause
        exit /b 1
    )
) else (
    echo   [ok]   Ollama already installed.
)
if !NEEDS_RESTART!==1 goto RESTART_NEEDED

REM ── OLLAMA MODEL ────────────────────────────────────────────
echo.
echo ============================================================
echo  [3/6] Model %OLLAMA_MODEL%
echo ============================================================
ollama list 2>nul | find "%OLLAMA_MODEL%" >nul
if errorlevel 1 (
    echo   Pulling - this is a few GB, it will take a while...
    ollama pull %OLLAMA_MODEL%
    if errorlevel 1 (
        echo   [FAIL] Pull failed. Check the network and re-run.
        pause
        exit /b 1
    )
    echo   [ok]   Model pulled.
) else (
    echo   [ok]   Model already present.
)

REM ── COQUI VENV ──────────────────────────────────────────────
REM A venv bakes absolute paths into its scripts, so one copied from
REM another machine is dead on arrival. Detect that and rebuild.
echo.
echo ============================================================
echo  [4/6] Coqui TTS virtual environment
echo ============================================================
set REBUILD_VENV=0
if not exist "%TOOLS%coqui-tts\venv\Scripts\python.exe" (
    echo   No venv found - creating.
    set REBUILD_VENV=1
) else (
    "%TOOLS%coqui-tts\venv\Scripts\python.exe" -c "pass" >nul 2>&1
    if errorlevel 1 (
        echo   Existing venv is broken - it was copied from another machine.
        echo   Deleting and rebuilding...
        rmdir /s /q "%TOOLS%coqui-tts\venv"
        set REBUILD_VENV=1
    ) else (
        echo   [ok]   Working venv already present.
    )
)

if !REBUILD_VENV!==1 (
    if not exist "%TOOLS%coqui-tts" mkdir "%TOOLS%coqui-tts"
    py -%PYVER% -m venv "%TOOLS%coqui-tts\venv"
    if errorlevel 1 (
        echo   [FAIL] venv creation failed.
        pause
        exit /b 1
    )
    echo   [ok]   venv created.
)

set "VPY=%TOOLS%coqui-tts\venv\Scripts\python.exe"

echo.
echo   Upgrading pip...
"%VPY%" -m pip install --upgrade pip --quiet
if errorlevel 1 echo   [WARN] pip upgrade failed - continuing.

REM torch first, from the CPU index. Left to the lock file pip would take
REM the default PyPI wheel, which is the ~2.5GB CUDA build.
echo.
echo   Installing %TORCH_PIN% (CPU build)...
"%VPY%" -m pip install %TORCH_PIN% --index-url %TORCH_INDEX%
if errorlevel 1 (
    echo   [FAIL] torch install failed.
    pause
    exit /b 1
)
echo   [ok]   torch installed.

echo.
echo   Installing the locked package set (146 packages, several minutes)...
"%VPY%" -m pip install -r "%TOOLS%requirements-coqui.txt"
if errorlevel 1 (
    echo   [FAIL] Package install failed. Scroll up for the first error.
    pause
    exit /b 1
)
echo   [ok]   Coqui environment ready.

REM ── TANU PROXY DEPS ─────────────────────────────────────────
REM StartAIServers runs the proxy under system python, not the venv,
REM so flask and requests must exist there too.
echo.
echo ============================================================
echo  [5/6] Tanu proxy dependencies (system Python)
echo ============================================================
where python >nul 2>&1
if errorlevel 1 (
    echo   [WARN] No 'python' on PATH. The proxy will not start.
    echo          Either add Python to PATH, or edit StartAIServers_LAN.bat
    echo          to launch the proxy with the venv python instead.
) else (
    python -m pip install flask requests --quiet
    if errorlevel 1 (
        echo   [WARN] Install failed - check the proxy manually.
    ) else (
        echo   [ok]   flask + requests installed.
    )
)

REM ── WHISPER MODEL + FOLDERS + FIREWALL ──────────────────────
echo.
echo ============================================================
echo  [6/6] Whisper model, folders, firewall
echo ============================================================
if not exist "%TOOLS%whisper.cpp\models\ggml-small.en.bin" (
    echo   Downloading ggml-small.en.bin...
    pushd "%TOOLS%whisper.cpp\models"
    call download-ggml-model.cmd small.en
    popd
    if not exist "%TOOLS%whisper.cpp\models\ggml-small.en.bin" (
        echo   [FAIL] Model download failed. Fetch it by hand from
        echo          https://huggingface.co/ggerganov/whisper.cpp
        pause
        exit /b 1
    )
    echo   [ok]   Whisper model downloaded.
) else (
    echo   [ok]   Whisper model already present.
)

REM Conversation history lives here. It does not travel unless copied.
if not exist "%TOOLS%tanu_memory" (
    mkdir "%TOOLS%tanu_memory"
    echo   [ok]   Created empty tanu_memory - no prior chat history on this box.
) else (
    echo   [ok]   tanu_memory present.
)

REM Always delete then re-add. An existing rule may sit on the wrong profile,
REM and a name-only check would skip fixing it.
netsh advfirewall firewall delete rule name="%FWRULE%" >nul 2>&1
netsh advfirewall firewall add rule name="%FWRULE%" dir=in action=allow protocol=TCP localport=8080,5002,11435 profile=any remoteip=%LANSCOPE% >nul 2>&1
if errorlevel 1 (
    echo   [WARN] Firewall rule failed - open TCP 8080, 5002, 11435 by hand.
) else (
    echo   [ok]   Firewall set: TCP 8080, 5002, 11435 from %LANSCOPE%, all profiles.
)
REM Report which profile is active, so a Public network is visible up front.
echo.
echo   Network profile on this machine:
powershell -NoProfile -Command "Get-NetConnectionProfile | Select-Object Name,InterfaceAlias,NetworkCategory | Format-Table -AutoSize" 2>nul

echo.
echo ============================================================
echo   SETUP COMPLETE
echo ============================================================
echo.
echo   Next:
echo     1. Make sure this PC's network is set to Private, or the
echo        firewall rule will not apply.
echo     2. Run StartAIServers_LAN.bat
echo     3. Copy the ini block it prints into the UE machine's
echo        Config\DefaultErosRealmOnline.ini
echo.
echo   Note: whisper-server.exe here was built with CUDA support.
echo   Without an NVIDIA driver it falls back to CPU, which is slower
echo   but works. Nothing to change.
echo.
pause
exit /b 0

:RESTART_NEEDED
echo.
echo ============================================================
echo   REOPEN AND RE-RUN
echo ============================================================
echo.
echo   Something was just installed but is not on PATH in this
echo   window yet. Close it, open a new elevated window, and run
echo   this script again. It will skip what is already done.
echo.
pause
exit /b 2
