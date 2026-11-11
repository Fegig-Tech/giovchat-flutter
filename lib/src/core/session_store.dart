/// Where the session secret lives between launches.
library;

import 'dart:convert';

import 'models.dart';

/// Persists the `{conversationId, sessionToken}` pair, one per [scope].
///
/// The session token is a bearer secret that proves this device owns the conversation: **back this
/// with the platform's secure storage** (Keychain on iOS, Keystore-backed encrypted preferences on
/// Android, for example `flutter_secure_storage`), never plain `SharedPreferences`. The SDK ships
/// no such dependency; [InMemoryGiovSessionStore] (the default) forgets the conversation when the
/// app process ends.
///
/// Implementations may throw; the SDK reports a [GiovStorageException] and carries on without the
/// stored session.
abstract class GiovSessionStore {
  /// The stored session for [scope], or null.
  Future<GiovSession?> read(String scope);
  Future<void> write(String scope, GiovSession session);
  Future<void> delete(String scope);
}

/// Keeps sessions in memory only.
class InMemoryGiovSessionStore implements GiovSessionStore {
  final Map<String, GiovSession> _sessions = {};

  @override
  Future<GiovSession?> read(String scope) async => _sessions[scope];

  @override
  Future<void> write(String scope, GiovSession session) async =>
      _sessions[scope] = session;

  @override
  Future<void> delete(String scope) async => _sessions.remove(scope);
}

/// The key a session is stored under: one per API, workspace and visitor identity ([sessionKey]
/// and the contact's `userId`), so signing in as someone else never resumes the previous person's
/// conversation. Names, email and phone are left out: a profile edit keeps the conversation.
String giovSessionScope(String baseUrl, String tenantKey,
        {GiovContact? contact, String? sessionKey}) =>
    jsonEncode([
      baseUrl.replaceAll(RegExp(r'/$'), ''),
      tenantKey,
      sessionKey,
      contact?.userId,
    ]);

final _sessionToken = RegExp(r'^[a-f0-9]{64}$');

/// A stored pair is used only if it looks like one.
bool isValidStoredSession(GiovSession? session) =>
    session != null &&
    session.conversationId.isNotEmpty &&
    _sessionToken.hasMatch(session.sessionToken);
