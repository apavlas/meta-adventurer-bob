# meta-adventurer-bob

iOS SwiftUI companion for **Meta Adventurer** AI glasses (variant **1H41**, self-branded Meta Glasses) talking to **Bob** (Chief of Staff).

Two DAT paths, gated by `BOB_USE_MOCK_DEVICE`:

| `BOB_USE_MOCK_DEVICE` | Boot |
|---|---|
| `NO` (committed default, device Run) | `Wearables.configure()` only. **Does not** call `MockDeviceKit.enable`. Registration goes through Meta AI. Session selects real `.metaGlasses`. |
| `YES` (simulator / no glasses) | Today's mock path: `MockDeviceKit.enable(initiallyRegistered: true)`, pair `.metaGlasses`, no Meta AI hop. |

Both paths:

1. Device type stays **`.metaGlasses` / `META_GLASSES`** (Adventurer **1H41**). Not Ray-Ban Meta, not Display.
2. DAT `DeviceSession` start / stop. Camera stream stays off (`addCamera` is not called).
3. iOS CTA **Talk to Bob** starts the session.
4. Real path allows Bluetooth HFP and tags `stt_source=hfp` only when that input route is active. Otherwise, and on the mock path, STT stays `phone_mic`.
5. `BobBridge` stub (default) or HTTPS `POST /v0/bob/turn` when configured.
6. TTS / `spoken_line`.

The word **mock** in the header means **MockDeviceKit is on**. It is not the device type. A real-path header reads `path real` and registration reads `registered` (not `mock` / `no Meta AI`). Round-trip lines include `device_path=real|mock` and `meta_ai=used|none`.

BobCore tests run with `swift test`. This environment does not build the iOS app.

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

- `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription` (phone mic, or glasses HFP when that route is active)
- DAT URL scheme `bobcompanion://`, `MetaAppID = 0`, `com.meta.ar.wearable`
- `BOB_USE_MOCK_DEVICE` from xcconfig (`NO` in git)
- Bluetooth / external-accessory keys DAT expects

## Mock vs real

Committed default in `Apps/BobCompanion/Config/BobBridge.xcconfig`:

```xcconfig
BOB_USE_MOCK_DEVICE = NO
```

That value is copied into Info.plist as `$(BOB_USE_MOCK_DEVICE)`. On launch the app reads the process environment first, then Info.plist. Missing, blank, unexpanded `$(BOB_USE_MOCK_DEVICE)`, `NO`, or any token other than `YES` / `true` / `1` / `y` stays on the **real** path and does **not** call `MockDeviceKit.enable`.

Override locally the same way as BobBridge (do not commit the local file):

1. Xcode scheme → Run → Environment Variables: `BOB_USE_MOCK_DEVICE` = `YES` or `NO` (wins over the built plist).
2. `Apps/BobCompanion/Config/BobBridge.local.xcconfig` (gitignored), included after the committed xcconfig from Debug and Release:

```xcconfig
BOB_USE_MOCK_DEVICE = YES
```

Use `YES` for simulator and no-hardware demos. Use `NO` on a phone that should talk to real Adventurer glasses.

### Real path (device default)

Prerequisites:

- Meta AI app installed, and the Adventurer shows **Connected** there.
- **Developer Mode** on (Meta AI → Settings → your glasses → Developer Mode). This build keeps `MetaAppID = 0`, so registration is the Developer Mode flow, not a production Wearables Developer Center app id.
- Glasses are Meta Glasses / Adventurer 1H41 (`.metaGlasses`), not Ray-Ban Display.

On launch, when the flag is NO:

1. `Wearables.configure()` only. Console: `MockDeviceKit.enable not called`.
2. If registration is not already `.registered`, `Wearables.shared.startRegistration()` opens Meta AI. The return URL is handled by the existing `onOpenURL` → `Wearables.shared.handleUrl`.
3. Devices are filtered to `deviceType() == .metaGlasses`. Other types are logged and ignored.
4. DAT 0.8 does not put a device in `devicesStream` until at least one permission is granted, and the only permission is camera. If the list is empty after registration, the app calls `requestPermission(.camera)` so the glasses can appear. It still does **not** call `addCamera` or start a camera stream.
5. **Talk to Bob** creates a `DeviceSession` with `SpecificDeviceSelector` on that `.metaGlasses` id.

