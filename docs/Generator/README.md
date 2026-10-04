# README 미리보기 생성기

`docs/images/`의 미리보기 이미지를 만드는 Swift 코드입니다. 앱의 합성 스냅숏만 써서 이 Mac의 로그·프로젝트·경로·IP가 들어가지 않습니다. CoreGraphics·CoreText·ImageIO만 쓰고 외부 도구와 네트워크는 쓰지 않습니다.

## 명령 (저장소 루트)

```sh
./build.sh
mkdir -p work && swiftc -O docs/Generator/*.swift -o work/docs-generator && work/docs-generator
```

- `--app <TokenCat.app 또는 실행 파일>`: 기본 `dist/TokenCat.app`
- `--out <폴더>`: 기본 `docs/images`

macOS 27.0.1·Swift 6.4에서 두 번 실행해 모든 파일의 SHA-256이 같음을 확인했습니다. OS나 글꼴 버전이 다르면 바이트가 달라질 수 있습니다.

## 입력

| 입력 | 쓰는 곳 |
|---|---|
| `--snapshot-fixtures` (상태마다 다크 \| 라이트) | 히어로 팝오버, `popover-*` |
| `--snapshot-menubar --fixtures` (두 줄·`--inline`·`--minimal`) | 히어로 메뉴 막대 항목, `menubar-*`, `architecture` |
| `--snapshot-settings --pane general\|menubar\|cat\|about --fixtures [--light]` | 히어로 창, `settings-*` |
| `Assets/runner-v2@1x.png`, `runner-v2-fx@1x.png`, `runner-v2.json` | `cat-*.gif`, `poses-*` |
| `Assets/app-icon-v2-1024.png`, `-32.png`, `-16.png` | `app-icon-*`, `icon.png`, `architecture` |

- 스냅숏은 임시 폴더에 만들고 끝나면(실패해도) 지웁니다. 실데이터를 읽는 `--snapshot`(픽스처 없음)과 `--diagnose`는 쓰지 않습니다.
- 자를 위치는 좌표를 고정하지 않고 스냅숏에서 찾습니다. 다크·라이트 경계, 양쪽 끝까지 이어진 카드 띠, 회색 바탕 위 메뉴 막대 칸(7행 × 4열)을 찾으며, 구조가 다르면 멈춥니다.

## 출력

- 다크·라이트 한 쌍: `hero`, `popover-flow`·`-sessions`·`-subagents`·`-detail`·`-limits`·`-empty`·`-onboarding`, `menubar-layouts`, `menubar-states`, `architecture`(데이터 흐름도), `settings`, `poses`(밝은 막대와 어두운 막대에서 일곱 자세), `app-icon`, `cat`(GIF)
- 테마 공용: `icon.png`(README 머리의 256 px 앱 아이콘, 바깥은 투명)
- PNG는 2배 해상도(144 dpi)이고 바깥 모서리는 투명하게 둥글립니다. GIF도 같은 반지름으로 둥글리되, GIF는 반투명을 못 쓰므로 모서리를 앤티에일리어싱 없이 잘라 바깥을 투명 색으로 둡니다. README에서는 표시 폭을 픽셀의 절반으로 지정합니다.

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
  <img src="docs/images/hero-light.png" width="800" alt="…">
</picture>
```

## 정한 것

- 배경은 차분한 인디고·슬레이트 그라디언트이고, 제공사 브랜드 색과 로고는 쓰지 않습니다. 그라디언트는 픽셀마다 직접 계산합니다. CoreGraphics 그라디언트는 디더링 때문에 PNG가 약 6배 커졌습니다.
- 히어로의 메뉴 막대 항목은 최소 표시(열림 상태, `입력 필요`)를 씁니다. 메뉴 막대 픽스처와 팝오버 픽스처의 시스템 값이 서로 달라서, 두 줄 표시를 쓰면 한 화면에 다른 CPU·배터리 값이 보이기 때문입니다. 배터리 글리프는 팝오버 값(58%)에 맞췄습니다.
- 세션 목록 이미지는 `context-limit` 픽스처를 씁니다. 실측 `요청 tok/s`는 Claude Code에서만 오므로 그 단위가 Claude Code 행에 붙은 화면을 골랐습니다(`retry` 픽스처는 Codex 행에 `요청 tok/s`가 있어 쓰지 않았습니다).
- 작동 방식 그림은 Mermaid 대신 이미지로 그립니다. GitHub의 Mermaid 틀은 높이가 고정돼 가로로 긴 흐름도의 아래쪽 노드를 잘랐습니다.
- 설정 묶음은 높이가 맞는 네 탭(일반 + 고양이 | 메뉴 막대 + 정보)만 쓰고, 두 열의 위·아래 끝을 맞추도록 짧은 열의 창 간격을 넓힙니다. 실측 탭 픽스처는 포트 충돌 예시를 보여 주는 상태 화면이라 소개용 이미지에서는 뺐습니다.
- 고양이 GIF의 프레임 시간은 매니페스트를 따릅니다(걷기 0.15초, 달리기 0.0714초, 정면 앉기 2.4·0.3초, 깜빡임 0.12초와 두 번 깜빡임 간격 0.15초, 잠 단계 1.6초, 하품 0.6초). 달리기는 앱의 출력 직후 달리기와 같은 1.2초(17프레임, 약 1.21초)이고, 앉기의 긴 유지 시간(6–11초)만 1.4초 안팎으로 줄였습니다. 한 바퀴는 약 15.6초입니다. GIF 지연은 1/100초 단위라 누적 시각으로 반올림해 오차가 쌓이지 않게 합니다. 움직임은 상태를 나타낼 뿐 속도가 아닙니다. ImageIO는 투명 픽셀이 있는 프레임을 차이 영역 없이 통째로 저장하므로 GIF는 한 장에 약 390 KB입니다.
