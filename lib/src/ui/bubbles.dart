/// Message bubbles, the greeting, the typing indicator and the GiovBot mark.
library;

import 'package:flutter/material.dart';

import '../core/identity.dart';
import '../core/models.dart';
import 'attachment_views.dart';
import 'brand_assets.dart';
import 'chat_markdown.dart';
import 'look.dart';

/// The compact GiovBot avatar shown beside AI replies.
class GiovBotMark extends StatelessWidget {
  const GiovBotMark({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: ExcludeSemantics(
          child: Image.memory(giovBotMarkPng,
              width: size,
              height: size,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              key: const ValueKey('giovbot-mark')),
        ),
      );
}

const _bubbleRadius = Radius.circular(16);
const _tailRadius = Radius.circular(4);

/// Left/right aligned row that leaves the bubble at most 78% of the width.
class _BubbleRow extends StatelessWidget {
  const _BubbleRow(
      {required this.visitor, required this.child, this.leading, this.below});

  final bool visitor;
  final Widget child;
  final Widget? leading;
  final Widget? below;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
        child: Column(
          crossAxisAlignment:
              visitor ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) => Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 8)],
                  ConstrainedBox(
                    constraints:
                        BoxConstraints(maxWidth: constraints.maxWidth * 0.78),
                    child: child,
                  ),
                ],
              ),
            ),
            if (below != null) below!,
          ],
        ),
      );
}

class GreetingBubble extends StatelessWidget {
  const GreetingBubble({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: _BubbleRow(
        visitor: false,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: look.agentBubble,
            borderRadius: const BorderRadius.only(
                topLeft: _bubbleRadius,
                topRight: _bubbleRadius,
                bottomRight: _bubbleRadius,
                bottomLeft: _tailRadius),
          ),
          child: Text(text,
              style: look.style.text(
                  TextStyle(fontSize: 14, height: 1.43, color: look.text),
                  look.style.agentText)),
        ),
      ),
    );
  }
}

