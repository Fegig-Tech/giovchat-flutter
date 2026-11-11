/// The state the chat UI listens to. [GiovChatController] runs the whole visitor session on top of
/// [GiovChatClient]: it loads the configuration, resumes a stored conversation, starts one when the
/// visitor writes, keeps the socket up, catches up on history after every reconnect, resends the
/// outbox, shows streaming replies, counts unread replies and registers push tokens.
///
/// ```dart
/// final chat = GiovChatController(tenantKey: 'ws_123', contact: GiovContact(userId: id, userHash: hash));
/// await chat.start();
/// chat.addListener(() => setState(() {}));   // or ListenableBuilder(listenable: chat, …)
/// await chat.send('Hello');
/// ```
///
/// Call [dispose] when the screen is gone and forward app lifecycle changes to [handleLifecycle]
/// (or [pause] / [resume]).
library;

import 'dart:async';
import 'dart:math';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'attachments.dart';
import 'client.dart';
import 'errors.dart';
import 'i18n.dart';
import 'identity.dart';
import 'models.dart';
import 'outbox.dart';
import 'session_store.dart';
import 'socket.dart';
import 'unread.dart';

/// `ready`: the chat can be used but no conversation exists yet. Per the visitor protocol a native
/// client starts one when the visitor sends the first message (or submits the pre-chat form), so
/// opening the screen never creates an empty conversation. `idle`: hidden with nothing to resume.
enum GiovChatPhase { idle, loading, preChat, ready, connecting, active, error }

enum GiovConnectionStatus { connecting, connected, disconnected }

/// A file being uploaded; [progress] is 0 to 1.
class GiovUploadProgress {
  const GiovUploadProgress(this.name, this.progress);
  final String name;
  final double progress;
}

/// Contact fields the workspace requires and the host has not supplied (or that are malformed).
GiovRequestUserInfo missingContactFields(
    GiovRequestUserInfo fields, GiovContact contact) {
  bool missing(bool required, String? value, {bool email = false}) {
    if (!required) return false;
    final text = value?.trim() ?? '';
    return text.isEmpty ||
        (email && !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text));
  }

  return GiovRequestUserInfo(
    email: missing(fields.email, contact.email, email: true),
    phone: missing(fields.phone, contact.phone),
    firstName: missing(fields.firstName, contact.firstName),
    lastName: missing(fields.lastName, contact.lastName),
  );
}

/// By server id; a copy without a local key keeps the one it was shown under, so the bubble is not
/// redrawn. Sorted by creation time.
List<GiovMessage> mergeMessages(
    List<GiovMessage> current, List<GiovMessage> incoming) {
  final messages = {for (final message in current) message.id: message};
  for (final message in incoming) {
    final existing = messages[message.id];
    messages[message.id] =
        existing?.clientMessageId != null && message.clientMessageId == null
            ? message.copyWith(clientMessageId: existing!.clientMessageId)
            : message;
  }
  return messages.values.toList()
    ..sort((a, b) => a.createdAt != b.createdAt
        ? a.createdAt.compareTo(b.createdAt)
        : a.id.compareTo(b.id));
}

/// A reply being written.
class GiovDraft {
  const GiovDraft(this.content, this.createdAt);
  final String content;
  final int createdAt;
}

/// What the visitor sees: saved messages, then what is still sending, then replies being written.
/// [describe] supplies names and types for files sent from this device.
List<GiovMessage> displayMessages(
  List<GiovMessage> saved,
  List<OutboxEntry> pending,
  Map<String, GiovDraft> drafts, {
  GiovAttachment Function(String url)? describe,
}) {
  GiovAttachment known(String url) =>
      describe?.call(url) ?? GiovAttachment(url: url);
  final shown = {
    for (final message in saved)
      if (message.clientMessageId != null) message.clientMessageId!
  };
  final list = <GiovMessage>[
    for (final message in saved)
      if (message.attachments.isEmpty)
        message
      else
        message.copyWith(attachments: [
          for (final attachment in message.attachments)
            () {
              final local = known(attachment.url);
              return GiovAttachment(
                url: attachment.url,
                filename: attachment.filename.isNotEmpty
                    ? attachment.filename
                    : local.filename,
                preview: attachment.preview ?? local.preview,
                contentType: attachment.contentType ?? local.contentType,
              );
            }(),
        ]),
  ];
  for (final entry in pending) {
    if (shown.contains(entry.clientMessageId)) continue;
    list.add(GiovMessage(
      id: entry.clientMessageId,
      clientMessageId: entry.clientMessageId,
      role: GiovRole.visitor,
      content: entry.content,
      createdAt: entry.createdAt,
      delivery: entry.state == OutboxState.failed
          ? GiovDelivery.failed
          : GiovDelivery.sending,
      attachments: [for (final url in entry.attachments) known(url)],
    ));
  }
  for (final entry in drafts.entries) {
    final key = 'stream:${entry.key}';
    if (shown.contains(key) || entry.value.content.isEmpty) continue;
    list.add(GiovMessage(
      id: key,
      clientMessageId: key,
      role: GiovRole.agent,
      content: entry.value.content,
      createdAt: entry.value.createdAt,
      isBot: true,
      isAutomated: true,
      streamId: entry.key,
      isStreaming: true,
    ));
  }
  return list
    ..sort((a, b) => a.createdAt != b.createdAt
        ? a.createdAt.compareTo(b.createdAt)
        : a.id.compareTo(b.id));
}

