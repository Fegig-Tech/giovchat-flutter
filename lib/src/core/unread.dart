/// Unread replies per chat controller, so any screen can show a badge without passing the
/// controller around. Each [GiovChatController] publishes its own count under its workspace key.
library;

import 'package:flutter/foundation.dart';

class GiovUnread {
  GiovUnread._();

  static final Map<Object, ({String tenantKey, int count})> _counts = {};
  static final Map<String?, ValueNotifier<int>> _notifiers = {};

  /// Called by the controller; apps do not need it.
  static void publish(Object owner, String tenantKey, int count) {
    final current = _counts[owner];
    if (current != null &&
        current.tenantKey == tenantKey &&
        current.count == count) {
      return;
    }
    _counts[owner] = (tenantKey: tenantKey, count: count);
    _notify();
  }

  static void forget(Object owner) {
    if (_counts.remove(owner) != null) _notify();
  }

  /// Agent replies not seen because the chat was closed, summed over all chats (or one workspace).
  /// Counts only while a controller with `keepConnected` stays connected; opening the chat clears it.
  static int read([String? tenantKey]) {
    var total = 0;
    for (final entry in _counts.values) {
      if (tenantKey == null || entry.tenantKey == tenantKey) {
        total += entry.count;
      }
    }
    return total;
  }

  /// A listenable count for a badge: `ValueListenableBuilder(valueListenable: GiovUnread.watch(), …)`.
  static ValueListenable<int> watch([String? tenantKey]) =>
      _notifiers.putIfAbsent(tenantKey, () => ValueNotifier(read(tenantKey)));

  static void _notify() {
    for (final entry in _notifiers.entries) {
      entry.value.value = read(entry.key);
    }
  }
}
