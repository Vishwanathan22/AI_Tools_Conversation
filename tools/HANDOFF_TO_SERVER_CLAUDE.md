# Handoff: make the AI voice servers reachable over the LAN

You are running on the **server machine, 192.168.1.50**. Another Claude session on
the **client machine, 192.168.1.182** produced this. Do the work described here on
your machine, verify it, and report back the exact output asked for at the end.

Do not copy files from the other machine. Edit what is already on yours.

---

## Roles

| Machine | Role |
|---|---|
| 192.168.1.50 (you) | Hosts the four AI servers in `E:\tools` |
| 192.168.1.182 | Runs Unreal Engine, acts as the HTTP client |

The UE client initiates every request. Your machine must accept unsolicited
inbound TCP on 8080, 5002 and 11435.

## The four servers

| Port | Server | Started by |
|---|---|---|
| 11434 | Ollama | `ollama serve` |
| 8080 | whisper.cpp STT | `whisper-server.exe` |
| 5002 | Coqui TTS (aligned) | `coqui_aligned_server.py` |
| 11435 | Tanu persona/memory proxy | `tanu_llm_proxy.py` |

UE never calls Ollama directly. It calls the proxy on 11435, which forwards to
Ollama over loopback on the same machine.

---

## What was measured from the client, and what it means

Facts, gathered from 192.168.1.182:

- ARP for `192.168.1.50` resolves to MAC `4C-CF-7C-2D-F2-50`, state `Reachable`.
  Windows Firewall does not filter ARP, so your machine is powered on, cabled,
  and answering at layer 2. The host is not the problem.
- The route to you is on-link via the `Ethernet` adapter, NextHop `0.0.0.0`.
  No VPN or ZTNA client is intercepting the path.
- ICMP echo from the client to you: **times out**.
- TCP connect from the client to ports 135, 139, 445, 3389, 8080, 5002, 11434,
  11435: **all time out**. Not one returns REFUSED.
- A control probe from the client to a known-good listener on itself returns
  OPEN, so the probe method is sound.

**Diagnosis: your machine drops all unsolicited inbound traffic.**

Timeout and refused mean different things and this distinction drives everything:

- **REFUSED** - the host replied with a TCP RST. Nothing is listening on that
  port, or the listener is bound to `127.0.0.1` only.
- **TIMEOUT** - no reply at all. A firewall is dropping the packet before any
  listener is consulted.

Because every port times out - including standard Windows services on 135, 139,
445 and 3389 - the block is not specific to our three ports. It is the firewall
policy for unsolicited inbound as a whole.

**A ping working in the other direction does not contradict this.** When your
machine pings the client, that is outbound from you, and the reply is solicited
return traffic that your stateful firewall permits because it is already
tracking the flow. It exercises your *outbound* policy. The traffic that matters
here is *inbound* to you, which is a separate rule path. That is why ICMP
succeeds one way and fails the other.

There are two independent faults to fix. The firewall one masks the other: while
packets are dropped, a loopback-bound server and a firewalled server are
indistinguishable from outside.

---

## Task 1 - bind the servers to all interfaces

Open `E:\tools\StartAIServers.bat` (adjust the path if your install differs).

A socket bound to `127.0.0.1` is placed on the loopback interface only. The
kernel never exposes it on the network card, so no other machine can connect
regardless of firewall rules. This is a property of the bind address, not a
permission problem. Bind `0.0.0.0` to listen on all interfaces.

Make these four edits. Match the existing text exactly; if a line already shows
`0.0.0.0`, it is done - leave it.

**1. Ollama.** It has no `--host` flag; it reads the `OLLAMA_HOST` environment
variable. Add it to the front of the existing `set` chain.

Find:
```
start "Ollama" cmd /k "set OLLAMA_VULKAN=false && set CUDA_VISIBLE_DEVICES=-1 && set HIP_VISIBLE_DEVICES=-1 && set GGML_VK_VISIBLE_DEVICES=-1 && ollama serve"
```
Replace with:
```
REM OLLAMA_HOST is the only way to change the bind address - there is no --host flag.
start "Ollama" cmd /k "set OLLAMA_HOST=0.0.0.0:11434 && set OLLAMA_VULKAN=false && set CUDA_VISIBLE_DEVICES=-1 && set HIP_VISIBLE_DEVICES=-1 && set GGML_VK_VISIBLE_DEVICES=-1 && ollama serve"
```

**2. Whisper.** Change `--host 127.0.0.1` to `--host 0.0.0.0` on the line
starting `start "Whisper"`.

**3. Coqui TTS.** Change `--host 127.0.0.1` to `--host 0.0.0.0` on the line
starting `start "CoquiTTS"`. Leave `--length_scale 1.15` alone - it is the
server-side fallback, and the UE client overrides it per request.

**4. Tanu proxy.** Change `--host 127.0.0.1` to `--host 0.0.0.0` on the line
starting `start "TanuProxy"`, and pin the Ollama URL explicitly:

```
REM Binds wide for the LAN client, but reaches Ollama over loopback - same box.
start "TanuProxy" cmd /k "cd /d E:\tools && python tanu_llm_proxy.py --host 0.0.0.0 --port 11435 --ollama_url http://localhost:11434"
```

### Two things in that file to leave alone

- **The verify `curl` calls further down must keep using `localhost`.** They run
  on your machine, testing your own listeners. There are five of them. Changing
  them to the LAN IP would make the script's self-test depend on the firewall it
  is not responsible for.
