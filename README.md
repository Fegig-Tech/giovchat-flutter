# giovchat (Flutter)

The Giov live chat for Flutter apps: the same conversation your website visitors have with the web widget, as a native screen. Widget settings (colours, greeting, pre-chat fields, GiovBot name and avatar, attachment policy, branding) are managed in the **Agent Dashboard**; the SDK fetches them with your tenant key.

It matches the React Native SDK 0.2 and implements the Giov visitor protocol v1. Full documentation: [giovchat.app/docs](https://giovchat.app/docs).

What you get:

- Replies stream in as GiovBot writes them, formatted with Chat Markdown (bold, lists, links, code, quotes). Only `http(s)` and `mailto` links open.
- The header shows who is answering: GiovBot (name and avatar) while it answers, the teammate's name and photo once a person takes over, otherwise your team.
- Messages typed offline or while reconnecting wait in an outbox and go out in order once the connection is back, each under one id so it is never stored twice. Failures show **Not sent · Tap to retry** with a Discard button.
- After a dropped connection or when the app returns to the foreground the chat reconnects and catches up on what it missed.
- Typing indicators both ways, attachments with upload progress and previews, an unread count while the chat is closed, push notifications.
- Interface text in English, French, Spanish, Portuguese and German, following the device language.
- Light, dark or automatic theme; the dashboard's brand colour.

A conversation starts when the visitor sends the first message (or submits the pre-chat form), so opening the chat never creates an empty conversation. A stored conversation is always resumed first; a closed one is forgotten and the next message starts a new one.

## Install

```sh
flutter pub add giovchat
```

Requires Flutter 3.22 or newer (Dart 3.4). The SDK depends only on `http`, `http_parser`, `web_socket_channel` and `url_launcher`. File picking, secure storage and push tokens use your app's own packages through small adapters (below), so you add only the plugins you use.

Material icons are used: keep `uses-material-design: true` in your `pubspec.yaml` (the default for new apps).

## Platform setup

The chat itself needs network access and nothing else:

- **Android:** release builds need `<uses-permission android:name="android.permission.INTERNET"/>` in `android/app/src/main/AndroidManifest.xml` (Flutter's template declares it only for debug and profile builds).
- **macOS:** add `<key>com.apple.security.network.client</key><true/>` to both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`.
- **iOS, web, Windows, Linux:** nothing to add.

Links and attachments open with `url_launcher`'s `launchUrl` (no `canLaunchUrl` check), so no `<queries>` or `LSApplicationQueriesSchemes` entries are needed. Replace it with `onOpenUrl` if you prefer.

### Attachment pickers

The attach button appears only when you pass an `attachmentPicker`, and the SDK ships none. The examples below use [`file_picker`](https://pub.dev/packages/file_picker), [`image_picker`](https://pub.dev/packages/image_picker) and [`mime`](https://pub.dev/packages/mime); each plugin's own README is the reference for its setup. What they need:

| Platform | `image_picker` (photos) | `file_picker` (documents) |
|---|---|---|
| iOS (`ios/Runner/Info.plist`) | `NSPhotoLibraryUsageDescription`; also `NSCameraUsageDescription` if you take photos and `NSMicrophoneUsageDescription` if you record video | `NSPhotoLibraryUsageDescription` if you pick from the photo library (`FileType.image` / `media`); none for documents |
| Android | nothing (it uses the system photo picker) | nothing (it uses the system document picker) |
| macOS (both `.entitlements` files) | `com.apple.security.files.user-selected.read-only` | `com.apple.security.files.user-selected.read-only` |
| Web | works; files come back as bytes or a stream | works; use `withData: true`, file paths are not available |

For example, in `Info.plist`:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Choose photos to send in the support chat.</string>
<key>NSCameraUsageDescription</key>
<string>Take a photo to send in the support chat.</string>
```

### Web

- Inline images (attachments and teammate avatars) load with `Image.network`. With the CanvasKit and skwasm renderers the browser fetches the bytes itself, so the image host must send CORS headers (`Access-Control-Allow-Origin`). An image that is blocked shows a placeholder icon (an avatar falls back to the initial); tapping it still opens the file.
- The session store runs in the browser: `flutter_secure_storage` on web keeps data in browser storage, which is not a hardware-backed keystore. Leave the default in-memory store if you do not need the conversation to survive a reload.
- Push registration is for APNs and FCM device tokens from mobile apps.

## Quick start

The chat is a widget: put it in any route, sheet or tab.

```dart
import 'package:giovchat/giovchat.dart';

Navigator.of(context).push(MaterialPageRoute<void>(
  builder: (context) => Scaffold(
    body: GiovChat(
      tenantKey: 'YOUR_TENANT_KEY',
      onClose: () => Navigator.of(context).pop(), // shows a close button
    ),
  ),
));
```

`GiovChat` creates, starts and disposes its own controller, handles every phase (loading, pre-chat form, greeting, connecting, active, error with retry), forwards app lifecycle changes, and keeps content clear of notches and the keyboard. Inside a bottom sheet that already does that, pass `safeArea: false`.

## Controller or widget

`GiovChat` is a thin screen on top of `GiovChatController`, a `ChangeNotifier` that runs the whole visitor session (phase, messages, header identity, typing, unread count, errors, uploads). Use the widget for the ready-made UI, the controller on its own for a custom UI, or both:

```dart
final chat = GiovChatController(tenantKey: 'YOUR_TENANT_KEY', keepConnected: true, visible: false);
await chat.start();

// Later, anywhere: the ready-made screen on the controller you own.
GiovChat(controller: chat, autoStart: false, onClose: () => Navigator.pop(context));
```

With a controller you own, `GiovChat` never disposes it, and when the screen is removed it marks the chat not visible so a `keepConnected` controller keeps counting unread replies. Call `chat.dispose()` yourself.

### `GiovChat` parameters

| Parameter | Description |
|---|---|
| `controller` / `tenantKey` | Pass exactly one. A `tenantKey` makes the widget create its own controller from the options below. |
| `baseUrl`, `contact`, `sessionKey`, `sessionStore`, `keepConnected`, `onError`, `onConversationStart`, `onConnectionStatusChange`, `onUnreadCountChange` | Options for the controller the widget creates. `contact` also pre-fills the pre-chat form. Changing `tenantKey`, `contact.userId` or `sessionKey` starts a fresh controller; other contact edits keep the conversation. |
| `visible` | Whether the chat is on screen (default `true`). A hidden chat disconnects unless `keepConnected`; showing it clears unread replies. |
| `autoStart` | Start the controller on mount (default `true`). `start()` on a controller that is already started does nothing, so a running connection is kept either way; `retry()` is the explicit restart. |
| `onClose` | Shows a close button in the header. |
| `theme` | `GiovThemeMode.light`, `dark` or `auto`. Overrides the dashboard setting. |
| `primaryColor` | Overrides the dashboard's brand colour. |
| `styleOverrides` | Fonts and colours per surface (below). |
| `locale`, `strings` | Interface language (`'fr'`, `'pt-BR'`, …) and string replacements. |
| `attachmentPicker` | Your file/image picker. Without it the attach button is hidden. |
| `onOpenUrl` | How links and attachments open (default: `url_launcher`). Only `http(s)` and `mailto` links reach it. |
| `safeArea` | Keep clear of notches and the home indicator (default `true`). |

Through a `GlobalKey<GiovChatState>` you get `controller`, `reset()` and `registerPushToken(…)`.

## Session storage

By default nothing is persisted: the conversation is forgotten when the app process ends. Pass a `GiovSessionStore` to resume the same conversation next time. **The session token is a private credential**: back the store with the Keychain / Keystore (for example `flutter_secure_storage`), never plain `SharedPreferences`, never log it.

```dart
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:giovchat/giovchat.dart';

class SecureSessionStore implements GiovSessionStore {
  const SecureSessionStore([this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;
  // A stable key per scope (hashCode is not stable across runs and may collide).
  String _key(String scope) => 'giovchat.${base64Url.encode(utf8.encode(scope))}';

  @override
  Future<GiovSession?> read(String scope) async {
    final value = await _storage.read(key: _key(scope));
    return value == null ? null : GiovSession.fromJson(jsonDecode(value) as Map<String, Object?>);
  }

  @override
  Future<void> write(String scope, GiovSession session) => _storage.write(key: _key(scope), value: jsonEncode(session.toJson()));

  @override
  Future<void> delete(String scope) => _storage.delete(key: _key(scope));
}

GiovChat(tenantKey: 'YOUR_TENANT_KEY', sessionStore: const SecureSessionStore());
```

## Signed-in users

```dart
GiovChat(
  tenantKey: 'YOUR_TENANT_KEY',
  contact: GiovContact(userId: user.id, userHash: user.giovUserHash, email: user.email, firstName: user.firstName),
  sessionKey: user.id,
);
```

- `userHash` is the HMAC-SHA256 (lowercase hex) of `userId` with the visitor identity secret from **Settings → Chat widget → Visitor details**. Compute it on your server and send it to the app; never ship the secret. Without `userHash`, `userId` is an unverified claim and does not link the chat to an existing contact.
- Any contact field you supply skips the matching pre-chat field.
- **Sign-out and account switching:** first `await chat.unregisterPushToken(token)` (it needs the conversation), then change `sessionKey` (or call `reset()`). The previous identity's session, queued messages, unread count and remembered push token are dropped.
- The stored conversation is keyed by the workspace, `sessionKey` and `userId` only, so editing a name, email or phone keeps it.

## Attachments

Attachments appear once the conversation has started, when you pass an `attachmentPicker` **and** the published GiovBot agent allows them (Dashboard → GiovBot → agent settings). Visitors can pick only the types and sizes the agent allows, up to 5 files per message; the server checks again. The SDK ships no picker: return `GiovPickedFile`s from yours, or `[]` when the visitor cancels. The request tells you the allowed MIME types, the file count and the size limit.

```dart
// file_picker: documents and images
Future<List<GiovPickedFile>> pickFiles(GiovPickerRequest request) async {
  final result = await FilePicker.platform.pickFiles(allowMultiple: request.maxFiles > 1, withData: true);
  if (result == null) return const [];
  return [
    for (final file in result.files.take(request.maxFiles))
      if (file.bytes != null)
        GiovPickedFile.bytes(name: file.name, mimeType: lookupMimeType(file.name) ?? 'application/octet-stream', bytes: file.bytes!),
  ];
}
```

```dart
// image_picker: photos (also pass width/height when you know them, so every viewer sees the shape before it loads)
Future<List<GiovPickedFile>> pickPhotos(GiovPickerRequest request) async {
  final images = await ImagePicker().pickMultiImage(limit: request.maxFiles < 2 ? null : request.maxFiles, imageQuality: 85);
  return [
    for (final image in images)
      GiovPickedFile.stream(
        name: image.name,
        mimeType: image.mimeType ?? 'image/jpeg',
        size: await image.length(),
        openRead: image.openRead,
      ),
  ];
}
```

Then `GiovChat(tenantKey: …, attachmentPicker: pickFiles)`. `lookupMimeType` comes from the `mime` package. See [Attachment pickers](#attachment-pickers) for the Info.plist keys and entitlements these plugins need. Files with an unknown type are refused by the policy check with a message; uploads show progress in the composer; images appear inline in a box of their final shape, other files as rows that open through an authenticated link.

## Unread badge

By default the chat connects only while it is visible. To count replies that arrive while it is closed, keep a controller alive with `keepConnected: true` and `visible: false`. It only resumes an existing conversation and never starts one in the background. Read the count anywhere, without passing the controller around:

```dart
ValueListenableBuilder<int>(
  valueListenable: GiovUnread.watch('YOUR_TENANT_KEY'),   // omit the key to sum all workspaces
  builder: (context, unread, _) => Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.chat_bubble_outline)),
);
```

Opening the chat clears the count. See [`example/`](example/lib/main.dart) for a complete app.

## Push notifications

Your app gets a notification when the team or GiovBot replies while the chat is not open. In the Giov dashboard, a workspace adds its Apple Push key and/or Firebase service account under **Settings → Chat widget → Push notifications**; notifications are sent with your keys, from your app.

Register the **raw** device token once your app has one, and again whenever it changes: the APNs token on iOS (or the FCM token if your iOS app uses Firebase Messaging), the FCM token on Android.

```dart
final token = await FirebaseMessaging.instance.getToken();
if (token != null) {
  await chat.registerPushToken(
    token,
    GiovPushPlatform.fcm,                       // or GiovPushPlatform.apns for a raw APNs token
    options: GiovPushOptions(
      environment: kDebugMode ? GiovPushEnvironment.sandbox : GiovPushEnvironment.production, // APNs only
    ),
  );
}
FirebaseMessaging.instance.onTokenRefresh.listen((token) => chat.registerPushToken(token, GiovPushPlatform.fcm));
```

Pass `environment: GiovPushEnvironment.sandbox` from iOS **debug** builds (Xcode installs get sandbox APNs tokens); TestFlight and App Store builds use production.

It registers immediately when connected, otherwise as soon as the conversation connects, and never throws. Before any conversation exists the call waits for the first one (the visitor's first message); disposing the controller resolves it as `GiovPushResult.notRegistered(GiovPushFailure.noConversation)`, so do not block app start on it. The token is remembered: when the team closes a conversation and the visitor starts a new one, the device is registered for it automatically. Against a server without visitor push it resolves `GiovPushResult.notRegistered(GiovPushFailure.unsupported)` after one probe and makes no further requests.

On sign-out call `await chat.unregisterPushToken(token)` **before** `reset()` or changing `sessionKey`: it works while the chat is closed or disconnected (it uses the stored session with a fresh visitor token), but `reset()` forgets that session and the remembered token.

A tapped notification carries `{type: 'giov.message', tenantId, conversationId, messageId}` (under the `giov` key on APNs, in `data` on FCM). Open the chat screen and it catches up from history.

## Languages

The interface follows the device language (English, French, Spanish, Portuguese, German; others use English). Text the business writes in the dashboard (greeting, placeholder, bot name) is shown as written.

```dart
GiovChat(
  tenantKey: '…',
  locale: 'pt-BR',
  strings: (base) => base.copyWith(sendMessage: 'Enviar', startChat: 'Começar'),
);
```

Any string can be replaced through `copyWith`; empty values are ignored. `giovStrings` exports the built-in tables. With a controller you own, the language is the controller's (`GiovChatController(locale: …)`) unless you set `locale` or `strings` on `GiovChat`.

## Theming

- **Theme:** the dashboard setting (`light`, `dark`, `auto`) applies; `auto` follows the device. Override it with `theme`.
- **Colour:** the dashboard's primary colour paints the header, the visitor's bubbles and the buttons; override it with `primaryColor`. Foreground colours switch between white and near-black to stay readable.
- **Fonts and colours of each surface:** `styleOverrides`.

```dart
GiovChat(
  tenantKey: '…',
  styleOverrides: const GiovChatStyleOverrides(
    fontFamily: 'YourAppFont', // Register this font in your app first.
    container: Color(0xFFF8FAFC),
    header: Color(0xFF0F172A),
    headerTitle: GiovTextOverride(color: Colors.white, fontWeight: FontWeight.w700),
    headerSubtitle: GiovTextOverride(color: Color(0xFFCBD5E1)),
    agentBubble: Color(0xFFE2E8F0),
    agentText: GiovTextOverride(color: Color(0xFF0F172A)),
    visitorBubble: Color(0xFF2563EB),
    visitorText: GiovTextOverride(color: Colors.white),
    composer: Color(0xFFF8FAFC),
    input: GiovTextOverride(color: Color(0xFF0F172A)),
    inputBackground: Colors.white,
    button: Color(0xFF2563EB),
    buttonText: GiovTextOverride(color: Colors.white),
  ),
);
```

| Slot | Applies to |
|---|---|
| `container`, `header`, `composer`, `form` (colour) | Chat surface, header, composer row, pre-chat form |
| `agentBubble`, `visitorBubble` (colour) | Agent / greeting / typing bubbles and the visitor's bubbles |
| `button` (colour), `buttonText` | Send, start-chat and retry buttons |
| `headerTitle`, `headerSubtitle` | Header text; the title colour also applies to the close icon |
| `agentText`, `visitorText` | Message content, sender labels and timestamps; agent text also covers the greeting and typing bubbles |
| `formTitle`, `label`, `hint`, `errorText` | Form heading and labels, loading hint / attachment chips / placeholders, errors |
| `input`, `inputBackground` | Composer and pre-chat inputs |

The top-level `fontFamily` is the default for customizable text; a slot's `fontFamily` takes precedence. Font sizes, spacing, dimensions, borders and the branding footer stay SDK-controlled.

### Branding and plans

The widget reads `showBranding` from the server's `/widget/config` response. Starter and Pro plans always display **Powered by GiovChat**; higher plans can remove it in the dashboard. Branding stays visible when the field is missing or the configuration cannot be loaded; only an explicit server `false` hides it. Its colours are isolated from all style overrides. If you build your own UI on the controller, honour `controller.config?.showBranding` yourself.

## Accessibility

Controls, the message input and the pre-chat fields have semantic labels in the chosen language and at least 44 x 44 pt tap targets; the header is a heading; errors, the reconnecting notice, the typing indicator and file problems are live regions; replies that arrive while the chat is open are announced once they are complete; links in messages are exposed as link actions. Text on the brand colour is white or near-black, whichever has the higher WCAG contrast, and small labels (sender, time) keep 4.5:1. Text follows the device's font scale (capped at 200% inside the chat so the layout holds).

The header has a privacy button that opens the workspace's `privacyPolicyUrl` (Giov's privacy page when none is set), as in the web widget. A connection that fails or drops is retried with the protocol backoff, with a "Connection lost. Reconnecting…" notice, and the composer stays editable while files upload. Messages are limited to 2000 UTF-16 code units, as the server counts them; a longer paste is cut at the limit.

## Testing

The transport is injectable: `GiovChatController` takes an `http.Client`, a `GiovSocketFactory` and a clock, as the package's `test/` folder shows.

## Licence

MIT. See [LICENSE](LICENSE).
