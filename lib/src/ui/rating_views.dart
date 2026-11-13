/// The conversation rating card, the thumbs under GiovBot answers and the rating sheet.
library;

import 'dart:async';

// Flutter 3.47 deprecates this import (Material moves to its own package); the SDK still supports Flutter 3.22.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/errors.dart';
import '../core/i18n.dart';
import '../core/models.dart';
import '../core/rating.dart';
import 'look.dart';
import 'style_overrides.dart';

/// Answers a rating card; throws the controller's typed failures.
typedef GiovRateCallback = Future<void> Function(
    String requestId, int score, String comment);

/// Votes on a GiovBot answer; throws the controller's typed failures.
typedef GiovVoteCallback = Future<void>
    Function(String messageId, GiovFeedbackValue value, {String? reason});

const _faces = ['😞', '🙁', '😐', '🙂', '😄'];

/// The rating card (a `rating` block): five faces, an optional comment and Send; after an answer
/// "Thanks" with the chosen face. The pick stays on screen while the answer is on its way and is
/// taken back, with a short message, when it fails.
class GiovRatingCard extends StatefulWidget {
  const GiovRatingCard(
      {super.key, required this.block, this.onRate, this.now = DateTime.now});

  final GiovRatingBlock block;

  /// Without it the card is read-only.
  final GiovRateCallback? onRate;

  /// The clock, for tests.
  final DateTime Function() now;

  @override
  State<GiovRatingCard> createState() => _GiovRatingCardState();
}

class _GiovRatingCardState extends State<GiovRatingCard> {
  final _comment = TextEditingController();
  Timer? _timer;
  int _pick = 0;
  bool _editing = false;
  ({int score, String comment})? _pending;
  String? _error;
  GiovRatingPhase? _lock;
  int _nowMs = 0;

  @override
  void initState() {
    super.initState();
    _nowMs = widget.now().millisecondsSinceEpoch;
    _arm();
  }