/// How long after the last keystroke the agent stops seeing "typing" (the widget's value).
const typingIdle = Duration(milliseconds: 2500);

class GiovChatController extends ChangeNotifier {
  GiovChatController({
    required this.tenantKey,
    String baseUrl = giovDefaultBaseUrl,
    GiovContact? contact,
    String? sessionKey,
    GiovSessionStore? sessionStore,
    this.keepConnected = false,
    bool visible = true,
    String? locale,
    GiovChatStrings Function(GiovChatStrings base)? overrideStrings,
    this.backgroundGrace = const Duration(seconds: 5),
    this.onError,
    this.onConversationStart,
    this.onConnectionStatusChange,
    this.onUnreadCountChange,
    Outbox? outbox,
    http.Client? httpClient,
    GiovSocketFactory? socketFactory,
    DateTime Function()? now,
    Random? random,
  })  : baseUrl = normalizeBaseUrl(baseUrl),
        _baseContact = contact,
        _contact = contact ?? const GiovContact(),
        _store = sessionStore ?? InMemoryGiovSessionStore(),
        _visible = visible,
        _clock = now ?? DateTime.now,
        _random = random ?? Random(),
        strings = resolveGiovStrings(locale: locale, override: overrideStrings),
        outbox = outbox ??
            Outbox(
                now: now == null ? null : () => now().millisecondsSinceEpoch) {
    _client = GiovChatClient(
      tenantKey: tenantKey,
      baseUrl: baseUrl,
      outbox: this.outbox,
      flushOnOpen: false,
      locale: resolveGiovLocale(locale ?? giovDeviceLocale()),
      httpClient: httpClient,
      socketFactory: socketFactory,
      now: now,
      random: random,
    );
    _scope = giovSessionScope(this.baseUrl, tenantKey,
        contact: _contact, sessionKey: sessionKey);
    _outboxStop = this.outbox.subscribe(_changed);
  }

  final String tenantKey;
  final String baseUrl;

  /// Stay connected while the chat is not visible (app in the foreground) to count unread replies.
  /// Never starts a conversation.
  final bool keepConnected;

  /// How long the app may be in the background before the socket is closed (so pushes arrive).
  final Duration backgroundGrace;

  /// The interface text for the resolved language.
  final GiovChatStrings strings;

  /// Messages waiting for the server; survives reconnects.
  final Outbox outbox;

  final void Function(GiovChatException error)? onError;
  final void Function(String conversationId)? onConversationStart;
  final void Function(GiovConnectionStatus status)? onConnectionStatusChange;
  final void Function(int count)? onUnreadCountChange;

  final GiovContact? _baseContact;
  final GiovSessionStore _store;
  final DateTime Function() _clock;
  final Random _random;
  late final GiovChatClient _client;
  late final String _scope;
  late final void Function() _outboxStop;

  GiovContact _contact;
  GiovSession? _session;
  bool _loadedStore = false;
  bool _startNow = false;
  bool _started = false;
  Future<void>? _startRun;
  bool _disposed = false;
  bool _visible;
  bool _foreground = true;
  bool _wanted = false;
  int _generation = 0;
  Timer? _graceTimer;
  Timer? _typingTimer;

  /// A failed connection being retried with the protocol backoff.
  Timer? _retryTimer;
  int _retryAttempt = 0;

  /// The current conversation has been connected at least once (so a lost socket is "reconnecting").
  bool _hadConnection = false;
  DateTime? _accessRenewedAt;
  bool _typingSent = false;
  final List<StreamSubscription<Object?>> _subs = [];
  Future<void> Function()? _catchUp;
  ({
    String token,
    GiovPushPlatform platform,
    GiovPushOptions options,
    Completer<GiovPushResult> done
  })? _pushRequest;

