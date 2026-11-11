import 'package:flutter/material.dart';
import 'package:giovchat/giovchat.dart';

/// Your workspace key, from the Giov dashboard.
const tenantKey = 'YOUR_TENANT_KEY';

void main() => runApp(const ExampleApp());

// SECURE STORAGE
// The session token proves that this device owns the conversation. Keep it in the Keychain /
// Keystore, never in SharedPreferences. With `flutter_secure_storage`:
//
//   class SecureSessionStore implements GiovSessionStore {
//     const SecureSessionStore([this._storage = const FlutterSecureStorage()]);
//     final FlutterSecureStorage _storage;
//     // A stable key per scope (hashCode is not stable across runs and may collide).
//     String _key(String scope) => 'giovchat.${base64Url.encode(utf8.encode(scope))}';
//
//     @override
//     Future<GiovSession?> read(String scope) async {
//       final value = await _storage.read(key: _key(scope));
//       return value == null ? null : GiovSession.fromJson(jsonDecode(value) as Map<String, Object?>);
//     }
//
//     @override
//     Future<void> write(String scope, GiovSession session) =>
//         _storage.write(key: _key(scope), value: jsonEncode(session.toJson()));
//
//     @override
//     Future<void> delete(String scope) => _storage.delete(key: _key(scope));
//   }
//
// Then pass `sessionStore: const SecureSessionStore()` below. Without it the conversation is
// forgotten when the app process ends.

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Giov chat example',
        theme: ThemeData(
            colorSchemeSeed: const Color(0xFF7C3AED), useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // One controller for the whole app session: it keeps the conversation, counts unread replies
  // while the chat is closed (keepConnected) and survives opening and closing the chat screen.
  late final GiovChatController _chat = GiovChatController(
    tenantKey: tenantKey,
    keepConnected: true,
    visible: false, // The chat screen is not open yet.
    // sessionStore: const SecureSessionStore(),
    // For signed-in users, compute `userHash` on YOUR server (HMAC-SHA256 of userId with the
    // identity secret from Settings → Chat widget → Visitor details) and pass it down:
    // contact: GiovContact(userId: user.id, userHash: user.giovUserHash, email: user.email),
    onError: (error) => debugPrint('Giov chat: $error'),
  );

  @override
  void initState() {
    super.initState();
    _chat
        .start(); // Resumes a stored conversation so the badge counts replies. Never starts one.
    // PUSH NOTIFICATIONS
    // Register the raw device token once the app has one, and again whenever it changes:
    //
    //   FirebaseMessaging.instance.getToken().then((token) {
    //     if (token != null) {
    //       _chat.registerPushToken(
    //         token,
    //         GiovPushPlatform.fcm, // or GiovPushPlatform.apns for a raw APNs token
    //         // iOS debug builds get sandbox APNs tokens:
    //         options: GiovPushOptions(environment: kDebugMode ? GiovPushEnvironment.sandbox : GiovPushEnvironment.production),
    //       );
    //     }
    //   });
    //   FirebaseMessaging.instance.onTokenRefresh.listen((token) => _chat.registerPushToken(token, ...));
    //
    // Tokens come from your push setup: the FCM token from `firebase_messaging` on Android, and on
    // iOS either the FCM token (if you use Firebase Messaging) or the raw APNs token. The workspace
    // adds its Apple key / Firebase service account in the Giov dashboard under
    // Settings → Chat widget → Push notifications.
    //
    // A tapped notification carries {type: 'giov.message', tenantId, conversationId, messageId}
    // (under `giov` on APNs, in `data` on FCM); open the chat screen and it catches up from history.
  }

  @override
  void dispose() {
    _chat.dispose();
    super.dispose();
  }

  void _openChat() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          // The chat draws its own header; `onClose` adds the close button.
          body: GiovChat(
            controller: _chat,
            autoStart: false, // Already started in initState.
            onClose: () => Navigator.of(context).pop(),
            // attachmentPicker: pickFiles, // See the README for a file_picker / image_picker adapter.
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Giov chat example')),
        body: Center(
          child: ValueListenableBuilder<int>(
            valueListenable: GiovUnread.watch(tenantKey),
            builder: (context, unread, _) => Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: FilledButton.icon(
                onPressed: _openChat,
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Chat with us'),
              ),
            ),
          ),
        ),
      );
}
