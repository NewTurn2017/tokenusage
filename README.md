# Token Usage

## 무엇을 하나요

Token Usage는 macOS 메뉴 막대에서 AI 서비스의 사용량과 한도, 초기화 시각을 한눈에 보여 주는 네이티브 SwiftUI 앱입니다. 여러 계정과 프로필을 저장해 전환할 수 있고, 새로고침에 실패하면 가능한 경우 마지막으로 확인한 값을 표시합니다.

현재 지원하는 서비스는 다음과 같습니다.

* **Claude**: 5시간 한도와 주간 한도
* **Codex**: 주간 한도와 프로필별 상태
* **OpenRouter**: 사용량, 크레딧 또는 한도, 잔액, 티어와 요청 제한

## 요구 사항

* macOS 14 이상
* Claude를 쓰려면 Claude Code에 로그인되어 있어야 합니다.
* Codex를 쓰려면 `codex` CLI가 설치되어 있고 로그인되어 있어야 합니다. 앱은 CLI의 app server를 통해 조회합니다.
* OpenRouter를 쓰려면 API 키를 `OPENROUTER_API_KEY` 환경 변수에 넣거나 `~/.config/openrouter/key` 파일에 저장해야 합니다.

로컬 배포 패키지는 Apple Silicon과 Intel을 포함하는 Universal 빌드입니다. Apple Silicon에서 실행을 확인했으며, Intel 하드웨어에서의 실행은 아직 검증하지 않았습니다.

## 인증과 데이터

앱은 사용량을 서비스에서 직접 읽습니다. Claude는 macOS 키체인의 `Claude Code-credentials` 항목에서 OAuth 토큰을 읽고 `https://api.anthropic.com/api/oauth/usage`에 요청합니다. Codex는 설치된 `codex app-server --stdio` 프로세스에 JSON-RPC로 요청합니다. OpenRouter는 API 키를 사용해 `https://openrouter.ai/api/v1/key`와 `https://openrouter.ai/api/v1/credits`에 GET 요청을 보냅니다.

Codex 프로필 자격 증명은 macOS 키체인에 저장되고, 프로필 이름과 같은 메타데이터는 `UserDefaults`에 저장됩니다. Codex 로그인 검증 중에는 임시 디렉터리의 제한된 파일을 사용한 뒤 제거합니다. OpenRouter 키 파일은 앱이 읽기만 합니다. 코드상 별도의 분석 서버나 앱 자체 수집 엔드포인트는 확인되지 않았습니다. 서비스 요청에는 각 서비스의 인증 정보와 사용량 응답이 포함될 수 있으므로, 네트워크 사용과 해당 서비스의 정책을 고려해 사용하세요.

## 빌드와 실행

Swift 6 toolchain이 필요합니다. 저장소 루트에서 실행합니다.

```sh
swift build
swift run TokenUsageApp
```

테스트:

```sh
swift test
```

소스에서 빌드해 `~/Applications/Token Usage.app`에 설치하려면 다음을 실행합니다.

```sh
./scripts/install-app.sh
```

로컬 배포 ZIP과 SHA-256 체크섬을 생성하려면 다음을 실행합니다.

```sh
./scripts/create-release.sh
```

결과는 `build/release/`에 생성됩니다. 이 명령은 패키지 구조, 서명, 압축 해제 후 체크섬과 격리된 환경에서의 앱 실행을 검증합니다. 기본 서명은 로컬 테스트용 ad hoc 서명이며, 검증 통과가 Apple 공증을 뜻하지는 않습니다.

## 현재 배포 상태

공개 공증 릴리스는 아직 게시되지 않았습니다. 로컬 릴리스 후보는 Developer ID로 서명하고 Hardened Runtime을 적용했지만, Apple 공증 전이므로 Gatekeeper가 신뢰하는 공개 배포판은 아닙니다. 기본 빌드 스크립트는 별도 서명 설정이 없으면 ad hoc 서명을 사용합니다. 공개 배포 전에 Apple 공증이 필요합니다.

자동 업데이트 기능은 현재 코드에서 확인되지 않았습니다. 따라서 자동 업데이트를 제공하지 않습니다.

## 초기화 쿠폰

Codex의 `account/rateLimits/read` 응답에 `rateLimitResetCredits.availableCount` 값이 있을 때만 프로필 행에 **초기화 쿠폰** 개수를 표시합니다. 이 기능은 개수를 읽어 보여 주는 읽기 전용 기능이며, 쿠폰을 사용하거나 충전하지 않습니다. 값이 없으면 표시하지 않습니다.

## 개인정보와 네트워크 요약

앱은 계정 인증 정보와 사용량을 로컬에서 읽고, 위에 적은 각 제공자의 엔드포인트 또는 로컬 Codex CLI에만 조회를 보냅니다. 이 저장소의 코드만으로 제공자의 보존 기간, 네트워크 로그, 제3자 처리 여부까지 보장할 수는 없습니다.

## 라이선스

이 프로젝트는 [MIT 라이선스](LICENSE)로 배포됩니다. 포함된 제공자 아이콘의 출처와 별도 이용 조건은 [고지 문서](Sources/TokenUsageApp/Resources/ProviderIcons/ATTRIBUTION.md)를 참고하세요.
