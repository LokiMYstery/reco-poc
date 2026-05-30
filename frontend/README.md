# Frontend POC

This folder is reserved for the Swift/iOS sensor-style frontend POC.

The frontend's main job is to collect observable user context and feedback events, then call the backend APIs:

- `POST /v1/recommend`
- `POST /v1/feedback`

See `../docs/frontend-backend-payload-contract.md` for the current payload contract.

## RecoPOC iOS package and host app

The current iOS frontend lives in `frontend/RecoPOC` as a SwiftPM library plus a minimal Xcode host app.

Key artifacts:

- Swift package: `RecoPOC/Package.swift`
- XcodeGen spec: `RecoPOC/project.yml`
- Generated project: `RecoPOC/RecoPOC.xcodeproj`
- Host app target: `RecoPOC/Host/RecoPOCHost`
- Host plist: `RecoPOC/Host/RecoPOCHost/Resources/Info.plist`

### Build and test

Prerequisites: Xcode and XcodeGen (`brew install xcodegen` if needed).

```bash
cd frontend/RecoPOC
swift build -j 1 -Xswiftc -warnings-as-errors
swift test -j 1 -Xswiftc -warnings-as-errors
xcodegen generate
xcodebuild -project RecoPOC.xcodeproj -list
xcodebuild -project RecoPOC.xcodeproj \
  -scheme RecoPOCHost \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Use `xcodebuild -project RecoPOC.xcodeproj -scheme RecoPOCHost -showdestinations` to pick a different installed simulator.

### Backend URL

The host reads `RecoBackendBaseURL` from `Info.plist`, backed by the Xcode build setting `RECO_BACKEND_BASE_URL`. The committed Debug value currently points at `http://66.245.216.223:8000`; if the build setting is emptied, the app falls back to `http://127.0.0.1:8000`.

Example override:

```bash
cd frontend/RecoPOC
xcodebuild -project RecoPOC.xcodeproj \
  -scheme RecoPOCHost \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1' \
  CODE_SIGNING_ALLOWED=NO \
  RECO_BACKEND_BASE_URL=http://<host>:<port> \
  build
```

The temporary PoC backend is currently configured as `http://66.245.216.223:8000`. When a DNS/HTTPS endpoint is available, update `RECO_BACKEND_BASE_URL` and remove the temporary IP ATS exception.

### ATS / HTTP backend note

`Info.plist` currently enables local HTTP development through `NSAllowsLocalNetworking`, adds a narrow HTTP exception for `66.245.216.223`, and does not enable broad arbitrary loads. Once the backend host is finalized:

- HTTPS domain: no ATS exception should be needed.
- HTTP DNS name: add a narrow exception keyed by the DNS host only.
- HTTP IP literal: add a narrow exception keyed by the IP only.

The ATS key must not include scheme or port. For example, use `66.245.216.223`, not `http://66.245.216.223:8000`.

### Device signing

Simulator builds can still use `CODE_SIGNING_ALLOWED=NO`. Physical-device builds use the configured Apple Developer Team in `project.yml`; if the bundle identifier conflicts under that team, change `PRODUCT_BUNDLE_IDENTIFIER` to a unique value in Xcode or `project.yml`.
