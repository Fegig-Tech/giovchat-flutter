# Changelog

All notable changes to this package are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the package uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-13

### Added

- **Footer follows your style:** `GiovChatStyleOverrides.branding` (`GiovBrandingOverride`: `fontFamily`, `color`, `brandColor`, `backgroundColor`) and the top-level `fontFamily` now apply to the "Powered by GiovChat" footer. It stays on (only the plan's `showBranding: false` removes it); its layout, size and text stay fixed. Colours must be opaque and reach 4.5:1 contrast against the footer background; transparent or low-contrast colours fall back to the default for that property, with a message in debug builds (`resolveGiovFooterStyle`).
- **`GiovBranding`:** a drop-in footer widget for custom UIs built on `GiovChatController` or `GiovChatClient`. It reads `showBranding` (a `showBranding:` bool, a `controller:` or a `tenantKey:`) and the same style overrides. Starter and Pro workspaces are asked to show it.
- **Immediate close and reopen:** the `conversation_state` socket frame's `status` (`open` or `closed`, sent on close and reopen) switches the chat to the read-only view with **Start a new conversation**, or back to the normal composer, without waiting for the next history catch-up. Older servers send no `status`: the history decides there. `GiovChatClient.conversationStates` exposes the frame (`GiovConversationState`). A `rating` frame without `comment` clears the answer's comment.
- README: complete style-override reference and a "Build your own UI" section.
- **Conversation ratings:** the chat draws the rating card ("How did we do?") from the team, GiovBot or the workspace's close-time setting: five labelled faces (a radio-style group for screen readers), an optional comment (1,000 characters), Send, then Thanks with the chosen face. The visitor can change the answer until the server's `closesAt`; the card is read-only after it, hidden when replaced (by the `rating` socket frame with `state: "replaced"` or by a newer card), and patched live when the answer changes on another device. Server refusals (`rating_closed`, `request_replaced`, `too_many_changes`, `rate_limited`) are handled in the card.
- **Answer feedback:** thumbs up/down under each finished GiovBot answer (not under its rating request), with an optional reason after a thumbs-down; history rows restore the visitor's vote.
- **Public API:** `GiovChatController.ratingRequest`, `ratingsSupported`, `ratingEvents` (`GiovRatingRequestedEvent`, `GiovRatingSubmittedEvent`, `GiovAnswerFeedbackEvent`), `submitRating`, `submitAnswerFeedback` and the callbacks `onRatingRequested`, `onRatingSubmitted`, `onAnswerFeedback`; `GiovChat(ratingCard:, answerFeedback:, …)`; `GiovChatState.showRating`, `submitRating`, `submitAnswerFeedback`, `ratingRequest`; `showGiovRatingSheet(context, controller)`; `GiovChatClient.submitRating`, `submitAnswerFeedback`, `ratingFrames`, `ratingsUnsupported`; `GiovRatingException` with `GiovRatingProblem`; the models `GiovRatingBlock`, `GiovRatingRequest`, `GiovRatingResult`, `GiovRatingFrame`, `GiovFeedbackValue` and `GiovMessage.rating` / `feedback`; the pure helpers `patchRating`, `supersedeRatings`, `pendingRatingRequest`, `ratingPhase`, `nextFeedback`.
- **Strings:** the rating strings in English, French, Spanish, Portuguese and German (optional constructor parameters of `GiovChatStrings`, so existing code keeps compiling).
- **Closed conversations:** when the team closes a conversation (history says `closed`, or resume answers 409 and its history can still be read) it stays on screen read-only: the history is visible, a rating card stays answerable until `closesAt` (including an "ask on close" card that arrives after the close), and the composer is replaced by a **Start a new conversation** button (five languages, `GiovChatStrings.startNewConversation`). `GiovChatController.closed` and `startNewConversation()` clear the closed conversation; the next message creates the new one. If the server refuses the history of a closed conversation, it is forgotten as before. A close is noticed at the next history catch-up (no live close frame exists in the protocol yet).
- Against an older server (404 on the new routes) the thumbs are hidden; unknown blocks and frames are ignored. The example app shows a "Rate your chat" entry point.

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
