/// The chat header: avatar (photo, GiovBot mark or initial), who is answering and a status line.
library;

import 'package:flutter/material.dart';

import '../core/identity.dart';
import 'bubbles.dart';
import 'look.dart';

class ChatHeader extends StatelessWidget {
  const ChatHeader(
      {super.key,
      required this.title,
      this.subtitle,
      this.avatarUrl,
      this.kind,
      this.onClose,
      this.onPrivacy});

  final String title;
  final String? subtitle;

  /// http(s) photo of the person or bot answering.
  final String? avatarUrl;
  final GiovHeaderKind? kind;
  final VoidCallback? onClose;

  /// Opens the privacy policy (the web widget's "GDPR and privacy"); null hides the button.
  final VoidCallback? onPrivacy;

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final onHeader =
        look.style.headerTitle?.color ?? giovReadableOn(look.headerColor);
    final letter = title.trim().isEmpty
        ? ''
        : String.fromCharCode(title.trim().runes.first).toUpperCase();
    final initial = MediaQuery.withNoTextScaling(
      child: Text(letter,
          style: look.style.text(
              TextStyle(
                  color: onHeader, fontWeight: FontWeight.w700, fontSize: 17),
              look.style.headerTitle)),
    );
    final avatar = Container(
      width: 38,
      height: 38,
      clipBehavior: Clip.antiAlias,
      decoration:
          BoxDecoration(color: onHeader.withAlpha(56), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: avatarUrl != null
          ? Image.network(avatarUrl!,
              width: 38,
              height: 38,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => initial)
          : kind == GiovHeaderKind.bot
              ? const GiovBotMark(size: 26)
              : initial,
    );
    return Material(
      color: look.headerColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            ExcludeSemantics(child: avatar),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: look.style.text(
                          TextStyle(
                              color: onHeader,
                              fontWeight: FontWeight.w700,
                              fontSize: 16),
                          look.style.headerTitle),
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        key: const ValueKey('giov-header-status'),
                        style: look.style.text(
                            TextStyle(
                                color: giovSecondaryOn(look.headerColor,
                                    onHeader.withAlpha(199), onHeader),
                                fontSize: 12),
                            look.style.headerSubtitle),
                      ),
                    ),
                ],
              ),
            ),
            if (onPrivacy != null)
              Semantics(
                button: true,
                link: true,
                label: look.strings.privacy,
                excludeSemantics: true,
                child: InkResponse(
                  key: const ValueKey('giov-privacy'),
                  onTap: onPrivacy,
                  radius: 24,
                  child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(Icons.privacy_tip_outlined,
                          color: onHeader, size: 20)),
                ),
              ),
            if (onClose != null)
              Semantics(
                button: true,
                label: look.strings.closeChat,
                excludeSemantics: true,
                child: InkResponse(
                  key: const ValueKey('giov-close'),
                  onTap: onClose,
                  radius: 24,
                  child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(Icons.close, color: onHeader, size: 20)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
