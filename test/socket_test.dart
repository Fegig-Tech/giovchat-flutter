import 'package:flutter_test/flutter_test.dart';
import 'package:giovchat/src/core/socket.dart';

void main() {
  test('only an upgrade answered 410 means the conversation was deleted', () {
    expect(
        isConversationDeletedUpgradeError(Exception(
            "Connection to 'https://api.test/conversations/c1/ws?role=user' was not upgraded to websocket, HTTP status code: 410")),
        isTrue);
    expect(
        isConversationDeletedUpgradeError(Exception('HTTP status code: 401')),
        isFalse);
    // A conversation id that happens to contain "410" is not a deletion.
    expect(
        isConversationDeletedUpgradeError(Exception(
            "Connection to 'https://api.test/conversations/9c410f2e-4100-4abc-8410-000000000410/ws' failed: Connection reset by peer")),
        isFalse);
    expect(
        isConversationDeletedUpgradeError(Exception(
            '... was not upgraded to websocket, HTTP status code: 4101')),
        isFalse);
  });
}
