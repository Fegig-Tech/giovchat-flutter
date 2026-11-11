/// Data the visitor protocol carries (docs/protocol/visitor-api.openapi.yaml and
/// visitor-realtime.asyncapi.yaml), parsed defensively: unknown fields are ignored and malformed
/// values fall back instead of throwing, as the protocol's versioning rules require.
library;

import 'dart:convert';

import 'attachments.dart';

/// The widget's default brand colour when the configured one cannot be parsed.
const defaultPrimaryColor = '#7c3aed';

Map<String, Object?> asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

String? _string(Object? value) => value is String ? value : null;
String? _nonEmpty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

/// An http(s) URL, or null. Images and links from the network are used only when they pass.
String? safeHttpUrl(Object? value) {
  final text = _nonEmpty(value);
  return text != null &&
          RegExp(r'^https?:\/\/', caseSensitive: false).hasMatch(text)
      ? text
      : null;
}

/// Only http(s) images are loaded; anything else falls back to an initial.
String? safeImageUrl(Object? value) => safeHttpUrl(value);

/// `light`, `dark`, or `auto` (follow the device).
enum GiovThemeMode { light, dark, auto }

/// Fields the workspace asks for in a pre-chat form before the first message.
class GiovRequestUserInfo {
  const GiovRequestUserInfo(
      {this.email = false,
      this.phone = false,
      this.firstName = false,
      this.lastName = false});

  factory GiovRequestUserInfo.fromJson(Object? json) {
    final map = asMap(json);
    return GiovRequestUserInfo(
      email: map['email'] == true,
      phone: map['phone'] == true,
      firstName: map['firstName'] == true,
      lastName: map['lastName'] == true,
    );
  }

  final bool email;
  final bool phone;
  final bool firstName;
  final bool lastName;

  bool get any => email || phone || firstName || lastName;
}

/// `GET /widget/config`: everything the business set up for its chat.
class GiovWidgetConfig {
  const GiovWidgetConfig({
    required this.title,
    this.primaryColor = defaultPrimaryColor,
    this.greetingText = 'Hi! How can we help?',
    this.textArea,
    this.theme = GiovThemeMode.auto,
    this.botEnabled = false,
    this.botName,
    this.botAvatarUrl,
    this.avatarUrl,
    this.attachments,
    this.showBranding = true,
    this.privacyPolicyUrl,
    this.requestUserInfo = const GiovRequestUserInfo(),
    this.launcherStyle = 'bubble',
  });

  factory GiovWidgetConfig.fromJson(Map<String, Object?> json) {
    final themeName = json['theme'];
    return GiovWidgetConfig(
      title: _nonEmpty(json['title']) ?? 'Support',
      primaryColor: _string(json['primaryColor']) ?? defaultPrimaryColor,
      greetingText: _string(json['greetingText']) ?? 'Hi! How can we help?',
      textArea: _nonEmpty(json['textArea']),
      theme: GiovThemeMode.values.firstWhere((mode) => mode.name == themeName,
          orElse: () => GiovThemeMode.auto),
      botEnabled: json['botEnabled'] == true,
      botName: _nonEmpty(json['botName']),
      botAvatarUrl: safeImageUrl(json['botAvatarUrl']),
      avatarUrl: safeImageUrl(json['avatarUrl']),
      attachments: GiovAttachmentPolicy.fromJson(json['attachments']),
      // Only an explicit false removes the branding (a server-resolved plan policy).
      showBranding: json['showBranding'] != false,
      privacyPolicyUrl: safeHttpUrl(json['privacyPolicyUrl']),
      requestUserInfo: GiovRequestUserInfo.fromJson(json['requestUserInfo']),
      launcherStyle: json['launcherStyle'] == 'pill' ? 'pill' : 'bubble',
    );
  }

  /// The team's name, for the header when neither a person nor the bot answers.
  final String title;

  /// Brand colour as sent, usually `#rrggbb`.
  final String primaryColor;

  /// Shown before the visitor writes. Plain text.
  final String greetingText;

  /// Composer placeholder.
  final String? textArea;
  final GiovThemeMode theme;
  final bool botEnabled;
  final String? botName;
  final String? botAvatarUrl;
  final String? avatarUrl;

  /// The answering GiovBot's attachment rules; null when no bot is published (then images only).
  final GiovAttachmentPolicy? attachments;
  final bool showBranding;
  final String? privacyPolicyUrl;
  final GiovRequestUserInfo requestUserInfo;