UI: header `path real`, path row `real · Meta AI`, registration `registered` / `available` / `registering` / `unavailable`. Round-trip: `device_path=real`, `meta_ai=used` once registration is `.registered`. Live speech is `stt_source=hfp` when the input route is Bluetooth HFP, and `stt_source=phone_mic` when it is not. See [Glasses microphone](#glasses-microphone-bluetooth-hfp).

Connecting the glasses in Meta AI cannot drop mock by itself. The flag has to be `NO`. If the header still says `path mock`, MockDeviceKit is on — change the flag and run again.

### Mock path (`BOB_USE_MOCK_DEVICE=YES`)

On launch the app:

1. Calls `Wearables.configure()` (ignores `alreadyConfigured` if MockDeviceKit already did it).
2. Calls `MockDeviceKit.shared.enable(config: MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true))`.
3. Pairs **`.metaGlasses`**, then `powerOn()` / `unfold()` / `don()`.
4. Treats registration as **already `.registered`** — label `registered (mock, no Meta AI)`. No Meta AI hop.

Header includes the word **mock**. That word means MockDeviceKit, not `deviceType`. `deviceType` is still `META_GLASSES`. Round-trip: `device_path=mock`, `meta_ai=none`, `stt_source=phone_mic`.

Then:

1. Tap **Talk to Bob** (`Opens a hands-free session` sits under the button).
2. App starts a DAT `DeviceSession` via `SpecificDeviceSelector` on the mock glasses (no `addCamera`).
3. Speaks and logs: `Bob here. Listening.` Capture waits until that line finishes.
4. Starts `SFSpeechRecognizer` on the iPhone microphone, tagged `phone_mic` (HFP is not enabled on this path).
5. Injects a demo utterance (`What's next?`) so the first proof logs a complete round-trip without requiring you to speak.
6. Stub Bob replies: `Next up is the 2pm with Sue.`
7. Tap **End** → `Paused — say Bob when you’re back.`

Golden-path demo buttons (session must be live):

| Button | `spoken_line` | Extra |
|---|---|---|
| Reply | `Next up is the 2pm with Sue.` | — |
| Desk | `Full note on desk.` | `desk_full` with the long note |
| Fail | `Session cut — check the phone.` | one sentence |

Watch **Xcode console** and the on-screen **Round-trip log**. Every line includes `device_path`, `deviceType=META_GLASSES`, `meta_ai`, and `spoken_line` length / cap check. Bob turns include `stt_source`. On the real path that is `hfp` only when the input route is HFP (`hfp=wired` plus `audio_route=`). Otherwise it stays `phone_mic` and `hfp=not_wired`. The mock path stays `phone_mic`.

BobCore (no DAT, no simulator) can be checked from any Swift 5.9 host:

```bash
swift test
```

## What Gage verifies

Real path (`BOB_USE_MOCK_DEVICE=NO`, physical Adventurer, Meta AI Connected, Developer Mode):

- [ ] Launch does **not** log `MockDeviceKit.enabled`. Console includes `mock_kit=off` / `MockDeviceKit.enable not called`.
- [ ] Header says `path real` and does not say mock. Registration does not say `mock` or `no Meta AI`.
- [ ] Select `.metaGlasses` only — log `deviceType=META_GLASSES` (not Ray-Ban Meta, not Display).
- [ ] After Meta AI registration, round-trip shows `device_path=real` and `meta_ai=used`.
- [ ] After **Talk to Bob**, wait until `Bob here. Listening.` finishes, then speak into the glasses. Console shows `[Audio] tap_energy` with a non-zero `tap_peak` and `[Audio] partial chars=` before the next card. That card is `REPLY` with `stt_capture=live`. If the glasses mic is the input, that line shows `stt_source=hfp`, `hfp=wired`, and `audio_route=BluetoothHFP:<glasses name>`. If the iPhone mic is still selected, the same line stays `stt_source=phone_mic` and `hfp=not_wired`. Do not expect `hfp` until `audio_route` shows that hands-free port.
- [ ] If you stay quiet, about 5 seconds later you hear `Didn’t catch that — say it again.` The card is `NO_FINAL`, has no `stt_source`, and listening starts again. That card is not a transcript. Its note includes `tap_buffers` and `tap_peak`.
- [ ] Camera stream off (no `addCamera`).

Mock path (`BOB_USE_MOCK_DEVICE=YES`), in order:

- [ ] Pair `.metaGlasses` — log `deviceType=META_GLASSES` (not Ray-Ban Meta, not Display)
- [ ] DAT register / session — `MockDeviceKitConfig.initiallyRegistered = true` so state is `.registered` **without** Meta AI / Developer Mode (`meta_ai=none`, registration text includes mock)
- [ ] iOS CTA only — **Talk to Bob** starts the session; no Hey Meta; no third-party wake
- [ ] `stt_source=phone_mic` (not HFP) and `device_path=mock`
- [ ] Camera off (voice v0 does not call `addCamera`)
- [ ] One complete round-trip after mock pair + CTA: start line + stub reply
- [ ] `spoken_line` length within caps (open ≤12 words; reply ≤2 sentences / ~35 words)

## BobBridge contract

Locked OpenAPI 3.0.3: [`docs/bobbridge-openapi.yaml`](docs/bobbridge-openapi.yaml).

Omi phone chat (Ask Bob) is a separate adapter contract: [`docs/omi/`](docs/omi/).

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

## Glasses microphone (Bluetooth HFP)

DAT does not capture the glasses microphone. Meta's microphone guidance is the phone Bluetooth stack: category `.playAndRecord`, the HFP option, then `setPreferredInput` on the `BluetoothHFP` port. Confirm `currentRoute.inputs` before calling it the glasses mic. A2DP is output-only and does not provide a microphone. HFP and A2DP are mutually exclusive; while HFP is up, playback on that link is 8 kHz mono.

On the real path (`BOB_USE_MOCK_DEVICE=NO`) Bob uses mode `.voiceChat` with `.allowBluetooth` (the iOS 16 name for `.allowBluetoothHFP`). It does **not** set `.allowBluetoothA2DP` or `.defaultToSpeaker`. Those options keep the phone speaker and leave the input on the iPhone microphone. The session prefers an HFP port whose name looks like the glasses when more than one hands-free device is connected.

`hfp=wired` is not proof that SpeechKit received samples. After TTS the route can already be `BluetoothHFP` while the SCO uplink is still the playback graph, and `.voiceChat` delivers that uplink to VoiceProcessingIO. The capture graph therefore:

- prefers 16 kHz mono (HFP wideband) before the session activates
- re-asserts `setPreferredInput` and activates the session again after the open line, so the mic direction of SCO is attached
- enables voice processing on the engine input, then starts the engine, then installs the tap on the **running** bus format
- if that bus rate or channel count disagrees with the hardware format, reactivates the session and restarts the engine once so the bus can renegotiate. The input node stays off the mixer: wiring it plays the mic back into the glasses, and voice processing already owns that graph
- keeps on-device SpeechKit off for HFP. Narrowband buffers often never produce `isFinal`

Capture starts only after `Bob here. Listening.` has finished. A partial that sits still for about a second ends the audio buffer so SpeechKit can finalize; if `isFinal` still does not arrive, that partial is the utterance and the route tag is whatever the input is at that moment. The route is read again when the phrase is delivered. A listen window with no partial still speaks the retry line. That line is never tagged `hfp`.

`stt_source=hfp` is sent only when that **current input** is Bluetooth HFP/SCO, or a port that is clearly the glasses hands-free input. The built-in mic, a wired headset, A2DP, and Bluetooth LE with no hands-free marker stay `phone_mic`. The tag is never forced. The mock path does not enable HFP and always tags `phone_mic`.

| Input route | BobBridge tag | Round-trip |
|---|---|---|
| Bluetooth HFP/SCO, or a clear glasses hands-free port | `stt_source=hfp` | `hfp=wired` and `audio_route=<port type>:<port name>` |
| iPhone mic, wired headset, A2DP-only, or no input | `stt_source=phone_mic` | `hfp=not_wired` and `audio_route=` when a port was read |

`audio_route` uses `_` instead of spaces. The same line is printed as `[Audio]` in the Xcode console, plus `available_inputs=`, `preferred_input=`, and `reassert_input=` when the real path configures the session.

For the first 3 seconds after the tap is installed the console also prints `[Audio] tap_energy` (`tap_buffers`, `tap_rms`, `tap_peak`, `sample_rate`, `partial_events`) and `[Audio] formats` (`session_rate`, `hardware_rate`, `output_rate`, `voice_processing`). Each SpeechKit update prints `[Audio] partial chars=`. `tap_rms` is the latest buffer. `tap_peak` is the loudest sample since this listen window opened.

### Verify live HFP speak → REPLY

On a phone with `BOB_USE_MOCK_DEVICE=NO` (the committed default):

1. Meta AI shows the Adventurer **Connected**. Developer Mode is on. This build keeps `MetaAppID = 0`.
2. Run Bob. The header says `path real`. Registration reaches `registered`.
3. Tap **Talk to Bob**. The first card is `START` / `Bob here. Listening.` with `hfp=wired` and `audio_route=BluetoothHFP:<glasses name>` when that mic is already the input.
4. Wait until that line finishes. Console then shows `[Audio] listening armed`, `[Audio] formats` with `voice_processing=on`, and `[Audio] tap sample_rate=...`. Do not speak over the open line. Capture is not running yet.
5. Speak a short phrase into the glasses, then pause. Within the first 3 seconds, `[Audio] tap_energy` should show `tap_buffers` greater than 0 and `tap_peak` above `0.0050`, then `[Audio] partial chars=` greater than 0. Console then shows `[Audio] utterance reason=speechkit-final` or, if SpeechKit never sets `isFinal`, `[Audio] endAudio reason=partial-silence` followed by `reason=partial-promoted`.
6. The next card is **REPLY**. It includes `device_path=real`, `meta_ai=used`, `stt_capture=live`, `stt_source=hfp`, `hfp=wired`, and `audio_route=BluetoothHFP:<glasses name>`.
7. If the input is still the iPhone mic, the same REPLY card stays `stt_source=phone_mic` and `hfp=not_wired`. The tag follows the route. It is not forced. A phone-mic REPLY is still a successful turn.

Golden-path demo buttons inject text. Those lines stay `stt_source=phone_mic` because they were not captured from the route.

### If nothing is transcribed

Stay quiet after the open line. About 5 seconds after listening is armed you hear `Didn’t catch that — say it again.`

- The card is `NO_FINAL`. It has no `stt_source` and no `stt_capture`. It is not a Bob reply and not a fake `hfp` transcript.
- Console includes `[Audio] speechkit_no_final timeout_s=5` and `restart_listening`. The same note on the card adds `tap_buffers`, `tap_peak`, `sample_rate`, and `partial_events`.
- Read those fields before treating it as “SpeechKit heard nothing”:
  - `tap_buffers=0` — the tap never fired.
  - `tap_buffers` greater than 0 and `tap_peak=0.0000` — buffers arrived and were digital silence. The route can still be HFP.
  - `tap_peak` above `0.0050` and `partial_events=0` — the mic has energy and SpeechKit did not return text.
  - `partial_events` greater than 0 — a partial was logged. The next successful phrase should be a REPLY, not another guess.
- After that line finishes, listening starts again. Speak then. A real phrase still becomes a REPLY with the honest route tag.
- `path=start` / `path=end` can already show `hfp=wired` when this happens. That only means the route is HFP. The REPLY card is the line that proves SpeechKit returned text.

### If it stays `phone_mic`

That result is honest. The route was not HFP.

- Meta AI does not show the Adventurer as **Connected**, or registration is not `registered`. No HFP input will appear.
- `audio_route` is `MicrophoneBuiltIn:...`. iOS kept the phone mic. Media audio can still play on the glasses over A2DP while the mic stays on the phone; that is still `phone_mic`.
- `audio_route` names a different headset. The tag is `hfp` whenever that HFP port is the input, and the route name shows which device. Disconnect the other hands-free device, or confirm Adventurer is the Bluetooth input, and speak again.
- `audio_route` is Bluetooth LE only, with no hands-free / HFP port. Discovery is not the glasses mic.
- The STT row says `mic not granted`. Microphone or speech permission was denied, so there is no live line.
- The header says `path mock`. `BOB_USE_MOCK_DEVICE=YES` does not select HFP.
- You spoke while `Bob here. Listening.` was still playing. The mic opens after that line. Wait for it to end, then speak.
- The only new card is `NO_FINAL`. SpeechKit returned no text. That prompt is not the missing REPLY. Speak again after you hear it. A REPLY card is still required for a successful turn. Use `tap_peak` on that card to see whether the glasses mic produced samples.

Camera stream stays off. Meta's "configure HFP before starting the camera stream" ordering applies when `addCamera` is used. This voice path does not call it.

## Out of scope

- Android
- Perfect Process / PerfectRouter
- Custom wake word
- Camera / Display experiences (`addCamera` stays off; camera permission is requested only so DAT 0.8 will list a device)
- WebSocket BobBridge (deferred until barge-in)
