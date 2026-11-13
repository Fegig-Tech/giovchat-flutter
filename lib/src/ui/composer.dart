/// The composer row (attach, multiline input, send) and the strip of files waiting to be sent.
library;

import 'dart:math' as math;

// Flutter 3.47 deprecates this import (Material moves to its own package); the SDK still supports Flutter 3.22.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/attachments.dart';
import '../core/controller.dart';
import '../core/outbox.dart' show maxMessageChars;
import 'look.dart';

/// Keeps the text within [max] UTF-16 code units, the unit the server counts (a Dart `String.length`).
/// `maxLength` would count characters, so emoji-heavy text could pass it and be refused. Longer text
/// (a paste) is cut at the limit, never between the two halves of a surrogate pair.
class GiovMessageLengthLimit extends TextInputFormatter {
  const GiovMessageLengthLimit([this.max = maxMessageChars]);

  final int max;

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final text = newValue.text;
    // While an input method composes, wait for the composed text.
    if (text.length <= max || newValue.composing.isValid) return newValue;
    var end = max;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end -= 1;
    final selection = newValue.selection;
    return TextEditingValue(
      text: text.substring(0, end),
      selection: selection.isValid
          ? selection.copyWith(
              baseOffset: math.min(selection.baseOffset, end),
              extentOffset: math.min(selection.extentOffset, end))
          : TextSelection.collapsed(offset: end),
    );
  }
}

class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.textController,
    required this.placeholder,
    required this.enabled,
    required this.canSend,
    required this.onSend,
    required this.onChanged,
    this.onAttach,
    this.attachEnabled = true,
  });

  final TextEditingController textController;
  final String placeholder;
  final bool enabled;
  final bool canSend;
  final VoidCallback onSend;
  final ValueChanged<String> onChanged;

  /// Null hides the attach button.
  final VoidCallback? onAttach;
  final bool attachEnabled;

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final strings = look.strings;
    final border = OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: BorderSide(color: look.inputBorder));
    return Container(
      decoration: BoxDecoration(
          color: look.composerColor,
          border: Border(top: BorderSide(color: look.divider, width: 0.5))),
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (onAttach != null) ...[
            Semantics(
              button: true,
              enabled: attachEnabled,
              label: strings.attachFile,
              excludeSemantics: true,
              child: Opacity(
                opacity: attachEnabled ? 1 : 0.4,
                child: InkResponse(
                  key: const ValueKey('giov-attach'),
                  onTap: attachEnabled ? onAttach : null,
                  radius: 24,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: look.inputBorder)),
                    child: Icon(Icons.add, size: 22, color: look.secondaryText),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Semantics(
              label: strings.messageInput,
              child: TextField(
                key: const ValueKey('giov-input'),
                controller: textController,
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                inputFormatters: const [GiovMessageLengthLimit()],
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                onChanged: onChanged,
                style: look.style.text(
                    TextStyle(fontSize: 14, color: look.text),
                    look.style.input),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: placeholder,
                  hintStyle: look.hintStyle,
                  filled: true,
                  fillColor: look.inputFill,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  enabledBorder: border,
                  disabledBorder: border,
                  focusedBorder: border.copyWith(
                      borderSide: BorderSide(color: look.primary, width: 1.5)),
                  border: border,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            enabled: canSend,
            label: strings.sendMessage,
            excludeSemantics: true,
            child: Opacity(
              opacity: canSend ? 1 : 0.35,
              child: InkResponse(
                key: const ValueKey('giov-send'),
                onTap: canSend ? onSend : null,
                radius: 24,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: look.buttonColor),
                  child: Icon(Icons.arrow_upward,
                      size: 20, color: look.buttonTextStyle.color),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Files picked and waiting to be sent, with upload progress while they go, and the reason a pick
/// was refused.
class PendingFiles extends StatelessWidget {
  const PendingFiles(
      {super.key,
      required this.files,
      required this.uploads,
      required this.sending,
      required this.problem,
      required this.onRemove});

  final List<GiovPickedFile> files;
  final List<GiovUploadProgress> uploads;
  final bool sending;
  final String? problem;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final strings = look.strings;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      decoration: BoxDecoration(
          color: look.background,
          border: Border(top: BorderSide(color: look.divider, width: 0.5))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (problem != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(problem!,
                    key: const ValueKey('giov-file-problem'),
                    style: look.errorStyle.copyWith(fontSize: 12)),
              ),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var index = 0; index < files.length; index++)
                Container(
                  constraints:
                      const BoxConstraints(minHeight: 44, maxWidth: 240),
                  padding: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(
                      color: look.inputFill,
                      borderRadius: BorderRadius.circular(22)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          index < uploads.length
                              ? strings.uploading(
                                  (uploads[index].progress * 100).round())
                              : files[index].name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: look.style
                              .text(TextStyle(fontSize: 12, color: look.text),
                                  look.style.hint)
                              .copyWith(
                                  color: look.style.hint?.color ?? look.text),
                        ),
                      ),
                      if (!sending)
                        Semantics(
                          button: true,
                          label: strings.removeAttachment(files[index].name),
                          excludeSemantics: true,
                          child: InkResponse(
                            key: ValueKey('giov-remove-$index'),
                            onTap: () => onRemove(index),
                            radius: 22,
                            child: SizedBox(
                                width: 44,
                                height: 44,
                                child: Icon(Icons.close,
                                    size: 16, color: look.secondaryText)),
                          ),
                        )
                      else
                        const SizedBox(width: 12),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
