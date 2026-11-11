/// Who the visitor is talking to and who wrote each message (README, "Identity"), as the web
/// widget shows it (`apps/widget-web/src/components/header-identity.ts`, `message-identity.ts`).
library;

import 'i18n.dart';
import 'models.dart';

enum GiovHeaderKind { person, bot, team }

/// What the chat header shows.
class GiovHeaderIdentity {
  const GiovHeaderIdentity(
      {required this.kind, required this.title, this.avatar});

  final GiovHeaderKind kind;
  final String title;

  /// An http(s) image URL, or null (show the initial).
  final String? avatar;

  /// The status line under the title.
  String status(GiovChatStrings strings) => switch (kind) {
        GiovHeaderKind.person => strings.statusPerson,
        GiovHeaderKind.bot => strings.statusBot,
        GiovHeaderKind.team => strings.statusTeam,
      };

  @override
  bool operator ==(Object other) =>
      other is GiovHeaderIdentity &&
      other.kind == kind &&
      other.title == title &&
      other.avatar == avatar;

  @override
  int get hashCode => Object.hash(kind, title, avatar);

  @override
  String toString() => 'GiovHeaderIdentity($kind, $title, $avatar)';
}

/// First match wins: a person once one has written or history names an assigned teammate; else the
/// bot while it answers (`botEnabled` and `botName`); else the team (`title`, `avatarUrl`).
GiovHeaderIdentity headerIdentity(GiovWidgetConfig config,
    {String? agentName, String? agentAvatar}) {
  if (agentName != null && agentName.isNotEmpty) {
    return GiovHeaderIdentity(
        kind: GiovHeaderKind.person,
        title: agentName,
        avatar: safeImageUrl(agentAvatar));
  }
  final botName = config.botName;
  if (config.botEnabled && botName != null && botName.isNotEmpty) {
    return GiovHeaderIdentity(
        kind: GiovHeaderKind.bot,
        title: botName,
        avatar: safeImageUrl(config.botAvatarUrl));
  }
  return GiovHeaderIdentity(
      kind: GiovHeaderKind.team,
      title: config.title,
      avatar: safeImageUrl(config.avatarUrl));
}

/// The label above a bubble. AI replies are also automated internally; the AI identity wins.
/// [agentName] is the assigned teammate, used for people's messages that carry no name (history).
String messageSenderLabel(GiovMessage message, GiovChatStrings strings,
    {String? botName, String? agentName}) {
  if (message.role != GiovRole.agent) return strings.you;
  if (message.isBot) {
    final name = botName?.trim();
    return name != null && name.isNotEmpty ? name : 'GiovBot';
  }
  if (message.isAutomated) return strings.automated;
  final sender = message.senderName?.trim();
  if (sender != null && sender.isNotEmpty) return sender;
  final assigned = agentName?.trim();
  return assigned != null && assigned.isNotEmpty ? assigned : strings.agent;
}

/// Whether the agent-side typing indicator shows and whether it is the bot's.
class GiovTypingState {
  const GiovTypingState({this.visible = false, this.isBot});

  final bool visible;

  /// Null when the server did not say; only explicit metadata brands the indicator as the AI.
  final bool? isBot;

  @override
  bool operator ==(Object other) =>
      other is GiovTypingState &&
      other.visible == visible &&
      other.isBot == isBot;

  @override
  int get hashCode => Object.hash(visible, isBot);
}

/// Applies a `typing` / `typing_end` frame. A `typing_end` for the other kind (bot vs team) keeps
/// the current indicator.
GiovTypingState reduceAgentTyping(
    GiovTypingState current, Map<String, Object?> frame) {
  if (frame['role'] != 'agent') return current;
  final isBot = frame['isBot'] is bool ? frame['isBot']! as bool : null;
  if (frame['type'] == 'typing') {
    return GiovTypingState(visible: true, isBot: isBot);
  }
  if (frame['type'] == 'typing_end') {
    if (isBot != null && current.isBot != null && isBot != current.isBot) {
      return current;
    }
    return const GiovTypingState();
  }
  return current;
}
