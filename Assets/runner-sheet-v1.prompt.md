# TokenCat 달리기 스프라이트 v1

- 생성: 내장 `image_gen`, 신규 생성, `transparent_background: true`.
- 저장: `Assets/runner-sheet-v1.png`. 생성 원본을 그대로 복사.
- 크기: 1774 × 887 RGBA. 실제 알파 0–255, 완전 투명 픽셀 68.846%, 네 모서리 알파 모두 0.
- SHA-256: `872d31ecbfb2d204cf4e8b678d813b9df53abec0afb314d980eb4b348cab4a79`.
- 구성: 4열 × 2행, 총 8프레임. 앱에서 동일한 영역을 잘라 캐시하고 작은 크기로 표시한다. 원본 이미지 파일은 수정하지 않는다.

## 최종 프롬프트

```text
Create a production-quality ORIGINAL pixel-art sprite sheet for a native macOS menu-bar utility called TokenCat. Exactly 8 distinct animation frames in EXACTLY 4 equal square columns by 2 equal square rows, read left to right then next row. Overall canvas aspect ratio 2:1. Transparent background with genuine alpha; NO background colors, NO checkered pattern, NO tile panels, NO labels, NO borders, NO text, NO watermark. Each equal cell contains exactly one identical friendly white/light-gray cat, side view facing right, thick charcoal outline, small bright-blue collar, tiny dark eyes, simple face, long curved tail, running in place. Crisp handcrafted 16-bit pixel art with large clean pixels, readable at 30x20 screen pixels. Keep identical scale, horizontal center, consistent ground baseline and adequate blank padding in all 8 cells; no cropping or parts touching cell edges. Make a real smooth full 8-frame running gait, deliberately different paw placement in each frame, with extended flight, landing front paws, compression, rear drive, gathering paws and opposite extension. Subtle body bounce only. Include no extra cats or objects. No resemblance to Nyan Cat and do not copy RunCat artwork. White/light-gray fur and charcoal contours must remain legible against both light and dark macOS menu bars. Output only the complete transparent sprite sheet.
```
