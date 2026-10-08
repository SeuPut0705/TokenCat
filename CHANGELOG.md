# Changelog · 변경 기록

The release workflow puts the `## <version>` entry into that version's release notes. · 릴리스 워크플로가 `## <버전>` 항목을 그 버전의 릴리스 노트에 넣습니다.

## 0.18.2

**macOS and Windows**

- The Mac download is now `TokenCat-macOS.zip`, next to `TokenCat-Windows.zip`. The same file is also attached as `TokenCat.zip` for a while so TokenCat 0.18.1 and earlier still update in the app; from this version the app takes `TokenCat-macOS.zip`. · Mac용 내려받기 파일 이름이 `TokenCat-Windows.zip`과 짝을 맞춰 `TokenCat-macOS.zip`이 되었습니다. TokenCat 0.18.1 이하도 앱 안에서 업데이트할 수 있도록 한동안 같은 파일을 `TokenCat.zip`으로도 함께 올리며, 이번 버전부터 앱은 `TokenCat-macOS.zip`을 받습니다.
- The Windows version is no longer labelled a preview in the README, details and release notes. · README·자세한 동작·릴리스 노트에서 Windows 버전의 미리보기 표기를 뺐습니다.

## 0.18.1

**macOS and Windows**

- Claude's weekly and 5-hour limits stay live while you work through omp or Pi, even when Claude Code's own sign-in has expired: the live check now falls back to omp's or Pi's saved Claude sign-in for the same account instead of showing an older omp record. · omp·Pi로 작업하는 동안 Claude Code 자체 로그인이 만료됐어도 Claude 주간·5시간 한도가 실시간으로 유지됩니다. 실시간 확인이 오래된 omp 기록을 보이는 대신 같은 계정으로 omp·Pi에 저장된 Claude 로그인을 씁니다.

## 0.18.0

**macOS and Windows**