class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key, this.isBot});

  /// Only explicit server AI identity brands the indicator as the AI.
  final bool? isBot;

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200));
  bool _animating = false;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate = !MediaQuery.disableAnimationsOf(context);
    if (animate && !_animating) {
      _pulse.repeat();
    } else if (!animate && _animating) {
      _pulse.stop();
    }
    _animating = animate;
  }

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final ai = widget.isBot == true;
    final label = ai
        ? look.strings.botTyping(look.botName?.trim().isNotEmpty == true
            ? look.botName!.trim()
            : 'GiovBot')
        : look.strings.teamTyping;
    final dotColor = look.style.agentText?.color ??
        (look.dark ? const Color(0xFF8A8A8A) : const Color(0xFF999999));
    return Semantics(
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: _BubbleRow(
        visitor: false,
        leading: ai ? const GiovBotMark() : null,
        child: Container(
          key: const ValueKey('giov-typing'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: look.agentBubble,
            borderRadius: const BorderRadius.only(
                topLeft: _bubbleRadius,
                topRight: _bubbleRadius,
                bottomRight: _bubbleRadius,
                bottomLeft: _tailRadius),
          ),
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var dot = 0; dot < 3; dot++)
                  Padding(
                    padding: EdgeInsets.only(left: dot == 0 ? 0 : 5),
                    child: Opacity(
                      opacity: _animating
                          ? 0.35 + 0.65 * _wave((_pulse.value - dot * 0.18) % 1)
                          : 0.7,
                      child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                              color: dotColor, shape: BoxShape.circle)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static double _wave(double t) => t < 0.5 ? t * 2 : (1 - t) * 2;
}

class MessageBubble extends StatelessWidget {
  const MessageBubble(
      {super.key, required this.message, this.onRetry, this.onDiscard});

  final GiovMessage message;

  /// Offered on a visitor message that failed to send.
  final void Function(GiovMessage message)? onRetry;
  final void Function(GiovMessage message)? onDiscard;

  String _time(BuildContext context) {
    final at = DateTime.fromMillisecondsSinceEpoch(message.createdAt);
    final localizations = MaterialLocalizations.of(context);
    return localizations.formatTimeOfDay(TimeOfDay.fromDateTime(at),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
  }

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final strings = look.strings;
    final visitor = message.role == GiovRole.visitor;
    final isBot = message.role == GiovRole.agent && message.isBot;
    final failed = visitor && message.delivery == GiovDelivery.failed;
    final sending = visitor && message.delivery == GiovDelivery.sending;
    final overrideText =
        visitor ? look.style.visitorText : look.style.agentText;
    final textColor = visitor ? look.onVisitorBubble : look.onAgentBubble;
    final darkBubble =
        visitor ? look.visitorBubble.computeLuminance() <= 0.6 : look.dark;
    final label = messageSenderLabel(message, strings, botName: look.botName);
    // The sender label and time are small: each keeps 4.5:1 on its bubble, else takes the text colour.
    final bubble = visitor ? look.visitorBubble : look.agentBubble;
    final subtle = giovSecondaryOn(
        bubble,
        visitor
            ? textColor.withAlpha(184)
            : (look.dark ? const Color(0xFF999999) : const Color(0xFF595959)),
        textColor);
    final faint = giovSecondaryOn(
        bubble,
        visitor
            ? textColor.withAlpha(140)
            : (look.dark ? const Color(0xFF999999) : const Color(0xFF666666)),
        textColor);
    final contentStyle = look.style.text(
        TextStyle(fontSize: 14, height: 1.43, color: textColor), overrideText);
    final accent =
        darkBubble ? const Color(0x80FFFFFF) : const Color(0x33000000);
    final code = darkBubble ? const Color(0x2EFFFFFF) : const Color(0x0F000000);
    final time = sending ? strings.sending : _time(context);

    return KeyedSubtree(
      key: ValueKey('bubble:${message.key}'),
      child: _BubbleRow(
        visitor: visitor,
        leading: isBot ? const GiovBotMark() : null,
        below: failed
            ? Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      button: true,
                      enabled: onRetry != null,
                      label: '${strings.notSent}. ${strings.tapToRetry}',
                      excludeSemantics: true,
                      child: InkWell(
                        key: const ValueKey('giov-retry'),
                        onTap: onRetry == null ? null : () => onRetry!(message),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 44),
                          child: Center(
                            widthFactor: 1,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: Text(
                                  '${strings.notSent}${onRetry != null ? ' · ${strings.tapToRetry}' : ''}',
                                  style: TextStyle(
                                      color: look.error, fontSize: 12)),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (onDiscard != null)
                      Semantics(
                        button: true,
                        label: strings.discard,
                        excludeSemantics: true,
                        child: InkWell(
                          key: const ValueKey('giov-discard'),
                          onTap: () => onDiscard!(message),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                                minHeight: 44, minWidth: 44),
                            child: Center(
                              widthFactor: 1,
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                child: Text(strings.discard,
                                    style: TextStyle(
                                        color: look.secondaryText,
                                        fontSize: 12)),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              )
            : null,
        child: Semantics(
          container: true,
          child: Opacity(
            opacity: sending ? 0.75 : 1,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: visitor ? look.visitorBubble : look.agentBubble,
                borderRadius: BorderRadius.only(
                  topLeft: _bubbleRadius,
                  topRight: _bubbleRadius,
                  bottomLeft: visitor ? _bubbleRadius : _tailRadius,
                  bottomRight: visitor ? _tailRadius : _bubbleRadius,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(label,
                        style: look.style
                            .text(
                                TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: subtle),
                                overrideText)
                            .copyWith(color: overrideText?.color ?? subtle)),
                  ),
                  if (message.attachments.isNotEmpty)
                    AttachmentList(
                        attachments: message.attachments,
                        textColor: textColor,
                        onDarkSurface: darkBubble),
                  if (message.content.isNotEmpty)
                    giovMarkdown(context, look, message.content, contentStyle,
                        accent: accent, code: code),
                  if (!message.isStreaming)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(time,
                            style: look.style
                                .text(TextStyle(fontSize: 10, color: faint),
                                    overrideText)
                                .copyWith(color: overrideText?.color ?? faint)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
