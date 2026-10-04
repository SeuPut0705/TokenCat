# TokenCat 앱 아이콘 v2

- 생성 방식: 타일·16 · 32 px 머리·합성은 `Assets/Generator/IconArt.swift`가 결정적으로 그린다. 이 v2 합성 단계는 이미지 생성 서비스·네트워크를 쓰지 않는다. 가운데 마크는 기존 `app-mark-v1.png`(내장 image_gen 원본, `app-mark-v1.prompt.md`)를 그대로 쓴다.
- 도구: Swift 6.4 `swiftc`, CoreGraphics(타일·그라디언트), ImageIO(PNG 읽기·쓰기). 앱 번들의 `.iconset`과 `.icns`는 `build.sh`가 `sips`와 `iconutil`로 만든다.
- 명령(저장소 루트):

  ```sh
  mkdir -p work && swiftc -O Assets/Generator/*.swift -o work/asset-generator && work/asset-generator icon
  ./build.sh && work/asset-generator previews system   # work/app-icon-v2-preview.png, work/app-icon-v2-system-small.png
  ```

  아래 bytes·SHA-256은 macOS 27.0.1·Swift 6.4에서 두 번 생성해 같음을 확인한 값이다. 타일은 CoreGraphics 안티앨리어싱을, 파일은 ImageIO PNG 인코더를 거치므로 다른 OS에서는 아이콘 바이트(타일 가장자리 픽셀 포함)가 달라질 수 있다.
- 입력: `Assets/app-mark-v1.png`(SHA-256 `4350d73557050070da2caf589a3b18a6ebcb1e74bc223dc3c2d9ba6a10e20538`). 마크 파일은 수정하지 않으며 앱 안 브랜드 마크로 계속 쓴다.

## 구성

- 1024 캔버스에 824 타일(여백 100 px). 타일은 연속 곡률 슈퍼타원(n = 5)으로, 대각선 지점이 반지름 185 px 둥근 사각형과 맞는다.
- 배경: 왼쪽 위 `#5361D6`(차분한 인디고 코발트) → `#3B4787` → 오른쪽 아래 `#283246`(슬레이트) 선형 그라디언트. 위쪽 흰색 18% 광원, 안쪽 테두리는 위가 밝고 아래가 어두움. 타일 밖은 완전 투명(바깥 그림자 없음).
- 제공사 브랜드 팔레트(검정·흰색만, 클레이·크림)를 쓰지 않는다.
- 고양이: app-mark-v1을 알파 경계로 잘라 타일 폭의 68%로 축소해 중앙보다 8 px 아래에 둠. 부드러운 접지 그림자(아래 14 px, 흐림 30, 남색 43%).
- 16 · 32 px: 손으로 그린 픽셀 머리. 줄무늬·수염 없음, 큰 눈, 목걸이 유지.
  - 16 px: 10 × 10 머리, 1 px 외곽선, 2 × 2 눈, 4 px 목걸이.
  - 32 px: 20 × 20 머리, 2 px 외곽선, 4 × 4 눈(맨 아래 줄은 가운데 2 px로 둥글림), 귀 안쪽, 2 px 코, 목걸이 태그. 하이라이트는 각 눈의 왼쪽 위 모서리에서 대각선으로 한 칸 안쪽에 둔 1 px로, 두 눈이 같은 위치다(같은 광원). 눈 모서리에 두면 털과 같은 색이라 모서리를 깎은 것처럼 보였다.
  - 타일은 여백 없이 꽉 채운다. macOS 27에서 16·32 px 이미지에 1024 기준 비례 여백을 두면 회색 판 안에 갇혀 표시되었고, 꽉 채운 타일은 시스템이 마스크와 그림자를 입혀 큰 크기와 같은 모양으로 보여 주었다.

## 결정: macOS 13–15의 16 · 32 px은 알려진 절충

