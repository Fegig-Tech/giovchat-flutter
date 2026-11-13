/// Pure rules for conversation ratings and the thumbs under GiovBot answers (docs/protocol,
/// "Conversation ratings"): patching a card from a socket frame, which card is open, and how the
/// documented refusals map to typed errors.
library;

import 'errors.dart';
import 'models.dart';

/// The comment of a rating is at most this long (characters).
const maxRatingComment = 1000;

/// The reason after a thumbs-down is at most this long (characters).
const maxFeedbackReason = 300;

/// Sets the answer, deadline and state on the card a frame (or an answer) names; other messages
/// are returned unchanged. A frame without a score means "no answer yet".
List<GiovMessage> patchRating(
    List<GiovMessage> messages, GiovRatingFrame frame) {
  var changed = false;
  final next = [
    for (final message in messages)
      if ((frame.messageId != null && message.id != frame.messageId) ||
          message.rating?.requestId != frame.requestId)
        message
      else
        () {
          changed = true;
          final block = message.rating!;
          return message.withRating(block.copyWith(
            closesAt: frame.closesAt,
            clearAnswer: true,
            score: frame.score,
            comment: frame.comment,
            replaced: frame.replaced || block.replaced,
          ));
        }(),
  ];
  return changed ? next : messages;
}

/// One open card per conversation: an older card the visitor never answered is replaced by a newer
/// one (also before the server's own `replaced` mark arrives). Answered cards keep their answer.
List<GiovMessage> supersedeRatings(List<GiovMessage> messages) {
  var latest = -1;
  for (var i = 0; i < messages.length; i++) {
    final card = messages[i].rating;
    if (card != null && !card.replaced) latest = i;
  }
  var changed = false;
  final next = [
    for (var i = 0; i < messages.length; i++)
      if (messages[i].rating == null ||
          messages[i].rating!.replaced ||
          i == latest ||
          messages[i].rating!.answered)
        messages[i]
      else
        () {
          changed = true;
          return messages[i]
              .withRating(messages[i].rating!.copyWith(replaced: true));
        }(),
  ];
  return changed ? next : messages;
}

/// How a card looks at [now]: hidden (replaced), open (can be answered or changed) or closed
/// (read-only: the clock reached `closesAt`; the server decides).
enum GiovRatingPhase { hidden, open, closed }

GiovRatingPhase ratingPhase(GiovRatingBlock block, int nowMs) => block.replaced
    ? GiovRatingPhase.hidden
    : nowMs < block.closesAt
        ? GiovRatingPhase.open
        : GiovRatingPhase.closed;

/// The card the visitor can answer or change at [nowMs], or null.
GiovRatingRequest? pendingRatingRequest(List<GiovMessage> messages, int nowMs) {
  GiovMessage? found;
  for (final message in supersedeRatings(messages)) {
    final card = message.rating;
    if (card != null && ratingPhase(card, nowMs) == GiovRatingPhase.open) {
      found = message;
    }
  }
  final card = found?.rating;
  if (found == null || card == null) return null;
  return GiovRatingRequest(
    requestId: card.requestId,
    messageId: found.id,
    closesAt: card.closesAt,
    answered: card.answered,
    score: card.score,
    comment: card.comment,
    url: card.url,
  );
}

/// A refusal for one card: closed makes it read-only now, replaced hides it.
List<GiovMessage> markRating(
    List<GiovMessage> messages, String requestId, GiovRatingProblem problem,
    {required int nowMs}) {
  return [
    for (final message in messages)
      if (message.rating?.requestId != requestId)
        message
      else if (problem == GiovRatingProblem.requestReplaced)
        message.withRating(message.rating!.copyWith(replaced: true))
      else if (problem == GiovRatingProblem.ratingClosed)
        message.withRating(message.rating!.copyWith(
            closesAt: message.rating!.closesAt < nowMs
                ? message.rating!.closesAt
                : nowMs))
      else
        message,
  ];
}

/// What tapping a thumb sends: the same thumb again takes the vote back.
GiovFeedbackValue nextFeedback(
        GiovFeedbackValue? current, GiovFeedbackValue tapped) =>
    current == tapped ? GiovFeedbackValue.none : tapped;

/// Replaces (or removes) the visitor's thumb on a message.
List<GiovMessage> applyFeedback(
        List<GiovMessage> messages, String id, GiovFeedbackValue? value) =>
    [
      for (final message in messages)
        message.id == id ? message.withFeedback(value) : message,
    ];

/// Thumbs go under finished GiovBot answers, never under the rating request itself.
bool canVoteOn(GiovMessage message) =>
    message.role == GiovRole.agent &&
    message.isBot &&
    !message.isStreaming &&
    !message.id.startsWith('stream:') &&
    message.rating == null;

/// The documented refusals of the rating and feedback routes as typed errors. A 404 with no code is
/// a server without the routes ([GiovRatingProblem.unsupported]).
GiovChatException ratingFailure(
    int status, Map<String, Object?> body, Duration retryAfter) {
  final code = body['error'] is String ? body['error']! as String : null;
  const known = {
    'invalid_rating': GiovRatingProblem.invalidRating,
    'invalid_feedback': GiovRatingProblem.invalidFeedback,
    'request_not_found': GiovRatingProblem.requestNotFound,
    'message_not_found': GiovRatingProblem.messageNotFound,
    'request_replaced': GiovRatingProblem.requestReplaced,
    'rating_closed': GiovRatingProblem.ratingClosed,
    'too_many_changes': GiovRatingProblem.tooManyChanges,
  };
  final problem = known[code];
  if (problem != null) {
    return GiovRatingException(problem, 'Rating was refused.',
        status: status, code: code);
  }
  if (status == 404 || status == 405 || status == 501) {
    return GiovRatingException(
        GiovRatingProblem.unsupported, 'This chat does not take ratings.',
        status: status, code: code);
  }
  if (status == 401 || status == 403) {
    return GiovSessionExpiredException(
        'Chat session expired. Please start a new chat.',
        status: status,
        code: code);
  }
  if (status == 429) {
    return GiovRateLimitedException('Too many requests.',
        retryAfter: retryAfter, status: status);
  }
  return GiovServerException('Chat is unavailable.',
      status: status, code: code);
}
