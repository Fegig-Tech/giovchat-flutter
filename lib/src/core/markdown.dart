/// Chat markdown: the grammar of the web widget's `formatMessage`
/// (apps/widget-web/src/lib/formatMessage.ts), parsed into the renderer-neutral tree of
/// docs/protocol/conformance/markdown-vectors.json. Paragraphs and line breaks, **bold**,
/// *italic* or _italic_, ~~strike~~, <u>underline</u>, `code`, fenced code, # headings,
/// - / * / + and 1. lists (one nested level), > quotes, --- rules, [links](https://…) and bare
/// links. Only http(s)/mailto links get an href. Unfinished markup (while a reply streams in)
/// stays as text until it is closed. Pure Dart: the widgets in `ui/chat_markdown.dart` draw it.
library;

/// Formatting on one run of text.
class InlineMarks {
  const InlineMarks(
      {this.bold = false,
      this.italic = false,
      this.strike = false,
      this.underline = false,
      this.code = false});

  final bool bold;
  final bool italic;
  final bool strike;
  final bool underline;
  final bool code;

  static const none = InlineMarks();

  InlineMarks withCode() => InlineMarks(
      bold: bold,
      italic: italic,
      strike: strike,
      underline: underline,
      code: true);

  @override
  bool operator ==(Object other) =>
      other is InlineMarks &&
      other.bold == bold &&
      other.italic == italic &&
      other.strike == strike &&
      other.underline == underline &&
      other.code == code;

  @override
  int get hashCode => Object.hash(bold, italic, strike, underline, code);

  /// The vectors' shape: only the marks that are on, sorted by name.
  Map<String, bool> toJson() => {
        if (bold) 'bold': true,
        if (code) 'code': true,
        if (italic) 'italic': true,
        if (strike) 'strike': true,
        if (underline) 'underline': true,
      };
}

/// A run of text with the same formatting (and link).
class InlineNode {
  InlineNode(this.text, this.marks, [this.href]);

  String text;
  final InlineMarks marks;

  /// Set only for http(s) and mailto links.
  final String? href;

  Map<String, Object?> toJson() =>
      {'text': text, 'marks': marks.toJson(), if (href != null) 'href': href};
}

/// One visual line; lines in a paragraph, quote or list item are separated by line breaks.
typedef InlineLine = List<InlineNode>;

sealed class MarkdownBlock {
  const MarkdownBlock();
  Map<String, Object?> toJson();
}

class ParagraphBlock extends MarkdownBlock {
  const ParagraphBlock(this.lines);
  final List<InlineLine> lines;
  @override
  Map<String, Object?> toJson() =>
      {'type': 'paragraph', 'lines': _linesJson(lines)};
}

class HeadingBlock extends MarkdownBlock {
  const HeadingBlock(this.content);
  final InlineLine content;
  @override
  Map<String, Object?> toJson() => {
        'type': 'heading',
        'content': [for (final node in content) node.toJson()]
      };
}

class QuoteBlock extends MarkdownBlock {
  const QuoteBlock(this.lines);
  final List<InlineLine> lines;
  @override
  Map<String, Object?> toJson() =>
      {'type': 'quote', 'lines': _linesJson(lines)};
}

class CodeBlock extends MarkdownBlock {
  const CodeBlock(this.text);
  final String text;
  @override
  Map<String, Object?> toJson() => {'type': 'code', 'text': text};
}

class RuleBlock extends MarkdownBlock {
  const RuleBlock();
  @override
  Map<String, Object?> toJson() => {'type': 'rule'};
}

class ListItem {
  ListItem(this.lines);
  final List<InlineLine> lines;
  final List<ListBlock> children = [];
  Map<String, Object?> toJson() => {
        'lines': _linesJson(lines),
        'children': [for (final child in children) child.toJson()]
      };
}

class ListBlock extends MarkdownBlock {
  ListBlock({required this.ordered, required this.start, required this.items});
  final bool ordered;
  final int start;
  final List<ListItem> items;
  @override
  Map<String, Object?> toJson() => {
        'type': 'list',
        'ordered': ordered,
        'start': start,
        'items': [for (final item in items) item.toJson()]
      };
}

List<List<Map<String, Object?>>> _linesJson(List<InlineLine> lines) => [
      for (final line in lines) [for (final node in line) node.toJson()]
    ];

