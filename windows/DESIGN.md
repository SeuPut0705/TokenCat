# TokenCat for Windows — design (v1)

Status: implemented in 0.11.0 (`windows/`). Design record; code comments cite its § numbers; where it differs from the code, the code wins.
Scope rule: port the mac app's specs, not its UI toolkit. One Core library holds every rule and every check; the Windows
shell is thin. No third-party packages.

### Changes from review (2026-10-05)
Facts marked *probed* were run on this Mac (.NET 10.0.401); the rest are Windows behaviours the CI/PC steps must confirm.
1. **JSON from other apps (probed):** `JsonDocument.Parse(bytes)` throws on a UTF-8 BOM (Swift `JSONSerialization` accepts it), and
   `Utf8JsonWriter` by default escapes Korean/`&`/`+`/`'` as `\uXXXX` and writes `Environment.NewLine` (CRLF on Windows). Rule 3 (§6.2) now
   fixes all three, or `settings.json` gets rewritten in a different form and BOM files are treated as invalid.
2. **Log change detection:** on NTFS the size/mtime held in a directory listing lags while a writer keeps the file open (Codex keeps its
   rollout open). Per-tick size comes from a fresh `FileInfo` query, never from enumeration data. A Windows CI case covers it (rule 8, WP1).
3. **Tray/flyout bugs that only show on Windows:** `NotifyIcon.Click` also fires for the right button; clicking the icon while the flyout
   is open hides it on `Deactivated` and the same click reopens it; WPF `Left/Top` across mixed-DPI monitors misplaces it; a second
   launch can't give the first instance the foreground unless it calls `AllowSetForegroundWindow` first; `AllowsTransparency` makes a
   software-rendered layered window. Fixed in §2.9/§4.2 and **built into the spike** so the PC smoke test exercises them.
4. **Settings store race:** a JSON file isn't `UserDefaults`. A CLI process (`--disconnect-telemetry`) and the running app would
   overwrite each other's keys. Every write is now a read-modify-write under a named mutex (§7.2).