  /// `bubble` or `pill`.
  final String launcherStyle;

  /// What a visitor may attach right now: the bot's policy, or the server's default (images).
  GiovAttachmentPolicy get attachmentPolicy =>
      attachments ?? GiovAttachmentPolicy.defaultPolicy;
}

/// Contact details the host app knows. All untrusted except a `userId` with its `userHash`.
class GiovContact {
  const GiovContact(
      {this.userId,
      this.userHash,
      this.email,
      this.phone,
      this.firstName,
      this.lastName});

  /// Your stable customer id. Trusted only together with [userHash].
  final String? userId;

  /// `HMAC-SHA256(identity secret, userId)`, lowercase hex, computed on YOUR server. Never ship the
  /// identity secret in an app.
  final String? userHash;
  final String? email;
  final String? phone;
  final String? firstName;
  final String? lastName;

  GiovContact merge(GiovContact other) => GiovContact(
        userId: other.userId ?? userId,
        userHash: other.userHash ?? userHash,
        email: other.email ?? email,
        phone: other.phone ?? phone,
        firstName: other.firstName ?? firstName,
        lastName: other.lastName ?? lastName,
      );

  /// The fields `POST /conversations` accepts; empty values are left out.
  Map<String, String> toStartFields() => {
        for (final entry in {
          'userId': userId,
          'userHash': userHash,
          'email': email,
          'phone': phone,
          'firstName': firstName,
          'lastName': lastName,
        }.entries)
          if (entry.value != null && entry.value!.trim().isNotEmpty)
            entry.key: entry.value!.trim(),
      };
}

/// The private proof that this device owns a conversation. Store it securely; never log it.
class GiovSession {
  const GiovSession({required this.conversationId, required this.sessionToken});

  factory GiovSession.fromJson(Map<String, Object?> json) => GiovSession(
      conversationId: json['conversationId']! as String,
      sessionToken: json['sessionToken']! as String);

  final String conversationId;
  final String sessionToken;

  Map<String, String> toJson() =>
      {'conversationId': conversationId, 'sessionToken': sessionToken};

  @override
  bool operator ==(Object other) =>
      other is GiovSession &&
      other.conversationId == conversationId &&
      other.sessionToken == sessionToken;

  @override
  int get hashCode => Object.hash(conversationId, sessionToken);
}

enum GiovRole { visitor, agent }

/// Local delivery state of a visitor message.
enum GiovDelivery { sending, sent, failed }

/// One message in the conversation, from the socket, history or this device.
class GiovMessage {
  const GiovMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.isBot = false,
    this.isAutomated = false,
    this.senderName,
    this.senderAvatar,
    this.attachments = const [],
    this.delivery = GiovDelivery.sent,
    this.clientMessageId,
    this.streamId,
    this.isStreaming = false,
  });

  /// The stored id, or the client id while the message is still on its way.
  final String id;
  final GiovRole role;

  /// Chat markdown.
  final String content;

  /// Unix milliseconds.
  final int createdAt;

  /// Written by GiovBot.
  final bool isBot;

  /// An automatic notice (away message, bot failure notice); not a person.
  final bool isAutomated;

  /// The person who wrote it, for team messages; null for the bot and notices.
  final String? senderName;
  final String? senderAvatar;
  final List<GiovAttachment> attachments;
  final GiovDelivery delivery;

  /// The id this message was shown under before the server confirmed it. Use [key] for list keys.
  final String? clientMessageId;

  /// For a bot reply: the visitor message it answers.
  final String? streamId;

  /// A GiovBot reply still being written.
  final bool isStreaming;

  /// Stable across the optimistic → stored swap and the draft → reply swap, so a list does not
  /// rebuild (or reload images for) the bubble.
  String get key =>
      clientMessageId ?? (streamId != null && isBot ? 'stream:$streamId' : id);

  /// Written by a person on the team (the header identity's "person" signal).
  bool get isFromPerson => role == GiovRole.agent && !isBot && !isAutomated;

  GiovMessage copyWith({
    String? id,
    String? content,
    int? createdAt,
    GiovDelivery? delivery,
    String? senderName,
    List<GiovAttachment>? attachments,
    String? clientMessageId,
    bool? isStreaming,
  }) =>
      GiovMessage(
        id: id ?? this.id,
        role: role,
        content: content ?? this.content,
        createdAt: createdAt ?? this.createdAt,
        isBot: isBot,
        isAutomated: isAutomated,
        senderName: senderName ?? this.senderName,
        senderAvatar: senderAvatar,
        attachments: attachments ?? this.attachments,
        delivery: delivery ?? this.delivery,
        clientMessageId: clientMessageId ?? this.clientMessageId,
        streamId: streamId,
        isStreaming: isStreaming ?? this.isStreaming,
      );

  /// A message from a socket frame (camelCase) or a history row (camelCase, with the deprecated
  /// snake_case names as a fallback). The visitor's role is `user` in history and `visitor` on the
  /// socket. Returns null for anything that is not a message.
  static GiovMessage? fromJson(Object? json) {
    final map = asMap(json);
    final role = switch (map['role']) {
      'user' || 'visitor' => GiovRole.visitor,
      'agent' => GiovRole.agent,
      _ => null,
    };
    final id = _nonEmpty(map['id']);
    final content = map['content'];
    final createdAt = map['createdAt'] ?? map['created_at'];
    if (role == null ||
        id == null ||
        content is! String ||
        createdAt is! num ||
        !createdAt.isFinite) {
      return null;
    }
    final agent = role == GiovRole.agent;
    final isBot = agent && (map['isBot'] == true || map['is_bot'] == 1);
    final isAutomated =
        agent && (map['isAutomated'] == true || map['is_automated'] == 1);
    final person = agent && !isBot && !isAutomated;
    return GiovMessage(
      id: id,
      role: role,
      content: content,
      createdAt: createdAt.toInt(),
      isBot: isBot,
      isAutomated: isAutomated,
      senderName: agent ? _nonEmpty(map['senderName']) : null,
      senderAvatar: person ? safeImageUrl(map['senderAvatar']) : null,
      attachments: parseAttachments(map['attachmentId'] ?? map['attachment_id'],
          map['attachmentPreviews'] ?? map['attachment_previews']),
      streamId: _nonEmpty(map['streamId']),
    );
  }
}

