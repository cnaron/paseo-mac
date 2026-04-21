# Daemon protocol notes

Reading `packages/server/src/...` in the open-source Paseo repo to derive what PaseoMac needs to speak.

## Confirmed so far

- Transport: WebSocket at path `/ws`.
- URL builder: `buildDaemonWebSocketUrl(endpoint)` in `packages/server/src/shared/daemon-endpoints.ts` — uses `wss://` when port is 443, else `ws://`.
- Default local endpoint: `localhost:6767` (observed on VPS).
- Relay protocol version constant: `CURRENT_RELAY_PROTOCOL_VERSION = "2"`.

## Open questions (Phase 1 will answer)

1. Pairing / authentication: how does a fresh client join? Look at `connection-offer.ts`, `daemon-keypair.ts`, and whatever the iOS app does on first launch.
2. Message envelope: JSON schema for RPC requests and streamed events. `shared/messages.ts` and `server/chat/chat-rpc-schemas.ts` likely define this.
3. Agent list call: exact method name for the `paseo ls` equivalent.
4. Conversation stream: how deltas are delivered and how to merge them.
5. Binary uploads (images/files): does the WS accept binary frames, or is there an HTTP side channel?
6. Relay topology: when endpoint is `relay.paseo.sh` (or similar), what handshake steps are needed?

## Research plan

- Clone the repo locally on Air so we can read code without round-tripping to the GitHub API:
  ```
  git clone --depth 1 https://github.com/getpaseo/paseo /Users/naron/Public/Project/paseo-mac/.vendor/paseo-upstream
  ```
  (Kept under `.vendor/` and git-ignored; we just want to read code.)
- Pair an existing device (the Electron app or `paseo onboard`) to the daemon on VPS, then inspect the on-disk config to see what tokens/keys are stored.
