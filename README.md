# TokenCat

시스템 지표와 Codex·Claude Code 토큰 기록을 함께 표시하는 작은 macOS 메뉴바 앱입니다. macOS 13 이상, Swift·AppKit·SwiftUI만 사용합니다. RunCat의 이미지나 코드는 사용하지 않습니다.

## 실행

```sh
./build.sh
open dist/TokenCat.app
```

메뉴바를 누르면 상세 패널이 열립니다. AI는 제공사별 고정 카드 대신 세션 목록으로 표시합니다. 각 행에 프로젝트·짧은 세션/에이전트 ID·모델·실측 속도·측정 시각을 표시하고, 최근 수신한 모델 실측과 활동이 있는 세션을 위에 배치합니다. 진행 중인 턴에는 상태·경과시간·확인된 출력 누적량·최근 5초 이내 증가량을 한 줄 더 표시합니다. 최근 활동 세션은 전부 포함하고 최신 완료 세션으로 기본 6개를 채웁니다. 화면에는 행 높이에 따라 2~4행을 온전히 표시하고 나머지는 스크롤로 확인합니다. 전체 목록 버튼으로 추가 세션도 볼 수 있으며 접으면 맨 위로 돌아옵니다. 시스템은 CPU·메모리·저장 공간을 한 행, 배터리·네트워크를 다음 행에 배치합니다.

우측 설정 버튼에서 메뉴바 표시 항목을 켜고 끄거나 순서를 바꿀 수 있습니다. 기본 두 줄 표시와 아이콘을 쓰는 한 줄 표시를 선택할 수 있습니다. 지표는 앱이 자동으로 1초마다 갱신하며 주기를 설정할 필요가 없습니다. 고양이 표시와 움직임 기준도 변경할 수 있으며 AI 기준에서는 최근 5초 내 실측값에 반응합니다. 설정은 앱의 UserDefaults에 저장됩니다. 이전 Codex·Claude 항목은 AI 세션 항목으로 합쳐 기존 순서와 표시 선택을 유지합니다.

메뉴바에는 CPU·메모리·저장 공간·배터리·업로드/다운로드·최근 활동 AI 세션 수를 표시합니다. 두 줄 모드에서는 지표 이름과 숫자를 분리하고, 항목마다 폭을 고정해 값이 바뀌어도 위치가 흔들리지 않습니다. 네트워크는 `B/s`·`kB/s`·`MB/s`·`GB/s` 단위를 생략하지 않습니다. AI는 활동 0개와 첫 수집 전 미측정을 구분하며, 모델별 속도는 목록의 각 행에서 확인합니다. 배터리가 없는 Mac에서는 해당 항목을 숨깁니다. 네트워크는 물리 Wi-Fi·Ethernet 인터페이스를 합산하며 로컬 루프백·VPN 가상 인터페이스는 제외합니다.

아이콘과 8프레임 달리기 고양이는 내장 imagegen으로 새로 생성했습니다. 투명 PNG 원본과 최종 프롬프트·알파 검증 기록은 `Assets/`에 있습니다. 앱은 원본을 번들에 포함하고 애니메이션 프레임을 한 번만 디코딩해 재사용합니다. 앱 아이콘의 크기별 PNG·ICNS는 macOS 번들 포맷으로 만들어지며 생성 원본은 유지됩니다.

## 토큰 지표

`~/.codex/sessions`와 `~/.claude/projects`의 로컬 JSONL 기록에서 세션·모델·출력 토큰·진행 상태를 읽습니다. 로그 시각의 차이로 토큰 생성 속도를 추정하지 않습니다. 턴 전체 시간에는 도구 실행과 대기가 포함되므로 이를 생성 속도로 표시하지 않습니다. 실제 계측 데이터가 없으면 속도는 `—`입니다.

TokenCat은 시작할 때 로컬 수집기의 준비 상태를 확인한 뒤 Codex `~/.codex/config.toml`의 OpenTelemetry exporter와 Claude Code `~/.claude/settings.json`의 계측 환경 변수를 자동으로 추가합니다. 두 클라이언트는 **다음 새 실행부터** 적용되며 진행 중인 작업은 재시작하지 않습니다. TokenCat이 실행 중이어야 데이터를 받을 수 있습니다. 별도 갱신 주기·실측 연결 설정 화면은 제공하지 않습니다. 수집기가 준비되지 않으면 클라이언트 설정을 변경하지 않습니다.