/// `GET /conversations/{id}/history`, parsed.
class GiovHistory {
  const GiovHistory(
      {required this.messages,
      required this.closed,
      this.assignedAgentName,
      this.assignedAgentAvatar,
      this.attachmentAccess});

  factory GiovHistory.fromJson(Map<String, Object?> json) {
    final assignedName = _nonEmpty(json['assignedAgentName']);
    final rows = json['messages'];
    final messages = <GiovMessage>[];
    if (rows is List) {
      for (final row in rows) {
        final message = GiovMessage.fromJson(row);
        if (message == null) continue;
        // History rows carry no sender; a person's message is shown under the assigned teammate.
        messages.add(message.isFromPerson &&
                message.senderName == null &&
                assignedName != null
            ? message.copyWith(senderName: assignedName)
            : message);
      }
    }
    return GiovHistory(
      messages: messages,
      closed: json['status'] == 'closed',
      assignedAgentName: assignedName,
      assignedAgentAvatar: assignedName != null
          ? safeImageUrl(json['assignedAgentAvatar'])
          : null,
      attachmentAccess: AttachmentAccess.fromJson(json['attachmentAccess']),
    );
  }

  final List<GiovMessage> messages;
  final bool closed;
  final String? assignedAgentName;
  final String? assignedAgentAvatar;
  final AttachmentAccess? attachmentAccess;
}

/// `POST /auth/widget-token`.
class VisitorToken {
  const VisitorToken(
      {required this.token, required this.expiresAt, this.attachmentAccess});

  factory VisitorToken.fromJson(Map<String, Object?> json, DateTime now) {
    final token = _nonEmpty(json['token']);
    if (token == null) {
      throw const FormatException('Invalid visitor token response.');
    }
    final seconds = json['expiresAt'];
    // The one time in seconds in the protocol; assume a little under 15 minutes when absent.
    final expiresAt = seconds is num && seconds.isFinite
        ? DateTime.fromMillisecondsSinceEpoch((seconds * 1000).toInt())
        : now.add(const Duration(minutes: 14));
    return VisitorToken(
        token: token,
        expiresAt: expiresAt,
        attachmentAccess: AttachmentAccess.fromJson(json['attachmentAccess']));
  }

  final String token;
  final DateTime expiresAt;
  final AttachmentAccess? attachmentAccess;

  /// Renew before every connect and when less than a minute is left.
  bool usableAt(DateTime now) =>
      expiresAt.difference(now) > const Duration(minutes: 1);
}

/// Decodes a JSON-encoded string, returning null when it is not valid JSON.
Object? tryJsonDecode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