- **`--ollama_url` stays `localhost`.** The proxy and Ollama are on the same
  machine; that hop must not traverse the network.

### Line endings

Write the file back as **CRLF**. A batch file with LF-only line endings breaks
`goto` and label resolution in cmd, and this script uses both. If your editor
may have normalised to LF, fix it:

```
powershell -NoProfile -Command "$p='E:\tools\StartAIServers.bat'; $c=[IO.File]::ReadAllText($p); $c=$c -replace \"`r`n\",\"`n\" -replace \"`n\",\"`r`n\"; [IO.File]::WriteAllText($p,$c)"
```

---

## Task 2 - fix the firewall rule

A rule named `ErosRealm AI Servers` probably already exists on your machine and
is not working. `SetupAIServers.bat` was run here with an earlier version that
created it with `profile=private`.

Two traps, both of which make a rule look correct while doing nothing:

1. **`profile=private` does not match a Public network.** Windows classifies
   unknown networks as Public. On the client machine both adapters are Public,
   and yours is very likely the same. A private-profile rule then matches no
   traffic at all - it appears in the rule list and every connection still times
   out. Check yours with `Get-NetConnectionProfile`.
2. **`netsh advfirewall firewall add` with an existing name creates a duplicate,
   it does not replace.** So adding a corrected rule while the broken one
   survives leaves the broken one in place. Delete first.

Run this elevated. Delete then add:

```
netsh advfirewall firewall delete rule name="ErosRealm AI Servers"
```

```
netsh advfirewall firewall add rule name="ErosRealm AI Servers" dir=in action=allow protocol=TCP localport=8080,5002,11435 profile=any remoteip=192.168.1.0/24
```

`profile=any` avoids depending on the network classification. `remoteip` scopes
it to the local subnet, so `any` does not mean exposed everywhere - it is
narrower than a Private-profile rule with no remote scope.

Port 11434 is deliberately not opened. UE talks to the proxy on 11435; Ollama
only needs to be reachable from your own machine. Add 11434 only if you
specifically want remote debugging access to Ollama.

If the ports still time out after this, suspect a third-party security suite
enforcing policy above Windows Firewall. Check with:

```
powershell -NoProfile -Command "Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct | Select-Object displayName,productState"
```

### Optional hygiene

If your `SetupAIServers.bat` still contains `profile=private`, or gates the rule
behind a name-only existence check, fix it so a future run self-heals: always
delete then add, and use `profile=any` with a `remoteip` subnet variable.

---

## Task 3 - restart and verify locally

Restart the servers with `StartAIServers.bat` and wait for `ALL SERVERS ONLINE`.
Changing the bat does nothing until the processes are restarted.

**Check 1 - did the bind take.**

```
netstat -ano | findstr ":8080 :5002 :11435"
```

Read the local address column, not the port. Every line must show `0.0.0.0`.
Any line showing `127.0.0.1` means that server ignored the flag or was not
restarted.

**Check 2 - bind versus firewall, isolated.** Call your own LAN IP rather than
localhost. A machine connecting to its own address bypasses inbound firewall
rules, so this tests only the bind:

```
curl.exe http://192.168.1.50:11435/health
```

Expect `{"status":"ok","model":"mistral:7b-instruct-q4_K_M","ollama_url":"http://localhost:11434"}`.
Refused here means the bind is still wrong and no firewall change will help.

In PowerShell use `curl.exe`, not `curl` - bare `curl` is an alias for
`Invoke-WebRequest`, which takes different arguments.

**Check 3 - the other two services.**

```
curl.exe http://192.168.1.50:5002/health
```

```
curl.exe -o test.wav "http://192.168.1.50:5002/api/tts?text=hello&speaker_id=p248"
```

`test.wav` should be several tens of KB. The response also carries an
`X-Phoneme-Alignment` header holding base64 JSON phoneme timings - UE needs it
for lip sync, and audio can arrive without it. Check it with `-D -`:

```
curl.exe -s -D - -o test.wav "http://192.168.1.50:5002/api/tts?text=hello&speaker_id=p248" | findstr /I "X-Phoneme-Alignment"
```

---

## Report back

Paste the raw output of these four, unedited:

1. `netstat -ano | findstr ":8080 :5002 :11435"`
2. `powershell -NoProfile -Command "Get-NetConnectionProfile | Select-Object Name,InterfaceAlias,NetworkCategory"`
3. `netsh advfirewall firewall show rule name="ErosRealm AI Servers"`
4. `curl.exe http://192.168.1.50:11435/health`

Also state whether all four server windows are running, and paste any error text
from the CoquiTTS or TanuProxy windows.

The client side will then re-run its checker. The signal to watch for: if the
result changes from TIMEOUT to REFUSED, the firewall is fixed and only the bind
address remains wrong.

## Reference - what the client will set once this works

For context only; do not change anything in the UE project from this machine.
On the client, in `Config\DefaultErosRealmOnline.ini`:

```ini
[/Script/ErosRealmOnline.ErosRealmOnlineConfig]
aiVoiceSTTURL="http://192.168.1.50:8080/inference"
aiVoiceLLMURL="http://192.168.1.50:11435/api/generate"
aiVoiceLLMResetURL="http://192.168.1.50:11435/reset"
aiVoiceTTSURL="http://192.168.1.50:5002/api/tts"
```
