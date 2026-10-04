# TokenCat 앱 마크 v1

- 생성 모드: 내장 `image_gen` 도구, 신규 생성.
- 옵션: `transparent_background: true`.
- 결과: 1254 × 1254 RGBA PNG, 687197 bytes.
- 실제 알파: 최소 0 / 최대 255. 완전 투명 픽셀 820556개(52.181%), 완전 불투명 픽셀 1253개, 부분 알파 픽셀 750707개. 네 모서리 알파는 모두 0.
- PNG 원본을 그대로 복사했으며 색·형태·크기·배치·배경을 후처리하지 않음. 원본과 복사본 SHA-256 일치.
- SHA-256: `4350d73557050070da2caf589a3b18a6ebcb1e74bc223dc3c2d9ba6a10e20538`.
- 저장 파일: `Assets/app-mark-v1.png`.
- 육안 확인: 고양이 머리 한 개, 흰 털·회색 디테일·짙은 윤곽·파랑 목걸이, 글자·타일·그림자 없음. 작은 크기에서의 앱 표시 확인은 앱 통합 단계에서 수행.

## 최종 프롬프트

```text
Use case: logo-brand
Asset type: original transparent mascot mark for a native macOS menu bar app called TokenCat; will also be used as the app icon.
Primary request: one original, friendly, compact white-and-light-gray cat head, with a tiny cobalt-blue collar accent visible under the chin. Express alert calm intelligence with a subtle confident smile, two pointed ears, round cheek silhouette, clear minimal dark eyes, and just two short whisker marks per side.
Scene/backdrop: genuinely transparent background with clean alpha; no canvas, tile, scenery, ground, or background.
Style/medium: crisp, flat, polished 2D cartoon brand mark, simple bold shapes and clear thick charcoal outlines. Tiny-size legibility for macOS at 16–32 pixels is the priority. Use two or three flat colors, sparse features, no gradients or intricate shading.
Composition/framing: centered single front-facing cat head and tiny collar, near-square compact silhouette, generous clear transparent padding around the subject, all ear tips and whiskers fully visible. Subject takes about 78 percent of square canvas.
Color palette: white fur, light-gray ear interior and small accents, deep-charcoal outlines and face, tiny cobalt-blue collar. The bright cat interior and dark outline should retain clarity on both light and dark UI surfaces.
Constraints: original character, not any existing app mascot; do not imitate RunCat. Exactly one cat, one standalone mark, no full body, no paws, no duplicate, no variants, no icon tile, no background square, no shadow, no glow. Real alpha transparency, not a checkerboard picture. No text, letters, numbers, watermark, labels, logo typography, or sprite sheet.
```