// Placeholders and mark delimiters are control characters that never survive in chat text, and
// none is a word character, so the italic rules see the same neighbours as in the widget's HTML.
const _code = '\u0000';
const _link = '\u0001';
const _boldOpen = '\u0010', _boldClose = '\u0011';
const _italicOpen = '\u0012', _italicClose = '\u0013';
const _strikeOpen = '\u0014', _strikeClose = '\u0015';
const _underlineOpen = '\u0016', _underlineClose = '\u0017';

final _controlChars = RegExp('[\u0000\u0001\u0010-\u0017]');
final _codeSpan = RegExp(r'`([^`\n]+)`');
final _labelledLink = RegExp(
    r'\[([^\]\n]+)\]\(((?:https?:\/\/|mailto:)[^\s)]+)\)',
    caseSensitive: false);
final _bareLink = RegExp(
    r'''(^|[\s(])((?:https?:\/\/)[^\s<]+[^\s<.,;:!?)'"&])''',
    caseSensitive: false);
final _boldStars = RegExp(r'\*\*(?=\S)([^*]+?\S)\*\*');
final _boldUnderscores = RegExp(r'__(?=\S)([^_]+?\S)__');
final _italicStar = RegExp(r'(^|[^*\w])\*(?=\S)([^*\n]+?\S)\*(?![*\w])');
final _italicUnderscore = RegExp(r'(^|[^_\w])_(?=\S)([^_\n]+?\S)_(?![_\w])');
final _strike = RegExp(r'~~(?=\S)([^~]+?\S)~~');
final _underline = RegExp(r'<u>([\s\S]+?)<\/u>', caseSensitive: false);

/// Inline markup on one line, in the widget's order: code spans and links are cut out first.
InlineLine parseInline(String text) {
  final codes = <String>[];
  final links = <({String label, String href})>[];
  String keep(String label, String href) {
    links.add((label: label, href: href));
    return '$_link${links.length - 1}$_link';
  }

  var out = text.replaceAll(_controlChars, '');
  out = out.replaceAllMapped(_codeSpan, (m) {
    codes.add(m[1]!);
    return '$_code${codes.length - 1}$_code';
  });
  out = out.replaceAllMapped(_labelledLink, (m) => keep(m[1]!, m[2]!));
  out = out.replaceAllMapped(_bareLink, (m) => m[1]! + keep(m[2]!, m[2]!));
  out = out
      .replaceAllMapped(_boldStars, (m) => '$_boldOpen${m[1]}$_boldClose')
      .replaceAllMapped(_boldUnderscores, (m) => '$_boldOpen${m[1]}$_boldClose')
      .replaceAllMapped(
          _italicStar, (m) => '${m[1]}$_italicOpen${m[2]}$_italicClose')
      .replaceAllMapped(
          _italicUnderscore, (m) => '${m[1]}$_italicOpen${m[2]}$_italicClose')
      .replaceAllMapped(_strike, (m) => '$_strikeOpen${m[1]}$_strikeClose')
      .replaceAllMapped(
          _underline, (m) => '$_underlineOpen${m[1]}$_underlineClose');

  final nodes = <InlineNode>[];
  var bold = 0, italic = 0, strike = 0, underline = 0;
  InlineMarks current() => InlineMarks(
      bold: bold > 0,
      italic: italic > 0,
      strike: strike > 0,
      underline: underline > 0);
  void push(InlineNode node) {
    if (node.text.isEmpty) return;
    final last = nodes.isEmpty ? null : nodes.last;
    if (last != null &&
        last.href == null &&
        node.href == null &&
        last.marks == node.marks) {
      last.text += node.text;
    } else {
      nodes.add(node);
    }
  }

  final buffer = StringBuffer();
  void flush() {
    push(InlineNode(buffer.toString(), current()));
    buffer.clear();
  }

  for (var index = 0; index < out.length; index++) {
    final char = out[index];
    switch (char) {
      case _boldOpen || _boldClose:
        flush();
        bold += char == _boldOpen ? 1 : -1;
      case _italicOpen || _italicClose:
        flush();
        italic += char == _italicOpen ? 1 : -1;
      case _strikeOpen || _strikeClose:
        flush();
        strike += char == _strikeOpen ? 1 : -1;
      case _underlineOpen || _underlineClose:
        flush();
        underline += char == _underlineOpen ? 1 : -1;
      case _code || _link:
        final end = out.indexOf(char, index + 1);
        final slot = int.parse(out.substring(index + 1, end));
        flush();
        if (char == _code) {
          push(InlineNode(codes[slot], current().withCode()));
        } else {
          push(InlineNode(links[slot].label, current(), links[slot].href));
        }
        index = end;
      default:
        buffer.write(char);
    }
  }
  flush();
  return nodes;
}

