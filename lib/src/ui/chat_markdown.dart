/// Draws the core's chat-markdown block tree as native text. Links open through the chat's URL
/// opener, and only http(s) and mailto links are tappable.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../core/markdown.dart';
import 'look.dart';

const _monospace = 'monospace';
const _monospaceFallback = ['Menlo', 'Courier New', 'Courier'];

class ChatMarkdown extends StatefulWidget {
  const ChatMarkdown({
    super.key,
    required this.content,
    required this.textStyle,
    required this.accentColor,
    required this.codeBackground,
    required this.onOpenLink,
  });

  final String content;

  /// The bubble's text style; every run carries it so overrides reach each word.
  final TextStyle textStyle;

  /// Quote bars and rules.
  final Color accentColor;
  final Color codeBackground;
  final void Function(String href) onOpenLink;

  @override
  State<ChatMarkdown> createState() => _ChatMarkdownState();
}

class _ChatMarkdownState extends State<ChatMarkdown> {
  List<MarkdownBlock> _blocks = const [];
  String? _parsed;
  final List<TapGestureRecognizer> _recognizers = [];

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  TextStyle _inline(InlineNode node) {
    final lines = <TextDecoration>[
      if (node.marks.underline || node.href != null) TextDecoration.underline,
      if (node.marks.strike) TextDecoration.lineThrough,
    ];
    return TextStyle(
      fontWeight: node.marks.bold ? FontWeight.w700 : null,
      fontStyle: node.marks.italic ? FontStyle.italic : null,
      decoration: lines.isEmpty ? null : TextDecoration.combine(lines),
      fontFamily: node.marks.code ? _monospace : null,
      fontFamilyFallback: node.marks.code ? _monospaceFallback : null,
      backgroundColor: node.marks.code ? widget.codeBackground : null,
      fontSize: node.marks.code ? 13 : null,
    );
  }

  List<InlineSpan> _lines(List<InlineLine> lines) {
    final spans = <InlineSpan>[];
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      if (lineIndex > 0) spans.add(const TextSpan(text: '\n'));
      for (final node in lines[lineIndex]) {
        final href = node.href;
        TapGestureRecognizer? recognizer;
        if (href != null && isOpenableHref(href)) {
          recognizer = TapGestureRecognizer()
            ..onTap = () => widget.onOpenLink(href);
          _recognizers.add(recognizer);
        }
        spans.add(TextSpan(
            text: node.text, style: _inline(node), recognizer: recognizer));
      }
    }
    return spans;
  }

  Widget _text(List<InlineSpan> spans, [TextStyle? extra]) => Text.rich(
      TextSpan(style: widget.textStyle.merge(extra), children: spans));

  Widget _list(ListBlock list) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < list.items.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 22,
                    child: ExcludeSemantics(
                        child: Text(
                            list.ordered ? '${list.start + index}.' : '•',
                            style: widget.textStyle)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _text(_lines(list.items[index].lines)),
                        for (final child in list.items[index].children)
                          _list(child),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      );

  Widget _block(MarkdownBlock block) => switch (block) {
        ParagraphBlock() => _text(_lines(block.lines)),
        HeadingBlock() => Semantics(
            header: true,
            child: _text(_lines([block.content]),
                const TextStyle(fontWeight: FontWeight.w700))),
        CodeBlock() => Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
                color: widget.codeBackground,
                borderRadius: BorderRadius.circular(8)),
            child: Text(block.text,
                style: widget.textStyle.copyWith(
                    fontFamily: _monospace,
                    fontFamilyFallback: _monospaceFallback,
                    fontSize: 13,
                    height: 1.4)),
          ),
        RuleBlock() => Container(
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 4),
            color: widget.accentColor),
        QuoteBlock() => Container(
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
                border: Border(
                    left: BorderSide(color: widget.accentColor, width: 3))),
            child: Opacity(opacity: 0.85, child: _text(_lines(block.lines))),
          ),
        ListBlock() => _list(block),
      };

  @override
  Widget build(BuildContext context) {
    if (_parsed != widget.content) {
      _parsed = widget.content;
      _blocks = parseChatMarkdown(widget.content);
    }
    _disposeRecognizers();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < _blocks.length; index++)
          Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 4),
              child: _block(_blocks[index])),
      ],
    );
  }
}

/// Convenience used by bubbles: markdown that opens links with the chat's opener.
Widget giovMarkdown(
        BuildContext context, GiovLook look, String content, TextStyle style,
        {required Color accent, required Color code}) =>
    ChatMarkdown(
      content: content,
      textStyle: style,
      accentColor: accent,
      codeBackground: code,
      onOpenLink: (href) => openGiovLink(look.openUrl, href),
    );

/// The words of a chat-markdown message without its markup, for screen-reader announcements.
String chatMarkdownPlainText(String content) {
  String line(InlineLine nodes) => nodes.map((node) => node.text).join();
  String lines(List<InlineLine> all) => all.map(line).join('\n');
  String list(ListBlock block) => [
        for (final item in block.items)
          [lines(item.lines), for (final child in item.children) list(child)]
              .join('\n'),
      ].join('\n');
  return parseChatMarkdown(content)
      .map((block) => switch (block) {
            ParagraphBlock() => lines(block.lines),
            HeadingBlock() => line(block.content),
            QuoteBlock() => lines(block.lines),
            CodeBlock() => block.text,
            RuleBlock() => '',
            ListBlock() => list(block),
          })
      .where((text) => text.isNotEmpty)
      .join('\n');
}
