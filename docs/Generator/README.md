# README 미리보기 생성기

`docs/images/`의 미리보기 이미지를 만드는 Swift 코드입니다. 글자가 들어간 이미지는 한국어·영어로 각각 만들어 `docs/images/ko/`·`docs/images/en/`에 두고, 글자 없는 이미지는 `docs/images/`에 둡니다. 앱의 합성 스냅숏만 써서 이 Mac의 로그·프로젝트·경로·IP가 들어가지 않습니다. CoreGraphics·CoreText·ImageIO만 쓰고 외부 도구와 네트워크는 쓰지 않습니다.

## 명령 (저장소 루트)

```sh
./build.sh
mkdir -p work && swiftc -O docs/Generator/*.swift -o work/docs-generator && work/docs-generator
```

- `--app <TokenCat.app 또는 실행 파일>`: 기본 `dist/TokenCat.app`
- `--out <폴더>`: 기본 `docs/images`(언어별 이미지는 그 아래 `ko/`·`en/`)
- 언어 옵션은 없습니다. 한 번 실행에 한국어와 영어를 모두 만들고, 앱 스냅숏마다 `--language ko|en`을 붙여 이 Mac의 언어와 상관없이 같은 결과를 냅니다.

macOS 27.0.1·Swift 6.4에서 두 번 실행해 모든 파일의 SHA-256이 같음을 확인했습니다. OS나 글꼴 버전이 다르면 바이트가 달라질 수 있습니다.

## 입력

| 입력 | 쓰는 곳 |
|---|---|
| `--snapshot-fixtures` (상태마다 다크 \| 라이트) | 히어로 팝오버, `popover-*` |
| `--snapshot-menubar --fixtures` (두 줄·`--inline`·`--minimal`) | 히어로 메뉴 막대 항목, `menubar-*`, `architecture` |
| `--snapshot-settings --pane general\|menubar\|cat\|telemetry\|about --fixtures [--light]` (`cat`은 캐릭터 탭) | 히어로 창(캐릭터 탭), `settings-*` |
| `Assets/runner-v2@1x.png`, `runner-v2-fx@1x.png`, `runner-v2.json` | `cat-*.gif`, `poses-*`, `characters-*` |
| `Assets/runner-{dog,hamster,penguin,robot}@1x.png` | `characters-*` |
| `Assets/app-icon-v2-1024.png`, `-32.png`, `-16.png` | `app-icon-*`, `icon.png`, `architecture` |

- 스냅숏은 임시 폴더에 만들고 끝나면(실패해도) 지웁니다. 실데이터를 읽는 `--snapshot`(픽스처 없음)과 `--diagnose`는 쓰지 않습니다.
- 자를 위치는 좌표를 고정하지 않고 스냅숏에서 찾습니다. 다크·라이트 경계, 양쪽 끝까지 이어진 카드 띠, 회색 바탕 위 메뉴 막대 칸(11행 × 4열)을 찾으며, 구조가 다르면 멈춥니다. 메뉴 막대 칸은 행마다 폭이 달라(평균 속도 행이 더 넓음) 열 시작은 첫 행에서, 끝은 행마다 찾습니다.

## 출력

- `ko/`·`en/`에 같은 이름으로 다크·라이트 한 쌍: `hero`, `popover-flow`·`-sessions`·`-subagents`·`-detail`·`-limits`·`-empty`·`-onboarding`, `menubar-layouts`, `menubar-states`, `architecture`(데이터 흐름도), `settings`, `poses`(밝은 막대와 어두운 막대에서 일곱 자세), `characters`(다섯 캐릭터의 앉기·걷기·정면 앉기·잠 정지 프레임), `cat`(GIF, 자세 이름과 상태 칩)
- `docs/images/` 언어 공용: `app-icon`(다크·라이트, 라벨은 숫자와 `×`뿐), `icon.png`(README 머리의 256 px 앱 아이콘, 바깥은 투명)
- PNG는 2배 해상도(144 dpi)이고 바깥 모서리는 투명하게 둥글립니다. GIF도 같은 반지름으로 둥글리되, GIF는 반투명을 못 쓰므로 모서리를 앤티에일리어싱 없이 잘라 바깥을 투명 색으로 둡니다. README에서는 표시 폭을 픽셀의 절반으로 지정합니다.

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/en/hero-dark.png">
  <img src="docs/images/en/hero-light.png" width="800" alt="…">
