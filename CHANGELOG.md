# Changelog · 변경 기록

The release workflow puts the `## <version>` entry into that version's release notes. · 릴리스 워크플로가 `## <버전>` 항목을 그 버전의 릴리스 노트에 넣습니다.

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
