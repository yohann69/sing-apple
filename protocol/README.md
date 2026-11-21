# Sing! pad protocol, version 1

The Mac is the only source of truth. Pads (iPad, iPhone, Android, web) find it with Bonjour, pair once, then use HTTP for requests and a WebSocket for live state. All bodies are JSON, UTF-8. Dates are milliseconds since 1970. Swift types live in `Packages/SingKit/Sources/SingCore/Protocol`.

## Discovery

Bonjour service `_sing._tcp`, TXT record `v=<protocol version>`. HTTP runs on the advertised port (default 47800). The live WebSocket runs on the next port (47801).

A join QR or link has the form `sing://<host>:<port>?code=<6 digits>&name=<Mac name>`.

## Pairing

`POST /v1/pair` with `{"code","deviceName","deviceModel","protocolVersion"}` returns `{"token","padID","role","server"}`. The host code (shown only on the Mac) gives the `host` role, the guest code (shown on the TV) gives `guest`. Send `Authorization: Bearer <token>` on every other request.

If `protocolVersion` is older than the Mac's `minimumProtocolVersion`, pairing fails with code `version` and a message asking to update the app.

## HTTP

| Method and path | Returns |
| --- | --- |
| `GET /v1/info` (no auth) | `ServerInfo` |
| `GET /v1/state` | `LiveState` |
| `GET /v1/songs?q=&ready=1&duet=1&decade=1990` | `SearchResponse` |
| `GET /v1/songs/{id}/artwork` | JPEG |
| `GET /v1/songs/{id}/lyrics` | `Lyrics` |
| `GET /v1/singers` / `POST /v1/singers {"name","emoji"}` | `[Singer]` / `Singer` |
| `GET /v1/stats?period=tonight|year|allTime` | `StatsResponse` |
| `GET /v1/stats/singers/{id}` | `SingerStats` |
| `GET /v1/suggestions?singer={id}` | `[Suggestion]` |

Errors use HTTP 400, 401 or 404 with `{"code","message"}`; the message is ready to show to people.

## Live WebSocket

Every message is `{"type": "...", "data": {...}}`.

The pad sends `{"type":"auth","data":{"token":"..."}}` first. The Mac answers `hello` then a full `state`.

Mac to pad: `hello`, `state` (full `LiveState` on every change), `position` (`positionMs`, `at`, `lineIndex`, once a second while playing), `progress` (separation progress per song), `youreUp` (`songsAway`, `entryID`, `singerID`), `toast`, `error`.

Pad to Mac: `enqueue` (`songID`, `singerIDs`, `playNext`), `remove` (`entryID`), `move` (`entryID`, `toIndex`), `transport` (`command`: play, pause, skip, restart, stop), `seek` (`positionMs`), `setGuideVocal` (`value` 0 to 1), `updateSettings` (a whole `SingSettings`), `ping`.

Guests may enqueue and remove their own entries when the host allows it. Everything else needs the host role.

## Versioning

Adding fields or message types keeps the version. Decoders ignore unknown fields and fall back to defaults for missing ones (see `SingSettings`). Removing or changing the meaning of a field bumps `SingProtocol.version`, and the Mac keeps accepting older pads down to `minimumSupportedVersion`.