final _fence = RegExp(r'^\s*```');
final _headingLine = RegExp(r'^(#{1,6})\s+(.*)$');
final _ruleLine = RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$');
final _quoteLine = RegExp(r'^>\s?(.*)$');
final _itemLine = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$');
final _itemStart = RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+');
final _continuation = RegExp(r'^\s+\S');
final _digit = RegExp(r'\d');

/// Parses message or stream content into blocks. Empty input gives no blocks.
List<MarkdownBlock> parseChatMarkdown(String content) {
  if (content.isEmpty) return const [];
  final lines = content.replaceAll(RegExp(r'\r\n?'), '\n').split('\n');
  final blocks = <MarkdownBlock>[];
  var paragraph = <String>[];
  var quote = <String>[];
  // Open lists, outermost first; one nested level, as in the widget.
  final lists = <({ListBlock list, int indent})>[];

  void flushParagraph() {
    if (paragraph.isNotEmpty) {
      blocks.add(
          ParagraphBlock([for (final line in paragraph) parseInline(line)]));
    }
    paragraph = [];
  }

  void closeLists([int toIndent = -1]) {
    while (lists.isNotEmpty && lists.last.indent > toIndent) {
      lists.removeLast();
    }
  }

  void flushQuote() {
    if (quote.isNotEmpty) {
      blocks.add(QuoteBlock([for (final line in quote) parseInline(line)]));
    }
    quote = [];
  }

  void flushAll() {
    flushParagraph();
    closeLists();
    flushQuote();
  }

  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    // Fenced code: everything up to the closing fence (or the end, while streaming) is literal.
    if (_fence.hasMatch(line)) {
      flushAll();
      final body = <String>[];
      while (++index < lines.length && !_fence.hasMatch(lines[index])) {
        body.add(lines[index]);
      }
      blocks.add(CodeBlock(body.join('\n')));
      continue;
    }
    if (line.trim().isEmpty) {
      flushParagraph();
      flushQuote();
      // A blank line between list items keeps the list going.
      final next = index + 1 < lines.length ? lines[index + 1] : '';
      if (lists.isNotEmpty && !_itemStart.hasMatch(next)) closeLists();
      continue;
    }
    final heading = _headingLine.firstMatch(line);
    if (heading != null) {
      flushAll();
      blocks.add(HeadingBlock(parseInline(heading[2]!)));
      continue;
    }
    if (_ruleLine.hasMatch(line)) {
      flushAll();
      blocks.add(const RuleBlock());
      continue;
    }
    final quoted = _quoteLine.firstMatch(line);
    if (quoted != null) {
      flushParagraph();
      closeLists();
      quote.add(quoted[1]!);
      continue;
    }
    flushQuote();
    final item = _itemLine.firstMatch(line);
    if (item != null) {
      flushParagraph();
      final indent = item[1]!.replaceAll('\t', '  ').length;
      final ordered = _digit.hasMatch(item[2]!);
      final entry = ListItem([parseInline(item[3]!)]);
      closeLists(indent);
      final top = lists.isEmpty ? null : lists.last;
      if (top != null && top.indent == indent && top.list.ordered == ordered) {
        top.list.items.add(entry);
      } else {
        if (top != null && top.indent == indent) closeLists(indent - 1);
        final parent = lists.isEmpty ? null : lists.last;
        // Only one nested level: deeper indentation joins the nested list.
        final nested = parent != null && indent > parent.indent;
        if (lists.length >= 2 && nested) {
          parent.list.items.add(entry);
          continue;
        }
        final list = ListBlock(
            ordered: ordered,
            start: ordered
                ? (int.tryParse(item[2]!.replaceAll(RegExp(r'[.)]'), '')) ?? 1)
                : 1,
            items: [entry]);
        if (nested) {
          parent.list.items.last.children.add(list);
        } else {
          blocks.add(list);
        }
        lists.add((list: list, indent: indent));
      }
      continue;
    }
    // A line indented under a list item continues that item.
    if (lists.isNotEmpty && _continuation.hasMatch(line)) {
      lists.last.list.items.last.lines.add(parseInline(line.trim()));
      continue;
    }
    closeLists();
    paragraph.add(line);
  }
  flushAll();
  return blocks;
}

final _openable = RegExp(r'^(?:https?:\/\/|mailto:)', caseSensitive: false);

/// Links are opened only for these schemes, whatever the text claims.
bool isOpenableHref(String? href) => href != null && _openable.hasMatch(href);
