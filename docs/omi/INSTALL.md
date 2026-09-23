# Install Ask Bob in Omi

Anton’s private Omi app. Chat can call **Ask Bob** (Anton’s Chief of Staff). The glasses companion is unchanged.

This repo holds the contract only:

- Manifest: [`omi-tools.json`](omi-tools.json)
- HTTP contract: [`omi-ask-bob-openapi.yaml`](omi-ask-bob-openapi.yaml)

`https://bob-bridge.fly.dev` serves those two routes. The Fly adapter is not in this repo. Do not add `server.js` here.

Realtime transcript webhooks and proactive chat notify stay off.

## Create the app

In the Omi app (Developer Mode on):

1. **Apps → Create App**. Capability: **External Integration**. Leave visibility **Private**. Do not submit it to the public store.
2. **App Home URL:** `https://bob-bridge.fly.dev`
3. **Chat Tools Manifest URL:** `https://bob-bridge.fly.dev/.well-known/omi-tools.json`
4. Leave realtime transcript, memory, and audio webhooks empty. Do not turn on proactive chat messages. The manifest already sets `chat_messages.enabled` to false.
5. Save. Omi fetches the manifest. Confirm one tool, `ask_bob`, method `POST`, endpoint `/v0/omi/tools/ask_bob`, `auth_required` false.
6. Install the app on your Omi account and leave it enabled.

Omi does not send the companion Bearer. The bridge attaches that token on the server. There is no connect-account step in the app.

## Send the App ID and API key

On the app’s management page, copy the **App ID** (Omi assigns it). Under **API Keys**, create a key and copy it immediately — Omi shows it once.

Send the App ID and the API key to Mira and Bob, outside this repo. Do not commit them, and do not paste them into chat logs that get archived in git.

v0 does not call Omi with that key. Mira/Bob keep it for a later notify path. Proactive notify stays deferred.

## Test in Omi chat

Say:

> Ask Bob what’s next

Omi should call `ask_bob` and show a short reply: at most 2 sentences, about 35 words. A stub bridge answers `Next up is the 2pm with Sue.`

You can check the host before opening the app:

```bash
curl -sS https://bob-bridge.fly.dev/.well-known/omi-tools.json
```

```bash
curl -sS -X POST https://bob-bridge.fly.dev/v0/omi/tools/ask_bob \
  -H "Content-Type: application/json" \
  -d '{"uid":"anton","app_id":"YOUR_APP_ID","tool_name":"ask_bob","utterance":"what'\''s next"}'
```

No `Authorization` header. A live turn looks like:

```json
{"result":"Next up is the 2pm with Sue."}
```

If Bob is cut, the call returns 503:

```json
{"error":"Session cut — check the phone."}
```
