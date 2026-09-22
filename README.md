# meta-adventurer-bob

iOS SwiftUI companion for **Meta Adventurer** AI glasses (variant **1H41**, self-branded Meta Glasses) talking to **Bob** (Chief of Staff).

This is the smallest working **mock** path:

1. `MockDeviceKit.enable` with mock registration (no Meta AI app)
2. `pairGlasses(model: .metaGlasses)` — not Ray-Ban Meta, not Display
3. DAT `DeviceSession` start / stop
4. iOS CTA **Talk to Bob** starts the session
5. Phone-mic STT tagged `stt_source = phone_mic`
6. `BobBridge` stub (default) or HTTPS `POST /v0/bob/turn` when configured
7. TTS / `spoken_line`

First proof: **one logged round-trip** with the golden spoken lines.

This PR is source + README. It was **not** run on a Mac iOS Simulator in this environment.

## Open in Xcode

Requires **Xcode 15+**, iOS **16+** deployment target.

1. Clone this repo.
2. Open `BobCompanion.xcworkspace` (or `Apps/BobCompanion/BobCompanion.xcodeproj`).
3. Wait for Swift Package Manager to resolve:
   - Local `BobCore` (this repo)
   - [meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios) `0.8.x`
4. Select the **BobCompanion** scheme and an iPhone simulator or device.
5. Run. Grant **Microphone** and **Speech Recognition** when asked.

SPM products linked on the app target:

| Product | Why |
|---|---|
| `MWDATCore` | Register + `DeviceSession` |
| `MWDATCamera` | Linked for later; **camera stays off** on voice v0 |
| `MWDATMockDevice` | `MockDeviceKit` |
| `BobCore` | BobBridge, spoken caps, golden lines, log types |

DAT **0.9.0** raises the SDK minimum to iOS 17.2. This project pins **0.8.x** so the locked iOS 16+ target still links, while still using official `GlassesModel.metaGlasses` / `DeviceType.metaGlasses` (added in 0.8.0). Raise the deployment target before moving to 0.9.

`Info.plist` includes:

- `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription` (phone-mic v0)
- DAT URL scheme `bobcompanion://`, `MetaAppID = 0`, `com.meta.ar.wearable`
- Bluetooth / external-accessory keys the DAT mock link-availability check expects

## How to run the mock

On launch the app:

1. Calls `Wearables.configure()` (ignores `alreadyConfigured` if MockDeviceKit already did it).
2. Calls `MockDeviceKit.shared.enable(config: MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true))`.
3. Pairs **`.metaGlasses`**, then `powerOn()` / `unfold()` / `don()`.
4. Treats registration as **already `.registered`** — no Meta AI hop.

Then:

1. Tap **Talk to Bob** (`Opens a hands-free session` sits under the button).
2. App starts a DAT `DeviceSession` via `SpecificDeviceSelector` on the mock glasses (no `addCamera`).
3. Speaks and logs: `Bob here. Listening.`
4. Starts phone-mic `SFSpeechRecognizer`, tagged `phone_mic`.
5. Injects a demo utterance (`What's next?`) so the first proof logs a complete round-trip without requiring you to speak.
6. Stub Bob replies: `Next up is the 2pm with Sue.`
7. Tap **End** → `Paused — say Bob when you’re back.`

Golden-path demo buttons (session must be live):

| Button | `spoken_line` | Extra |
|---|---|---|
| Reply | `Next up is the 2pm with Sue.` | — |
| Desk | `Full note on desk.` | `desk_full` with the long note |
| Fail | `Session cut — check the phone.` | one sentence |

Watch **Xcode console** and the on-screen **Round-trip log**. Every line includes `deviceType=META_GLASSES`, `spoken_line` length / cap check, and `stt_source=phone_mic` on Bob turns.

BobCore (no DAT, no simulator) can be checked from any Swift 5.9 host:

```bash
swift test
```

## What Gage verifies

Mock session-up, in order:

