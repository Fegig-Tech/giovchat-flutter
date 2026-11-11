import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:giovchat/giovchat.dart';

// The normalisation of the Giov protocol conformance runner (markdown.mjs): marks sorted, empty
// runs dropped, neighbours with the same marks and no link merged.
List<Map<String, Object?>> normalizeLine(List<Object?> runs) {
  final out = <Map<String, Object?>>[];
  for (final raw in runs) {
    final run = raw! as Map<String, Object?>;
    final text = run['text']! as String;
    if (text.isEmpty) continue;
    final marks = Map<String, Object?>.fromEntries(
      ((run['marks'] as Map<String, Object?>?) ?? {})
          .entries
          .where((entry) => entry.value == true)
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    );
    final next = <String, Object?>{
      'text': text,
      'marks': marks,
      if (run['href'] != null && run['href'] != '') 'href': run['href']
    };
    final last = out.isEmpty ? null : out.last;
    if (last != null &&
        last['href'] == null &&
        next['href'] == null &&
        jsonEncode(last['marks']) == jsonEncode(marks)) {
      last['text'] = '${last['text']}$text';
    } else {
      out.add(next);
    }
  }
  return out;
}

List<Object?> normalizeTree(List<Object?> blocks) => [
      for (final raw in blocks)
        () {
          final block = raw! as Map<String, Object?>;
          switch (block['type']) {
            case 'paragraph' || 'quote':
              return {
                'type': block['type'],
                'lines': [
                  for (final line in block['lines']! as List)
                    normalizeLine(line as List<Object?>)
                ]
              };
            case 'heading':
              return {
                'type': 'heading',
                'content': normalizeLine(block['content']! as List<Object?>)
              };
            case 'code':
              return {'type': 'code', 'text': block['text']};
            case 'rule':
              return {'type': 'rule'};
            case 'list':
              final ordered = block['ordered'] == true;
              return {
                'type': 'list',
                'ordered': ordered,
                'start': ordered ? (block['start'] ?? 1) : 1,
                'items': [
                  for (final item in block['items']! as List)
                    {
                      'lines': [
                        for (final line
                            in (item as Map<String, Object?>)['lines']! as List)
                          normalizeLine(line as List<Object?>)
                      ],
                      'children': normalizeTree(
                          (item['children'] as List<Object?>?) ?? const []),
                    },
                ],
              };
            default:
              throw StateError('unknown block ${block['type']}');
          }
        }(),
    ];

void main() {
  final file = File('test/fixtures/markdown-vectors.json');
  final vectors = (jsonDecode(file.readAsStringSync())
      as Map<String, Object?>)['vectors']! as List<Object?>;

  test('the vectors file is loaded',
      () => expect(vectors.length, greaterThan(40)));

  for (final raw in vectors) {
    final vector = raw! as Map<String, Object?>;
    test('markdown vector: ${vector['name']}', () {
      final blocks = parseChatMarkdown(vector['input']! as String);
      // Round-trip through JSON so the comparison sees plain maps and lists.
      final actual = normalizeTree(
          jsonDecode(jsonEncode([for (final block in blocks) block.toJson()]))
              as List<Object?>);
      final expected = normalizeTree(vector['tree']! as List<Object?>);
      expect(actual, equals(expected),
          reason: 'input: ${jsonEncode(vector['input'])}');
    });
  }
}
