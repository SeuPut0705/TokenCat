# Changelog · 변경 기록

The release workflow puts the `## <version>` entry into that version's release notes. · 릴리스 워크플로가 `## <버전>` 항목을 그 버전의 릴리스 노트에 넣습니다.

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