수집기는 `127.0.0.1:16493`에서 OTLP HTTP/JSON의 `/v1/logs`, `/v1/metrics`, `/v1/traces`를 받습니다. 외부 인터페이스에는 열지 않으며 웹페이지 Origin을 가진 요청을 거부합니다. 프롬프트·응답 본문 로깅은 끄고, 모델·세션/에이전트/요청 식별자·시간·출력 토큰 등 허용된 메타데이터만 메모리에 보관합니다. 원문 요청을 파일로 저장하지 않습니다. `/v1/diagnostics`에는 수신 건수와 service·metric 이름·단위·인식 여부만 최대 32개 유지합니다. HTTP 본문 2MB, 동시 연결 16개, 요청 제한 5초, 계측 기록 256개로 제한하며 종료 시 연결을 해제합니다.

표시 단위는 계측 기준에 따라 구분합니다.

- **생성 tok/s**: Codex 서버가 제공한 실제 토큰 간 시간(TBT)의 역수입니다. `codex.responses_api_engine_service_tbt.duration_ms` 또는 `codex.responses_api_engine_iapi_tbt.duration_ms`를 사용합니다.
- **모델 tok/s**: 서버 지표가 여러 관측을 묶어 전달하면 토큰 간 시간의 평균으로 계산합니다. 관측 횟수와 계측 구간을 도움말에 표시합니다. 여러 요청의 통계를 개별 세션 속도로 귀속하지 않습니다.
- **요청 tok/s**: Claude Code가 같은 `api_request` 사건에 제공한 출력 토큰 수를 실제 성공 요청 시간으로 나눈 처리율입니다. 첫 응답 대기·추론을 포함합니다. trace만 제공된 경우에는 재시도가 포함된 요청 시간임을 표시합니다. 순수 생성 속도와 측정 기준이 다릅니다.

첫 토큰 지연과 서버 inference 시간이 제공되면 도움말에서 원값을 확인할 수 있습니다. 첫 토큰 지연만으로 생성 속도를 만들지 않습니다. Codex SSE 이벤트 처리 시간을 모델 생성 시간으로 사용하지 않습니다. 최신 완료 계측을 표시하므로 진행 중 출력의 순간 속도를 의미하지 않습니다.