  @override
  void didUpdateWidget(GiovRatingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.closesAt != widget.block.closesAt) _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _comment.dispose();
    super.dispose();
  }

  /// Read-only from `closesAt` on, without waiting for another build.
  void _arm() {
    _timer?.cancel();
    final wait = widget.block.closesAt - widget.now().millisecondsSinceEpoch;
    if (wait <= 0) return;
    _timer = Timer(Duration(milliseconds: wait.clamp(1, 0x7fffffff) + 1), () {
      if (!mounted) return;
      setState(() => _nowMs = widget.now().millisecondsSinceEpoch);
    });
  }

  Future<void> _submit() async {
    final onRate = widget.onRate;
    if (_pick == 0 || _pending != null || onRate == null) return;
    final next = (score: _pick, comment: _comment.text.trim());
    setState(() {
      _error = null;
      _pending = next;
      _editing = false;
    });
    final strings = GiovChatScope.of(context).strings;
    try {
      await onRate(widget.block.requestId, next.score, next.comment);
    } on GiovRatingException catch (failure) {
      if (!mounted) return;
      setState(() {
        switch (failure.problem) {
          case GiovRatingProblem.ratingClosed:
            _lock = GiovRatingPhase.closed;
          case GiovRatingProblem.requestReplaced:
            _lock = GiovRatingPhase.hidden;
          case GiovRatingProblem.tooManyChanges:
            _editing = true;
            _error = strings.ratingTooMany;
          default:
            _editing = true;
            _error = strings.ratingFailed;
        }
      });
    } on GiovRateLimitedException catch (failure) {
      if (!mounted) return;
      setState(() {
        _editing = true;
        _error = strings.ratingWait(failure.retryAfter.inSeconds);
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _editing = true;
        _error = strings.ratingFailed;
      });
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final strings = look.strings;
    final block = widget.block;
    final phase = _lock ?? ratingPhase(block, _nowMs);
    if (phase == GiovRatingPhase.hidden) return const SizedBox.shrink();
    final closed = phase == GiovRatingPhase.closed;
    final score = _pending?.score ?? block.score;
    final text = _pending != null ? _pending!.comment : block.comment;
    final ink = look.onAgentBubble;
    final quiet = look.secondaryText;
    String label(int n) => strings.ratingFace(n);

    if (score != null && !_editing) {
      return Padding(
        key: const ValueKey('giov-rating-done'),
        padding: const EdgeInsets.only(top: 8),
        child: Semantics(
          container: true,
          label: '${strings.yourRating}: ${label(score)}',
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${_faces[score - 1]} ${strings.ratingThanks} · ${label(score)}',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: ink)),
              if (text != null && text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child:
                      Text(text, style: TextStyle(fontSize: 13, color: quiet)),
                ),
              if (!closed && widget.onRate != null)
                Semantics(
                  button: true,
                  enabled: _pending == null,
                  label: strings.ratingChange,
                  excludeSemantics: true,
                  child: InkWell(
                    key: const ValueKey('giov-rating-change'),
                    onTap: _pending != null
                        ? null
                        : () => setState(() {
                              _pick = score;
                              _comment.text = text ?? '';
                              _error = null;
                              _editing = true;
                            }),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: 1,
                        child: Text(strings.ratingChange,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: look.dark
                                    ? look.primary
                                    : look.buttonColor)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    if (closed) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(strings.ratingClosed,
            key: const ValueKey('giov-rating-closed'),
            style: TextStyle(fontSize: 13, color: quiet)),
      );
    }

    final canSend = _pick != 0 && _pending == null && widget.onRate != null;
    return Padding(
      key: const ValueKey('giov-rating-form'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            container: true,
            label: strings.yourRating,
            child: Wrap(
              spacing: 4,
              children: [
                for (var n = 1; n <= 5; n++)
                  Semantics(
                    inMutuallyExclusiveGroup: true,
                    checked: _pick == n,
                    label: label(n),
                    excludeSemantics: true,
                    child: InkWell(
                      key: ValueKey('giov-rating-face-$n'),
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _pick = n),
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color:
                                  _pick == n ? look.primary : look.inputBorder,
                              width: _pick == n ? 2 : 1),
                        ),
                        child: Text(_faces[n - 1],
                            style: const TextStyle(fontSize: 22)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('giov-rating-comment'),
            controller: _comment,
            maxLength: maxRatingComment,
            maxLines: 3,
            minLines: 1,
            style: TextStyle(fontSize: 14, color: ink),
            buildCounter: (_,
                    {required currentLength,
                    required isFocused,
                    required maxLength}) =>
                null,
            decoration: InputDecoration(
              isDense: true,
              hintText: strings.ratingComment,
              hintStyle: look.hintStyle,
              semanticCounterText: '',
              filled: true,
              fillColor: look.inputFill,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: look.inputBorder)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: look.inputBorder)),
            ),
          ),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!,
                    key: const ValueKey('giov-rating-error'),
                    style: TextStyle(fontSize: 13, color: look.error)),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                button: true,
                enabled: canSend,
                label: strings.ratingSend,
                excludeSemantics: true,
                child: Material(
                  color: look.buttonColor.withAlpha(canSend ? 255 : 100),
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    key: const ValueKey('giov-rating-send'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: canSend ? () => unawaited(_submit()) : null,
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(minHeight: 44, minWidth: 44),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 11),
                        child: Text(strings.ratingSend,
                            textAlign: TextAlign.center,
                            style: look.buttonTextStyle),
                      ),
                    ),
                  ),
                ),
              ),
              if (block.score != null)
                Semantics(
                  button: true,
                  label: strings.ratingCancel,
                  excludeSemantics: true,
                  child: InkWell(
                    key: const ValueKey('giov-rating-cancel'),
                    onTap: () => setState(() => _editing = false),
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(minHeight: 44, minWidth: 44),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Center(
                          child: Text(strings.ratingCancel,
                              style: TextStyle(fontSize: 14, color: quiet)),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Thumbs under a GiovBot answer: one vote, changeable; a thumbs-down offers an optional reason.
class GiovAnswerFeedbackBar extends StatefulWidget {
  const GiovAnswerFeedbackBar(
      {super.key, required this.messageId, this.value, required this.onVote});

  final String messageId;

  /// The visitor's vote now ([GiovFeedbackValue.up], [GiovFeedbackValue.down] or null).
  final GiovFeedbackValue? value;
  final GiovVoteCallback onVote;

  @override
  State<GiovAnswerFeedbackBar> createState() => _GiovAnswerFeedbackBarState();
}

class _GiovAnswerFeedbackBarState extends State<GiovAnswerFeedbackBar> {
  final _reason = TextEditingController();
  bool _asking = false;
  bool _failed = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _tap(GiovFeedbackValue tapped) async {
    final next = nextFeedback(widget.value, tapped);
    setState(() {
      _failed = false;
      _reason.clear();
      _asking = next == GiovFeedbackValue.down;
    });
    try {
      await widget.onVote(widget.messageId, next);
    } on Object {
      if (!mounted) return;
      setState(() {
        _asking = false;
        _failed = true;
      });
    }
  }

  Future<void> _sendReason() async {
    final text = _reason.text.trim();
    setState(() => _asking = false);
    if (text.isEmpty) return;
    try {
      await widget.onVote(widget.messageId, GiovFeedbackValue.down,
          reason: text);
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final strings = look.strings;
    Widget thumb(GiovFeedbackValue kind) {
      final selected = widget.value == kind;
      final up = kind == GiovFeedbackValue.up;
      return Semantics(
        button: true,
        selected: selected,
        label: up ? strings.answerGood : strings.answerBad,
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey('giov-feedback-${kind.name}'),
          customBorder: const CircleBorder(),
          onTap: () => unawaited(_tap(kind)),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Icon(
                  up
                      ? (selected ? Icons.thumb_up : Icons.thumb_up_outlined)
                      : (selected
                          ? Icons.thumb_down
                          : Icons.thumb_down_outlined),
                  size: 18,
                  color: selected
                      ? (look.dark ? look.primary : look.buttonColor)
                      : look.secondaryText),
            ),
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      label: strings.answerGroup,
      child: Column(
        key: ValueKey('giov-feedback-${widget.messageId}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              thumb(GiovFeedbackValue.up),
              thumb(GiovFeedbackValue.down),
              if (_failed)
                Semantics(
                  liveRegion: true,
                  child: Text(strings.answerFailed,
                      key: const ValueKey('giov-feedback-error'),
                      style: TextStyle(fontSize: 12, color: look.error)),
                ),
            ],
          ),
          if (_asking)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('giov-feedback-reason'),
                      controller: _reason,
                      maxLength: maxFeedbackReason,
                      style: TextStyle(fontSize: 13, color: look.text),
                      buildCounter: (_,
                              {required currentLength,
                              required isFocused,
                              required maxLength}) =>
                          null,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: strings.answerReason,
                        hintStyle: look.hintStyle,
                        filled: true,
                        fillColor: look.inputFill,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: look.inputBorder)),
                      ),
                    ),
                  ),
                  InkWell(
                    key: const ValueKey('giov-feedback-send'),
                    onTap: () => unawaited(_sendReason()),
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(minHeight: 44, minWidth: 44),
                      child: Center(
                        child: Text(strings.ratingSend,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: look.dark
                                    ? look.primary
                                    : look.buttonColor)),
                      ),
                    ),
                  ),
                  InkWell(
                    key: const ValueKey('giov-feedback-skip'),
                    onTap: () => setState(() => _asking = false),
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(minHeight: 44, minWidth: 44),
                      child: Center(
                        child: Text(strings.answerSkip,
                            style: TextStyle(
                                fontSize: 13, color: look.secondaryText)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Opens the built-in rating sheet for the controller's open rating card (for a host that turned
/// the in-chat card off, or wants its own "Rate us" button). Resolves true once the sheet was
/// shown and then closed; false at once when there is no card to answer.
///
/// The sheet follows the controller: it closes by itself when the card goes away (closed or
/// replaced), and "Thanks" replaces the faces after an answer. Colours and language follow the
/// workspace's configuration unless [theme], [primaryColor], [styleOverrides] or [strings] are set.
Future<bool> showGiovRatingSheet(
  BuildContext context,
  GiovChatController controller, {
  GiovThemeMode? theme,
  Color? primaryColor,
  GiovChatStyleOverrides styleOverrides = const GiovChatStyleOverrides(),
  GiovChatStrings? strings,
  GiovUrlOpener? onOpenUrl,
}) async {
  if (controller.ratingRequest == null) return false;
  final config = controller.config;
  final mode = theme ?? config?.theme ?? GiovThemeMode.light;
  final platform =
      MediaQuery.maybePlatformBrightnessOf(context) ?? Brightness.light;
  final dark = mode == GiovThemeMode.dark ||
      (mode == GiovThemeMode.auto && platform == Brightness.dark);
  final look = GiovLook(
    dark: dark,
    primary: primaryColor ?? parseBrandColor(config?.primaryColor),
    strings: strings ?? controller.strings,
    style: styleOverrides,
    openUrl: onOpenUrl ?? defaultGiovUrlOpener,
    attachmentUrl: controller.attachmentUrl,
    botName: config?.botName,
    config: config,
  );
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: look.background,
    showDragHandle: true,
    builder: (sheetContext) => GiovChatScope(
      look: look,
      child: _RatingSheet(controller: controller),
    ),
  );
  return true;
}

class _RatingSheet extends StatelessWidget {
  const _RatingSheet({required this.controller});

  final GiovChatController controller;

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final request = controller.ratingRequest;
        final message = request == null
            ? null
            : controller.messages
                .where((message) => message.id == request.messageId)
                .firstOrNull;
        final block = message?.rating;
        if (block == null) {
          // The card is gone (closed or replaced): the sheet closes itself.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).maybePop();
          });
          return const SizedBox(height: 120);
        }
        return Padding(
          key: const ValueKey('giov-rating-sheet'),
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(look.strings.rateTitle,
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: look.text)),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: look.strings.closeRating,
                      excludeSemantics: true,
                      child: InkWell(
                        key: const ValueKey('giov-rating-sheet-close'),
                        customBorder: const CircleBorder(),
                        onTap: () => Navigator.of(context).maybePop(),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(Icons.close,
                              size: 20, color: look.secondaryText),
                        ),
                      ),
                    ),
                  ],
                ),
                GiovRatingCard(
                  key: ValueKey('sheet-${block.requestId}'),
                  block: block,
                  onRate: controller.ratingsSupported
                      ? (requestId, score, comment) async {
                          await controller.submitRating(score,
                              comment: comment, requestId: requestId);
                        }
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