  /// The last token the host registered; registered again for every new conversation.
  ({
    String token,
    GiovPushPlatform platform,
    GiovPushOptions options
  })? _pushToken;

  /// The conversation [_pushToken] was last registered for.
  String? _pushConversation;
  final Map<String, GiovAttachment> _localFiles = {};

  GiovChatPhase _phase = GiovChatPhase.loading;
  GiovWidgetConfig? _config;
  List<GiovMessage> _messages = const [];
  final Map<String, GiovDraft> _drafts = {};
  bool _agentTyping = false;
  bool? _agentTypingIsBot;
  String? _agentName;
  String? _agentAvatar;
  AttachmentAccess? _access;
  int _unread = 0;
  GiovChatException? _error;
  bool _sending = false;
  List<GiovUploadProgress> _uploads = const [];
  GiovRequestUserInfo _requiredFields = const GiovRequestUserInfo();
  bool _hasConversation = false;
  GiovConnectionStatus _status = GiovConnectionStatus.disconnected;
  GiovMessage? _lastIncoming;
  List<GiovMessage>? _display;

  // ---------------------------------------------------------------------------------------------
  // State for the UI

  GiovChatPhase get phase => _phase;

  /// Null until the configuration has loaded.
  GiovWidgetConfig? get config => _config;

  /// What to draw, oldest first: saved messages, sending ones, and streaming drafts.
  List<GiovMessage> get messages => _display ??=
      displayMessages(_messages, outbox.list(), _drafts, describe: _describe);

  /// Who the header shows (person, bot, team); null until the configuration has loaded.
  GiovHeaderIdentity? get header => _config == null
      ? null
      : headerIdentity(_config!,
          agentName: _agentName, agentAvatar: _agentAvatar);

  /// The latest reply that arrived live (team, GiovBot or a notice; not history), for announcing it.
  GiovMessage? get lastIncoming => _lastIncoming;

  /// The teammate who has the conversation, once known.
  String? get currentAgentName => _agentName;
  String? get currentAgentAvatar => _agentAvatar;

  /// The agent side is typing. When [agentTypingIsBot] is true, show the bot's indicator.
  bool get agentTyping => _agentTyping;
  bool? get agentTypingIsBot => _agentTypingIsBot;

  /// Replies the visitor has not seen because the chat was not visible; 0 while visible.
  int get unreadCount => _visible ? 0 : _unread;

  /// The last failure worth showing; use [GiovChatErrorText.describeError]. Cleared when sending resumes.
  GiovChatException? get error => _error;
  bool get sending => _sending;
  List<GiovUploadProgress> get uploads => _uploads;

  /// Pre-chat fields still to ask for (when [phase] is [GiovChatPhase.preChat]).
  GiovRequestUserInfo get requiredFields => _requiredFields;

  /// A conversation exists (so attachments can be uploaded).
  bool get hasConversation => _hasConversation;
  GiovConnectionStatus get connectionStatus => _status;

  /// A connection is being restored: the socket of a conversation that was connected dropped, or a
  /// failed attempt waits for its retry. Show [GiovChatStrings.reconnecting].
  bool get reconnecting =>
      _phase == GiovChatPhase.connecting &&
      (_retryTimer != null || _hadConnection);
  bool get isConnected => _status == GiovConnectionStatus.connected;
  bool get visible => _visible;

  /// The conversation id, once started.
  String? get conversationId => _session?.conversationId;

  /// The underlying client, for features this controller does not wrap.
  GiovChatClient get client => _client;

  // ---------------------------------------------------------------------------------------------
  // Lifecycle

  bool get _wantConnection => _foreground && (_visible || keepConnected);

  /// Loads the configuration, resumes a stored conversation (connecting at once) and otherwise waits
  /// for the visitor. Completes when that first pass has settled. Calling it again does nothing (the
  /// connection stays); use [retry] to start over.
  Future<void> start() {
    if (_started) return _startRun ?? Future.value();
    _started = true;
    return _startRun = _restart();
  }

  /// Shows or hides the chat. Showing clears unread replies; a hidden chat that is not
  /// [keepConnected] disconnects.
  void setVisible(bool value) {
    if (value == _visible || _disposed) return;
    _visible = value;
    if (value) {
      _unread = 0;
      _publishUnread();
      if (keepConnected && _phase == GiovChatPhase.idle && _started) {
        unawaited(_restart());
        return;
      }
    }
    _sync();
    _changed();
  }