제공사·세션·에이전트 식별자가 정확히 일치할 때만 로그 행에 계측을 붙입니다. 모델 이름이나 시간의 근접성으로 연결하지 않습니다. 세션 식별자가 없는 서버 지표는 **모델 실측** 행으로 표시하고, 로그에 연결되지 않은 식별자는 **요청 실측** 행으로 유지합니다. 같은 세션의 모델이 바뀌면 현재 모델과 이전 측정 모델을 구분합니다. 공식 [Codex OpenTelemetry 설정](https://learn.chatgpt.com/docs/config-file/config-advanced)과 [Claude Code 모니터링 명세](https://code.claude.com/docs/en/monitoring-usage)를 따릅니다. 클라이언트 버전·서버 응답에 따라 지표나 식별자가 제공되지 않을 수 있습니다.

연결 전 원본 설정은 `~/Library/Application Support/TokenCat/telemetry-backups/`에 접근 제한을 적용해 백업합니다. 인증·모델·훅 등 기존 설정과 파일 권한을 유지합니다. 기존 외부 계측 목적지와 충돌하면 덮어쓰지 않습니다. 진단 명령 `--disconnect-telemetry`는 연결 후 사용자 변경이 없는 경우 원본 바이트를 복구하며, 변경이 있으면 자동 복구를 거부하고 사용자 설정을 보존합니다. 복구는 다음 클라이언트 실행부터 적용됩니다. 앱을 다시 시작하면 자동 연결을 다시 설정합니다.

Codex·Claude Code 하위 에이전트도 별도 행으로 수집합니다. 녹색 점은 로그에서 확인한 최근 120초 이내의 진행 중 턴 활동입니다. OS 프로세스 생존 여부를 뜻하지 않습니다. 파일 수정 시각은 활동 시각으로 사용하지 않습니다.

실시간 줄의 `진행`·`도구 실행`·`출력 기록`은 최근 로그 사건을 따릅니다. 토큰 증가는 로그가 기록한 시점에만 반영하며 중복 사용량은 다시 더하지 않습니다. 현재 턴 전체 구간을 읽지 못하면 `누적 미확인`으로 표시하고 확인된 최근 증가량만 보여줍니다. 120초 동안 새 활동 기록이 없으면 `로그 대기`로 바뀝니다. 완료·중단 기록을 확인하면 현재 턴 경과시간과 누적량을 지웁니다. 메뉴바 AI 항목은 도구 기록이 있으면 파랑, 최근 출력 증가가 있으면 초록, 활동 없이 로그를 기다리면 주황으로 표시합니다. `LIVE`는 시스템 수집 갱신 상태이며 도움말에서 시스템·AI 수집 시각을 확인합니다.

Claude 웹·일반 데스크톱 채팅은 Claude Code와 다른 경로이므로 현재 수집 대상이 아닙니다. 제공사별 최근 로그 파일을 최대 32개씩 읽으며 이후 추가된 부분만 수집합니다. 새 파일 목록은 5초마다 확인합니다. 긴 Codex 로그는 최대 16MB 범위의 모델·턴 메타데이터를 역방향으로 확인합니다. 누락된 토큰 구간은 재구성하지 않습니다. 시스템·로그 수집과 로컬 계측은 각각 독립된 백그라운드 큐에서 처리합니다. TokenCat 자체는 모델 호출·계정 로그인·자동 실행 등록을 수행하지 않습니다.

실제 환경에서는 Codex 0.160.0의 서버 TBT 수신과 네이티브 화면 표시를 확인했습니다. Claude Code 수집은 공식 명세·파싱·로컬 OTLP 통합으로 검증했으며, 인증된 실제 모델 호출의 수신 검증은 아직 완료하지 않았습니다. 실측 데이터가 없는 경우에는 숫자를 표시하지 않습니다.

## 검증 명령

```sh
dist/TokenCat.app/Contents/MacOS/TokenCat --self-test
dist/TokenCat.app/Contents/MacOS/TokenCat --diagnose
dist/TokenCat.app/Contents/MacOS/TokenCat --connect-telemetry
dist/TokenCat.app/Contents/MacOS/TokenCat --telemetry-readings
dist/TokenCat.app/Contents/MacOS/TokenCat --disconnect-telemetry
dist/TokenCat.app/Contents/MacOS/TokenCat --live-check
dist/TokenCat.app/Contents/MacOS/TokenCat --snapshot work/dashboard.png
dist/TokenCat.app/Contents/MacOS/TokenCat --snapshot work/dashboard-light.png --light
dist/TokenCat.app/Contents/MacOS/TokenCat --snapshot-menubar work/menubar.png
dist/TokenCat.app/Contents/MacOS/TokenCat --snapshot-menubar work/menubar-inline.png --inline
```

`--diagnose`는 시스템 수치·토큰 및 실측 메타데이터만 출력합니다. `--telemetry-readings`는 실행 중인 TokenCat 수집기의 계측 메타데이터를 확인합니다. `--snapshot`은 실제 로컬 지표로 상세 패널 이미지를 저장합니다. `--snapshot-menubar`는 같은 네이티브 렌더러로 메뉴 막대 미리보기를 저장하며 `--light`도 지원합니다. 첫 CPU·네트워크 샘플은 이전 카운터가 없으므로 미측정이며 두 번째 샘플부터 표시됩니다.

`--self-test`는 로그의 중복·부분 기록·시간 경계·재개된 세션·다중 세션 분리·모델 변경·하위 에이전트 경로 등을 검증하고, 번들 이미지의 투명도·8프레임 구성, OTLP 파싱·식별자 연결·속도 산출, 설정 보존·백업·복구·충돌·부분 저장 실패를 확인합니다.

`--live-check`는 자동 갱신 주기로 실제 시스템과 로컬 로그를 약 6초간 수집합니다. 갱신 간격·중복 시작 방지·종료 후 갱신 차단을 JSON으로 출력하며 실패하면 종료 코드 1을 반환합니다. 모델을 호출하지 않습니다.

현재 빌드는 이 Mac에서 실행하도록 ad-hoc 서명됩니다. App Store 배포·Developer ID 서명·공증·자동 업데이트는 포함하지 않습니다.

## 라이선스

소스와 저장소에 포함된 TokenCat 생성 자산은 [MIT License](LICENSE)로 공개합니다.