- New clients: Cursor (IDE agent and `cursor-agent` CLI; state, model, title, context and project, but no tokens or speed, which Cursor doesn't store), Grok Build, Hermes Agent, OpenClaw, Goose and Kimi Code (with Kimi Work and the archived kimi-cli as Kimi CLI). Grok, Hermes, Goose and Kimi Code show a measured request tok/s from the times they record; OpenClaw shows none. · 새 클라이언트: Cursor(IDE 에이전트와 `cursor-agent` CLI. 상태·모델·제목·컨텍스트·프로젝트를 보이며, Cursor가 저장하지 않는 토큰과 속도는 없음), Grok Build, Hermes Agent, OpenClaw, Goose, Kimi Code(Kimi Work, 그리고 Kimi CLI로 보이는 보관된 kimi-cli 포함). Grok·Hermes·Goose·Kimi Code는 스스로 기록한 시간으로 잰 요청 tok/s를 보이고, OpenClaw는 속도가 없습니다.
- Products that write another client's format show under their own names: Kilo Code and MiMo Code (OpenCode's store), OpenClaude and Qoder (Claude Code's), TRAE CLI (Codex's), Zoo Code and IBM Bob (Cline's). These rows show no Codex or Claude usage limits and no resume command. · 다른 클라이언트의 형식으로 기록하는 제품이 자기 이름으로 보입니다: Kilo Code·MiMo Code(OpenCode 저장소), OpenClaude·Qoder(Claude Code), TRAE CLI(Codex), Zoo Code·IBM Bob(Cline). 이 행에는 Codex·Claude 사용 한도와 재개 명령이 없습니다.
- OpenCode 2's `session_message` store is read beside the classic one; a session present in both is counted once. · OpenCode 2의 `session_message` 저장소도 기존 저장소와 함께 읽고, 양쪽에 있는 세션은 한 번만 셉니다.
- Existing clients are found in more data folders: `CODEX_HOME`, `CLAUDE_CONFIG_DIR` (also a comma-separated list) and `~/.config/claude`, Gemini CLI's sandbox folder (macOS), Cline's shared `~/.cline/data` and `CLINE_DIR`/`CLINE_DATA_DIR`/`CLINE_SESSION_DATA_DIR`, Cline-family tasks in every VS Code-style editor, omp profiles, `PI_CONFIG_DIR` and `$XDG_DATA_HOME/omp` (macOS), Pi's `PI_CODING_AGENT_SESSION_DIR` and Droid's `FACTORY_HOME_OVERRIDE`. Claude Code's `.orphaned-*` transcripts are ignored. · 기존 클라이언트를 더 많은 데이터 폴더에서 찾습니다: `CODEX_HOME`, `CLAUDE_CONFIG_DIR`(쉼표로 여럿 가능)와 `~/.config/claude`, Gemini CLI의 샌드박스 폴더(macOS), Cline 공용 `~/.cline/data`와 `CLINE_DIR`·`CLINE_DATA_DIR`·`CLINE_SESSION_DATA_DIR`, 모든 VS Code 계열 에디터의 Cline 계열 작업, omp 프로필·`PI_CONFIG_DIR`·`$XDG_DATA_HOME/omp`(macOS), Pi의 `PI_CODING_AGENT_SESSION_DIR`, Droid의 `FACTORY_HOME_OVERRIDE`. Claude Code의 `.orphaned-*` 기록은 무시합니다.
- Copy Resume Command works for the new clients that have one: `grok --resume`, `hermes --resume`, `kimi -r` and `goose session --resume --session-id`. · 재개 명령 복사가 명령이 있는 새 클라이언트에도 됩니다: `grok --resume`, `hermes --resume`, `kimi -r`, `goose session --resume --session-id`.

## 0.17.0

**macOS and Windows**

- Session titles line up: every live row puts its state glyph in the glyph column and its title on the text column shared with quiet rows and subagents, and the state's words (`Waiting for plan approval`, `Running command`, …) open the second line in place of the colored chip. · 세션 제목이 한 줄로 맞춰집니다. 진행 행마다 상태 글리프를 글리프 열에, 제목을 쉬는 행·하위 에이전트와 같은 글자 열에 두고, 색 칩 대신 상태를 말로(`계획 승인 대기`, `명령 실행 중` …) 둘째 줄 앞에 적습니다.
- Usage limits have their own card right under the header, named provider first (`Claude · 5-hour 42% used`), and an account's other live window gets its own line instead of hiding in help (Claude's weekly beside its 5-hour, and Codex's when both are logged). · 사용 한도가 헤더 바로 아래 자기 카드로 옮겨 제공사를 앞에 두고(`Claude · 5시간 42% 사용`), 계정의 다른 창도 도움말에 숨지 않고 한 줄을 따로 받습니다(Claude의 5시간 옆 주간, 둘 다 기록되면 Codex도).
- The output card is about half as tall: the total sits on the title line with the per-client split, the last record and Speed now share one line, and the bars are shorter (their scale moved to help). The session list grows to 312 pt before it scrolls, and the footer hides while everything is live (the check interval and last telemetry moved to the header's help), so a fifth live session fits without a taller popover. · 출력 카드 높이가 절반쯤으로 줄었습니다. 합계를 클라이언트별 내역과 함께 제목 줄에 두고, 마지막 기록과 지금 속도를 한 줄에 놓았으며, 막대를 낮췄습니다(눈금은 도움말로). 세션 목록은 312pt까지 늘어난 뒤 스크롤하고, 모두 정상일 때는 아래쪽 줄을 숨겨(확인 주기·마지막 실측 수신은 헤더 도움말로) 팝오버를 키우지 않고도 다섯째 진행 세션이 들어갑니다.
- One input wait is said once: a row waiting for you ends with only the time waited (`0:40`), and the output card no longer repeats `Waiting for input · reply to resume` under the header that already says it. · 입력 대기를 한 번만 말합니다. 입력을 기다리는 행은 기다린 시간(`0:40`)만 끝에 두고, 출력 카드도 헤더가 이미 말한 `입력 대기 · 답변하면 계속 기록`을 되풀이하지 않습니다.
- Speed now without a measurement says `No measured speed` instead of a `—` that read as a divider, and folded clients read `+1 more` (`외 1`) instead of a bare `+1`. · 실측이 없을 때 지금 속도는 구분선처럼 보이던 `—` 대신 `속도 실측 없음`이라고 적고, 접힌 클라이언트는 숫자만인 `+1` 대신 `외 1`(`+1 more`)로 적습니다.
- The list has one disclosure control, at its end (`Show all 12 sessions ⌄`, `Show less ⌃`), instead of a header toggle; the `+3 subagents waiting for log ⌄` line gets a chevron and turns primary on hover so it reads as a button. · 목록을 펼치고 접는 곳이 헤더 대신 목록 끝 한 곳(`세션 12개 모두 보기 ⌄`, `접기 ⌃`)이 되었고, `+3 하위 로그 대기 ⌄` 줄은 갈매기표와 마우스를 올리면 진해지는 글자로 버튼처럼 보입니다.
- The inline detail has `Copy Resume Command` and `Show in Finder` (Windows: `Show in File Explorer`) buttons, and ⌘⇧C (Ctrl+Shift+C) copies the selected session's resume command. · 인라인 상세에 `재개 명령 복사`·`Finder에서 보기`(Windows는 `탐색기에서 보기`) 버튼이 생겼고, ⌘⇧C(Ctrl+Shift+C)로 선택한 세션의 재개 명령을 복사합니다.
- A subagent without a distinguishing role reads `Subagent · a2222222` instead of a bare ID. · 구별되는 역할이 없는 하위 에이전트는 ID만 보이지 않고 `하위 에이전트 · a2222222`로 보입니다.
- The system meters share one length, and CPU's 30-second peak tick shows only when it's 5 points or more above the current value. · 시스템 미터가 같은 길이가 되었고, CPU의 30초 최고값 눈금은 지금 값보다 5 이상 높을 때만 보입니다.
- The first-launch card is one line per point with the explanations in help; a telemetry problem keeps its reason and `Open settings` on the card. · 처음 실행 카드가 항목마다 한 줄이 되고 설명은 도움말로 옮겼습니다. 실측 연결에 문제가 있으면 그 이유와 `설정 열기`는 카드에 남습니다.
- While any session waits for input, the menu bar (Windows: widget) AI number counts only those sessions. · 입력을 기다리는 세션이 있으면 메뉴 막대(Windows: 위젯) AI 숫자는 그 세션 수만 셉니다.
- Average speed shows up to three client icons whole, side by side and 1 pt apart instead of overlapping (the One Line item is a little wider). · 평균 속도의 클라이언트 아이콘을 겹치지 않고 최대 세 개까지 1pt 간격으로 나란히 그립니다(한 줄 표시의 항목이 조금 넓어짐).
- The right-click quick menu adds `N more sessions…` when more than three are live. · 진행 중인 세션이 세 개를 넘으면 우클릭 빠른 메뉴에 `그 외 N개 세션…`이 생깁니다.
- Settings › Telemetry: `Disconnect…` (with confirmation) and `Reconnect` replace the terminal command in the footer. · 설정 › 실측: 꼬리말의 터미널 명령 대신 `연결 해제…`(확인 후)와 `다시 연결` 단추를 둡니다.
- Settings › Telemetry: a working collector reads `On · 127.0.0.1:16493` with a check, idle clients `Nothing received yet`, the retry line no longer crowds the collector row, and each client row has a folder button for its config file. · 설정 › 실측: 정상 수집기는 체크와 `켜짐 · 127.0.0.1:16493`, 받은 것이 없는 클라이언트는 `아직 받은 실측 없음`으로 보이고, 재시도 줄이 수집기 줄을 밀지 않으며, 클라이언트 줄마다 설정 파일 폴더 단추가 있습니다.
- The character's visibility moved to the top of the item list (Menu Bar / Widget tab), and the item rows dim while Minimal is selected. · 캐릭터 표시를 항목 목록 맨 위(메뉴 막대·위젯 탭)로 옮기고, 최소 표시에서는 항목 줄을 흐리게 합니다.
- `Restore Defaults…` sits in its own section at the bottom of General; a found update shows only a prominent `Update` button; About lists the privacy facts as three left-aligned lines. · `기본값으로 되돌리기…`를 일반 탭 맨 아래 따로 두고, 새 버전이 있으면 강조한 `업데이트` 단추만 보이며, 정보 탭의 개인정보 문구를 왼쪽 정렬 세 줄로 나눕니다.

## 0.16.0

**macOS and Windows**

- Claude and Codex usage limits keep updating while you work through omp or Pi: TokenCat now reads, read-only, the newest 5-hour, weekly and Codex windows those clients record from their own usage checks (`usage_history` in `~/.omp/agent/agent.db` or `~/.pi/agent/agent.db`), only the percentages and times. They count as records with omp's or Pi's record time, merge with the other sources by recency, and the row says who recorded them (`… · omp recorded 4m ago`); Anthropic rows from an account other than Claude Code's are ignored. · omp나 Pi로 작업해도 Claude·Codex 사용 한도가 계속 갱신됩니다. 두 클라이언트가 직접 확인해 남기는 최근 5시간·주간·Codex 창(`~/.omp/agent/agent.db`·`~/.pi/agent/agent.db`의 `usage_history`)을 사용률과 시각만 읽기 전용으로 읽습니다. omp·Pi의 기록 시각을 가진 기록으로 다른 경로와 시각순으로 합치고, 누가 기록했는지 줄에 함께 적습니다(`… · omp 4분 전 기록`). Claude Code와 다른 계정의 Anthropic 기록은 쓰지 않습니다.
- Live usage limits are checked every minute while any running session uses that account's models, not only that provider's own client: an omp session on a Claude model keeps Claude's check at one minute, one on a GPT model keeps Codex's. · 실시간 한도 확인이 그 제공사 클라이언트뿐 아니라 그 계정의 모델을 쓰는 실행 중인 세션이 있으면 1분마다 확인합니다. Claude 모델을 쓰는 omp 세션은 Claude를, GPT 모델을 쓰는 세션은 Codex를 1분 주기로 유지합니다.
- Session rows show the session's title instead of only its project folder, and follow it live as the client renames or regenerates it: Claude Code `/rename` and generated titles, Codex thread names, OpenCode, omp and Pi, Gemini CLI, Qwen Code, Copilot CLI, Amp and Droid titles. The project stays on the row (the second line of a live row, beside the title on a quiet one), help, VoiceOver and `Speed now` name the title too, and long titles end in `…`. Only titles the client generated or you set are read, cut to one line of 80 characters and kept in memory only; Cline, Roo Code and Kilo Code (whose task title is the first prompt) keep showing the project. · 세션 행이 프로젝트 폴더 대신 세션 제목을 보여 주고, 클라이언트가 이름을 바꾸거나 다시 만들면 바로 따라갑니다. Claude Code `/rename`·자동 제목, Codex 스레드 이름, OpenCode, omp·Pi, Gemini CLI, Qwen Code, Copilot CLI, Amp, Droid 제목을 읽습니다. 프로젝트는 행에 남고(진행 중 행은 둘째 줄, 조용한 행은 제목 옆), 도움말·VoiceOver·`지금 속도`도 제목을 말하며, 긴 제목은 `…`로 줄입니다. 클라이언트가 만들었거나 사용자가 정한 제목만 한 줄 80자로 잘라 메모리에만 둡니다. 작업 제목이 첫 프롬프트인 Cline·Roo Code·Kilo Code는 그대로 프로젝트를 보여 줍니다.

## 0.15.0

**macOS and Windows**

- Gemini CLI and Qwen Code now get a measured speed (**request tok/s**). When `~/.gemini` or `~/.qwen` exists, TokenCat connects their built-in telemetry to its local collector like Codex and Claude Code: it sets `telemetry` in their `settings.json` (`enabled`, `target: "local"`, `otlpEndpoint: "http://127.0.0.1:16493"`, `otlpProtocol: "http"`, `logPrompts: false`), keeps every other key, backs up the original first, and `--disconnect-telemetry` reverts it. Each main-conversation `api_response` gives output tokens (plus thinking tokens counted apart) over its request time, attached to that session's row; subagent and utility requests are skipped. · Gemini CLI와 Qwen Code에도 실측 속도(**요청 tok/s**)가 붙습니다. `~/.gemini`나 `~/.qwen`이 있으면 Codex·Claude Code처럼 내장 실측을 로컬 수집기에 연결합니다. `settings.json`의 `telemetry`(`enabled`, `target: "local"`, `otlpEndpoint: "http://127.0.0.1:16493"`, `otlpProtocol: "http"`, `logPrompts: false`)를 설정하고 다른 키는 그대로 두며, 원본을 먼저 백업하고 `--disconnect-telemetry`로 되돌립니다. 메인 대화의 `api_response`마다 출력 토큰(따로 센 생각 토큰 포함)을 요청 시간으로 나눠 그 세션 행에 붙이고, 하위 에이전트·보조 요청은 건너뜁니다.
- A Gemini CLI or Qwen Code `settings.json` that already sends telemetry elsewhere, or isn't plain JSON, is left as it is and only that client is skipped; Settings › Telemetry shows `Not connected · existing telemetry settings kept` with the reason, and Codex and Claude Code still connect. A client installed after the connection joins it on the next launch under the same backups. · 이미 다른 곳으로 실측을 보내거나 순수 JSON이 아닌 Gemini CLI·Qwen Code `settings.json`은 그대로 두고 그 클라이언트만 건너뜁니다. 설정 › 실측에 `연결 안 함 · 기존 실측 설정 유지`와 이유가 보이며 Codex·Claude Code는 그대로 연결합니다. 연결 뒤 설치한 클라이언트는 다음 실행 때 같은 백업 아래 연결에 더해집니다.
- The collector now accepts chunked request bodies (`Transfer-Encoding: chunked`), which the Node OTLP/HTTP exporters in Gemini CLI and Qwen Code send without a length; a request with both a length and chunking, another coding or broken framing is still refused. · 수집기가 길이 없이 청크로 나눠 보내는 요청 본문(`Transfer-Encoding: chunked`)을 받습니다. Gemini CLI·Qwen Code의 Node OTLP/HTTP 전송기가 이렇게 보냅니다. 길이와 청크를 함께 쓰거나 다른 인코딩, 깨진 청크는 계속 거부합니다.
- Settings › Telemetry lists Gemini CLI and Qwen Code once detected, with buttons to show their settings files; the first-launch card names every client it connected. · 설정 › 실측에 감지된 Gemini CLI·Qwen Code 줄과 설정 파일 보기 버튼이 생기고, 처음 실행 카드는 연결한 클라이언트를 모두 적습니다.

## 0.14.2

**macOS and Windows**

- With no log folders, the empty dashboard no longer lists every client and about 30 folders: the title names no client (`Couldn't find any coding agent log folders`), one line names the supported clients, and the folders searched are in its help. · 기록 폴더가 없을 때 빈 상세 화면이 모든 클라이언트와 30개쯤의 폴더를 늘어놓지 않습니다. 제목에는 클라이언트 이름을 넣지 않고(`코딩 에이전트 기록 폴더를 찾지 못했습니다`), 지원하는 클라이언트를 한 줄로 보여 주며, 찾는 폴더는 그 줄의 도움말에 있습니다.
- The output card's per-client split lists clients largest first and folds those that don't fit beside Speed now into `+N`, so four or more clients no longer spill past the card. · 출력 카드의 클라이언트별 내역을 많은 순서로 보이고, 지금 속도 옆에 들어가지 않는 클라이언트는 `+N`으로 접어 클라이언트가 넷 이상이어도 카드 밖으로 넘치지 않습니다.
- Help texts that still named only Codex and Claude Code (loading, no active sessions, the output card's ⓘ and waiting captions) now speak of coding agents in general. · 아직 Codex·Claude Code만 말하던 도움말(기록 확인 중, 진행 중인 세션 없음, 출력 카드의 ⓘ와 대기 문구)을 코딩 에이전트 전반으로 고쳤습니다.
- The Average speed row in Settings now says what the item is (`Mean of measured session speeds, all clients`), since its bar label shows client icons instead of `AVG`. · 설정의 평균 속도 항목 줄에 이 항목이 무엇인지 적었습니다(`모든 클라이언트 세션의 실측 속도 평균`). 메뉴 막대에서는 `AVG` 대신 클라이언트 아이콘이 보이기 때문입니다.
- Gemini CLI: starting Gemini or a new chat no longer shows a phantom working turn; Esc-cancelled requests show as interrupted; mid-turn history compression keeps the turn's start and output; a resumed old session is no longer listed twice; out-of-range token counts can no longer crash the app. · Gemini CLI: 실행·새 대화만으로 작업 중 턴이 생기지 않고, Esc 취소는 중단으로, 턴 중 기록 압축은 턴 시작·출력을 유지하며, 이어 연 옛 세션이 두 줄로 나오지 않고, 범위를 벗어난 토큰 값으로 앱이 멈추지 않습니다.
- Roo Code / Kilo Code: a finished subtask completes instead of waiting for input for 24 h, and its parent shows as running an agent while it works; rows, details and speed help are labelled Roo Code, Kilo Code and Pi instead of Cline and omp. · Roo Code / Kilo Code: 끝난 하위 작업이 24시간 입력 대기로 남지 않고 완료되며, 그동안 부모 작업은 에이전트 실행 중으로 보입니다. 행·상세·속도 도움말에 Cline·omp 대신 Roo Code·Kilo Code·Pi로 표시합니다.
- omp / Pi: forked sessions stay top-level conversations instead of folding under the original as subagents; `PI_CODING_AGENT_DIR` is honoured. · omp / Pi: 포크한 세션이 원래 세션의 하위 에이전트로 접히지 않고 독립 대화로 남으며, `PI_CODING_AGENT_DIR`을 따릅니다.
- OpenCode: a request that failed with a large error page shows as interrupted instead of a stuck working turn; a busy database is read again instead of caching a wrong role; a relative `OPENCODE_DB` resolves inside OpenCode's data folder like OpenCode does; on Windows new activity is picked up even when no session was recent. · OpenCode: 큰 오류 페이지로 실패한 요청이 멈춘 작업 중 턴 대신 중단으로 표시되고, 바쁜 DB는 잘못된 역할을 캐시하지 않고 다시 읽으며, 상대 경로 `OPENCODE_DB`를 OpenCode처럼 데이터 폴더 기준으로 찾고, Windows에서 최근 세션이 없어도 새 활동을 감지합니다.
- Cline / Roo Code / Kilo Code: the project is found even when a pasted screenshot or large attachment comes first; large tasks are re-summarised at most every 5 s while streaming. · Cline / Roo Code / Kilo Code: 붙여넣은 스크린샷·큰 첨부가 앞에 있어도 프로젝트를 찾고, 스트리밍 중 큰 작업은 5초에 한 번만 다시 요약합니다.
- "Show Log File" now works for OpenCode, Amp, Cline/Roo/Kilo and older Gemini rows. · "기록 파일 보기"가 OpenCode·Amp·Cline/Roo/Kilo·옛 Gemini 행에서도 동작합니다.
- Windows: one oversized token total no longer freezes token updates for every client. · Windows: 토큰 합계 하나가 너무 커도 모든 클라이언트의 토큰 갱신이 멈추지 않습니다.
- Lower idle CPU: log folders are re-listed every 60 s instead of every 5 s, and a write to a session left out by the caps opens it at once. · 대기 중 CPU 감소: 로그 폴더를 5초가 아닌 60초마다 다시 훑고, 목록 한도 밖 세션에 기록이 생기면 바로 엽니다.
- Tool output, lock files and OpenCode snapshot writes in watched folders no longer wake a full log read (OpenCode's WAL still does). · 감시 폴더의 도구 출력·잠금 파일·OpenCode 스냅샷 기록은 더 이상 전체 로그 읽기를 깨우지 않습니다(OpenCode WAL은 계속 깨움).
- A quiet session still in a turn is no longer dropped when many clients list hundreds of logs. · 여러 클라이언트가 로그 수백 개를 나열해도 턴이 진행 중인 조용한 세션이 더 이상 빠지지 않습니다.
- One sessions rebuild per second instead of two; on macOS the menu bar is redrawn only when it changes. · 세션 목록 재구성을 초당 2회에서 1회로 줄였고, macOS에서는 메뉴 막대를 바뀔 때만 다시 그립니다.
- Faster first read of omp/Pi logs: tool results and side records are read from their first bytes, not decoded whole. · omp/Pi 로그 첫 읽기 가속: 도구 결과와 부가 기록을 통째로 해석하지 않고 앞부분만 읽습니다.
- Windows: one unreadable log no longer freezes every client's rows. · Windows: 읽을 수 없는 로그 하나가 모든 클라이언트 행을 멈추지 않습니다.

## 0.14.1

**macOS and Windows**

- A Codex subagent's measured speed now attaches to its own row and counts toward the Average speed; it used to be dropped and shown as a separate nameless measurement row. · Codex 하위 에이전트의 실측 속도가 이제 그 하위 에이전트 행에 붙고 평균 속도에도 들어갑니다. 전에는 빠지고 이름 없는 실측 행으로 따로 보였습니다.

## 0.14.0

**macOS and Windows**

- Other coding agents are now recognised automatically from their own data folders, with no setup: OpenCode, Gemini CLI, Qwen Code, Copilot CLI, Amp, Cline · Roo Code · Kilo Code, omp · Pi and Factory Droid show their sessions, turn state, model, project and output tokens next to Codex and Claude Code. OpenCode and omp record request durations, so their replies get a measured request tok/s and also feed the Average speed. · 다른 코딩 에이전트도 각자의 데이터 폴더로 자동 인식합니다. 설정은 필요 없습니다. OpenCode, Gemini CLI, Qwen Code, Copilot CLI, Amp, Cline·Roo Code·Kilo Code, omp·Pi, Factory Droid의 세션·턴 상태·모델·프로젝트·출력 토큰을 Codex·Claude Code와 함께 보여 줍니다. OpenCode와 omp는 요청 시간을 기록하므로 응답에 실측 요청 tok/s가 붙고 평균 속도에도 들어갑니다.
- The separate Codex speed and Claude speed items are gone; the **Average speed** item now shows which clients are contributing a fresh measured rate in place of `AVG`: one client's icon, or up to three icons overlapping like an avatar group (fastest first), named in its help (`Average speed 55.6 tokens per second · Codex, Claude Code`). Every client has its icon, and a Codex or Claude speed item you had turned on becomes the Average speed item. On one line the item is 81 pt wide (was 69) so `9999 tok/s` still fits beside three icons. · 따로 있던 Codex 속도·Claude 속도 항목을 없애고, **평균 속도** 항목이 `AVG` 자리에 지금 실측을 보태는 클라이언트를 보여 줍니다. 하나면 그 아이콘, 여럿이면 최대 세 개를 프로필 사진 묶음처럼 겹쳐(빠른 순) 그리고, 도움말에 이름을 붙입니다(`평균 속도 55.6 토큰/초 · Codex, Claude Code`). 모든 클라이언트에 아이콘이 있으며, 켜 두었던 Codex·Claude 속도 항목은 평균 속도 항목으로 바뀝니다. 한 줄에서는 폭이 81pt(이전 69pt)라 아이콘 세 개 옆에서도 `9999 tok/s`가 들어갑니다.

## 0.13.2

**macOS and Windows**

- The Codex and Claude speed items take less room: 56 pt on two lines and 69 pt on one (was 66 and 80), with the bar showing whole numbers from 100 tok/s up. · Codex·Claude 속도 항목의 폭을 줄였습니다(두 줄 56pt, 한 줄 69pt, 이전 66·80pt). 100 tok/s부터는 메뉴 막대에서 소수점 없이 표시합니다.
- New opt-in **Average speed** item (`AVG`): the mean tok/s of every session currently measured, across all clients, by the same freshness rule as **Speed now**; only measured rates are averaged, nothing is estimated. · 새 **평균 속도** 항목(`AVG`, 기본 꺼짐): **지금 속도**와 같은 규칙으로 지금 실측 중인 모든 클라이언트의 세션별 속도를 평균합니다. 실측값만 평균하며 추정하지 않습니다.

## 0.13.1

**macOS and Windows**

- The Codex and Claude speed items show the Codex and Claude app icons in their own colours instead of the generic `>_` and `✦` glyphs. · Codex·Claude 속도 항목이 일반 기호 `>_`·`✦` 대신 Codex·Claude 앱 아이콘을 원래 색 그대로 표시합니다.

## 0.13.0

**macOS and Windows**

- Settings › Menu Bar (Widget on Windows) can show Codex and Claude speed: a `>_` or `✦` glyph and that client's current speed in tok/s by the dashboard's Speed now rule, or `—` without a fresh measurement. Off by default. · 설정 › 메뉴 막대(Windows는 위젯)에서 Codex·Claude 속도 항목을 켤 수 있습니다. `>_`·`✦` 기호와 그 클라이언트의 현재 속도(tok/s)를 상세 화면의 지금 속도와 같은 규칙으로 보여 주고, 최근 실측이 없으면 `—`로 표시합니다. 기본은 꺼져 있습니다.

**Windows (preview)**

- Settings has a Widget tab like the Mac's Menu Bar tab: pick a preset and layout, turn items on or off, and reorder them by dragging, Alt+↑/↓ or right-click. The quick menu gains Layout too. · 설정에 Mac의 메뉴 막대 탭과 같은 위젯 탭이 생겼습니다. 프리셋과 표시 방식을 고르고, 항목을 켜고 끄며, 끌거나 Alt+↑·↓, 우클릭으로 순서를 바꿉니다. 빠른 메뉴에도 표시 방식이 생겼습니다.
- Show character in widget on the Character tab (or Character › Show in Widget in the quick menu) hides the character in the widget; the tray icon always shows it. · 캐릭터 탭의 위젯에 캐릭터 표시(빠른 메뉴의 캐릭터 › 위젯에 표시)로 위젯에서 캐릭터를 숨길 수 있습니다. 알림 영역 아이콘에는 항상 표시됩니다.
- The widget can be 100 to 300 % in size: set it in Settings › Widget, with Widget Size in the right-click menu, or with Ctrl + mouse wheel over the widget. · 위젯 크기를 100–300 % 사이에서 고를 수 있습니다. 설정 › 위젯, 우클릭 메뉴의 위젯 크기, 위젯 위에서 Ctrl+마우스 휠로 바꿉니다.
- When the widget grows or shrinks (size, layout, items or display scale), it keeps its nearest screen edges in place and returns to the same spot after a restart. · 크기·표시 방식·항목·디스플레이 배율이 바뀌어 위젯이 커지거나 작아져도 가까운 화면 가장자리를 기준으로 자리를 지키고, 다시 실행해도 같은 자리로 돌아옵니다.
- Restore Defaults also resets the widget's layout, items, size and Show character in widget; showing the widget and its position stay as they are. · 기본값으로 되돌리기가 위젯의 표시 방식·항목·크기와 위젯에 캐릭터 표시도 되돌립니다. 위젯 표시 여부와 위치는 그대로입니다.
- The widget starts on two lines like the Mac menu bar; if you never changed its layout, it switches to two lines after this update. · 위젯이 Mac 메뉴 막대처럼 두 줄 배치로 시작합니다. 배치를 바꾼 적이 없다면 이번 업데이트 뒤 두 줄로 바뀝니다.
- Drag the dashboard by its header or an empty spot to detach it into a window you can move, like dragging the Mac popover into a panel; the window remembers its place and height. · 상세 화면의 머리글이나 빈 곳을 잡고 끌면 Mac에서 팝오버를 끌어 패널로 분리하듯 옮길 수 있는 창으로 분리되고, 창은 위치와 높이를 기억합니다.

## 0.12.0

**macOS and Windows**

- Live usage limits (on by default, Settings › Telemetry) check the Codex and Claude limits with OpenAI and Anthropic using Codex and Claude Code's saved sign-in, every minute while in use and every 10 minutes otherwise, show fresh values as `live`, and keep the Claude token in memory only, never storing, logging or refreshing it. · 실시간 한도 확인(기본 켜짐, 설정 › 실측)이 Codex·Claude Code에 저장된 로그인으로 OpenAI·Anthropic에 사용 중에는 1분, 평소에는 10분마다 Codex·Claude 한도를 확인해 새 값을 `실시간`으로 보이며, Claude 토큰은 메모리에만 두고 저장·기록·갱신하지 않습니다.
- The collector rejects requests whose Host isn't `127.0.0.1` or `localhost`, so a web page using DNS rebinding can't read the readings. · 수집기가 Host가 `127.0.0.1`·`localhost`가 아닌 요청을 거부해, DNS 리바인딩을 쓰는 웹페이지가 실측 값을 읽지 못합니다.
- Up to 256 recent logs stay tracked, so many subagents no longer make sessions flicker or get re-read. · 최근 로그를 256개까지 계속 추적해, 하위 에이전트가 많아도 세션이 깜빡이거나 다시 읽히지 않습니다.
- The restart notice reads "Restart Codex and Claude Code for speed", and the Korean text calls the dashboard 상세 화면 everywhere, captions MCP tools as MCP 도구 실행 and fixes the particle in "HTTP 500 오류로". · 재시작 안내가 'Codex·Claude Code 재시작 후 속도 표시'로 바뀌고, 한국어 문구는 대시보드를 어디서나 상세 화면으로 부르며, MCP 도구 캡션을 'MCP 도구 실행'으로, 'HTTP 500 오류로'의 조사를 바로잡았습니다.

**macOS**

- The ⋯ menu in the dashboard header uses the same secondary tone as the gear. · 상세 화면 헤더의 ⋯ 메뉴가 톱니와 같은 보조 색을 씁니다.

**Windows (preview)**

- A widget on screen shows what the Mac menu bar shows, since the taskbar can't show text: the character, the AI status and session count, or the Two Lines and One Line layouts picked by preset in Settings › General. · 작업 표시줄에는 글자를 넣을 수 없어, Mac 메뉴 막대처럼 캐릭터와 AI 상태·세션 수를 보여 주는 위젯을 화면 위에 띄웁니다. 설정 › 일반의 프리셋으로 두 줄·한 줄 배치도 고를 수 있습니다.
- Drag the widget anywhere: it snaps to screen edges, remembers its place for each monitor setup, never takes the focus and hides while a full-screen app is in front. Click opens the dashboard, right-click the quick menu. · 위젯은 끌어서 아무 곳에나 둘 수 있습니다. 화면 가장자리에 붙고, 모니터 구성마다 위치를 기억하며, 포커스를 가져가지 않고, 전체 화면 앱이 앞에 있는 동안에는 숨습니다. 클릭하면 상세 화면이, 우클릭하면 빠른 메뉴가 열립니다.
- To hide it, choose Hide Widget from its right-click or tray menu, or turn off Show widget on screen in Settings › General. · 숨기려면 위젯이나 알림 영역 아이콘의 우클릭 메뉴에서 위젯 숨기기를 누르거나, 설정 › 일반에서 화면에 위젯 표시를 끕니다.
- Divider lines and card borders one pixel thin no longer vanish at 100 % scaling. · 100 % 배율에서 1픽셀 두께의 구분선과 카드 테두리가 사라지지 않습니다.
- The waiting status in Settings › Telemetry is drawn as an outline ring. · 설정 › 실측의 대기 상태를 빈 고리로 그립니다.
- `TokenCat.exe` has crisp 16 and 32 px icons. · `TokenCat.exe`의 16·32 px 아이콘이 선명합니다.
- Pressing Alt+F4 on the dashboard hides it instead of making the next open crash. · 상세 화면에서 Alt+F4를 누르면 숨기며, 다음에 열 때 종료되지 않습니다.
- Titles and captions in the output card share a baseline. · 출력 카드의 제목과 캡션 기준선이 맞습니다.

**Docs**

- The README has macOS and Windows download buttons at the top and clearer first-launch and Windows install steps. · README 맨 위에 macOS·Windows 내려받기 버튼을 두고, 처음 열 때와 Windows 설치 순서를 더 알기 쉽게 고쳤습니다.

## 0.11.2

**macOS**

- The Codex limit row no longer hides a nearly used-up 5-hour window behind an older session's weekly one (Windows too). · Codex 한도 행이 거의 다 쓴 5시간 창을 오래된 세션의 주간 창 뒤에 숨기지 않습니다(Windows도 같음).
- A notification for a plan waiting for approval says so, like the dashboard (Windows too). · 계획 승인 대기 알림이 상세 화면처럼 계획 승인 대기라고 알립니다(Windows도 같음).
- The cat no longer plays its content motion when a turn is interrupted or ends in an API error, a 429 limit included (Windows too). · 턴이 중단되거나 API 오류(429 한도 포함)로 끝나면 캐릭터가 만족 동작을 하지 않습니다(Windows도 같음).
- Setting the clock back no longer pauses token sampling or ignores clicks on the menu bar icon (the tray icon on Windows too). · 시계를 뒤로 돌려도 토큰 샘플링이 멈추거나 메뉴 막대 아이콘 클릭이 무시되지 않습니다(Windows 알림 영역 아이콘도 같음).
- A `settings.json` with duplicate keys is left unchanged instead of losing the env that's in use (on Windows it no longer fails or quits at launch). · 키가 중복된 `settings.json`은 쓰이는 env를 지우지 않고 그대로 둡니다(Windows는 실패하거나 시작 중 종료되지 않음).
- A record stamped in the future or a clock set back no longer freezes Claude sessions or shows a running Codex turn as stale (Windows too). · 미래 시각 기록이나 시계 역행 뒤에도 Claude 세션이 멈추거나 진행 중인 Codex 턴이 오래된 것으로 보이지 않습니다(Windows도 같음).
- Active subagents past the first 64 no longer trigger a full rescan on every write (Windows too). · 64개를 넘는 활성 하위 에이전트가 기록할 때마다 전체를 다시 찾지 않습니다(Windows도 같음).
- Prompts up to 1 MiB start a turn, after a relaunch too (Windows too). · 1 MiB까지의 프롬프트는 다시 실행한 뒤에도 턴 시작으로 잡습니다(Windows도 같음).
- With an update notice and the restart prompt together, the English dashboard no longer clips at both sides (Windows too). · 업데이트 알림과 재시작 안내가 함께 떠도 영어 상세 화면 좌우가 잘리지 않습니다(Windows도 같음).
- The selected session row has an accent outline, and VoiceOver reads the session picked with ↑↓ (Windows and Narrator too). · 선택한 세션 행에 강조색 테두리가 생기고, ↑↓로 고른 세션을 VoiceOver가 읽습니다(Windows와 내레이터도 같음).
- With full keyboard access, the copy button in row details shows focus and the "more" rows leave the Tab order (↑↓ and Return reach them); VO-Space opens a Measurement row. · 전체 키보드 접근에서 행 상세의 복사 버튼에 포커스가 보이고 '더 보기' 행은 Tab 순서에서 빠지며(↑↓와 Return으로 갑니다), VO-Space로 실측 행을 엽니다.

**Windows (preview)**

- Narrator reads session, limit and meter rows, the on/off state of Settings switches, character and motion choices by name with the selected one, and text buttons by their visible label. · 내레이터가 세션·한도·미터 행, 설정 스위치의 켜짐/꺼짐, 캐릭터·움직임 선택지의 이름과 선택 상태, 텍스트 버튼의 보이는 글자를 읽습니다.
- Open TokenCat at login says to quit before moving the app, and a moved `TokenCat.exe` is no longer registered and shown as on. · 로그인 시 TokenCat 열기 안내가 앱을 옮기기 전에 종료하라고 알려 주고, 옮겨진 `TokenCat.exe`를 등록하거나 켜짐으로 보이지 않습니다.
- The English tray tooltip keeps the AI line with Input needed within its 127-character limit. · 영어 알림 영역 툴팁이 127자 제한 안에서 입력 필요가 있는 AI 줄을 남깁니다.
- Double-clicking the tray icon opens the flyout instead of closing it at once. · 알림 영역 아이콘을 더블클릭하면 플라이아웃이 바로 닫히지 않고 열립니다.
- The tray and flyout menus follow a light/dark switch while running. · 실행 중 라이트/다크를 바꾸면 알림 영역 메뉴와 플라이아웃 메뉴도 따라 바뀝니다.
- Open, a notification, a second launch and Show Welcome Again open the flyout at the taskbar's corner. · 열기·알림·두 번째 실행·처음 안내 다시 보기가 플라이아웃을 작업 표시줄 쪽 모서리에 엽니다.
- A time zone change updates Today, Yesterday and times without a restart, records nested deeper than 64 levels are read as on macOS, and the footer's update item no longer overlaps a status that grows later. · 시간대를 바꾸면 다시 실행하지 않아도 오늘·어제와 시각이 바뀌고, 64단보다 깊이 중첩된 기록도 macOS처럼 읽으며, 하단 업데이트 항목이 나중에 길어진 상태 글자와 겹치지 않습니다.

**CI**

- Pushes and pull requests that touch the Swift code build the Mac app and run its checks, and a release also waits for both platforms' telemetry lifecycle checks and the Windows snapshots. · Swift 코드를 바꾸는 푸시와 PR마다 Mac 앱을 빌드해 검사하고, 릴리스는 두 플랫폼의 실측 수명 주기 검사와 Windows 스냅숏까지 통과해야 게시됩니다.

## 0.11.1

**macOS**

- The session list no longer fills up with unnamed telemetry-only rows (Windows too). · 세션 목록이 이름 없는 실측 전용 행으로 채워지지 않습니다(Windows도 같음).
- When space is short, Speed now keeps the session name, so it no longer reads as a combined speed (Windows too). · 자리가 좁아도 지금 속도에 세션 이름이 남아 여러 세션을 합친 속도처럼 읽히지 않습니다(Windows도 같음).
- The disconnect command in Settings shows the app's actual path. · 설정의 실측 해제 명령이 앱의 실제 경로를 보여 줍니다.
- The menu bar tooltip and VoiceOver count working sessions the way the dashboard header does (Windows too). · 메뉴 막대 툴팁과 VoiceOver의 진행 수가 상세 화면 헤더와 같습니다(Windows도 같음).
- Critical memory pressure has its own icon, not only its own color. · 메모리 압력 위험을 색뿐 아니라 아이콘으로도 구분합니다.
- The restart prompt at the bottom names the client to restart (Windows too). · 하단 재시작 안내가 다시 실행할 클라이언트를 알려 줍니다(Windows도 같음).
- Reading logs uses less CPU. · 로그 읽기의 CPU 사용이 줄었습니다.
- After a relaunch, subagents from the last hour are no longer missing (Windows too). · 다시 실행한 뒤에도 최근 1시간의 하위 에이전트가 빠지지 않습니다(Windows도 같음).

**Windows (preview)**

- Row text is no longer clipped at the bottom (a thousands comma looked like a period), mixed text sizes share a baseline, and Korean wraps between words. · 행 글자 아래가 잘려 천 단위 쉼표가 마침표처럼 보이던 문제, 크기가 다른 글자의 기준선, 단어 중간의 한국어 줄바꿈을 고쳤습니다.
- The dashboard scrolls when it's taller than the screen, and the system meters, the CPU peak mark and the tray dots at 200 % are sized and placed correctly. · 화면보다 긴 상세 화면은 스크롤되고, 시스템 미터·CPU 최고 표시·200 % 알림 영역 점의 크기와 위치를 바로잡았습니다.
- Settings no longer lose keyboard focus and clicks every second, keyboard focus shows in dark mode, and the Apps key or Shift+F10 opens a session row's menu. · 설정에서 키보드 포커스와 클릭이 매초 사라지지 않고, 다크 모드에서 키보드 포커스가 보이며, Apps 키나 Shift+F10으로 세션 행 메뉴를 엽니다.
- A `settings.json` that can't be written no longer quits the app. · `settings.json`을 쓸 수 없어도 앱이 종료되지 않습니다.
- The tray icon, a second launch, a notification or Open brings back a minimized dashboard window. · 알림 영역 아이콘, 두 번째 실행, 알림, 열기로 최소화한 대시보드 창을 다시 띄웁니다.
- Open TokenCat at login shows off when the startup entry points to another copy of `TokenCat.exe`. · 시작 프로그램 항목이 다른 `TokenCat.exe`를 가리키면 로그인 시 TokenCat 열기가 꺼짐으로 보입니다.
- The first-launch card no longer says it wrapped the Claude Code status line. · 처음 실행 카드가 Claude Code 상태 표시줄을 감쌌다고 말하지 않습니다.

**Docs**

- Windows install: extract the whole zip, `LICENSE` included; the PowerShell command creates the folder. The notes no longer promise Windows on Arm. · Windows 설치: `LICENSE`까지 zip 전체를 풀고, PowerShell 명령이 폴더를 만듭니다. 릴리스 노트에서 Arm용 Windows 문구를 지웠습니다.

## 0.11.0

- Windows preview: TokenCat also runs in the Windows 10 and 11 (x64) notification area, as `TokenCat-Windows.zip` on the same release. · Windows 미리보기: Windows 10·11(x64) 알림 영역에서도 실행되며, 같은 릴리스에 `TokenCat-Windows.zip`으로 올립니다.
- macOS: same as 0.10.1 (version number only). · macOS: 0.10.1과 같습니다(버전 번호만 변경).