</picture>
```

## 정한 것

- 생성기가 직접 그리는 글자(장면 제목·범례·자세 이름·흐름도 카드·히어로 시계)는 앱처럼 `loc(한국어, 영어)`로 고릅니다. 글꼴도 그 언어의 시스템 글꼴을 씁니다. 시계는 `10월 5일 (월) 오전 9:41` / `Mon Oct 5  9:41 AM`입니다. 메뉴 막대 매트릭스의 `stateNames`는 한국어 행 이름을 열쇠로만 쓰고 그리지 않습니다.
- 영어 문구는 한국어 배치에 맞춰 짧게 골랐습니다. 배치 수치는 두 언어가 같습니다.

- 배경은 차분한 인디고·슬레이트 그라디언트이고, 제공사 브랜드 색과 로고는 쓰지 않습니다. 그라디언트는 픽셀마다 직접 계산합니다. CoreGraphics 그라디언트는 디더링 때문에 PNG가 약 6배 커졌습니다.
- 히어로 팝오버는 `input-needed` 픽스처 전체(한도 카드의 Codex·Claude 세 줄, 지금 속도 포함)입니다. 진행·입력 대기 세션에는 지어낸 세션 제목(`Rate limiter`·`Settings cleanup`·`Install guide`)이 있고 쉬는 행 하나는 제목 없이 프로젝트로 보이며, Claude 두 창은 omp가 1분 전 기록한 값입니다. 캔버스는 폭 1600 px에 높이 최소 1080 px이고, 팝오버가 길면 아래 여백 64 px을 두고 늘어납니다.
- 출력 흐름 이미지는 `input-needed`의 위쪽(헤더, 한도 카드, 출력 카드)이고, 세션 목록 이미지는 한도 카드가 있는 픽스처라 셋째 카드를 자릅니다.
- 히어로의 메뉴 막대 항목은 최소 표시(열림 상태, `입력 필요`)를 씁니다. 메뉴 막대 픽스처와 팝오버 픽스처의 시스템 값이 서로 달라서, 두 줄 표시를 쓰면 한 화면에 다른 CPU·배터리 값이 보이기 때문입니다. 배터리 글리프는 팝오버 값(58%)에 맞췄습니다.
- 세션 목록 이미지는 `context-limit` 픽스처를 씁니다. 실측 `요청 tok/s`가 Claude Code 행에 붙고 Codex 행은 `— tok/s`인 화면이며, 세 행에 제목이 있고 로그 대기 행은 제목 없이 프로젝트로 보입니다.
- 작동 방식 그림은 Mermaid 대신 이미지로 그립니다. GitHub의 Mermaid 틀은 높이가 고정돼 가로로 긴 흐름도의 아래쪽 노드를 잘랐습니다. 왼쪽 묶음은 모든 코딩 에이전트의 로컬 기록·DB, 수집기 카드(OTLP 실측과 Claude Code 상태 표시줄 브리지), 그 밖의 사용 한도 경로(codex app-server, Anthropic 실시간 확인, Claude 데스크톱 기록, omp·Pi `agent.db`) 세 카드입니다. 업데이트 확인은 수집 경로가 아니라서 그리지 않습니다.
- `menubar-layouts`는 메뉴 막대 매트릭스의 `속도 · 4개` 행(네 클라이언트 실측, 평균 속도 항목이 아이콘 셋을 나란히 그림)을 씁니다.
- `popover-limits`는 `usage-limits` 부품 시트 전체(Codex 일곱 상태로 마지막은 omp 기록, Claude 네 상태이며 Claude는 초기화 전인 두 창을 두 줄로)입니다.
- 설정 묶음은 다섯 탭을 탭 순서대로 두 열(일반 + 메뉴 막대 | 캐릭터 + 실측 + 정보)에 놓고, 두 열의 위·아래 끝을 맞추도록 짧은 열의 창 간격을 넓힙니다. 0.9.0에서 정보 탭에 업데이트 섹션이 생겨 네 탭만으로는 두 열 높이가 약 360 px 어긋났고, 이 배치가 가장 고릅니다(약 150 px). 실측 탭 픽스처는 다른 앱이 16493 포트를 쓰는 예시를 보여 줍니다.
- 캐릭터 그림은 다섯 캐릭터(고양이·강아지·햄스터·펭귄·로봇, 앱의 이름)를 열로, 앉기·걷기·정면 앉기·잠을 행으로 두고 각 자세의 1번 프레임(정지 프레임)을 6배로 그립니다. 잠은 앱의 정지 상태처럼 큰 z(zL)를 함께 그립니다. 칸 배경은 그 테마의 메뉴 막대 색이고, 자세 이름 칸은 230 px로 고정해 두 언어의 배치가 같습니다. 캐릭터 시트는 앱처럼 고양이만 매니페스트의 시트를, 나머지는 `runner-<id>@1x.png`를 씁니다.
- 잠의 z 색은 메뉴 막대 픽스처에서 읽은 값(밝은 막대 `#434343`, 어두운 막대 `#C1C1C1`, 앱의 `labelColor` 72%)입니다.
- 고양이 GIF의 프레임 시간은 매니페스트를 따릅니다(걷기 0.15초, 달리기 0.0714초, 정면 앉기 2.4·0.3초, 깜빡임 0.12초와 두 번 깜빡임 간격 0.15초, 잠 단계 1.6초, 하품 0.6초). 달리기는 앱의 출력 직후 달리기와 같은 1.2초(17프레임, 약 1.21초)이고, 앉기의 긴 유지 시간(6–11초)만 1.4초 안팎으로 줄였습니다. 한 바퀴는 약 15.6초입니다. GIF 지연은 1/100초 단위라 누적 시각으로 반올림해 오차가 쌓이지 않게 합니다. 움직임은 상태를 나타낼 뿐 속도가 아닙니다. ImageIO는 투명 픽셀이 있는 프레임을 차이 영역 없이 통째로 저장하므로 GIF는 한 장에 약 390 KB입니다.