5. **Name collisions (C# compile errors):** `Monitor` collides with `System.Threading.Monitor` under implicit usings → `LiveMonitor`.
   The static class `ClaudeLimits` is hidden by the `ClaudeLimits` property it sits next to → `ClaudeUsage`.
6. **Build/publish:** publish settings live in the App csproj (`dotnet publish -c Release` alone gives one `TokenCat.exe` with no pdb);
   `ko` satellite resources are kept (WPF/WinForms built-in strings); an empty version from `build.sh` fails the build;
   `Application.SetColorMode` compiles warning-free on .NET 10 (whether the menu really renders dark → PC). Spike re-run (§1 #13).
7. **Cut:** the arm64 PE branch in the updater (x64 only), the Python ICO snippet (one `sips` command), and the stale action versions.
   CI now tests the real release zip (`--update-selftest <zip>`) and runs the exact bridge command through both Git Bash and PowerShell.
8. **Wrong claim fixed:** `Path.GetFileName` splits on `\` and `/` on Windows but only on `/` on macOS. Hence the explicit split.
9. **PC checklist** gains: console-window flash from the bridge when Claude Code runs without a console (IDE/Desktop), context menu
   keyboard/dark mode, live Codex update latency, and Defender scan result.

---

## 0. Decisions at a glance

| Topic | Decision | Why |
|---|---|---|
| Stack | C# / .NET 10 (LTS). `TokenCat.Core` = `net10.0` (no Windows APIs). `TokenCat.App` = `net10.0-windows`, WPF + `System.Windows.Forms.NotifyIcon`. | Approved. Core builds and runs its checks on macOS, Linux and Windows. |
| Packages | None. JSON = `System.Text.Json`, HTTP client = `HttpClient`, zip = `System.IO.Compression`, collector = `TcpListener`. | Stdlib covers all of it. |
| Distribution | Self-contained single-file `TokenCat.exe` (win-x64) in `TokenCat-Windows.zip` (+ `LICENSE`) on the same GitHub release as `TokenCat.zip`. | One file, no runtime install. Default is x64 only; Windows on ARM runs it under emulation (open question 4). |
| Compression | `EnableCompressionInSingleFile=false` by default (156 MB exe, 64 MB zip). | The download is the same size either way. Uncompressed assemblies are memory-mapped instead of inflated into private RAM, which matters for an app that runs all day. To measure on the PC (open question 3). |
| Collector | `TcpListener(IPAddress.Loopback, 16493)`, `ExclusiveAddressUse = true`, plus the ported `TelemetryHTTP.parse`. | No admin or URL ACL (`HttpListener`/http.sys needs one). It reuses the mac parser and its checks (Origin 403, caps). |
| Tray art | Icon ≥ 30 px (200 %+): full-body sprite at 1×. Below that (100–175 %): the cat **head** (existing 12×11 / 24×22 art), with pose shown by head variant + 1-art-px bob, and a corner dot for input/retry. | The 30×18 cell fits only a 32 px icon pixel-perfectly (measured, §2.1). Scaling pixel art by a non-integer ruins it. |
| Claude limits | (a) `%APPDATA%\Claude\plan-usage-history.json` when present. (b) The statusLine bridge as a PowerShell script, added **only when settings has no statusLine** in v1. | Re-running an existing command needs the shell Claude Code used (Git Bash or PowerShell). That can't be verified here (open question 2). |
| Notifications | Opt-in, `NotifyIcon.ShowBalloonTip` (Windows shows it as a toast). No WinRT/App SDK. | Zero packages and no AUMID/shortcut registration. Transient on Windows 11 (open question 9). |
| Login item | Opt-in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\TokenCat = "<exe path>"`. Status also reads `…\Explorer\StartupApproved\Run` (never writes it). | No admin. Task Manager's "disabled" state is visible. |
| Updates | Same GitHub `releases/latest`, asset `TokenCat-Windows.zip`, size + `sha256:` digest check, rename-then-replace of the running exe, relaunch. | The mac contract is unchanged (the mac app only looks for `TokenCat.zip`). |
| State | `%LOCALAPPDATA%\TokenCat\` holds `settings.json` (UserDefaults equivalent, **same key names**, read-modify-write under a named mutex), `telemetry-connection.json`, `telemetry-backups\` and `claude-statusline.ps1`. | Per-machine state, like Application Support. |
| Signing | Unsigned v1. | Signing has a cost and an eligibility question (open question 5). |

---

## 1. Spike (throwaway) — `spike/`

Layout: `spike/TokenCat.Windows.slnx`, `Directory.Build.props`, `TokenCat.Core` (net10.0), `TokenCat.Checks` (net10.0 console),
`TokenCat.App` (net10.0-windows, WPF + NotifyIcon, app.manifest PerMonitorV2, embedded repo PNGs/JSON).

Core contains three small but real ports so the check pattern is proven: `TelemetryHttp.Parse` (a 1:1 port of `TelemetryHTTP.parse`),
`TrayFrame` (integer nearest-neighbour cell/head compose) and `Lang.loc`. The App shows an animated tray icon from the real sprite or head art.
It sizes the icon by the taskbar's DPI, swaps HICONs without leaking, and has a Quit menu, a light/dark taskbar probe, a Run-key helper
and the real flyout mechanics (§4.2): left-click toggle with the hide/reopen guard, physical-pixel placement, Esc, and second-launch
hand-off with `AllowSetForegroundWindow`.

### Commands and results (all on this Mac)

| # | Command | Result |
|---|---|---|
| 1 | `dotnet new sln -n TokenCat.Windows; dotnet sln add TokenCat.Core TokenCat.Checks TokenCat.App` | .NET 10 creates `TokenCat.Windows.slnx`. |
| 2 | `dotnet build TokenCat.Windows.slnx -c Release` | **First failure:** `CS0104 'MessageBox' is ambiguous between System.Windows.Forms and System.Windows`. With `UseWPF` + `UseWindowsForms` + `ImplicitUsings`, WinForms adds global usings. **Fix:** `<Using Remove="System.Windows.Forms" />` and `<Using Remove="System.Drawing" />` in the App csproj. Then 0 warnings, 0 errors (`TreatWarningsAsErrors`), about 3.4 s. `EnableWindowsTargeting=true` sits in the App csproj, so plain `dotnet build` works on macOS/Linux. |
| 3 | `dotnet run --project TokenCat.Checks -c Release` | `TokenCat checks: PASS (12)`, exit 0. |
| 4 | XAML window (`Flyout.xaml`) added, rebuilt | The markup compiler runs on macOS (`obj/.../Flyout.g.cs` generated). WPF UI code is compile-checked on the Mac. |
| 5 | `dotnet publish TokenCat.App -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true` | `TokenCat.exe` **154,767,351 B**. `zip -9` gives **63,705,369 B**. Takes about 5 s (runtime pack restored from NuGet). |
| 6 | same, `-r win-arm64` | exe **168,623,999 B** |
| 7 | 5/6 plus `-p:EnableCompressionInSingleFile=true -p:DebugType=none` | x64 exe **69,340,519 B** (zip 63,529,906). arm64 exe **65,067,994 B** (zip 58,607,013). |
| 8 | framework-dependent single-file x64 (`--self-contained false`) | 247,858 B, but it needs the .NET 10 Desktop Runtime installed. Rejected. |
| 9 | Probe: WinForms only (no WPF), compressed, x64 | 49,065,355 B exe / 43,410,495 B zip. Dropping WPF saves about 20 MB of download. Not worth giving up WPF layout. |
| 10 | Version from `build.sh` inside MSBuild (`Directory.Build.props`, regex over `CFBundleShortVersionString`) | `dotnet msbuild -getProperty:Version` → `0.10.0`. `build.sh` is the single version source for both apps. |
| 11 | PE inspection of the Mac-published exe | Machine `0x8664`, subsystem 2 (GUI): correct. **No `VS_VERSION_INFO` in the apphost.** The SDK only writes Win32 resources (version, icon) into the apphost when the build host is Windows, so a Mac-built exe has neither. **Release builds must run on a Windows runner**, and the updater's version check depends on that (§9). |
| 12 | Size of an icon-only zip for the PC test | Superseded by #13. |
| 13 | Review re-run: publish settings moved into the App csproj (`RuntimeIdentifier`, `SelfContained`, `PublishSingleFile`, `IncludeNativeLibrariesForSelfExtract`), `DebugType=none` for Release in `Directory.Build.props`, `SatelliteResourceLanguages=en;ko`, version guard target, `Application.SetColorMode(System)`, flyout mechanics. `dotnet build --no-incremental` → 0 warnings/0 errors; checks `PASS (12)`; `dotnet publish TokenCat.App -c Release -o publish` → **only** `TokenCat.exe` 156,185,151 B (ko satellites add about 1.4 MB), machine `0x8664`, subsystem 2. Version now reads `0.10.1` because the parallel task bumped `build.sh`, which shows the single source works. | `spike/out/TokenCat-spike-win-x64.zip` 64,125,738 B, SHA-256 `e88e1bf4bf3c132c0210a29eaa217227c104f566833ca9bc5bb4a77b42b52300`. |

**Blockers: none for build, checks or publish on macOS.** This Mac can't execute anything Windows-only: tray rendering, DPI behaviour,
SmartScreen, the statusLine shell, Claude Desktop paths and running-exe replacement. Those move to (a) a `windows-latest` CI job and
(b) the user's PC (§11, §12).

**Optional PC smoke test of the spike:** unzip, run `TokenCat.exe`, look in the tray (possibly under `^`). The tooltip shows
`<size>px @ <dpi> dpi · head|body`. A walking body or bobbing head should animate. Left-click opens a small flyout next to the icon
showing the taskbar theme. Clicking the icon again, clicking outside or pressing Esc closes it, and it must not flash back open. Launching
`TokenCat.exe` a second time opens the flyout in front. Right-click → Quit (the menu should be dark on a dark system and work with arrow
keys/Esc). Watch Task Manager › Details › "GDI objects" stay flat. This checks icon size per DPI, animation smoothness, flyout
placement/focus and SmartScreen wording before any real work starts.

---

## 2. Research findings

### 2.1 Sprite fit (measured from `Assets/*@1x.png`)
Opaque bounds per frame (1×): cat up to **27×18**, dog 29×18, hamster 25×18, penguin 30×17 (run is 30×11), robot 26×18.
`SM_CXSMICON` is 16/20/24/28/32 px at 100/125/150/175/200 %. Only a 32 px icon (or 40, 48…) fits a 30×18 cell at an integer scale.
Heads `app-head-*@1x` (12×11) and `@2x` (24×22) fit 16/20 and 24/28/32 exactly. The heads exist for the cat only ("pixel heads stay the
cat's (brand)", Runner.swift).

### 2.2 Where the logs and configs are on Windows
* Claude Code: "On Windows, `~/.claude` means `%USERPROFILE%\.claude`." `CLAUDE_CONFIG_DIR` relocates it. Transcripts are under
  `projects\`. [code.claude.com/docs/en/settings]
* Codex: state lives under `CODEX_HOME`, default `~/.codex`, which is `%USERPROFILE%\.codex` (config.toml there). Rollouts are
  `sessions/YYYY/MM/DD/rollout-*.jsonl`. A Codex run in WSL uses the distro's own `~/.codex`. [learn.chatgpt.com config-advanced;
  developers.openai.com/codex/config-basic; search summaries]
* Parity: the mac app reads `<home>/.codex/sessions` and `<home>/.claude/projects` and ignores `CODEX_HOME`/`CLAUDE_CONFIG_DIR`.
  Windows v1 does the same (`home = %USERPROFILE%`). WSL logs are out of scope.
* Other agents (OpenCode, Gemini CLI, Qwen Code, Copilot CLI, Amp, Cline/Roo/Kilo, omp, Droid) are detected automatically by their data
  folders through the provider registry (`TokenProvider.All`, `Core/Tracking/TokenProviders.cs`, mirroring `TokenProviders.swift`). A
  provider is read once its parser (`TokenLogFormat`) lands; parsers are listed there as they do. For now only Codex and Claude Code are
  read; telemetry, live limits and the status line bridge stay with `TokenSource.TelemetryClients` (Codex, Claude Code).
* Codex `cwd` and Claude `cwd` in Windows logs look like `C:\Users\me\proj`. The project name must come from splitting on **both** `\`
  and `/`. .NET's `Path.GetFileName` splits on both only on Windows; on macOS it returns the whole `C:\…` string, so the checks running on
  the Mac would disagree.
* Many Windows users run Codex/Claude Code **inside WSL**. Those logs live in the distro (`\\wsl.localhost\<distro>\home\…`) and its
  OTLP exporters can't reach Windows loopback under default NAT networking. v1 doesn't track them; the empty-state/onboarding text says
  so ("WSL sessions aren't tracked yet") so a WSL user isn't left guessing.

### 2.3 Claude Code statusLine on Windows
"On Windows, Claude Code runs status line commands through Git Bash when Git Bash is installed, or through PowerShell when Git Bash is
absent." In Git Bash, backslashes in paths are lost, so commands should use forward slashes. The docs' own cross-shell form is
`powershell -NoProfile -File C:/Users/username/.claude/statusline.ps1`, which "works whether Claude Code routes the command through Git Bash
or PowerShell". `rate_limits.five_hour|seven_day.{used_percentage,resets_at}` is unchanged. [code.claude.com/docs/en/statusline]
→ Windows bridge command (works in both shells, no quoting of the first token):
`powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:/Users/<u>/AppData/Local/TokenCat/claude-statusline.ps1"`.
(`-ExecutionPolicy Bypass` because Windows client's default policy forbids scripts. An absolute forward-slash path: the docs say `~`
also expands, but that is unverified on the PowerShell route, and the absolute path is known to work in both shells. The cost is that the
user name appears in `settings.json`; the mac avoids that with `$HOME`.)
Limits of this form: a Group Policy execution policy (managed PCs) overrides `-ExecutionPolicy Bypass`, and the bridge then fails silently.
Claude Code debounces updates at 300 ms and **cancels an in-flight run** when a new update comes, so a slow PowerShell start can drop
forwards during a busy turn; limits still arrive on a quieter update. Whether `powershell.exe` flashes a console window when Claude Code
runs without a console of its own (IDE extension, Desktop) is unknown → PC checklist.
Rejected alternative: `TokenCat.exe --claude-statusline` as the command. It starts faster, but a quoted first token (any path with a
space) is a string expression, not a command, in PowerShell, so it can't be one cross-shell string.

### 2.4 Claude Desktop usage history
Not documented by Anthropic. Two independent Windows tools read `%APPDATA%\Claude\plan-usage-history.json` with the same `version:2`
`samples[{t,org,u:{fh,sd}}]` shape the mac code decodes (`decodeDesktopHistory`). [github.com/Hamras47/claude-usage-widget;
github.com/wus-technik/win_systray-claude-usage/issues/5] **Design: probe, never assume.** Read `%APPDATA%\Claude\plan-usage-history.json`.
If that is missing, glob `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\plan-usage-history.json`. That is the MSIX-virtualized
location: unverified, cheap to probe, and harmless if absent. A missing file means no desktop limits, never an error.

### 2.5 Tray icon size and animation
* "If only a 16x16 pixel icon is provided, it is scaled to a larger size in a system set to a high dpi value… Use LoadIconMetric…"
  (NOTIFYICONDATA). So we render exactly `GetSystemMetricsForDpi(SM_CXSMICON, dpi)`. `dpi` comes from
  `GetDpiForWindow(FindWindow("Shell_TrayWnd"))`, falling back to `GetDpiForSystem()`. Recompute on `SystemEvents.DisplaySettingsChanged`
  and `UserPreferenceChanged`. [learn.microsoft.com … notifyicondataw]
* No handle leaks: `Bitmap.GetHicon()` gives an HICON that must be released with `DestroyIcon` ("you must dispose of the original icon by
  using the DestroyIcon method"). Exactly one HICON is alive at a time: build the new one → assign → dispose the old `Icon` →
  `DestroyIcon(old)`. This is in the spike's `Native.SetIcon`. [learn.microsoft.com Icon.FromHandle]
* Explorer restarts are handled: WinForms `NotifyIcon` re-adds itself on `TaskbarCreated` (`WmTaskbarCreated` is in the .NET 10
  System.Windows.Forms.dll). **Windows 11 puts new tray icons in the `^` overflow and there is no API to promote one.** First-run copy
  must say so (§4.6).
* `NotifyIcon.Text` is capped at 127 chars ("Text length must be less than 128 characters long" in the .NET 10 assembly). The tooltip must
  be truncated.
* Events: WinForms raises `Click` **and** `MouseClick` on the right button's mouse-up as well, so only `MouseClick` with
  `Button == Left` opens the flyout. Keyboard activation (Win+B → Enter) on a legacy-version icon is undocumented → PC checklist.
* `ContextMenuStrip` keeps keyboard navigation under the WPF message loop (WinForms installs `HostedWindowsFormsMessageHook` when it
  isn't running its own loop). `Application.SetColorMode(SystemColorMode.System)` compiles warning-free on .NET 10 and should render the
  menu dark on a dark system → PC checklist.

### 2.6 Notifications
Balloon (`NIF_INFO`) is the zero-dependency path. Windows 10/11 render it as a toast. On Windows 11 it isn't kept in the notification
centre. One balloon shows at a time and later ones queue. `NIIF_RESPECT_QUIET_TIME` exists. [learn.microsoft.com NOTIFYICONDATAW;
learn.microsoft.com NotifyIcon.ShowBalloonTip; comcomponent.com guide] Persistent toasts need the Windows App SDK or WinRT plus an AUMID
Start-menu shortcut. Cut from v1.

### 2.7 Start at login
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` runs a command line (≤ 260 chars) at every logon, needs no admin, and "the system may
choose to delay" it. [learn.microsoft.com run-and-runonce-registry-keys] Task Manager's toggle writes
`HKCU\…\Explorer\StartupApproved\Run\TokenCat` as binary data where a first byte of `02` means enabled and `03` means disabled
(`06`/`07` are also seen; read it as "low bit set = disabled"). [elevenforum; nutanix] Show "Disabled in Task Manager › Startup apps"
like the mac `requiresApproval`, and never write that key: re-enabling is the user's action in Task Manager.

### 2.8 SmartScreen and Smart App Control
* Unsigned downloaded exe → "Windows protected your PC" → **More info** → **Run anyway**. Korean UI: "Windows의 PC 보호" → **추가 정보** →
  **실행** ("Microsoft Defender SmartScreen에서 인식할 수 없는 앱의 시작을 차단했습니다"). [learn.microsoft.com archive blog;
  comeinsidebox.com; opcstory.com] Alternative: zip Properties → **Unblock** (KO **차단 해제**) before extracting. The exact Korean
  strings need to be confirmed on the user's PC.
* **Smart App Control (Windows 11) blocks unsigned apps with no override.** "there is no way to bypass Smart App Control protection for
  individual apps"; the only options are turning SAC off or signing. [support.microsoft.com Smart App Control FAQ]
* Signing: Azure Artifact Signing costs $9.99/month. Individual eligibility is limited (US/Canada, and EU/UK businesses), so it is likely
  unavailable from Korea. Signing also doesn't give instant SmartScreen reputation. [learn.microsoft.com code-signing-options; devclass;
  learn.microsoft.com Q&A] → open question 5.
* Defender ML detections (`…!ml`) on unsigned, self-extracting single-file apps that write Run keys and edit other apps' configs are a
  known false-positive pattern. Release step: scan the zip with Defender on the PC. If it's flagged, submit it to Microsoft's WDSI
  false-positive form. That is the user's action and an external submission, so it needs explicit approval.
* In-app updates don't add Mark-of-the-Web (only browsers/attachment handlers do), so updates don't repeat the SmartScreen prompt.
  Smart App Control still checks every launch.

### 2.9 Single instance, theme, update, collector
* Single instance: `new Mutex(true, @"Local\dev.seuput.TokenCat", out first)`. A second launch calls
  `AllowSetForegroundWindow(ASFW_ANY)`, `Set()`s `EventWaitHandle(@"Local\dev.seuput.TokenCat.open")` and exits. Only the process the
  user just launched holds foreground rights, so without that call the first instance's flyout opens behind other windows and never gets
  `Deactivated`. The first instance waits on the event and opens the flyout (payload-free, like the mac hand-off; anchored at the primary
  work area's corner on the taskbar's side). `AbandonedMutexException` counts as acquired. CLI flags never take the mutex. (In the spike.)
* Theme: `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` has `SystemUsesLightTheme` (taskbar, which drives the tray dot
  outline) and `AppsUseLightTheme` (flyout and settings). Re-read on `SystemEvents.UserPreferenceChanged`. **WPF Fluent `ThemeMode` is still
  "in progress" in .NET 10**, so don't depend on it. Use our own two token dictionaries. [learn.microsoft.com wpf whats-new net100]
  Windows with a title bar (Settings, "Open as window") also set `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE = 20)`, or a dark
  window keeps a white title bar.
* Single-file: native runtime files are extracted to `%TEMP%\.net\…` on first run with `IncludeNativeLibrariesForSelfExtract`.
  `Assembly.Location` is empty, so use `Environment.ProcessPath` / `AppContext.BaseDirectory`. Compression decompresses assemblies into
  memory at start. [learn.microsoft.com single-file overview]
* Updating the running exe: NTFS lets you **rename** a running image but not overwrite or delete it. So: rename `TokenCat.exe` →
  `TokenCat.exe.old`, move the verified new exe in, start it with `--after-update <pid>`, and exit. The new process waits for the pid,
  takes the mutex and deletes `.old` (best effort; retried on the next launch).
* Collector: `HttpListener` needs a URL ACL for non-admin users. [octopus.com; learn.microsoft.com add-urlacl] `TcpListener` on loopback
  needs none. Set `ExclusiveAddressUse=true` before `Start` so no other socket can co-bind the port.
  [learn.microsoft.com TcpListener.ExclusiveAddressUse] **Windows-specific failure:** Hyper-V/WSL/WinNAT can reserve port ranges, and
  binding inside one fails with WSAEACCES 10013. Map 10013 to a new `failed` sub-reason whose text names
  `netsh int ipv4 show excludedportrange protocol=tcp`. [learn.microsoft.com error-10013; dev.to] The firewall prompt only appears for
  non-loopback listeners (to confirm on the PC).

---

## 3. Scope — Windows v1

### 3.1 Parity (ported 1:1, same rules and texts)
* Codex and Claude Code log tracking: discovery caps (32 recent per source, subagents capped separately, 128 retained), bounded tails,
  oversized-line handling, Claude open-turn start, Codex metadata restore. Per-session state (working/tool/input/retry/log wait/idle/stale/
  unfinished), turns, output tokens, context, subagent trees (Claude `subagents/agent-*`, Codex forked threads), Codex rate limits,
  5-minute output flow. Same JSONL gives the same `TokenReading` (§6.3 parity test).
* Loopback OTLP/HTTP-JSON collector on `127.0.0.1:16493`: `/v1/logs|metrics|traces`, `/v1/claude/status`, `/health`, `/v1/readings`,
  `/v1/diagnostics`, the same caps, retry delays [5,30,120] and busy-port detection via `/health`. Measured tok/s via `TokenSpeed.apply`.
  Never derived from log timings, never aggregated across sessions.
* Auto-connect telemetry (opt-out persisted): Codex `config.toml` `[otel]` exporters and Claude `settings.json` env, with manifest, SHA-256
  checks, backups, rollback and refusal on conflict. `--connect-telemetry` / `--disconnect-telemetry`. Prompt/response logging switches
  forced to `0`.
* Claude usage limits: statusLine bridge (§7.4) plus Claude Desktop history file. Codex limits come from logs.
* Dashboard (flyout): header sentence + head, onboarding card, flow card + limits, sessions header/list with children, system area, footer
  (telemetry notice, update notice). "Open in Explorer" replaces "Finder에서 보기". "Task Manager" replaces "Activity Monitor". "Open as
  window" replaces "패널로 열기".
* Characters (5) and motion sources (activity/cpu/measured/still), same director/animator timing. Reduce motion =
  `SystemParameters.ClientAreaAnimation == false`.
* Notifications (opt-in): input needed, turn complete/interrupted, update available. Same titles and bodies (`AttentionEvent`).
* Start at login (opt-in), self-update, ko/en (`--language`), single instance with second-launch hand-off, light/dark.
* CLI: `--self-test`, `--telemetry-lifecycle-checks [port]`, `--connect-telemetry`, `--disconnect-telemetry`, `--telemetry-readings`,
  `--update-check`, `--diagnose`, `--language ko|en`. New: `--snapshot <dir>` (renders fixtures to PNG for CI review).

### 3.2 Explicit cuts (v1) and their upgrade paths
| Cut | Reason | Later |
|---|---|---|
| Menu-bar item editing in the tray (per-item visibility and drag ordering) | A tray item is one square icon | Since 0.12.0 the on-screen widget (§4.7) draws the menu-bar item; since 0.13.0 Settings › Widget (§4.4) edits it like the mac's Menu Bar pane (items, order, layout, presets), with the character's visibility on the Character page. |
| Character art below 30 px (dog/hamster/penguin/robot heads, small bodies) | No such art exists. Non-integer scaling ruins it. | `Assets/Generator` emits `tray-<character>-16/24` sheets; App loads them by manifest. |
| Wrapping an **existing** Claude statusLine | Needs shell detection, unverifiable here | v1.1 after PC test (open question 2) |
| WSL logs, `CODEX_HOME`, `CLAUDE_CONFIG_DIR` | Parity with mac. WSL also needs polling over `\\wsl.localhost` (no change notifications) and a collector reachable from WSL2 NAT. | Extra roots in `AppPaths`; the empty state names WSL in v1 (§2.2) |
| Memory pressure level | No Windows equivalent | Shows "—" (spec: unknown is "—") |
| Persistent toasts, notification sound toggle | Packages/AUMID | Windows App SDK if wanted |
| VoiceOver announcements (`AnnouncementGate`) | UIA live regions are extra work | `AutomationProperties.LiveSetting` later. v1 gives every control an `AutomationProperties.Name` built from the existing `spoken` texts (rows, limits and the header status get their own peers: Panel and Border have none), and ↑↓ announces the selected row with `RaiseNotificationEvent`. |
| Increase Contrast variants | — | `SystemParameters.HighContrast` → system colours only |
| Docs generators (`--snapshot-menubar/-settings/-fixtures`, `docs/Generator`) | mac produces the docs | — |
| arm64-native exe, code signing | Size, cost | Open questions 4, 5 |
| `--live-check`, `--notification-status` CLI | `--live-check` is replaced by `MonitorChecks` (runs on Mac + CI) | — |

---

## 4. UX

### 4.1 Tray icon (one icon, the character)
Icon size `N` comes from §2.5. Frame pixels come from Core `TrayFrame`, with integer nearest-neighbour scaling only, centred:
* **Body mode** (`N ≥ 30`, i.e. 200 %+; 175 % is 28 px → head): `k = N / 30`. Selected character, pose/frame from `RunnerAnimator`, sleep
  `z` glyph from `runner-v2-fx`. This is full parity with the menu bar cat.
* **Head mode** (`N < 30`): cat head `@1x` at 16/20, `@2x` at 24/28. Pose mapping:

  | Pose | Head | Motion |
  |---|---|---|
  | sit | normal ↔ blink using the sit `holdSequence`/blink timing | — |
  | sleep | sleep | zS/zL glyph steps (sleep timing) if the corner fits, else none |
  | walk | normal | bob down 1 art px on frames 1 and 3 (walk durations) |
  | run | normal | bob on odd frames (run durations, so faster) |
  | alert | alert ↔ blink (alert timing) | — |
  | yawn / content | blink / normal | one-shot as on mac |

  Bob uses spare rows when there are any, otherwise it shifts up. Cadence is always the manifest's (K-6). Nothing animates while the pose is
  held (same one-shot timer rule as `RunnerAnimator`).
* **Corner dot** (both modes): 3×3 art px × the head scale `max(1, N / 12)` (body mode too, so it stays about 0.4 N), bottom-right. Yellow `attention` = input, orange `warning` = API retry. Nothing else
  (working/tool are motion). 1 art-px outline in the taskbar's opposite tone (`SystemUsesLightTheme`) for contrast.
* Pause the timer on `SessionSwitch` lock and `PowerModes.Suspend`, and resume after.
* Tooltip: `StatusBarContent.tooltip` text, truncated to 127 chars on a line boundary. The AI line comes before memory and storage, so
  the cut drops those first and "Input needed" stays.

### 4.2 Left click → flyout (dashboard)
Borderless (`WindowStyle=None`, `ResizeMode=NoResize`, **no** `AllowsTransparency`: that makes a layered, software-rendered window),
non-taskbar, topmost WPF `Window` 420 px wide (`DashboardLayout.width`) hosting `DashboardView` (a `UserControl`). Windows 11 rounded
corners come from `DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND`. The same control is hosted in a normal resizable window for "Open as
window".
Placement is in **physical pixels**: `Show()`, `SetWindowPos` onto the cursor's monitor (WPF rescales on `WM_DPICHANGED`), read the real
size with `GetWindowRect`, then clamp above/centred on the cursor into `Screen.FromPoint(cursor).WorkingArea` with a 12 DIP margin.
WPF `Left/Top` are DIPs of the window's *current* monitor, so they misplace it across mixed-DPI monitors. The working area excludes the
taskbar, so any taskbar edge works without `SHAppBarMessage`.
Toggle: `MouseClick` with `Button == Left` only (§2.5). It hides on `Deactivated` and Esc. Clicking the icon while it is open first
deactivates (hides) it, so a click within 300 ms of a hide does nothing instead of reopening. A double-click's second press hides it
and raises `MouseDoubleClick`, not `MouseClick`, so that event shows it again. The spike has exactly this
(`Native.ShowAt`). Sections and order are the mac `DashboardView.body`. Fonts: Segoe UI Variable/Segoe UI
with `Typography.NumeralAlignment="Tabular"` for "mono" digits. Korean falls back to Malgun Gothic automatically.
**Drag to detach** (the mac popover's `detachableWindow`): a left press on a part that doesn't click (the header, card backgrounds,
empty space; not buttons, links, the session list, the System area or the scroll bar) moved past
`SystemParameters.MinimumHorizontal/VerticalDragDistance` hides the flyout and opens "Open as window" with the grabbed point under the
pointer (placed before it shows, through `ClientToScreen`: `PointToScreen` needs the RootVisual that only `Show` sets; a point lower
than the window is tall stays 12 DIP inside its bottom edge) and the selected group still selected; while the button is held,
`DragMove` (the system move loop) carries it on. A click without movement does nothing new.
**Window bounds**: "Open as window" remembers its last position and height while neither minimized nor maximized
(`dashboardWindowBounds` = `[x, y, width, height]`, physical pixels, written on close; the width stays fixed). It comes back moved and
shortened into the work area holding most of it (`DashboardBounds.Restore`, Core); when none of it is on a current work area (that monitor
is gone) it opens where Windows puts a new window, as on the first opening. Checks: Core — restore/clamp and the stored value; App — the
header drags and the session list and Task Manager area don't, a click or a move within the drag distance doesn't detach, a one-axis
drag hands over the grabbed offset, the window opens under the pointer (also for a point lower than it is tall) and comes back with its
spot and height, and a selected child row or open detail becomes its top-level group in the window.

### 4.3 Right click → context menu (`ContextMenuStrip`)
Disabled headline (`QuickMenuSummary.headline`), session rows with the state colour square (click focuses that group in the flyout),
separator, **Open**, **Open as window**, separator, **Layout ▸** (3, checked), **Character ▸** (5, checked, then a separator and
**Show in Widget**, the mac "Show in Menu Bar": checked while shown, disabled when nothing else would be drawn), **Motion source ▸**
(4, checked), separator, update item (`UpdateState.quickMenuTitle`) when present, **Settings…**, **Task Manager**, **About TokenCat**,
separator, **Quit TokenCat**. **Show/Hide Widget** follows **Open as window**, then **Widget Size ▸** (the seven sizes, checked)
while the widget is on (§4.7). The widget's right-click shows this same menu. `Application.SetColorMode(SystemColorMode.System)` at start and again after a light/dark change should make the menu follow dark mode (PC check).

### 4.4 Settings window
Normal WPF window with the mac's five pages (left nav), "메뉴 막대" named **Widget**:
* **General**: start at login (with Run/StartupApproved status text), notifications (input, turn end), Restore Defaults. Restore
  Defaults also resets the widget's layout, item order and visibility, character visibility and size (the mac restores items, layout
  and character); the login item, update settings, showing the widget and its saved positions stay. `Preferences.Reset` returns the
  previous snapshot and `Restore` brings all of it back.
* **Widget** (mac `MenuBarPane`): show on screen; a live preview (`WidgetView` at the chosen size on the current theme, frame 0 of the
  current pose, cut with a 28 DIP fade when wider than the row) with its size in px; **Size** (a themed pop-up of the seven sizes; the
  caption names Ctrl + wheel and the right-click menu); **Preset** (shows 사용자 지정 / Custom when none matches); **Layout** (segmented
  최소 / 두 줄 / 한 줄). **Items**: one row per item in the stored order — drag handle, check box "title · bar label"
  (a speed item: the title, then its glyph, named by the title; disabled when it is the last shown item with the character hidden, or
  the battery on a PC without one: "이 PC에는 배터리가 없습니다"). Reorder by dragging a row (it takes each row's place as it passes, as on
  the mac), Alt+↑/↓ on a focused row (focus follows, Narrator hears "메모리, 9개 중 1번째"), or the row menu (right-click, Apps key, Shift+F10: 위로 이동 / 아래로 이동). Rows are named check boxes in UI Automation.
  WPF's ComboBox and ContextMenu don't follow dark mode, so the pop-ups are the WinForms menus the tray uses.
* **Character**: picker with live 2× preview, "위젯에 캐릭터 표시" (mac "메뉴 막대에 캐릭터 표시"; disabled with its reason when nothing
  else would be drawn; the tray icon always shows the character), motion source with `caption`/`subtitle` texts.
* **Telemetry**: collector state with Retry Now, per-client status, Claude limits status, the `--disconnect-telemetry` command as text, and
  buttons that show the backups folder and both config files in File Explorer. Connecting and disconnecting stay in the CLI.
* **About**: version, privacy note, licence, Show Welcome Again, and Updates (automatic check, check/install update, new-version notice).

Texts come from `SettingsView.swift`, minus the cut items.

### 4.5 Theme
Two `ResourceDictionary` token sets (Light/Dark) copied from `DesignTokens.swift` values (TCColor light/dark hex). They are swapped on
`AppsUseLightTheme` change. High contrast uses `SystemColors`.

### 4.6 First run
1. The flyout opens once with the onboarding card (mac `OnboardingCard` outcome texts).
2. One balloon: "TokenCat is in the notification area. If you don't see it, open ^ and drag the cat onto the taskbar" / "TokenCat이
   알림 영역에 있습니다. 보이지 않으면 ^를 열고 고양이를 작업 표시줄로 끌어 놓으세요."
3. Telemetry auto-connect runs as on mac (unless opted out).

### 4.7 On-screen widget (0.12.0)
The taskbar can't show text the way the mac menu bar does, so the menu-bar item also floats on screen (PC feedback after 0.11.2).
* **Window** (`Widget.cs`): borderless WPF `Window`, `Topmost`, `ShowInTaskbar=false`, `ShowActivated=false`, not focusable;
  `WS_EX_TOOLWINDOW` (no Alt+Tab) and `WS_EX_NOACTIVATE` plus a `WM_MOUSEACTIVATE → MA_NOACTIVATE` hook, so a click never takes the
  focus. Rounded by DWM like the flyout (no `AllowsTransparency`), opaque theme background so it reads over any wallpaper.
* **Content** (`WidgetView`): `StatusBarContentView.drawContent` ported to `OnRender` in mac points: the same items (`StatusBarContent.Metrics`,
  Core), 32 × 20 runner slot, fixed cells (minimal 30; two lines 32 / NET 66 / AI 36; one line 52 / 114 / 46), marks and label tones
  (labels and units at label 0.72, idle "0" at 0.45). Without the character (mac rules) the runner slot goes, the minimal AI cell is 41
  and a strip with nothing left is the 28 pt "TC"; `Preferences` never lets that happen outside the minimal layout. The one-line layout
  shows the short names (CPU, RAM…) where the mac draws SF Symbols. The Codex and Claude speed items (opt-in, after AI without a
  separator) draw the mac's `SpeedGlyph` (the Codex and Claude app icons, `speed-codex.png`/`speed-claude.png`) in the label slot and that client's "지금 속도" (`SessionPresentation.CurrentSpeed`,
  `Format.BarTps`, whole numbers from 100 up, + a smaller "tok/s") or "—", in 56 pt (two lines) / 69 pt (one line) cells. The Average speed
  item (opt-in, last, "평균 속도 · AVG" in the list) draws "AVG" as its label and the arithmetic mean of every client's fresh per-session
  rates (`SessionPresentation.AverageSpeed`, `CurrentSpeed`'s own filter; measured rates only, nothing estimated) in the same cells and
  format. `StatusBarContent.Speeds` keys all three by `MetricID`. Narrator reads the strip as one text
  element (`StatusBarMetric.Spoken`). Layout, items, order and the character come from Settings › Widget (§4.4); default **two
  lines** (like the mac bar), the six standard items, the character shown, 100 %.
* **Size**: 100, 125, 150, 175, 200, 250 or 300 % (`widgetScale`, default 100; another stored value becomes the nearest). Device pixels
  per point `p = max(1, round(display scale)) × size`, so 100 % is exactly 0.12.0 (100–125 % → 1, 150–200 % → 2); `WidgetView.Scale`
  (DIP per point) is `p / display scale`, text is laid out at `p` pixels per DIP and separators stay one device pixel. The runner — the
  tray's own `TrayFrame` body pixels — is drawn at `p` pixels per art pixel with nearest-neighbour when `p` is whole (crisp); at a
  fractional `p` the art is made at `ceil(p)` and drawn smoothly (`HighQuality`) into the same 30 p box: even, slightly soft, never the
  uneven pixels nearest-neighbour would give. DPI changes re-measure.
* **Resizing**: Settings › Widget › Size, **Widget Size ▸** in the tray/right-click menu, or Ctrl + mouse wheel over the widget (one
  size per notch, up for bigger; read from `WM_MOUSEWHEEL`'s own MK_CONTROL, so it works without activating the widget). Windows sends
  the wheel to the inactive window under the pointer only while the mouse setting "Scroll inactive windows when I hover over them"
  is on (the default); with it off the wheel goes to the focused app, so use the menu or Settings.
* **Anchoring**: any resize but a drag (size, layout, items, the character, a DPI change) keeps the edges nearest the work area —
  the right edge when the widget's centre is right of the work area's centre, the bottom edge when below — then keeps it inside the
  area (`WidgetPlacement.Resized`). It is applied in `WM_WINDOWPOSCHANGING`, so the resize and the move are one step (WPF would grow it
  from the top-left). Only the end of a drag is saved (its bounds): showing it again — a relaunch, after a full-screen app, a display
  change, a size changed while hidden — places the current size from those bounds by the same rule, so the spot never drifts (the
  strip is narrower before the first sample) and a dock/undock or DPI change never overwrites another monitor set's spot. The flyout
  anchor uses the widget's bounds as before.
* **Timers**: none of its own. Frames come from the tray animator's single frame timer (`RenderTray`); values, the full-screen check and
  showing/hiding come from the monitor publish (about 1 s).
* **Full screen**: hidden while `SHQueryUserNotificationState` is `QUNS_BUSY`, `QUNS_RUNNING_D3D_FULL_SCREEN` or `QUNS_PRESENTATION_MODE`,
  unless the foreground window is the desktop (`Progman`/`WorkerW`); shown again after.
* **Mouse**: drag moves it (manual capture, not `DragMove`, which would activate it); edges within 12 DIP of the work area snap, and it
  stays inside the work area of the cursor's monitor. Click toggles the flyout, hung below the widget in the top half of the screen and
  above it otherwise; a double-click counts once. Right-click brings the app forward (so the menu closes on an outside click) and shows
  the tray menu.
* **Persistence**: `showWidget` (default on), the mac keys `statusBarLayout`, `metricOrder`, `visibleMetrics`, `showRunner`, and
  `widgetScale`; positions in `widgetPositions` = `{ "<x,y,WxH per screen>": [x, y, width, height] }` (the last drag; 0.12.0's `[x, y]` still reads) in physical pixels, one per monitor set. A
  display change restores that set's position, or keeps the widget on a remaining screen. "기본값으로 되돌리기" resets the layout, items,
  character and size, and leaves `showWidget` and the positions alone.
* **Checks**: Core — metrics, the width contract (with and without the character), marks, snap/clamp, resize anchoring, flyout anchor,
  full-screen mapping, positions and preferences (items, order, the character rules, presets, sizes, reset and undo).
  App — measured width stable across values and equal to the contract × size (100/150/200/300 %, with and without the character),
  nearest-neighbour runner at whole pixels and smooth at fractional ones, the size menu and Ctrl + wheel, worst-case numbers unshrunk,
  300 frames handle-flat; Settings › Widget rows, keys and the pages in ko/en.
  Snapshot — `widget-{ko,en}.png` (with rows at 150 % and 200 % and without the character) and `settings-widget-{ko,en}.png`.

---

## 5. Project layout (repo: `windows/`)

```
windows/
  TokenCat.Windows.slnx
  global.json                      # SDK 10.0.x, rollForward latestFeature
  Directory.Build.props            # Nullable, ImplicitUsings, TreatWarningsAsErrors, InvariantGlobalization=false,
                                   # Version = regex(CFBundleShortVersionString, ../build.sh) + <Error> target when empty,
                                   # IncludeSourceRevisionInInformationalVersion=false, DebugType=none for Release
  TokenCat.Core/                   # net10.0. No packages, no P/Invoke. Everything with a rule or a check.
    Models.cs Lang.cs AppPaths.cs SettingsStore.cs Json.cs WidgetPlacement.cs   # Json.cs: BOM-tolerant parse + the one writer config (rule 3)
    Tracking/  Telemetry/  Presentation/  Runner/  Update/  LiveMonitor.cs
    Checks/    Check.cs Suites.cs <Suite>Checks.cs          # suites compiled into Core, like the mac target
  TokenCat.Checks/                 # net10.0 console, about 20 lines: Suites.RunAll() → "TokenCat checks: PASS", exit 1 on failure;
                                   # `-- --diagnose-tokens [home]` prints TokenReading JSON (parity test)
  TokenCat.App/                    # net10.0-windows WinExe, UseWPF+UseWindowsForms (NotifyIcon/ContextMenuStrip only); csproj holds
                                   # win-x64, SelfContained, PublishSingleFile, IncludeNativeLibrariesForSelfExtract,
                                   # SatelliteResourceLanguages=en;ko, so `dotnet publish -c Release` = the release exe
    TokenCat.App.csproj app.manifest (PerMonitorV2, asInvoker) TokenCat.ico
    Program.cs Shell.cs TrayIcon.cs Widget.cs Native.cs Sprites.cs Theme.cs Flyout.xaml(.cs) Dashboard.cs SessionList.cs SettingsWindow.cs
    WindowsSystemSampler.cs LoginItem.cs Fixtures.cs Snapshot.cs AppChecks.cs   # UI built in code; Flyout.xaml is the only XAML
```
Assets are **not copied into the repo**. `TokenCat.App.csproj` embeds `../../Assets/runner-*@{1x,2x}.png`, `app-head-*`, `runner-v2-fx*`
and `runner-v2.json` as `EmbeddedResource` with `LogicalName=%(Filename)%(Extension)`, excluding `runner-sheet-v1.png`. This is the same
list as `build.sh`. The spike shows the wildcard picks exactly these 21 files. `TokenCat.ico` is the one derived binary, generated once
on a Mac and committed: three PNG frames, `Assets/app-icon-v2-16.png`, `-32.png` and the 256 px frame from
`sips -s format ico -z 256 256 Assets/app-icon-v2-1024.png`, so the title bar, taskbar and Explorer get the pixel tiles at 16/32 instead of a
downsampled 256. 24/48 px still downsample; add tiles for them if they look soft.

Why suites live in Core: the App's `--self-test` and the console runner call the same `Suites.RunAll()`. An Exe-to-Exe project reference
would trip NETSDK1151 (self-contained → framework-dependent exe), so it is avoided.

---

## 6. Core port: module mapping and rules

### 6.1 File-by-file
| Swift (`Sources/TokenCat`) | C# (`windows/…`) | WP |
|---|---|---|
| Models.swift | Core/Models.cs (records) | 0 |
| Localization.swift, `Format` (App.swift 523–575) | Core/Lang.cs | 0 |
| LocalizationChecks.swift | Core/Checks/LocalizationChecks.cs (bundle localizations → `CurrentUICulture`) | 0 |
| TokenTracker.swift (tracker, cursor, parser) | Core/Tracking/TokenTracker.cs, TokenLogParser.cs | 1 |
| LogWatcher.swift (FSEvents) | Core/Tracking/LogWatcher.cs (`FileSystemWatcher`, subdirs, 64 KB buffer, `Error` → rediscover) | 1 |
| TokenSpeed.swift | Core/Tracking/TokenSpeed.cs | 1 |
| TokenFlow.swift (`FlowSeries`, `niceMax`; `FlowBars` shape → App) | Core/Tracking/TokenFlow.cs | 1 |
| TrackerChecks.swift, TokenSpeedChecks.swift | Core/Checks/TrackerChecks.cs, TokenSpeedChecks.cs | 1 |
| Telemetry.swift (models, collector, decode, HTTP parser, fetch) | Core/Telemetry/TelemetryCollector.cs, TelemetryHttp.cs, TelemetryDecode.cs, ClaudeUsage.cs | 2 |
| TelemetrySetup.swift | Core/Telemetry/TelemetrySetup.cs | 2 |
| TelemetryChecks.swift (incl. `runTelemetryLifecycleChecks`), TelemetrySetupChecks.swift | Core/Checks/TelemetryChecks.cs, TelemetryLifecycleChecks.cs, TelemetrySetupChecks.cs | 2 |
| SessionPresentation.swift (+`SessionListModel`) | Core/Presentation/SessionPresentation.cs, SessionList.cs | 3 |
| StatusBarView.swift 1–232 (`StatusAISummary`, `StatusBarContent` text/tooltip, `QuickMenuSummary`) | Core/Presentation/StatusSummary.cs | 3 |
| Notifier.swift 1–113 (`AttentionSignal/Event/Tracker`) | Core/Presentation/Attention.cs | 3 |
| App.swift `Preferences` (kept fields), `TelemetryRestartState`, `DashboardModel` | Core/Presentation/Preferences.cs, Core/LiveMonitor.cs | 3 |
| SessionPresentationChecks.swift; PreferenceChecks.swift `runPreferenceChecks` (kept prefs); `runShellChecks` attention/restart part; `runStatusBarChecks` text/summary part | Core/Checks/SessionPresentationChecks.cs, PreferenceChecks.cs, ShellChecks.cs, StatusSummaryChecks.cs, MonitorChecks.cs (replaces `--live-check`) | 3 |
| Runner.swift (manifest, poses, characters, heads, timing; NSImage building → App) | Core/Runner/RunnerManifest.cs, TrayFrame.cs | 4 |
| RunnerAnimator.swift (`RunnerMotion`, `RunnerPlan`, `RunnerActivity`, `RunnerDirector`, `RunnerAnimator` with injected clock) | Core/Runner/RunnerAnimator.cs | 4 |
| `runShellChecks` director/animator part | Core/Checks/RunnerChecks.cs (+ TrayFrame cases from the spike) | 4 |
| Updater.swift (logic) | Core/Update/Updater.cs (`AppVersion`, `UpdateRelease` asset `TokenCat-Windows.zip`, `UpdateFailure` with Windows texts, `UpdateResponse`, `UpdateThrottle`, `UpdateClient`, `UpdateStore`, `UpdateState`, `UpdateNotice`, `Updater`) | 4 |
| Updater.swift `UpdateInstaller` | Core/Update/UpdateInstaller.cs (§9) | 4 |
| UpdaterChecks.swift | Core/Checks/UpdaterChecks.cs | 4 |
| SystemSampler.swift | App/WindowsSystemSampler.cs (§7.6) | 5 |
| LoginItem.swift | App/LoginItem.cs | 5 |
| Entry.swift | App/Program.cs | 5 |
| App.swift `AppDelegate` | App/Shell.cs, TrayIcon.cs | 5 |
| DashboardView.swift, SettingsView.swift | App/Dashboard.xaml, SettingsWindow.xaml | 5 |
| DesignTokens.swift (+`runDesignTokenChecks` contrast pairs) | App/Theme.xaml + Theme.cs, contrast check in App `--self-test` | 5 |
| SnapshotFixtures.swift | App/Fixtures.cs + Snapshot.cs (`--snapshot`) | 5 |
| Notifier.swift 114–229 (UNUserNotificationCenter) | App/Notifications.cs (balloon) | 5 |
| AnnouncementGate, docs/Generator, Assets/Generator | — (cut / mac-only tools) | — |

### 6.2 Porting rules (these are where a "same input → same output" port breaks)
1. **The Swift checks are the spec.** Port each suite 1:1 and keep every failure description string verbatim, so a mismatch is
   greppable across both trees. Self-test language is `ko`, as on mac.
2. Swift `struct` → C# `sealed record` (immutable, `with`). `TokenSpeed.apply` mutates a *copy* in Swift, and a class would mutate the
   input. Content equality on records holding collections (`FlowSeries`, `ClaudeUsageLimits`, `UpdateState`) must be written out
   (`SequenceEqual`), because record equality compares collection references.
3. JSON: `JsonDocument`/`JsonElement` mirrors `[String: Any]`. Keep the Swift number rules: booleans are not numbers, finite only,
   the same ranges. All parsing and writing goes through `Core/Json.cs` (WP0), because the defaults differ from Foundation (*probed*):
   * **Parse:** strip a leading UTF-8 BOM (`EF BB BF`) before `JsonDocument.Parse(bytes)`. That call throws on a BOM, while Swift accepts
     it, and Windows editors/PowerShell 5.1 write one. Applies to `settings.json`, Claude Desktop history and our own files.
   * **Write** (the `settings.json` rewrite, `prettyPrinted + sortedKeys + withoutEscapingSlashes` on mac): `Utf8JsonWriter` with
     `Indented = true`, **`NewLine = "\n"`** (the default is `Environment.NewLine`, which is CRLF on Windows) and
     **`Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping`** (the default turns `홍길동` into `홍…` and escapes `& ' + < >`).
     Object keys are sorted ordinal by walking the `JsonElement`, and numbers are written with `WriteRawValue(GetRawText())`, so `0.1`
     stays `0.1`. A trailing `"\n"`. Byte output differs from Apple's `"k" : v` spacing. That's fine: the SHA-256 manifest only compares
     files the Windows app wrote, and the checks compare parsed values.
4. Dates: `DateTimeOffset` UTC. Parse **only** `yyyy-MM-ddTHH:mm:ss(.fraction)(Z|±hh:mm)` with `ParseExact`, as
   `ISO8601DateFormatter` does. `DateTimeOffset.Parse` would accept records the mac rejects.
5. Strings: `StringComparer.Ordinal` and `ToLowerInvariant` everywhere (sorting ids, keys). Count user-visible labels
   (`TokenLogParser.label` 1…48) with `StringInfo.LengthInTextElements` (grapheme parity).
6. Numbers to text: `CultureInfo.InvariantCulture` for every `String(format:)` port (`%.1f` → `"0.0"`). Group digits for
   `Format.tokens` with `ko-KR` explicitly, as the mac does.
7. Paths: the `id` relative path uses `/` (normalize `\` → `/`). The subagent test `"/subagents/"` applies to the normalized path. Project
   name = last segment split on `\` and `/`. NTFS is case-insensitive, but tracker keys come only from enumeration under one `home`
   string, so they're consistent; watcher paths are only hints (a miss just triggers discovery), so Ordinal keys are fine. .NET handles
   paths over 260 chars itself; no manifest entry needed.
8. Files: open logs with `FileAccess.Read, FileShare.ReadWrite | FileShare.Delete`. Writers (Codex in Rust, Claude Code via libuv) share
   all three, and denying delete would block their renames. Reopen per read, as the mac does. **Per-tick size = `new FileInfo(path).Length`
   (a fresh `GetFileAttributesEx`), never the `FileInfo` handed out by `Directory.Enumerate*`.** NTFS updates the directory-entry copy of
   size/mtime lazily while a writer holds the file open (Codex keeps its rollout open). The mac's 1 s stat poll is what makes updates timely;
   `FileSystemWatcher` (like FSEvents) is only a wake-up hint. Its size/last-write notifications fire "only when the cache is
   sufficiently flushed" [ReadDirectoryChangesW]. Discovery
   ranking (32 most recent) uses enumeration mtimes as mac does. `// ponytail: enumeration mtime may lag for a log held open since before
   launch; already-tracked recent logs are retained, so it only matters with 32+ newer files.` JSONL lines may end in `\r\n`: JSON treats
   `\r` as whitespace (probed), and any non-JSON prefix test trims it. File identity: mac uses `dev-ino`. Use `CreationTimeUtc` + the
   existing `size < offset` reset. `// ponytail: creation time can be tunnelled within 15 s on NTFS; upgrade to
   GetFileInformationByHandle file ID if a replaced log is ever missed.`
9. Atomic config writes: temp file in the same folder → `File.Replace` (keeps ACL/attributes) or `File.Move(…, overwrite:true)` when new.
   Retry 3× on `IOException` (editors and antivirus hold files briefly). POSIX permission fields stay in the manifest and are ignored on
   Windows. `config.toml` keeps the mac's text-level edit, which already preserves CRLF. A leading BOM is removed before the line scan
   (otherwise a first-line `[otel]` isn't recognised and a duplicate table breaks Codex) and put back on write.
10. Concurrency: `LiveMonitor` runs one async loop (`PeriodicTimer` 1 s + a `Channel` of watcher paths, 0.25 s min token interval) with a
    `CancellationToken`, instead of GCD queues plus generation counters. The ported live-check asserts one timer and no publish after
    `Stop()`.

### 6.3 "Same JSONL → same readings" parity test (Mac, during WP1)
Build the mac binary from the repo (`swift build`, never `/Applications/TokenCat.app`). Then run both against the same home at the same
moment: `TokenCat --diagnose` vs `dotnet run --project windows/TokenCat.Checks -- --diagnose-tokens`. Diff `tokens[]` for sessions whose
`lastLogAt` is older than 2 min (live ones move). Compare `id, source, sessionID, parentSessionID, agentID, project, model, isSubagent,
activityState, currentTurnOutputTokens, lastOutputTokens, lastTurnDurationSeconds, context, rateLimit, effort, agentRole`. The result must
be identical. This is read-only and uses no network beyond the running collector's loopback GET.

---

## 7. Platform adaptations (Core unless marked App)

### 7.1 Paths (`AppPaths`, WP0)
| What | Windows | macOS (dev runs of Core only) |
|---|---|---|
| Home | `%USERPROFILE%` | `$HOME` |
| Logs | `<home>\.codex\sessions`, `<home>\.claude\projects` | same |
| Configs | `<home>\.codex\config.toml`, `<home>\.claude\settings.json` | same (checks use temp homes only) |
| Support | `%LOCALAPPDATA%\TokenCat` | `~/Library/Application Support/TokenCat-windows-dev`. **Never** the mac app's folder. |
| Claude Desktop history | §2.4 probe list | `~/Library/Application Support/Claude/plan-usage-history.json` |
| Exe (recommended) | `%LOCALAPPDATA%\Programs\TokenCat\TokenCat.exe` (no installer) | — |

### 7.2 SettingsStore (WP0)
A JSON object file `settings.json` with `Get<T>(key)` / `Set<T>(key, value)` / `Remove(key)`. Unlike `UserDefaults`, a file has no
cross-process merge: the running app and a CLI process (`--disconnect-telemetry` sets `telemetryDisconnected`) would overwrite each
other's keys. So every `Set`/`Remove` is **lock the named mutex `Local\dev.seuput.TokenCat.settings` → re-read the file →
change one key → atomic write → unlock**. `Get` reads the file; caching it is allowed only keyed by `LastWriteTimeUtc` + length.
Named mutexes also work on macOS, so the check runs there. `AbandonedMutexException` counts as acquired. One check: two stores on the same file set different keys, and both keys survive.
**Key names are copied from the Swift `UserDefaults` keys** (`claudeUsageLimits`, `telemetryPendingRestart`, `telemetryDisconnected`,
`animationSource`, `animationSourceConfirmed`, …) so the two apps share one vocabulary.

### 7.3 Collector (WP2)
`TcpListener` on loopback, `ExclusiveAddressUse=true`, at most 16 connections, a 5 s deadline per connection, the ported `TelemetryHttp.Parse`
→ handler → `encode`. A bind error `AddressAlreadyInUse` → GET `/health` → `busyTokenCat`/`busyOtherApp` (as mac). `AccessDenied` (10013)
→ `failed` with the excluded-port-range hint. Retry with [5,30,120]. `Stop()` closes the listener before the process exits (update
relaunch, quit).

### 7.4 TelemetrySetup (WP2)
* Codex TOML and Claude JSON edits: 1:1 (text-level literal replace/remove, `parses` validation, manifest v1 with SHA-256, backups under
  `%LOCALAPPDATA%\TokenCat\telemetry-backups\<stamp>\`, rollback, conflict refusal, opt-out key).
* Bridge (Windows): `claude-statusline.ps1` in Support. `statusLineCommand` per §2.3. `runsBridge(cmd)` = contains
  `/TokenCat/claude-statusline.ps1` (with `\`/`/` normalized). Wrapping rule for v1: **only when `statusLine` is absent.** A present
  `statusLine` (command or not) is kept, with a new note `statusLineKept` ("Claude Code 상태 표시줄을 그대로 두었습니다. 사용 한도는 Claude
  데스크톱 앱 기록에서 읽습니다." / "Kept your Claude Code status line; usage limits come from the Claude desktop app's history."). Disconnect
  removes `statusLine` only while it is still exactly the bridge command (mac rule).
* Bridge script (sends raw stdin bytes to loopback only and prints nothing; status line output stays empty as with an absent original on mac):
  ```powershell
  # TokenCat: Claude Code status line bridge. Sends Claude Code's status JSON to TokenCat on 127.0.0.1 only and prints nothing.
  # TokenCat --disconnect-telemetry removes it from settings.json.
  $ErrorActionPreference = 'SilentlyContinue'
  $buffer = New-Object IO.MemoryStream; [Console]::OpenStandardInput().CopyTo($buffer); $body = $buffer.ToArray()
  $client = New-Object Net.Sockets.TcpClient
  if ($client.ConnectAsync('127.0.0.1', 16493).Wait(300)) {
    $stream = $client.GetStream(); $stream.ReadTimeout = 1000
    $head = [Text.Encoding]::ASCII.GetBytes("POST /v1/claude/status HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
    $stream.Write($head, 0, $head.Length); $stream.Write($body, 0, $body.Length); [void]$stream.Read((New-Object byte[] 64), 0, 64)
  }
  $client.Close()
  ```
  Raw bytes avoid PowerShell 5.1's OEM console decoding of non-ASCII paths. A raw socket avoids `Invoke-WebRequest` startup and proxies.
  There is no Origin header, so the collector accepts it. The 300 ms connect cap matters: Windows retries SYN after an RST on
  loopback, so a refused connect takes about 2 s without it. Keep the script **ASCII-only** (PowerShell 5.1 reads BOM-less scripts in the
  ANSI code page). Windows check (WP2, `windows.yml`): write the script, then run the **exact `statusLine.command` string** from the
  generated settings through both `bash -c` (Git Bash on the runner) and `powershell -NoProfile -Command`, with a sample status JSON
  containing Korean on stdin, against a collector on the port baked into the script (the generator takes the port, so the
  check uses a free test port). Assert that both deliver the limits and print nothing.

### 7.5 Claude Desktop limits (WP2)
`ClaudeUsage.DesktopReader`: first existing candidate, re-read only on size/mtime change, ignored above 2 MB. Same decode as mac.
Opened with full sharing (Electron writes it).

### 7.6 System sampler (App, WP5)
CPU = `GetSystemTimes` deltas. Memory = `GlobalMemoryStatusEx` (used = total − avail). Pressure = null. Disk = `DriveInfo` of the
`%USERPROFILE%` root. Network = `NetworkInterface` Up, not Loopback/Tunnel, **with a gateway** (drops Hyper-V/WSL vEthernet), with
`GetIPStatistics()` byte deltas and IPv4 unicast addresses. Battery = `SystemInformation.PowerStatus` (BatteryChargeStatus.NoSystemBattery →
`batteryPresent=false`, `powerSource` "AC Power"/"Battery Power" as on mac so `Format.power` is unchanged).

### 7.7 CLI on a GUI exe (App, WP5)
`WinExe` has no console. CLI flags call `AttachConsole(ATTACH_PARENT_PROCESS)` before printing, but only when
`GetStdHandle(STD_OUTPUT_HANDLE)` is null or invalid. A redirected stdout (CI pipe, bridge test) is already usable and must not be replaced.
cmd and PowerShell don't wait for GUI
binaries, so docs show `& "$env:LOCALAPPDATA\Programs\TokenCat\TokenCat.exe" --disconnect-telemetry | Out-Host` (the pipe makes PowerShell
wait). CI pipes output and waits naturally.

---

## 8. Localization
`Lang.Current` comes from `--language ko|en`, then `CultureInfo.CurrentUICulture` (Windows display language): `ko*` → ko, else en. Texts sit
at call sites, as on mac: `using static TokenCat.Lang;` then `loc("세션 상세", "Session details")`, `plural(...)`, `Format.span/ago/later`.
Every Korean/English string is copied verbatim from the Swift source. Platform words change only where the platform differs ("메뉴 막대" →
"알림 영역" / "notification area", "Finder" → "탐색기" / "File Explorer"). Date/number styles: `new CultureInfo(lang)`.

---

## 9. Updater (WP4)
* Endpoint unchanged: `GET https://api.github.com/repos/SeuPut0705/TokenCat/releases/latest`. `HttpClient` with no cookies, no
  credentials, UA `TokenCat/<version>`, ETag, and the same throttle/backoff. The only non-loopback traffic is the check and download.
* `UpdateRelease.assetName = "TokenCat-Windows.zip"`. A release without it is "no update for Windows" (quiet), not an error banner.
* `UpdateInstaller` (Windows):
  1. Blockers before download. `notBundle`: `Environment.ProcessPath` isn't `TokenCat.exe`, e.g. `dotnet run`. `translocated`: the
     process path is under `Path.GetTempPath()`, i.e. run from inside the zip in Explorer, with text telling the user to extract to
     `%LOCALAPPDATA%\Programs\TokenCat`. `notWritable`: the exe folder isn't writable, e.g. Program Files.
  2. Download to `<exeDir>\TokenCat.update\` (same volume, so renames are atomic). Verify size, then SHA-256 against the GitHub digest.
  3. `ZipFile` extract. Entries must be ⊆ {`TokenCat.exe`, `LICENSE`} and include `TokenCat.exe`, with no directories and no `..`
     (zip-slip guard).
  4. Validate: `FileVersionInfo.ProductVersion == release version` (mac parity: `CFBundleShortVersionString`), which is why release
     builds are Windows-hosted (§1 #11). It also proves the file is a PE with our resources. No machine-type branch: x64 only (open
     question 4).
  5. Replace: `File.Move(exe, exe + ".old", true)` → `File.Move(new, exe)`, each retried 3× on `IOException` (Defender scans a fresh exe
     and holds it briefly). On failure, move `.old` back → `replaceFailed`.
  6. Relaunch: `Process.Start(exe, "--after-update <pid>")`, then shut down (collector stopped, tray removed). The new process waits for the
     pid (≤ 60 s), acquires the mutex and deletes `.old` and `TokenCat.update\`.
* The Run key needs no change because the path is stable.

---

## 10. CI and release (WP4)

### 10.1 `.github/workflows/windows.yml` (new: build and check on pushes)
```yaml
name: Windows
on:
  push: { branches: [main], paths: ['windows/**', 'Assets/**', 'build.sh', '.github/workflows/windows.yml'] }
  pull_request: { paths: ['windows/**', 'Assets/**', '.github/workflows/windows.yml'] }
  workflow_dispatch:
permissions: { contents: read }
defaults: { run: { shell: bash } }
jobs:
  check:
    runs-on: windows-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v7                     # same major as release.yml
      - uses: actions/setup-dotnet@v6                 # latest major as of 2026-10 (v6.0.0)
        with: { global-json-file: windows/global.json }
      - run: dotnet publish windows/TokenCat.App -c Release -o publish # csproj sets win-x64/single-file; output = TokenCat.exe only
      - shell: pwsh
        run: Compress-Archive -Path publish/TokenCat.exe, LICENSE -DestinationPath TokenCat-Windows.zip   # flat entries, as released
      - run: ./publish/TokenCat.exe --self-test                         # App checks + Core suites incl. the open-writer log case (rule 8)
      - run: ./publish/TokenCat.exe --telemetry-lifecycle-checks       # real loopback + bridge command via Git Bash and PowerShell
      - run: ./publish/TokenCat.exe --update-selftest TokenCat-Windows.zip   # the real zip: extract, validate, rename-replace, relaunch
      - run: ./publish/TokenCat.exe --snapshot snapshots
      - uses: actions/upload-artifact@v7
        with: { name: windows-snapshots, path: snapshots, retention-days: 7 }
```
Bash on the runner is `bash -eo pipefail`. Git Bash waits for GUI-subsystem children, and stdout is already a pipe, so no `| cat`. The
GDI check in `--self-test` only creates and destroys HICONs, so it needs no visible tray. Hosted runners may have no Explorer taskbar.

### 10.2 `release.yml` change (applied at integration, after the parallel polish task has landed)
* New job `windows` (`needs: version`, `if: exists == 'false'`, `runs-on: windows-latest`). Steps: checkout, setup-dotnet, build,
  `dotnet publish … -r win-x64`, `--self-test`, then assert `(Get-Item publish/TokenCat.exe).VersionInfo.ProductVersion == $VERSION`
  (pwsh step). Then the same `Compress-Archive` step as §10.1, `--update-selftest TokenCat-Windows.zip`,
  `--telemetry-lifecycle-checks`, `--snapshot snapshots` (a crash blocks the release), and `actions/upload-artifact@v7`
  (`windows-release`, 1 day).
* Existing `release` job: `needs: [version, windows]`, plus `actions/download-artifact@v8` before "초안 릴리스 만들기". `gh release create
  "$TAG" TokenCat.zip TokenCat-Windows.zip …`. "초안 자산 확인" and "게시 결과 확인" loop over both names with their own SHA-256. Release
  notes gain "Windows" install sections (en/ko): extract to `%LOCALAPPDATA%\Programs\TokenCat`, SmartScreen steps (§2.8), the Smart App
  Control note, the tray overflow tip, what auto-connect changes on Windows, and the disconnect command (§7.7).
* The version comes from `build.sh` through `Directory.Build.props`, so nothing else needs passing. Effect: a failing Windows build
  blocks the mac release (one tag, both assets) (open question 6).

---

## 11. Work packages

### WP0 — skeleton (lead, before fan-out; about 2 h)
Owns: `windows/TokenCat.Windows.slnx`, `global.json`, `Directory.Build.props`, all three `.csproj`, `app.manifest`,
`Core/Models.cs` (**complete**: every record field copied from Models.swift, TokenSpeed.swift and Telemetry.swift's models, so no WP
edits it later), `Core/Lang.cs`, `Core/AppPaths.cs`, `Core/SettingsStore.cs`, `Core/Json.cs`, `Core/Checks/Check.cs`,
`Core/Checks/Suites.cs`, `Core/Checks/LocalizationChecks.cs` (+ Json/SettingsStore cases), `Checks/Program.cs` (its
`--diagnose-tokens` branch just calls `TokenDiagnostics.Run(home)`, a WP1 stub), `App/Program.cs` (stub, handed to WP5). It also creates **stub files with the exact public
signatures below**, bodies `throw new NotImplementedException()`, in each WP's folder, so every WP compiles from day one and replaces only
its own files. `Suites.cs` pre-registers every suite (`TrackerChecks.Run`, …), and each suite file returns `[]` until its WP fills it.
Done: Mac `dotnet build windows/TokenCat.Windows.slnx -c Release` gives 0 warnings, and `dotnet run --project windows/TokenCat.Checks`
gives PASS (Localization suite ported).

Shared contracts (WP0, `Models.cs`):
```csharp
public enum TokenSource { Codex, Claude, OpenCode, Gemini, Qwen, Copilot, Amp, Cline, Omp, Droid } // ids/JSON = Swift raw values ("codex", "opencode"…);
// Title/ShortTitle/ResumeCommand per source; static TokenSource.TelemetryClients = [Codex, Claude]; TokenSource.Listed(detected, readings)
public enum TokenActivityState { Idle, Working, Tool, Output, Complete, Interrupted, Stale, Unfinished, Input }
public enum ToolCategory { Command, File, Web, Agent, Mcp, Question, Other }
public sealed record TokenRetryState(int Attempt, int? MaxAttempts, DateTimeOffset? RetryAt, bool NetworkDown, DateTimeOffset At);
public sealed record TokenRateLimit(double UsedPercent, int? WindowMinutes, DateTimeOffset? ResetsAt, DateTimeOffset RecordedAt);
public sealed record TokenContextUsage(int UsedTokens, int? WindowTokens, DateTimeOffset RecordedAt, DateTimeOffset? CompactedAt);
public readonly record struct TokenOutputEvent(DateTimeOffset At, int Tokens);
public sealed record TokenSpeedMeasurement(...);            // all fields of TokenSpeed.swift's measurement, written by WP0
public sealed record TokenReading { /* every TokenReading field, same names in PascalCase, init-only */ }
public sealed record SystemSnapshot { /* SystemSnapshot fields */ }
public sealed record TelemetryReading { /* TelemetryReading fields */ }
public sealed record ClaudeLimitWindow(double UsedPercent, DateTimeOffset? ResetsAt, DateTimeOffset ReceivedAt);
public sealed record ClaudeUsageLimits(ClaudeLimitWindow? FiveHour, ClaudeLimitWindow? SevenDay);
public enum TelemetryCollectorState { Starting, Waiting, Receiving, BusyTokenCat, BusyOtherApp, Failed, Stopped }
public sealed record PixelSheet(byte[] Bgra, int Width, int Height);   // decoded by App, composed by Core
```

### WP1 — Tracking (Core)
Owns `Core/Tracking/*` (incl. `TokenDiagnostics.cs` behind `--diagnose-tokens`), `Core/Checks/TrackerChecks.cs`, `TokenSpeedChecks.cs`.
API:
```csharp
public sealed class TokenTracker {
  public TokenTracker(string home, Func<DateTimeOffset>? now = null, int initialTailBytes = 1_048_576, double discoveryIntervalSeconds = 5,
      Func<string, string?>? environment = null, IReadOnlyList<TokenProvider>? providers = null);
  public IReadOnlyList<string> WatchedDirectories { get; }   // roots of providers with a format
  public IReadOnlySet<TokenSource> DetectedSources();        // providers with an existing root, read or not
  public bool IsLog(string path);
  public void NoteChanged(IEnumerable<string> paths);
  public List<TokenReading> Sample(); }
public sealed record TokenProvider(TokenSource Source, Func<string, Func<string, string?>, IReadOnlyList<string>> Roots, TokenLogFormat? Format);
public sealed record TokenLogFormat(Func<IReadOnlyList<string>, TokenDiscovery, IEnumerable<string>> Files, Func<string, bool> IsLog,
    Func<string, ITokenLogReader> Open);                     // TokenLogFormat.Codex / .Claude
public interface ITokenLogReader { void Read(int tailLimit, DateTimeOffset now); IEnumerable<TokenReading> Readings(string id, DateTimeOffset now);
    bool IsRecent(DateTimeOffset now); }
public sealed class TokenLogParser { /* public for checks, as in Swift */ }
public static class TokenSpeed { public static List<TokenReading> Apply(IReadOnlyList<TokenReading> readings, IReadOnlyList<TelemetryReading> measurements); }
public sealed record FlowSeries(...) { public static FlowSeries Make(IReadOnlyList<TokenReading> readings, DateTimeOffset now); }
public static class FlowMath { public static double NiceMax(double value); }
public sealed class LogWatcher : IDisposable { public LogWatcher(Action<string[]> changed); public bool Start(IEnumerable<string> directories); public void Stop(); }
```
Done: all TrackerChecks/TokenSpeedChecks descriptions ported and passing. Extra cases: Windows `cwd` (`C:\Users\me\proj` → `proj`),
backslash subagent paths, CRLF lines, a temp-home end-to-end (write JSONL lines → `Sample()`; a `FileSystemWatcher` event arrives on
macOS), and the **open-writer case**: keep one `FileStream` (`FileShare.ReadWrite | FileShare.Delete`) open, append and `Flush()`
without closing, and the next `Sample()` sees the line. On Windows CI this is the evidence for rule 8.
The §6.3 parity diff is empty. Mac verification is complete. Windows: the same suites run in `windows.yml`.

### WP2 — Telemetry, limits, config setup (Core)
Owns `Core/Telemetry/*`, `Core/Checks/TelemetryChecks.cs`, `TelemetryLifecycleChecks.cs`, `TelemetrySetupChecks.cs`.
API:
```csharp
public sealed class TelemetryCollector : IDisposable {
  public const int DefaultPort = 16493;
  public TelemetryCollector(int port = DefaultPort, double[]? retryDelays = null);
  public void Start(Action? onReady = null); public void Stop(); public void RetryNow();
  public TelemetryCollectorState State { get; } public string Status { get; } public DateTimeOffset? NextRetryAt { get; }
  public IReadOnlyDictionary<TokenSource, DateTimeOffset> LastBatchAt { get; } public ClaudeUsageLimits ClaudeLimits { get; }
  public List<TelemetryReading> Snapshot();
  public static bool IsOwnCollectorRunning(TimeSpan timeout); public static List<TelemetryReading> FetchSnapshot(TimeSpan timeout); }
public static class TelemetryHttp { public static HttpDecision Parse(ReadOnlySpan<byte> data); public static byte[] Encode(int code, byte[] body); }
public static class ClaudeUsage {   // not `ClaudeLimits`: the collector's `ClaudeLimits` property would hide it
  public static ClaudeUsageLimits Merged(ClaudeUsageLimits a, ClaudeUsageLimits b);
  public static ClaudeUsageLimits? Decode(ReadOnlySpan<byte> statusJson, DateTimeOffset receivedAt);
  public static ClaudeUsageLimits? DecodeDesktopHistory(ReadOnlySpan<byte> json);
  public sealed class DesktopReader { public DesktopReader(IReadOnlyList<string> candidates); public ClaudeUsageLimits Read(); } }
public sealed class TelemetrySetup {
  public TelemetrySetup(string home, string supportDirectory);
  public TelemetrySetupResult Connect(); public TelemetrySetupResult Disconnect(); }   // + TelemetrySetupNote/Failure/Error as Swift
```
Done: suites ported and passing on Mac (setup checks on temp homes only). The lifecycle checks open real loopback listeners on free test
ports on macOS. On Windows (`OperatingSystem.IsWindows()`), the lifecycle checks also run the bridge command through Git Bash and
PowerShell (§7.4) and assert the limits arrive. That runs in `windows.yml`.

### WP3 — Presentation and Monitor (Core)
Owns `Core/Presentation/*`, `Core/LiveMonitor.cs`, `Core/Checks/SessionPresentationChecks.cs`, `PreferenceChecks.cs`, `ShellChecks.cs`
(attention/restart), `StatusSummaryChecks.cs`, `MonitorChecks.cs`.
API to WP5:
```csharp
public sealed class LiveMonitor : IDisposable {   // not `Monitor`: System.Threading.Monitor is an implicit using
  public LiveMonitor(MonitorOptions options);   // Home, SupportDirectory, Func<SystemSnapshot> sampleSystem, TelemetryCollector?, Func<DateTimeOffset>? clock
  public event Action<MonitorState>? Updated;   // raised off the UI thread; never after Stop() returns
  public MonitorState Current { get; } public void Start(); public void Stop(); public void Refresh();
  public void RetryTelemetryNow(); public void NoteTelemetryConnected(IEnumerable<TokenSource> sources); }
public sealed record MonitorState(
  DateTimeOffset Now, SystemSnapshot System, bool HasSample, IReadOnlyList<double> CpuHistory,
  IReadOnlyList<TokenReading> Tokens, DateTimeOffset? TokensSampledAt, IReadOnlyList<SessionGroup> Groups,
  SessionListModel Sessions, FlowSeries Flow, DateTimeOffset? NewestOutputAt,
  TelemetryCollectorState TelemetryState, string TelemetryStatus, DateTimeOffset? TelemetryNextRetryAt,
  IReadOnlySet<TokenSource> TelemetryRestartNeeded, IReadOnlySet<TokenSource> TelemetryRestartExpired,
  IReadOnlyDictionary<TokenSource, DateTimeOffset> TelemetryLastReceived, ClaudeUsageLimits ClaudeLimits, bool LogFoldersFound,
  IReadOnlySet<TokenSource> DetectedSources) { public IReadOnlyList<TokenSource> ListedSources { get; } }
// plus SessionPresentation/StatusSummary/QuickMenuSummary/AttentionTracker/Preferences with the Swift member names
```
Done: suites ported and passing. `MonitorChecks` (temp home, fake sampler, 6 s run) asserts the ~1 s cadence, that repeated `Start` keeps
one loop, no `Updated` after `Stop`, and that a JSONL append produces a token sample within 1.5 s (one tick plus margin: on Windows the
watcher may lag and the poll is what counts). Mac verification is complete.

### WP4 — Runner logic, Updater, pipeline (Core + CI)
Owns `Core/Runner/*`, `Core/Update/*`, `Core/Checks/RunnerChecks.cs`, `UpdaterChecks.cs`, `.github/workflows/windows.yml`, and the
`release.yml` patch plus release-notes text (prepared as a patch file, applied at integration).
API:
```csharp
public sealed record RunnerManifest(...) { public static RunnerManifest Parse(ReadOnlySpan<byte> json); public RunnerTiming Timing(RunnerPose p); }
public static class TrayFrame { public static int? BodyScale(int icon); public static int HeadScale(int icon);
  public static byte[] Body(PixelSheet sheet, RunnerPose pose, int frame, PixelSheet? fx, int fxStep, int icon, StateDot dot, bool lightTaskbar);
  public static byte[] Head(PixelSheet head, int bob, PixelSheet? fx, int fxStep, int icon, StateDot dot, bool lightTaskbar); }
public sealed class RunnerAnimator { public RunnerAnimator(RunnerManifest m, Func<DateTimeOffset> clock);
  public void Apply(RunnerPlan plan); public (RunnerPose Pose, int Frame, int? FxStep) Current { get; }
  public void Advance(); public bool PlayContent(); public void Stop(); }
public struct RunnerDirector { /* Observe, Plan, QuietSince as Swift */ }
public sealed class Updater { /* Start(bool automatic), CheckNow, Install, DashboardOpened, SystemDidWake, State, StateChanged event */ }
public static class UpdateInstaller { Blocker, Verify, Extract, Validate, Replace, Relaunch, FinishAfterUpdate(int pid), SelfTest(string zip) }
```
Done: suites ported and passing on Mac, including the installer flow on temp dirs (Mac rename semantics stand in; the Windows run is the
real test). `UpdateInstaller.SelfTest(zip)` backs `--update-selftest <zip>`: copy the running exe to a temp dir, run the copy against
the **given release zip** (Extract's entry rules and the version check apply to the real artifact), and expect rename → replace →
relaunch → marker file → `.old` removed. `windows.yml` is green on a pushed branch (needs the user's push
approval). The `release.yml` patch is reviewed and kept until integration.

### WP5 — Windows shell (App)
Owns everything under `windows/TokenCat.App/` except the csproj and `app.manifest`. That includes `Program.cs` once WP0 hands over
the stub, and with it the CLI flag dispatch to WP1/WP2/WP4 APIs.
Uses: `LiveMonitor`, `MonitorState`, presentation types, `RunnerAnimator`, `TrayFrame`, `Updater`, `TelemetrySetup`, `Preferences`.
Done:
* Mac: `dotnet build` with 0 warnings (XAML compiles on macOS, spike #4).
* `windows.yml`: `--self-test` passes. It runs Core suites plus App checks: every embedded PNG decodes with the manifest dimensions
  (180×126 / 360×252 sheets, 12×11 / 24×22 heads); 2,000 `SetIcon` swaps leave `GetGuiResources(GR_GDIOBJECTS|GR_USEROBJECTS)` within
  ±4; theme token contrast pairs from `runDesignTokenChecks`.
* `--snapshot` renders `Fixtures` (ported `SnapshotFixtures`: sessions, subagents, limits, onboarding, empty, restart-needed, log-wait)
  × {light, dark} × {ko, en} for the flyout and each settings page, using `RenderTargetBitmap`, plus tray frames at 16/20/24/32 for every
  pose. Artifacts are uploaded and reviewed on the Mac.
* The user's PC checklist (§12) passes.
Developers can bind the flyout to `Fixtures` before WP3 lands (fixtures construct `MonitorState` directly).

Dependency graph: WP0 → {WP1, WP2, WP4, WP5-shell} in parallel. WP3 code is parallel too but links against WP1/WP2 stubs until they land.
WP5 data binding finishes after WP3. All file ownership is disjoint. `Suites.cs` and the csproj files are WP0's and are not edited later
(the csproj files use wildcards).

---

## 12. Integration checklist
1. Merge WP0, then WP1, WP2, WP4, WP3, WP5 (each touches only its folders). After each merge on the Mac:
   `dotnet build windows/TokenCat.Windows.slnx -c Release` and `dotnet run --project windows/TokenCat.Checks -c Release` both pass.
2. Mac parity diff (§6.3) is empty for idle sessions.
3. Push the branch, with the user's approval. `windows.yml` is green: checks, publish, `--self-test`, lifecycle + PowerShell bridge,
   `--update-selftest`, snapshots. Review the snapshot PNGs.
4. User PC (artifact zip from step 3; Windows 11 at the user's scale, plus a check at 100 % and 200 %):
   - [ ] SmartScreen wording/steps match the README (en/ko). Note whether Smart App Control is on.
   - [ ] Tray: icon appears (or in `^`). Head mode at 100–175 % and body mode at 200 %. Animation per state (start a Codex/Claude turn →
         walk; output → run; AskUserQuestion → alert + yellow dot; idle 10 min → sleep). GDI objects flat over 30 min.
   - [ ] Flyout opens by the tray (bottom and top taskbar on Win10 if available), with a second monitor at a different scale if
         available. It closes on outside click/Esc, and clicking the icon while it's open closes it without flashing back. Right-click
         menu works with arrow keys/Esc and is dark on a dark system. Win+B → Enter opens it.
   - [ ] Widget (§4.7): appears bottom-right; clicking it or the desktop never steals the focus from the app you're typing in. Drag
         snaps to edges, survives a restart, and comes back per monitor set (dock/undock, a second monitor at another scale: crisp
         after moving across). Click toggles the flyout (below it near the top edge); right-click menu closes on an outside click.
         Size from the menu, Settings and Ctrl + wheel (on a 100 % display 125/150 % smooth, 200 % crisp); in a corner it grows away from the edges and
         comes back there after a restart. Settings › Widget: drag, Alt+↑/↓ and the row menu reorder items; Narrator reads the rows.
         Hidden during a full-screen video/game/slideshow, back after; clicking the desktop doesn't hide it. Not in Alt+Tab or the taskbar.
   - [ ] Live latency: during a Codex turn the session row/tok updates within about 1 s (rule 8, open writer).
   - [ ] Defender: right-click the zip → Scan with Microsoft Defender. Record any detection name (§2.8).
   - [ ] Dark ↔ light switch updates the flyout and tray dot outline live.
   - [ ] Auto-connect: `config.toml`/`settings.json` changed as documented, backups in `%LOCALAPPDATA%\TokenCat\telemetry-backups`. After
         restarting the clients, tok/s appears. `--disconnect-telemetry | Out-Host` restores both.
   - [ ] Claude limits: with no statusLine → bridge row appears after the first response, and the status line latency is acceptable. With an
         existing statusLine → kept untouched plus the note. Claude Desktop installed → limits from `plan-usage-history.json` (record which
         path existed). With Claude Code in the VS Code extension / Claude Desktop (no console), no PowerShell window flashes; if
         one does, the bridge needs `-WindowStyle Hidden` or a different host. Record whether Git Bash is installed.
   - [ ] No firewall prompt. Port-busy states: run a second copy, and an app occupying 16493.
   - [ ] Notifications (opt-in): input and turn end appear once. Click opens the right group.
   - [ ] Start at login: on → reboot → running. Task Manager disable → settings shows it.
   - [ ] Second launch opens the flyout. Quit frees the port.
   - [ ] Memory: working set after 1 h, uncompressed vs compressed build (open question 3).
5. After the parallel polish task has merged: apply the `release.yml` patch, add README/README.ko Windows sections, bump `build.sh`. The
   release has both assets with matching digests, `/releases/latest` readback passes for both, and the mac updater still installs
   `TokenCat.zip` (UpdaterChecks unchanged).
6. Next release: in-app update N-1 → N on the PC (rename-replace, relaunch, Run key still valid, `.old` removed).

---

## 13. Open questions (defaults in bold)
1. **Tray art:** cat head at 16–28 px and full body only at ≥ 30 px, **ship v1 like this**, or first add tray-size character sheets to
   `Assets/Generator`?
2. **Existing Claude statusLine:** **leave it untouched in v1** (limits only via Claude Desktop history), or wrap it now? Wrapping needs to
   re-run the original in the shell Claude Code used. Heuristic: `$env:MSYSTEM` set → Git Bash `bash.exe -c`, else
   `powershell -NoProfile -Command`. Untestable without the PC.
3. **Single-file compression:** **off** (156 MB on disk, mapped, lower private RAM, faster start) or on (69 MB on disk, inflated into RAM
   at launch)? The download is about 64 MB either way. Decide from the PC measurement.
4. **arm64:** **x64 only** in `TokenCat-Windows.zip` (runs emulated on Windows on ARM), or also `TokenCat-Windows-arm64.zip` with the
   updater choosing by `RuntimeInformation.OSArchitecture`?
5. **Code signing:** **unsigned v1** (SmartScreen "Run anyway"; Smart App Control users must turn SAC off). Azure Artifact Signing costs
   $9.99/month, may not be available to an individual in Korea, and doesn't remove the warning at first.
6. **Release coupling:** **one release job, so a Windows build failure blocks the mac release**, or let mac publish alone and attach the
   Windows asset when it builds?
7. **Install location:** no installer. **README recommends `%LOCALAPPDATA%\Programs\TokenCat`**, and the app refuses updates/login item when
   run from `%TEMP%`. Should it offer "Move to recommended folder" itself?
8. **`CODEX_HOME` / `CLAUDE_CONFIG_DIR` / WSL:** **ignored, as on mac; the empty state says WSL isn't tracked.** Honour them on Windows
   only? WSL is the bigger gap (§2.2, §3.2). Decide after the user says whether they run the CLIs natively or in WSL.
9. **Notifications:** **balloons** (transient on Windows 11, no packages) are enough for v1?
10. The PowerShell bridge pays a Windows PowerShell 5.1 start per status line run (unmeasured; expect about 0.3–1 s with Defender), and
    Claude Code cancels it if a newer update arrives first. **Acceptable** (it's the form Claude's docs use; limits change slowly), or is
    it a reason to prefer the Claude Desktop source only? Measure on the PC.

---

## 14. Sources
* Claude Code status line (Windows shell, rate_limits): https://code.claude.com/docs/en/statusline
* Claude Code settings (`%USERPROFILE%\.claude`, `CLAUDE_CONFIG_DIR`): https://code.claude.com/docs/en/settings
* Codex config / `CODEX_HOME`: https://learn.chatgpt.com/docs/config-file/config-advanced · https://developers.openai.com/codex/config-basic
* Claude Desktop `plan-usage-history.json` on Windows (third-party evidence): https://github.com/Hamras47/claude-usage-widget ·
  https://github.com/wus-technik/win_systray-claude-usage/issues/5 · https://github.com/anthropics/claude-code/issues/96716
* NOTIFYICONDATAW (icon sizes, LoadIconMetric, balloons, quiet time): https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-notifyicondataw
* Icon.FromHandle / DestroyIcon: https://learn.microsoft.com/en-us/dotnet/api/system.drawing.icon.fromhandle
* NotifyIcon.ShowBalloonTip: https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.notifyicon.showballoontip · https://comcomponent.com/en/blog/windows-tray-icon-toast-notification-guide/
* Single-file deployment (extraction, compression, ProcessPath): https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview
* WPF in .NET 10 (Fluent still in progress): https://learn.microsoft.com/en-us/dotnet/desktop/wpf/whats-new/net100
* Run keys: https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys · StartupApproved: https://www.elevenforum.com/t/enable-or-disable-startup-apps-in-windows-11.699/
* TcpListener.ExclusiveAddressUse: https://learn.microsoft.com/en-us/dotnet/api/system.net.sockets.tcplistener.exclusiveaddressuse
* HttpListener URL ACL: https://octopus.com/docs/support/troubleshooting-access-denied-starting-http-listener · https://learn.microsoft.com/en-us/windows/win32/http/add-urlacl
* Excluded port ranges / WSAEACCES: https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/error-10013-wsaeacces-is-returned · https://dev.to/milkyway008/socket-error-10013-on-windows-your-port-is-reserved-not-blocked-1kja
* SmartScreen: https://learn.microsoft.com/en-us/archive/blogs/vsnetsetup/windows-smartscreen-prevented-an-unrecognized-app-from-running-running-this-app-might-put-your-pc-at-risk · KO: https://comeinsidebox.com/unprotect-your-pc-in-windows/ · https://www.opcstory.com/2024/04/windows-pc.html
* Smart App Control: https://support.microsoft.com/en-us/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions
* Code signing options / Artifact Signing: https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options · https://www.devclass.com/security/2026/01/14/code-signing-windows-apps-may-be-easier-and-more-secure-with-new-azure-artifact-service/4079554
* ReadDirectoryChangesW (size/last-write notifications wait for cache flush): https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw
* Probed locally (review): System.Text.Json BOM/encoder/newline behaviour (`dotnet run` file programs), `sips -s format ico`, the 127-char
  NotifyIcon message, `HostedWindowsFormsMessageHook`/`WmTaskbarCreated` in Microsoft.WindowsDesktop.App 10.0.12 System.Windows.Forms.dll,
  and the latest action majors via api.github.com (checkout v7, setup-dotnet v6, upload-artifact v7, download-artifact v8).
* mac source of truth: `Sources/TokenCat/*.swift`, `build.sh`, `.github/workflows/release.yml`, `Assets/runner-v2.json` (repo at ae08ab3)

---

## 15. Skeleton as built (WP0, 2026-10-05)

Open questions 1–10 are settled at their **bold defaults**. Where this section and §5–§11 differ, this section wins.

**Ownership** (disjoint; nobody edits another package's file, `Suites.cs` or a csproj):

| Package | Owns (create/edit) |
|---|---|
| WP0 (frozen) | `TokenCat.Windows.slnx`, `global.json`, `Directory.Build.props`, `DESIGN.md`, the three csproj, `TokenCat.App/app.manifest`, `TokenCat.App/TokenCat.ico`, `TokenCat.Checks/Program.cs`, `Core/{Models,Lang,AppPaths,Json,SettingsStore}.cs`, `Core/Checks/{Check,Suites,LocalizationChecks,CoreChecks}.cs` |
| WP1 | `Core/Tracking/**`, `Core/Checks/{TrackerChecks,TokenSpeedChecks}.cs` |
| WP2 | `Core/Telemetry/**`, `Core/Checks/{TelemetryChecks,TelemetrySetupChecks,TelemetryLifecycleChecks}.cs` |
| WP3 | `Core/Presentation/**`, `Core/LiveMonitor.cs`, `Core/Checks/{SessionPresentationChecks,PreferenceChecks,ShellChecks,StatusSummaryChecks,MonitorChecks}.cs` |
| WP4 | `Core/Runner/**`, `Core/Update/**`, `Core/Checks/{RunnerChecks,UpdaterChecks}.cs`, `.github/workflows/windows.yml`, `windows/release.yml.patch` |
| WP5 | `TokenCat.App/**` except the csproj, `app.manifest` and `TokenCat.ico` |

New files inside an owned folder need no registration (SDK wildcards). Keep every stub signature that another package uses;
add members freely.

**Conventions every package follows**
* One namespace, `TokenCat` (Swift has one module). `using static TokenCat.Lang;` → `Loc(ko, en)`, `Plural(n, noun)`;
  `Format.Span/Ago/Later/Age/Tokens/CompactTokens/Percent/Tps/Ratio/Capacity/Power` (Lang.cs). `Format` is `partial`: WP3 adds `Elapsed`.
* Both entry points set the process culture to invariant (Swift interpolation and `String(format:)` are locale-free). Name a
  culture only where mac does: `Lang.Culture` for dates, ko-KR for token grouping. .NET's `F1`/`F0` already round like printf.
* Models are init-only records changed with `with`. Swift computed members on a model go in the owner's file through a
  `partial` record (only `TokenSpeedMeasurement` today) and carry `[JsonIgnore]`; enums get C# 14 `extension` blocks
  (`source.Id`, `source.Title`, `state.IsRunning`, `SessionDisplayState.MostUrgent(…)`).
* JSON only through `Json`: `Parse` (BOM-tolerant, null on invalid) with `Field(key)?.Number/.Text/.Bool` for Swift's casts,
  `ParseNode` for edits, `Write` (sorted, LF, raw numbers) for files other apps read, `Serialize`/`Options` for models
  (camelCase, raw-value enums, nulls omitted). Atomic writes: `AppPaths.WriteAtomically` (rule 9). Settings:
  `SettingsStore.Shared.Get<bool?>(key)` / `Set` / `Remove`.
* A check suite: `var c = new Check("Tracker"); void check(bool ok, string d) => c.That(ok, d); … return c.Done();` (pass the
  Swift prefix, e.g. `new Check("Localization", "Localization: ")`; `c.Skip()` for Updater's skips). `Suites.RunAll()` runs every
  registered suite in Korean; `Suites.Report(failures)` prints and returns the exit code (the App's `--self-test` appends its
  own checks first).
* `TokenCat.Checks`: no args → all suites; `-- --diagnose-tokens [home]` → `TokenDiagnostics.Run` (WP1);
  `-- --telemetry-lifecycle-checks [port]` → `TelemetryLifecycleChecks.Run(int?)` (WP2; null = pick a free pair).

**Differences from §11's sketches**
* `TokenReading.RequestIDs` is `ImmutableHashSet<string>` (System.Text.Json can't create an `IReadOnlySet`).
* `TelemetrySetupNote` adds `StatusLineKept`; `TelemetrySetupFailure` is a record hierarchy (`WriteFailed(bool Restored)`);
  `TelemetrySetupError` is an exception carrying it. `TelemetrySetup.Port`/`OptOutKey` are constants.
* `SessionDisplayState`, `SessionMember` and `SessionGroup` (`Members`, `State`, `LastActivity`) are already real: WP4's
  `RunnerActivity` merges before WP3. `SessionPresentation.Groups` is a stub.
* `Core/Telemetry/TelemetryHttp.cs` holds the spike's working `Parse` (no checks yet); `Encode` is a stub.
* `LocalizationChecks` holds SessionPresentationChecks.swift's three Format cases ("token format", "compact token format",
  "ages use the model clock"); WP3 skips them and ports the SessionPresentation/OnboardingCard halves of the Swift
  localization checks into its own suite with the same descriptions.
* Entry points for the App CLI: `Updater.CommandLineCheck()`, `UpdateInstaller.FinishAfterUpdate(pid)`, `UpdateInstaller.SelfTest(zip)`.
* The App embeds the 23 artwork files from `../../Assets` (`GetManifestResourceStream("runner-v2@1x.png")`); nothing is copied
  into the repo. The skeleton App shows the cat head and an empty flyout with the §4.2 mechanics.
