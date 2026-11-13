/// Attachments inside a bubble: images in a box of their final shape (a blurred placeholder shows
/// until they load), other files as rows. Downloads carry the conversation's access token.
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

// Flutter 3.47 deprecates this import (Material moves to its own package); the SDK still supports Flutter 3.22.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../core/attachments.dart';
import 'look.dart';

const maxImageWidth = 200.0;
const maxImageHeight = 150.0;

/// The box an image takes before it loads (200 x 150 when its shape is unknown).
Size previewBoxSize(GiovAttachmentPreview? preview) {
  final width = preview?.width, height = preview?.height;
  if (width == null || height == null || width <= 0 || height <= 0) {
    return const Size(maxImageWidth, maxImageHeight);
  }
  final scale =
      math.min(1.0, math.min(maxImageWidth / width, maxImageHeight / height));
  return Size(math.max(1, (width * scale).roundToDouble()),
      math.max(1, (height * scale).roundToDouble()));
}

class AttachmentList extends StatelessWidget {
  const AttachmentList(
      {super.key,
      required this.attachments,
      required this.textColor,
      required this.onDarkSurface});

  final List<GiovAttachment> attachments;
  final Color textColor;

  /// The bubble is dark (the visitor's brand colour or dark mode): borders and placeholders adapt.
  final bool onDarkSurface;

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final strings = look.strings;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < attachments.length; index++)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 6),
              child: () {
                final attachment = attachments[index];
                final url = look.attachmentUrl(attachment.url);
                final name = attachment.displayName.isNotEmpty
                    ? attachment.displayName
                    : (attachment.isImage ? strings.image : strings.attachment);
                return attachment.isImage
                    ? _AttachmentImage(
                        attachment: attachment,
                        url: url,
                        name: name,
                        dark: onDarkSurface)
                    : _FileRow(
                        url: url,
                        name: name,
                        color: textColor,
                        dark: onDarkSurface);
              }(),
            ),
        ],
      ),
    );
  }
}

bool _isHttp(String url) =>
    RegExp(r'^https?://', caseSensitive: false).hasMatch(url);

Future<void> _open(GiovLook look, String url) async {
  if (!_isHttp(url)) return;
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    await look.openUrl(uri);
  } on Object {
    // Nothing can open it.
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow(
      {required this.url,
      required this.name,
      required this.color,
      required this.dark});

  final String url;
  final String name;
  final Color color;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    return Semantics(
      link: true,
      button: true,
      label: look.strings.openAttachment(name),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(look, url),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44, maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
                color:
                    dark ? const Color(0x2EFFFFFF) : const Color(0x1F000000)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.attach_file, size: 16, color: color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        color: color,
                        decoration: TextDecoration.underline,
                        decorationColor: color)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachmentImage extends StatelessWidget {
  const _AttachmentImage(
      {required this.attachment,
      required this.url,
      required this.name,
      required this.dark});

  final GiovAttachment attachment;
  final String url;
  final String name;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final box = previewBoxSize(attachment.preview);
    final thumb = attachment.preview?.thumbBytes;
    final fill = dark ? const Color(0xFF1F1F1F) : const Color(0xFFECECEC);
    return Semantics(
      button: true,
      image: true,
      label: look.strings.openAttachment(name),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(look, url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: box.width,
            height: box.height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: fill),
                if (thumb != null)
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: Image.memory(thumb,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                  ),
                if (_isHttp(url))
                  // Keyed by the URL: a new credential means a fresh load, so a failed image tries again.
                  Image.network(
                    url,
                    key: ValueKey('giov-image:$url'),
                    fit: BoxFit.cover,
                    frameBuilder: (context, child, frame, sync) => sync
                        ? child
                        : AnimatedOpacity(
                            opacity: frame == null ? 0 : 1,
                            duration: const Duration(milliseconds: 150),
                            child: child),
                    errorBuilder: (_, __, ___) => Center(
                        child: Icon(Icons.broken_image_outlined,
                            color: dark
                                ? const Color(0xFF8A8A8A)
                                : const Color(0xFF777777))),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
