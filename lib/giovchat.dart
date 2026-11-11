/// Giov visitor chat for Flutter: the ready-made chat screen ([GiovChat]) on top of the core layer.
///
/// [GiovChat] is the full chat screen; embed it in any route or sheet.
/// Start with [GiovChatController]: it runs a whole visitor session and is a `ChangeNotifier` for
/// the chat screen. [GiovChatClient] is the protocol transport underneath, for apps that build
/// their own state handling. Both implement the Giov visitor protocol v1 (https://giovchat.app/docs).
library giovchat;

export 'src/core/attachments.dart';
export 'src/core/client.dart'
    show
        GiovAck,
        GiovChatClient,
        GiovPushEnvironment,
        GiovPushFailure,
        GiovPushOptions,
        GiovPushPlatform,
        GiovPushResult,
        GiovStreamEnd,
        GiovStreamEvent,
        GiovStreamUpdate,
        GiovTypingEvent,
        GiovUploadResult,
        giovClientMarker,
        giovDefaultBaseUrl,
        giovReconnectDelay,
        giovSdkVersion,
        normalizeBaseUrl,
        socketOpenTimeout,
        socketPingInterval,
        socketPongTimeout;
export 'src/core/controller.dart'
    show
        GiovChatController,
        GiovChatPhase,
        GiovConnectionStatus,
        GiovDraft,
        GiovUploadProgress,
        displayMessages,
        mergeMessages,
        missingContactFields,
        typingIdle;
export 'src/core/errors.dart';
export 'src/core/i18n.dart';
export 'src/core/identity.dart';
export 'src/core/markdown.dart';
export 'src/core/models.dart' hide asMap, tryJsonDecode;
export 'src/core/outbox.dart';
export 'src/core/session_store.dart';
export 'src/core/socket.dart';
export 'src/core/unread.dart';
export 'src/ui/bubbles.dart' show GiovBotMark;
export 'src/ui/chat_markdown.dart' show ChatMarkdown;
export 'src/ui/giov_chat.dart' show GiovChat, GiovChatState;
export 'src/ui/look.dart'
    show GiovUrlOpener, defaultGiovUrlOpener, parseBrandColor;
export 'src/ui/style_overrides.dart';