  /// Forward `WidgetsBindingObserver.didChangeAppLifecycleState` here.
  void handleLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      resume();
    } else {
      pause();
    }
  }

  /// The app went to the background. The socket is closed after [backgroundGrace] so the server
  /// can push replies (a socket that keeps pinging counts as watching).
  void pause() {
    if (_disposed || !_foreground || _graceTimer != null) return;
    _graceTimer = Timer(backgroundGrace, () {
      _graceTimer = null;
      _foreground = false;
      _sync();
    });
  }

  /// The app returned to the foreground: reconnects if the socket was closed, otherwise reloads the
  /// history so nothing sent meanwhile is missed.
  void resume() {
    if (_disposed) return;
    _graceTimer?.cancel();
    _graceTimer = null;
    if (!_foreground) {
      _foreground = true;
      _sync();
      return;
    }
    if (_phase == GiovChatPhase.active) {
      final catchUp = _catchUp;
      if (catchUp != null) unawaited(catchUp());
    } else {
      _client.reconnectNow();
    }
  }

  /// Starts over after an error ([GiovChatPhase.error]) or to force a fresh connection.
  Future<void> retry() {
    _retryAttempt = 0;
    return _restart();
  }

  /// Forgets the conversation, the stored session and the outbox (sign-out, "new chat").
  Future<void> reset() async {
    _generation++;
    _stopTyping();
    _cancelSubs();
    _client.disconnect();
    _session = null;
    _contact = _baseContact ?? const GiovContact();
    _loadedStore = true;
    outbox.clear();
    _localFiles.clear();
    _startNow = false;
    _hasConversation = false;
    _messages = const [];
    _drafts.clear();
    _agentTyping = false;
    _agentTypingIsBot = null;
    _agentName = _agentAvatar = null;
    _access = null;
    _unread = 0;
    _publishUnread();
    _error = null;
    _hadConnection = false;
    _retryAttempt = 0;
    _pushToken = null;
    _pushConversation = null;
    _pushRequest?.done.complete(
        const GiovPushResult.notRegistered(GiovPushFailure.noConversation));
    _pushRequest = null;
    try {
      await _store.delete(_scope);
    } on Object {
      _report(const GiovStorageException(
          'Saved chat session could not be cleared.'));
    }
    if (_started) await _restart();
  }

  /// The pre-chat form was submitted: stores the contact details and starts the conversation.
  Future<void> submitContact(GiovContact info) {
    _contact = _contact.merge(info);
    _startNow = true;
    return _restart();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _graceTimer?.cancel();
    _typingTimer?.cancel();
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelSubs();
    _pushRequest?.done.complete(
        const GiovPushResult.notRegistered(GiovPushFailure.noConversation));
    _pushRequest = null;
    _outboxStop();
    GiovUnread.forget(this);
    _client.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------------------------
  // The session

  bool _alive(int generation) => !_disposed && generation == _generation;

  void _sync() {
    if (!_started || _disposed) return;
    if (_wantConnection != _wanted) unawaited(_restart());
  }

  Future<void> _restart() {
    if (_disposed) return Future.value();
    final generation = ++_generation;
    _retryTimer?.cancel();
    _retryTimer = null;
    _stopTyping();
    _cancelSubs();
    _client.disconnect();
    _wanted = _wantConnection;
    if (!_wanted) {
      _agentTyping = false;
      _agentTypingIsBot = null;
      _drafts.clear();
      _setStatus(GiovConnectionStatus.disconnected);
      _changed();
      return Future.value();
    }
    return _run(generation);
  }

  Future<void> _run(int generation) async {
    try {
      await _start(generation);
    } on Object catch (failure) {
      if (!_alive(generation)) return;
      _cancelSubs();
      _client.disconnect();
      final error = toGiovException(failure);
      if (error is GiovSessionExpiredException) await _clearSession();
      if (!_alive(generation)) return;
      _error = error;
      _setStatus(GiovConnectionStatus.disconnected);
      _report(error);
      // Like the web widget, a failure the network or the server may recover from is retried with
      // the protocol backoff; the conversation stays on screen while it is (once there is one to draw).
      final delay = _retryDelay(error);
      _phase = delay != null && _config != null
          ? GiovChatPhase.connecting
          : GiovChatPhase.error;
      if (delay != null) {
        _retryTimer = Timer(delay, () {
          _retryTimer = null;
          unawaited(_restart());
        });
      }
      _changed();
    }
  }

  /// When to try again after [error], or null when only the visitor can decide (Try again).
  Duration? _retryDelay(GiovChatException error) {
    final retryable = error is GiovNetworkException ||
        error is GiovRateLimitedException ||
        error is GiovWorkspaceBusyException ||
        (error is GiovServerException &&
            (error.status == null || error.status! >= 500));
    if (!retryable) return null;
    final backoff =
        giovReconnectDelay(_retryAttempt++, jitter: _random.nextDouble());
    final wait = switch (error) {
      GiovRateLimitedException(:final retryAfter) ||
      GiovWorkspaceBusyException(:final retryAfter) =>
        retryAfter,
      _ => Duration.zero,
    };
    return wait > backoff ? wait : backoff;
  }

  /// The session is gone (two 401s): end the chat and forget the stored pair.
  void _sessionGone(GiovChatException error) {
    _cancelSubs();
    _client.disconnect();
    _error = error;
    _phase = GiovChatPhase.error;
    _setStatus(GiovConnectionStatus.disconnected);
    unawaited(_clearSession());
    _changed();
  }

  Future<void> _clearSession() async {
    _session = null;
    _hasConversation = false;
    _hadConnection = false;
    _messages = const [];
    try {
      await _store.delete(_scope);
    } on Object {
      _report(const GiovStorageException(
          'Chat session could not be saved or restored.'));
    }
  }

  /// The conversation was closed or deleted: forget it; the visitor's next message starts a new one.
  Future<void> _forget(int generation) async {
    if (!_alive(generation)) return;
    _cancelSubs();
    _client.disconnect();
    await _clearSession();
    if (!_alive(generation)) return;
    _agentName = _agentAvatar = null;
    _drafts.clear();
    _agentTyping = false;
    _agentTypingIsBot = null;
    _phase = GiovChatPhase.ready;
    _setStatus(GiovConnectionStatus.disconnected);
    _error =
        const GiovConversationClosedException('This conversation has ended.');
    _changed();
  }

  Future<void> _start(int generation) async {
    bool alive() => _alive(generation);
    _phase = _config == null
        ? GiovChatPhase.loading
        : (_session != null ? GiovChatPhase.connecting : GiovChatPhase.ready);
    _error = null;
    _agentTyping = false;
    _agentTypingIsBot = null;
    _sending = false;
    _setStatus(GiovConnectionStatus.connecting);
    _changed();
    final config = _config ?? await _client.fetchWidgetConfig();
    if (!alive()) return;
    _config = config;
    _changed();
    if (!_loadedStore) {
      _loadedStore = true;
      try {
        final stored = await _store.read(_scope);
        if (!alive()) return;
        if (isValidStoredSession(stored)) _session = stored;
      } on Object {
        _report(const GiovStorageException(
            'Chat session could not be saved or restored.'));
      }
    }
    if (!alive()) return;
    final existing = _session;
    if (existing != null) {
      try {
        _session = await _client.resumeConversation(existing, _contact);
      } on GiovChatException catch (failure) {
        if (!alive()) return;
        if (failure is! GiovSessionExpiredException &&
            failure is! GiovConversationClosedException &&
            failure.status != 404) {
          rethrow;
        }
        await _clearSession();
      }
    }
    if (!alive()) return;
    // Hidden and nothing to resume: wait until the chat is opened instead of starting a conversation.
    if (!_visible && _session == null) {
      _phase = GiovChatPhase.idle;
      _setStatus(GiovConnectionStatus.disconnected);
      _changed();
      return;
    }
    _requiredFields = missingContactFields(config.requestUserInfo, _contact);
    if (_session == null && _requiredFields.any) {
      _phase = GiovChatPhase.preChat;
      _setStatus(GiovConnectionStatus.disconnected);
      _changed();
      return;
    }
    if (_session == null && !_startNow) {
      _phase = GiovChatPhase.ready;
      _setStatus(GiovConnectionStatus.disconnected);
      _changed();
      return;
    }
    _phase = GiovChatPhase.connecting;
    _changed();
    if (_session == null) {
      final created = await _client.startConversation(_contact);
      if (!alive()) return;
      _startNow = false;
      _session = created;
      try {
        await _store.write(_scope, created);
      } on Object {
        _report(const GiovStorageException(
            'Chat session could not be saved or restored.'));
      }
      if (!alive()) return;
      try {
        onConversationStart?.call(created.conversationId);
      } on Object {
        // Host callbacks are isolated.
      }
    }
    final session = _session;
    if (!alive() || session == null) return;
    _hasConversation = true;
    _changed();

    var openedOnce = false;
    _subs
      ..add(_client.messages.listen((message) {
        if (!alive()) return;
        _messages = mergeMessages(_messages, [message]);
        if (message.role == GiovRole.agent) {
          _lastIncoming = message;
          _agentTyping = false;
          _agentTypingIsBot = null;
          final name = message.senderName?.trim();
          if (message.isFromPerson && name != null && name.isNotEmpty) {
            _agentName = name;
            _agentAvatar = message.senderAvatar;
          }
          if (!_visible) {
            _unread += 1;
            _publishUnread();
          }
        }
        _changed();
      }))
      ..add(_client.acks.listen((ack) {
        if (!alive()) return;
        _messages = mergeMessages(_messages,
            [ack.message.copyWith(clientMessageId: ack.clientMessageId)]);
        _changed();
      }))
      ..add(_client.streamEvents.listen((event) {
        if (!alive()) return;
        switch (event) {
          case GiovStreamEnd():
            if (_drafts.remove(event.streamId) == null) return;
          case GiovStreamUpdate():
            _drafts[event.streamId] = GiovDraft(
                event.content,
                _drafts[event.streamId]?.createdAt ??
                    _clock().millisecondsSinceEpoch);
            if (event.content.isNotEmpty) _agentTyping = false;
        }
        _changed();
      }))
      ..add(_client.attachmentAccess.listen((value) {
        if (alive()) _captureAccess(value);
      }))
      ..add(_client.typing.listen((event) {
        if (!alive()) return;
        // A stop for the other kind keeps the indicator (a person's typing_end must not hide the bot's).
        final otherKind = event.isBot != null &&
            _agentTypingIsBot != null &&
            event.isBot != _agentTypingIsBot;
        if (!event.active && _agentTyping && otherKind) return;
        _agentTyping = event.active;
        _agentTypingIsBot = event.active ? event.isBot : null;
        _changed();
      }))
      ..add(_client.errors.listen((failure) {
        if (!alive()) return;
        _report(failure);
        if (failure is GiovConversationClosedException) {
          unawaited(_forget(generation));
          return;
        }
        _error = failure;
        if (failure is GiovSessionExpiredException) {
          _phase = GiovChatPhase.error;
          unawaited(_clearSession());
        }
        _changed();
      }));

    // Catch-up: history merged by id with what arrived meanwhile, then the outbox is resent.
    Future<void> refreshHistory() async {
      GiovHistory history;
      try {
        history = await _client.fetchHistory();
      } on GiovChatException catch (failure) {
        if (failure.status == 404) {
          await _forget(generation);
          return;
        }
        rethrow;
      }
      if (!alive()) return;
      if (history.closed) {
        await _forget(generation);
        return;
      }
      _captureAccess(history.attachmentAccess);
      _agentName = history.assignedAgentName;
      _agentAvatar = history.assignedAgentAvatar;
      _messages = mergeMessages(_messages, history.messages);
      _changed();
      _client.flush();
    }

    // A catch-up while connected (after a reconnect or on app resume) that fails: a dead session ends
    // the chat; anything else is shown, and the outbox is still resent, since resends are idempotent
    // and nothing else would flush it on this socket.
    Future<void> catchUp() => refreshHistory().catchError((Object failure) {
          if (!alive()) return;
          final error = toGiovException(failure);
          _report(error);
          if (error is GiovSessionExpiredException) {
            _sessionGone(error);
            return;
          }
          _error = error;
          // Resends are idempotent, and nothing else would flush the outbox on this socket.
          _client.flush();
          _changed();
        });

    _catchUp = catchUp;
    _subs.add(_client.connection.listen((connected) {
      if (!alive()) return;
      if (!connected) {
        _agentTyping = false;
        _agentTypingIsBot = null;
        // A reply being written is lost with the socket; the saved copy arrives with the catch-up.
        _drafts.clear();
      }
      _setStatus(connected
          ? GiovConnectionStatus.connected
          : GiovConnectionStatus.disconnected);
      _phase = connected ? GiovChatPhase.active : GiovChatPhase.connecting;
      if (connected) {
        _error = null;
        // Catch up on whatever arrived while the socket was down.
        if (openedOnce) unawaited(catchUp());
        openedOnce = true;
        _hadConnection = true;
        _retryAttempt = 0;
        final push = _pushRequest;
        final remembered = _pushToken;
        if (push != null) {
          _pushRequest = null;
          unawaited(_registerPush(push.token, push.platform, push.options)
              .then(push.done.complete));
        } else if (remembered != null &&
            _pushConversation != session.conversationId) {
          // A new conversation for the same visitor: the device registers again without the host.
          unawaited(_registerPush(
              remembered.token, remembered.platform, remembered.options));
        }
      }
      _changed();
    }));
    await _client.connect(session);
    if (!alive()) return;
    await refreshHistory();
  }

  void _cancelSubs() {
    for (final subscription in _subs) {
      unawaited(subscription.cancel());
    }
    _subs.clear();
    _catchUp = null;
  }

  // ---------------------------------------------------------------------------------------------
  // Sending

  /// What a file picked now may be: the answering bot's policy against the server's limits.
  ({List<GiovPickedFile> accepted, List<AttachmentProblem> problems})
      checkFiles(List<GiovPickedFile> files, {int alreadyAttached = 0}) =>
          validateAttachments(files,
              (_config ?? const GiovWidgetConfig(title: '')).attachmentPolicy,
              existingCount: alreadyAttached);

  /// Sends text and files. Files upload first (they need the conversation); the message then waits
  /// in the outbox until a socket takes it, so text typed while reconnecting is never lost. Several
  /// files go as one message each after the text, as in the widget. Resolves false when nothing
  /// was queued (empty, wrong phase, or an upload failed; see [error]).
  Future<bool> send(String text,
      {List<GiovPickedFile> files = const []}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && files.isEmpty) return false;
    if (_phase != GiovChatPhase.active &&
        _phase != GiovChatPhase.connecting &&
        _phase != GiovChatPhase.ready) {
      return false;
    }
    // Uploads need a live conversation; the attach button only appears once one exists.
    if (files.isNotEmpty && _session == null) return false;
    final generation = _generation;
    _stopTyping();
    _error = null;
    final urls = <String>[];
    if (files.isNotEmpty) {
      if (!_client.isConnected && _client.session == null) {
        _error = const GiovNetworkException(
            'Chat is reconnecting. Please try again.');
        _changed();
        return false;
      }
      _sending = true;
      _uploads = [for (final file in files) GiovUploadProgress(file.name, 0)];
      _changed();
      try {
        for (var index = 0; index < files.length; index++) {
          final file = files[index];
          final result =
              await _client.uploadAttachment(file, onProgress: (progress) {
            if (_generation != generation || _disposed) return;
            _uploads = [
              for (var i = 0; i < _uploads.length; i++)
                i == index
                    ? GiovUploadProgress(_uploads[i].name, progress)
                    : _uploads[i]
            ];
            _changed();
          });
          final preview = result.preview ??
              (file.width != null && file.height != null
                  ? GiovAttachmentPreview(
                      width: file.width, height: file.height)
                  : null);
          _localFiles[result.url] = GiovAttachment(
            url: result.url,
            filename: result.filename.isNotEmpty ? result.filename : file.name,
            contentType: file.mimeType,
            preview: preview,
          );
          urls.add(result.url);
        }
      } on Object catch (failure) {
        if (_generation == generation && !_disposed) {
          final cause = toGiovException(failure);
          _report(cause);
          if (cause is GiovConversationClosedException) {
            // 404: the conversation is gone; the visitor's next message starts a new one.
            unawaited(_forget(generation));
          } else if (cause is GiovSessionExpiredException) {
            _sessionGone(cause);
          } else {
            _error = cause;
          }
        }
        return false;
      } finally {
        if (_generation == generation && !_disposed) {
          _sending = false;
          _uploads = const [];
          _changed();
        }
      }
      if (_generation != generation) return false;
    }
    final parts = urls.length > 1
        ? [
            if (trimmed.isNotEmpty) (content: trimmed, attachments: <String>[]),
            for (final url in urls) (content: '', attachments: [url])
          ]
        : [(content: trimmed, attachments: urls)];
    try {
      for (final part in parts) {
        outbox.enqueue(part.content,
            attachments: part.attachments,
            now: _clock().millisecondsSinceEpoch);
      }
    } on GiovChatException catch (failed) {
      _report(failed);
      _error = failed;
      _changed();
      return false;
    }
    if (_session != null) {
      _client.flush();
    } else if (!_startNow) {
      // The first message starts the conversation; it goes out once the socket is open.
      _startNow = true;
      unawaited(_restart());
    }
    _changed();
    return true;
  }

  /// Tries a failed message again ("tap to retry"); it is sent in its original place in the queue.
  void retryMessage(String clientMessageId) {
    if (outbox.retry(clientMessageId)) _client.flush();
  }

  /// Removes a failed message the visitor does not want to retry.
  void discardMessage(String clientMessageId) => outbox.remove(clientMessageId);

  /// Call on every keystroke: the agent sees "typing" once per burst and it ends after a pause.
  void notifyTyping() {
    if (!_client.isConnected) return;
    if (!_typingSent) {
      _client.sendTyping();
      _typingSent = true;
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(typingIdle, () {
      _typingTimer = null;
      _typingSent = false;
      _client.sendTypingEnd();
    });
  }

  void _stopTyping() {
    _typingTimer?.cancel();
    _typingTimer = null;
    if (_typingSent) _client.sendTypingEnd();
    _typingSent = false;
  }

  /// A download URL for an attachment with exactly one credential (the attachment access token,
  /// else the visitor token).
  ///
  /// On a long session the tokens run out: an unusable access token renews the visitor token (and
  /// with it the access token) in the background, at most once a minute, as the web widget does.
  String attachmentUrl(String url) {
    final now = _clock();
    final access = _access;
    final usable = access != null && access.usableAt(now) ? access.token : null;
    if (usable == null) _renewAttachmentAccess(now);
    return attachmentDisplayUrl(url,
        accessToken: usable, visitorToken: _client.usableVisitorToken);
  }

  void _renewAttachmentAccess(DateTime now) {
    final last = _accessRenewedAt;
    if (_disposed ||
        _client.session == null ||
        (last != null && now.difference(last) < const Duration(minutes: 1))) {
      return;
    }
    _accessRenewedAt = now;
    scheduleMicrotask(() async {
      if (_disposed) return;
      // A new access token redraws through the attachmentAccess stream; a new visitor token alone here.
      if (await _client.renewVisitorToken()) _changed();
    });
  }

  /// Registers the device for push now when connected, or as soon as the conversation connects.
  /// Never throws. Call again whenever the platform hands out a new token.
  ///
  /// Before any conversation exists the request waits for the first one (the visitor's first
  /// message); [dispose] resolves it as [GiovPushFailure.noConversation]. The token is remembered
  /// and registered again for every new conversation (after the team closes one) until [reset] or
  /// [unregisterPushToken].
  Future<GiovPushResult> registerPushToken(
      String token, GiovPushPlatform platform,
      {GiovPushOptions options = const GiovPushOptions()}) {
    if (_disposed) {
      return Future.value(
          const GiovPushResult.notRegistered(GiovPushFailure.noConversation));
    }
    _pushToken = (token: token, platform: platform, options: options);
    if (_client.isConnected) return _registerPush(token, platform, options);
    _pushRequest?.done
        .complete(const GiovPushResult.notRegistered(GiovPushFailure.failed));
    final done = Completer<GiovPushResult>();
    _pushRequest =
        (token: token, platform: platform, options: options, done: done);
    return done.future;
  }

  Future<GiovPushResult> _registerPush(
      String token, GiovPushPlatform platform, GiovPushOptions options) async {
    final conversationId = _client.session?.conversationId;
    final result = await _client.registerPushToken(token, platform, options);
    if (result.registered && _pushToken?.token == token) {
      _pushConversation = conversationId;
    }
    return result;
  }

  /// Stops push notifications about this conversation on this device and forgets the token. Never
  /// throws. Works while the chat is closed or disconnected (it uses the stored session); call it
  /// before [reset] or a change of `sessionKey`, which forget that session.
  Future<bool> unregisterPushToken(String token) async {
    if (_disposed) return false;
    if (_pushToken?.token == token) {
      _pushToken = null;
      _pushConversation = null;
    }
    final pending = _pushRequest;
    if (pending != null && pending.token == token) {
      _pushRequest = null;
      pending.done
          .complete(const GiovPushResult.notRegistered(GiovPushFailure.failed));
    }
    var session = _session;
    if (session == null && !_loadedStore) {
      try {
        final stored = await _store.read(_scope);
        if (isValidStoredSession(stored)) session = stored;
      } on Object {
        // Nothing stored to unregister from.
      }
    }
    if (_disposed) return false;
    return _client.unregisterPushToken(token, session: session);
  }

  // ---------------------------------------------------------------------------------------------
  // Plumbing

  GiovAttachment _describe(String url) =>
      _localFiles[url] ?? GiovAttachment(url: url);

  void _captureAccess(AttachmentAccess? incoming) {
    final next = AttachmentAccess.newer(_access, incoming);
    if (!identical(next, _access)) {
      _access = next;
      _changed();
    }
  }

  void _publishUnread() {
    GiovUnread.publish(this, tenantKey, unreadCount);
    try {
      onUnreadCountChange?.call(unreadCount);
    } on Object {
      // Host callbacks are isolated.
    }
  }

  void _setStatus(GiovConnectionStatus value) {
    _status = value;
    try {
      onConnectionStatusChange?.call(value);
    } on Object {
      // Host callbacks are isolated.
    }
  }

  void _report(GiovChatException failure) {
    try {
      onError?.call(failure);
    } on Object {
      // Host callbacks are isolated.
    }
  }

  void _changed() {
    _display = null;
    if (!_disposed) notifyListeners();
  }
}