- `.icns` 하나를 모든 OS가 쓰므로 16 · 32 px 여백은 한쪽에만 맞출 수 있다. macOS 26 이상(이 Mac의 macOS 27에서 확인)에 맞춰 꽉 채운 타일을 유지한다.
- macOS 13–15는 작은 크기에 마스크를 씌우지 않으므로 Finder 목록·Spotlight·로그인 항목에서 16 · 32 px 아이콘이 다른 앱의 약 13 px 타일보다 약 23% 크고 그림자 없는 사각형으로 보일 가능성이 높다. 13–15 실기기에서는 확인하지 않았다. 64 px 이상은 1024 기준 여백을 그대로 쓰므로 영향이 없다.
- Icon Composer `.icon` → `actool` Assets.car(`CFBundleIconName`, 26 이상) + 여백 있는 `.icns`(13–15) 경로는 택하지 않았다. 빌드에 Xcode 26 이상의 `actool`이 필요해지거나 컴파일된 Assets.car 바이너리를 저장소에 둬야 하고, `.icon`은 작은 크기를 레이어에서 시스템이 그리므로 손으로 다듬은 16 · 32 px 픽셀 머리를 26 이상에서 쓸 수 없으며, 13–15 결과도 이 Mac에서 확인할 수 없다. 13–15 사용자의 표시 문제가 보고되면 이 경로로 전환한다(이 Mac에는 Xcode 27 `actool`과 Icon Composer가 있어 시험 가능).

## iconset 매핑 (`build.sh`)

| iconset 파일 | 원본 |
|---|---|
| `icon_16x16.png` | `app-icon-v2-16.png` |
| `icon_16x16@2x.png`, `icon_32x32.png` | `app-icon-v2-32.png` |
| `icon_32x32@2x.png`(64) ~ `icon_512x512.png`(512) | `app-icon-v2-1024.png`을 `sips -z`로 축소 |
| `icon_512x512@2x.png` | `app-icon-v2-1024.png` 그대로 |

## 측정값

| 파일 | 크기 | 완전 투명 | 완전 불투명 | 부분 알파 | 네 모서리 알파 | bytes | SHA-256 |
|---|---|---|---|---|---|---|---|
| `app-icon-v2-1024.png` | 1024 × 1024 | 402340 (38.37%) | 643512 | 2724 | 0 | 793543 | `5b6b7a36c6083a4dee73f6aa421052faafc0ab080f4d542f71693ee67b6637db` |
| `app-icon-v2-32.png` | 32 × 32 | 24 (2.34%) | 908 | 92 | 0 | 1886 | `c3d415166e2e2a9292d7a24d7161e1dbd28bf23970f000d46a0cc381afa44a6a` |
| `app-icon-v2-16.png` | 16 × 16 | 4 (1.56%) | 216 | 36 | 0 | 648 | `756968c10ed878911976b10c0711d52d75e15e204f03b976602354c8ecc553d0` |

## 확인

- `work/app-icon-v2-preview.png`: 16 · 32 · 64 · 128 · 512 실제 크기(밝은·어두운 배경)와 16 × 8 · 32 × 4 · 64 × 2 확대. 16 px에서도 귀·두 눈·목걸이가 구별된다.
- `work/app-icon-v2-system-small.png`(`work/asset-generator system`): 빌드한 번들을 새 경로에 복사해 macOS 27.0.1의 `NSWorkspace.icon(forFile:)`로 16 · 32 · 64 · 128 pt를 @2x로 그린 결과. 모두 회색 판 없이 마스크·그림자가 입혀진 타일로 표시되고, 16 pt에는 손으로 그린 32 px 머리가 쓰인다. 앱은 실행하지 않는다.
- `work/app-icon-v2-system.png`: 이전 라운드에 같은 NSWorkspace 방식으로 만든 큰 크기 v1·v2 비교. v1(투명 배경 머리)은 회색 스퀘어클 안에 들어가고 v2는 타일로 표시된다(1024 원본은 이후 바뀌지 않음).
- 번들 `.icns`에서 꺼낸 16 · 32 px 항목은 원본 PNG와 알파·불투명 픽셀이 같다(부분 알파 가장자리 색만 iconutil 재인코딩으로 다름).
- 다크·틴트 모양은 시스템 자동 처리에 맡긴다(Assets.car를 만들지 않은 이유는 위 결정 참고).
