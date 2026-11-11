# Changelog

All notable changes to this package are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the package uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0]

First release, at parity with the React Native SDK 0.2 and the Giov visitor protocol v1.

### Chat screen

- `GiovChat`: the full chat screen (embeddable in any route or sheet) on a controller you pass or one it creates. Draws every phase (loading skeleton, pre-chat form, greeting, connecting, active, error with retry), forwards app lifecycle changes and visibility to the controller, and keeps content clear of notches and the keyboard.
- Header with bot / teammate / team identity, avatar with GiovBot mark or initial fallback, and status line; message list that follows the newest message and keeps its position while the visitor reads older ones; bubbles with Chat Markdown (only http(s) and mailto links open, via `url_launcher`); streaming drafts replaced in place by the saved reply; sender labels; failed messages with retry and discard; typing indicator (bot vs person); attachments (picker adapter, policy errors, upload progress, image previews with authenticated URLs, file rows); multiline composer with typing notifications; "Powered by GiovChat" footer when the workspace's plan shows it.
- Light, dark and auto theme from the dashboard or the `theme` prop, the dashboard's brand colour, and `GiovChatStyleOverrides` for fonts and colours per surface.
- Accessibility: semantic labels, 44 pt minimum tap targets, live regions for errors and typing, text scaling capped at 200%.
- `GiovChatStrings.discard` (the label of the Discard button) in all five languages.
- `example/` app and a README covering install, platform setup, controller vs widget, secure session storage, identity, attachments, unread badge, push notifications, languages and theming.

### Core

- `GiovChatController`: a `ChangeNotifier` running a whole visitor session (phase, messages, header identity, typing, unread count, errors, uploads). Starts a conversation only on the first message or the pre-chat form, resumes a stored one at once, forgets it when it is closed, deleted or the session expires, reloads history after every reconnect and on app resume, resends the outbox after the catch-up.
- `GiovChatClient`: widget config (with `X-Giov-Client: flutter/<version>`), start/resume, visitor tokens renewed before expiry, the `role=user` WebSocket (10 s open timeout, ping every 25 s, 10 s pong deadline, reconnect backoff `min(1500 x 2^n, 15000)` ms plus jitter), history, streaming replies (`stream` / `stream_end`), typing in and out, attachment upload with progress, attachment access tokens, and push registration (`registerPushToken` / `unregisterPushToken`, never throws, stops asking when the server answers 404/405/501).
- `Outbox`: stable client message ids, ordered resend, 10 s ack timeout, save-failure retries after 2 s and 4 s, then "not sent" with retry/discard.
- `GiovSessionStore` with an in-memory default; back it with Keychain/Keystore storage in production.
- Header and sender identity (person, bot, team), visitor identity (`userId` + `userHash`), unread counts with `keepConnected`.
- Strings in English, French, Spanish, Portuguese and German, device-locale resolution and overrides.
- Chat Markdown parser checked against the protocol's conformance vectors (`test/fixtures/markdown-vectors.json`).
- Transport is injectable (`http.Client`, `GiovSocketFactory`, clock) for tests.
