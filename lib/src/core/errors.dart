/// Typed failures. The SDK never shows a server's `error` code to people; the UI maps each type
/// to a translated sentence (see `GiovChatStrings`).
library;

sealed class GiovChatException implements Exception {
  const GiovChatException(this.message, {this.status, this.code});

  /// For logs, in English. Not for people.
  final String message;

  /// The HTTP status, when the failure came from a response.
  final int? status;

  /// The server's `error` code, when it sent one.
  final String? code;

  @override
  String toString() =>
      '$runtimeType: $message${status != null ? ' ($status${code != null ? ' $code' : ''})' : ''}';
}

/// The network could not be reached, or a request timed out.
class GiovNetworkException extends GiovChatException {
  const GiovNetworkException(super.message, {this.timedOut = false});
  final bool timedOut;
}

/// The stored session is gone (expired, foreign, deleted). The SDK forgets it; the next message
/// starts a new conversation.
class GiovSessionExpiredException extends GiovChatException {
  const GiovSessionExpiredException(super.message, {super.status, super.code});
}

/// The team closed the conversation. The next message starts a new one.
class GiovConversationClosedException extends GiovChatException {
  const GiovConversationClosedException(super.message,
      {super.status, super.code});
}

/// `429 rate_limited`: wait [retryAfter] before trying again.
class GiovRateLimitedException extends GiovChatException {
  const GiovRateLimitedException(super.message,
      {required this.retryAfter,
      super.status = 429,
      super.code = 'rate_limited'});
  final Duration retryAfter;
}

/// `503 workspace_busy`: the workspace is at its plan's limit of open conversations.
class GiovWorkspaceBusyException extends GiovChatException {
  const GiovWorkspaceBusyException(super.message,
      {required this.retryAfter,
      super.status = 503,
      super.code = 'workspace_busy'});
  final Duration retryAfter;
}

/// `401 invalid_user_hash`: the workspace requires a signed identity and the one given is wrong.
class GiovIdentityRejectedException extends GiovChatException {
  const GiovIdentityRejectedException(super.message,
      {super.status = 401, super.code = 'invalid_user_hash'});
}

/// An upload was refused (type, size, or the bot's attachment policy).
class GiovAttachmentRejectedException extends GiovChatException {
  const GiovAttachmentRejectedException(super.message,
      {super.status, super.code});
}

/// A message could not be delivered (refused frame, or three failed saves).
class GiovSendFailedException extends GiovChatException {
  const GiovSendFailedException(super.message, {super.code});
}

/// The server answered something the protocol does not allow.
class GiovInvalidResponseException extends GiovChatException {
  const GiovInvalidResponseException(super.message, {super.status});
}

/// The chat was closed (or the client disposed) while a call was in flight.
class GiovDisconnectedException extends GiovChatException {
  const GiovDisconnectedException([super.message = 'Chat closed.']);
}

/// The [GiovSessionStore] failed to read, write or delete the stored session.
class GiovStorageException extends GiovChatException {
  const GiovStorageException(super.message);
}

/// Any other refusal (`404 tenant_not_found`, `403 origin_not_allowed`, `5xx`, …).
class GiovServerException extends GiovChatException {
  const GiovServerException(super.message, {super.status, super.code});
}
