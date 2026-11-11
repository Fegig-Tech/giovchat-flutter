/// The WebSocket seam. The client talks to [GiovSocket], so tests (and apps with special needs)
/// can supply their own; the default wraps `web_socket_channel`.
library;

import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

/// One conversation socket. Callbacks are set right after creation and fire asynchronously.
abstract class GiovSocket {
  /// The upgrade succeeded.
  void Function()? onOpen;

  /// A text frame.
  void Function(String data)? onMessage;

  /// The connection failed or broke; [onClose] follows.
  void Function(Object error)? onError;

  /// The socket is finished (also after a failed attempt, with null code). Close code `1000` with
  /// reason `Conversation deleted` means the conversation is gone (README, "Connecting").
  void Function(int? code, String? reason)? onClose;

  bool get isOpen;
  void send(String frame);
  void close([int? code, String? reason]);
}

/// Creates a socket for `ws(s)://…/conversations/{id}/ws?role=user&token=…`. Start connecting at once.
typedef GiovSocketFactory = GiovSocket Function(Uri url);

GiovSocket defaultGiovSocketFactory(Uri url) => ChannelGiovSocket(url);

/// True when a failed upgrade was answered 410 (the conversation was deleted). dart:io reports it
/// as "... was not upgraded to websocket, HTTP status code: 410"; only the status is matched, never
/// the URL, since conversation ids are UUIDs and may contain "410".
bool isConversationDeletedUpgradeError(Object error) =>
    RegExp(r'status code:?\s*410\b', caseSensitive: false)
        .hasMatch(error.toString());

/// [GiovSocket] over `web_socket_channel` (dart:io and the browser).
class ChannelGiovSocket extends GiovSocket {
  ChannelGiovSocket(Uri url) : _channel = WebSocketChannel.connect(url) {
    _channel.ready.then<void>((_) {
      if (_ended) return;
      _open = true;
      onOpen?.call();
    }, onError: _fail);
    _channel.stream.listen(
      (data) {
        if (data is String && !_ended) onMessage?.call(data);
      },
      onError: _fail,
      onDone: () => _finish(_channel.closeCode, _channel.closeReason),
    );
  }

  final WebSocketChannel _channel;
  bool _open = false;
  bool _ended = false;

  @override
  bool get isOpen => _open && !_ended;

  void _fail(Object error, [StackTrace? _]) {
    if (_ended) return;
    onError?.call(error);
    final deleted = isConversationDeletedUpgradeError(error);
    _finish(deleted ? 1000 : null, deleted ? 'Conversation deleted' : null);
  }

  void _finish(int? code, String? reason) {
    if (_ended) return;
    _ended = true;
    _open = false;
    onClose?.call(code, reason);
  }

  @override
  void send(String frame) {
    if (!isOpen) throw StateError('Socket is not open.');
    _channel.sink.add(frame);
  }

  @override
  void close([int? code, String? reason]) {
    _open = false;
    try {
      unawaited(_channel.sink.close(code, reason).catchError((Object _) {}));
    } on Object {
      // Already closed.
    }
  }
}