- [ ] Pair `.metaGlasses` — log `deviceType = META_GLASSES` (not Ray-Ban Meta, not Display)
- [ ] DAT register / session — `MockDeviceKitConfig.initiallyRegistered = true` so state is `.registered` **without** Meta AI / Developer Mode
- [ ] iOS CTA only — **Talk to Bob** starts the session; no Hey Meta; no third-party wake
- [ ] `stt_source = phone_mic` (not HFP)
- [ ] Camera off (voice v0 does not call `addCamera`)
- [ ] One complete round-trip after mock pair + CTA: start line + stub reply
- [ ] `spoken_line` length within caps (open ≤12 words; reply ≤2 sentences / ~35 words)

## BobBridge contract

Locked OpenAPI 3.0.3: [`docs/bobbridge-openapi.yaml`](docs/bobbridge-openapi.yaml).

**HTTPS** `POST /v0/bob/turn` with Bearer auth.

**Request JSON (required):** `session_id`, `utterance`, `stt_source` (`phone_mic` \| `hfp`)

**200 JSON:** `spoken_line` (required), `desk_full` (string or null)

**401 Unauthorized** and **503 CoS unavailable:** client speaks `Session cut — check the phone.`

**Caps** (client enforces when applying a 200; server should too):

- open ≤12 words
- reply ≤2 sentences / ~35 words
- longer desk answer → `spoken_line = Full note on desk.` + `desk_full`
- end / fail = one sentence

Default Bob is the local **stub** (`StubBobService`) so the mock demo works offline. `HttpsBobTransport` POSTs when `BOB_BRIDGE_MODE=remote` and both base URL and Bearer are set. **No production URL is committed.** WebSocket is deferred until barge-in.

### Stub vs remote

Resolution order: process environment, then `Info.plist` / xcconfig. Unexpanded `$(BOB_BRIDGE_*)` placeholders are ignored.

| Key | Meaning |
|---|---|
| `BOB_BRIDGE_MODE` | `stub` (default) or `remote` |
| `BOB_BRIDGE_BASE_URL` | Origin only — no live URL committed in this repo |
| `BOB_BRIDGE_BEARER_TOKEN` | Bearer token. Never commit it. |

If mode is `remote` but the URL or token is missing, the app **stays on stub** and logs why (`[BobBridge] … reason=…`).

**xcconfig HTTPS trap:** In `.xcconfig`, `//` starts a comment. Writing `BOB_BRIDGE_BASE_URL = https://bob-bridge.fly.dev` silently truncates to `https:` (Bearer can still look fine while remote calls fail with RoundTrip `note=sessionCut`). Escape the double slash with an empty `$()` expansion:

```xcconfig
BOB_BRIDGE_BASE_URL = https:/$()/bob-bridge.fly.dev
```

Set them in any of:

1. Xcode scheme Environment Variables (preferred for a token; plain `https://…` URLs are fine here)
2. `Apps/BobCompanion/Config/BobBridge.local.xcconfig` (gitignored — never commit tokens), included from Debug/Release
3. `Apps/BobCompanion/Config/BobBridge.xcconfig` placeholders (empty in git)

```xcconfig
BOB_BRIDGE_MODE = remote
BOB_BRIDGE_BASE_URL = https:/$()/bob-bridge.fly.dev
BOB_BRIDGE_BEARER_TOKEN = your-local-token
```

### Example curl

```bash
curl -sS -X POST "$BOB_BRIDGE_BASE_URL/v0/bob/turn" \
  -H "Authorization: Bearer $BOB_BRIDGE_BEARER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"session_id":"session-demo","utterance":"What'\''s next?","stt_source":"phone_mic"}'
```

Expected 200:

```json
{"spoken_line":"Next up is the 2pm with Sue.","desk_full":null}
```

401 / 503 → companion speaks `Session cut — check the phone.`

## Later: real HFP

Adventurer hands-free (HFP) audio is out of scope. Keep tagging `phone_mic` until a glasses SCO / HFP capture path exists, then set `stt_source = hfp`. Real Meta AI, Developer Mode, and physical Adventurer hardware are also out of scope here.

## Out of scope

- Real Meta AI app / Developer Mode / real Adventurer HFP
- Android
- Perfect Process / PerfectRouter
- Custom wake word
- Camera / Display experiences
- WebSocket BobBridge (deferred until barge-in)
