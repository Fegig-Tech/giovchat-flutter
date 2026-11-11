/// Attachments, as the protocol describes them (README.md, "Attachments"): the server's file
/// limits and the answering bot's policy decide what a visitor may send, previews from the
/// network are validated field by field, and downloads carry a narrow per-conversation access
/// token. Pure Dart.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The server's upload limit.
const maxAttachmentBytes = 10 * 1024 * 1024;

/// At most this many attachments in one message frame.
const maxAttachedFiles = 5;

/// Types `upload-visitor` accepts; a policy wildcard cannot enable anything else.
const supportedAttachmentTypes = <String>[
  'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'application/pdf',
  'text/plain', 'text/csv', //
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'audio/mpeg', 'audio/mp4', 'audio/ogg', 'audio/webm', 'audio/wav',
];

/// What a visitor may attach while GiovBot answers (`WidgetConfig.attachments`).
class GiovAttachmentPolicy {
  const GiovAttachmentPolicy(
      {required this.enabled,
      required this.allowedTypes,
      required this.maxSizeMb});

  /// Without a published bot policy, visitors may send images (the widget's default).
  static final defaultPolicy = GiovAttachmentPolicy(
    enabled: true,
    allowedTypes: supportedAttachmentTypes
        .where((type) => type.startsWith('image/'))
        .toList(growable: false),
    maxSizeMb: 10,
  );

  final bool enabled;

  /// Concrete MIME types (wildcards already expanded against [supportedAttachmentTypes]).
  final List<String> allowedTypes;
  final double maxSizeMb;

  static GiovAttachmentPolicy? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json.cast<String, Object?>();
    final patterns = raw['allowedTypes'] is List
        ? (raw['allowedTypes']! as List)
            .whereType<String>()
            .map((type) => type.toLowerCase())
            .toList()
        : defaultPolicy.allowedTypes;
    bool matches(String type) => patterns.any((pattern) =>
        pattern == '*' ||
        pattern == type ||
        (pattern.endsWith('/*') &&
            type.startsWith(pattern.substring(0, pattern.length - 1))));
    final size = raw['maxSizeMb'];
    return GiovAttachmentPolicy(
      enabled: raw['enabled'] != false,
      allowedTypes:
          supportedAttachmentTypes.where(matches).toList(growable: false),
      maxSizeMb:
          size is num && size.isFinite ? size.toDouble().clamp(0.1, 10) : 10,
    );
  }

  int get maxBytes => (maxSizeMb * 1024 * 1024).floor();
}

/// A file the host's picker returned.
class GiovPickedFile {
  /// A file whose bytes are already in memory.
  GiovPickedFile.bytes(
      {required this.name,
      required this.mimeType,
      required Uint8List bytes,
      this.width,
      this.height,
      this.thumbnail})
      : size = bytes.length,
        _open = (() => Stream.value(bytes));

  /// A file read lazily, e.g. `File(path).openRead`; [size] is required for the upload.
  GiovPickedFile.stream(
      {required this.name,
      required this.mimeType,
      required int this.size,
      required Stream<List<int>> Function() openRead,
      this.width,
      this.height,
      this.thumbnail})
      : _open = openRead;

  final String name;

  /// MIME type, e.g. `image/jpeg`. Files without a known type are refused by the policy check.
  final String mimeType;
  final int? size;

  /// Image size, when known; stored so every viewer sees the shape before the image loads.
  final int? width;
  final int? height;

  /// Optional placeholder: `data:image/jpeg;base64,…` (or webp), about 32 px, at most 6000 chars.
  final String? thumbnail;
  final Stream<List<int>> Function() _open;

  Stream<List<int>> openRead() => _open();
}

/// Lets the host open its platform picker (file_picker, image_picker, …). The SDK ships none.
typedef GiovAttachmentPicker = Future<List<GiovPickedFile>> Function(
    GiovPickerRequest request);

class GiovPickerRequest {
  const GiovPickerRequest(
      {required this.allowedTypes,
      required this.maxFiles,
      required this.maxSizeMb});
  final List<String> allowedTypes;
  final int maxFiles;
  final double maxSizeMb;
}

/// Why a picked file cannot be sent.
sealed class AttachmentProblem {
  const AttachmentProblem();
}

class AttachmentsDisabled extends AttachmentProblem {
  const AttachmentsDisabled();
}

class AttachmentTypeNotAllowed extends AttachmentProblem {
  const AttachmentTypeNotAllowed(this.name);
  final String name;
}

class AttachmentTooLarge extends AttachmentProblem {
  const AttachmentTooLarge(this.name, this.maxSizeMb);
  final String name;
  final double maxSizeMb;
}

class TooManyAttachments extends AttachmentProblem {
  const TooManyAttachments(this.max);
  final int max;
}

/// The picked files checked against the policy; the server stays authoritative.
({List<GiovPickedFile> accepted, List<AttachmentProblem> problems})
    validateAttachments(
  List<GiovPickedFile> files,
  GiovAttachmentPolicy policy, {
  int existingCount = 0,
}) {
  if (!policy.enabled) {
    return (
      accepted: const [],
      problems: files.isEmpty ? const [] : const [AttachmentsDisabled()]
    );
  }
  final accepted = <GiovPickedFile>[];
  final problems = <AttachmentProblem>[];
  final capacity =
      (maxAttachedFiles - existingCount).clamp(0, maxAttachedFiles);
  for (final file in files) {
    final size = file.size;
    if (!policy.allowedTypes.contains(file.mimeType.toLowerCase())) {
      problems.add(AttachmentTypeNotAllowed(file.name));
    } else if (size != null &&
        (size > policy.maxBytes || size > maxAttachmentBytes)) {
      problems.add(AttachmentTooLarge(file.name, policy.maxSizeMb));
    } else if (accepted.length >= capacity) {
      if (!problems.any((problem) => problem is TooManyAttachments)) {
        problems.add(const TooManyAttachments(maxAttachedFiles));
      }
    } else {
      accepted.add(file);
    }
  }
  return (accepted: accepted, problems: problems);
}

final _thumbPattern =
    RegExp(r'^data:image\/(jpeg|webp);base64,[A-Za-z0-9+/=]+$');
const _maxThumbLength = 6000;

/// A blurred placeholder for an image while it loads.
class GiovAttachmentPreview {
  const GiovAttachmentPreview({this.thumb, this.width, this.height});

  /// Keeps only the parts of an untrusted preview that are safe to render.
  static GiovAttachmentPreview? sanitize(Object? json) {
    if (json is! Map) return null;
    final thumb = json['thumb'];
    final safeThumb = thumb is String &&
            thumb.length <= _maxThumbLength &&
            _thumbPattern.hasMatch(thumb)
        ? thumb
        : null;
    int? side(Object? value) =>
        value is num && value.isFinite && value > 0 && value <= 20000
            ? value.toInt()
            : null;
    final width = side(json['width']), height = side(json['height']);
    // An aspect ratio needs both sides, so a lone dimension is dropped.
    final sized = width != null && height != null;
    if (safeThumb == null && !sized) return null;
    return GiovAttachmentPreview(
        thumb: safeThumb,
        width: sized ? width : null,
        height: sized ? height : null);
  }

  final String? thumb;
  final int? width;
  final int? height;

  /// The placeholder's bytes, for `Image.memory`.
  Uint8List? get thumbBytes {
    final value = thumb;
    if (value == null) return null;
    try {
      return base64Decode(value.substring(value.indexOf(',') + 1));
    } on FormatException {
      return null;
    }
  }

  double? get aspectRatio =>
      width != null && height != null ? width! / height! : null;
}

/// A file attached to a message.
class GiovAttachment {
  const GiovAttachment(
      {required this.url, this.filename = '', this.preview, this.contentType});

  /// The download URL without credentials; see [attachmentDisplayUrl].
  final String url;

  /// Empty when the server did not say; the UI then names it from the URL.
  final String filename;
  final GiovAttachmentPreview? preview;

  /// Known only for files sent from this device.
  final String? contentType;

  static final _imageExtension =
      RegExp(r'\.(jpe?g|png|gif|webp)$', caseSensitive: false);

  /// Images render inline; everything else is a file row.
  bool get isImage {
    if (contentType != null) return contentType!.startsWith('image/');
    if (preview != null) return true;
    return _imageExtension.hasMatch(_lastSegment(url));
  }

  /// A readable name: the known filename, else the last path segment of the URL.
  String get displayName => filename.isNotEmpty ? filename : _lastSegment(url);

  static String _lastSegment(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final decoded = Uri.decodeComponent(
        path.split('/').lastWhere((part) => part.isNotEmpty, orElse: () => ''));
    // Keys look like `attachments/<tenant>/<conversation>/<file>`, URL-encoded into one segment.
    return decoded.split('/').last;
  }
}

/// `attachmentId` is a JSON-encoded array of URLs; `previews` is a real array aligned by index.
List<GiovAttachment> parseAttachments(Object? attachmentId,
    [Object? previews]) {
  if (attachmentId is! String || attachmentId.isEmpty) return const [];
  Object? urls;
  try {
    urls = jsonDecode(attachmentId);
  } on FormatException {
    return const [];
  }
  if (urls is! List) return const [];
  final list = previews is List ? previews : const <Object?>[];
  final out = <GiovAttachment>[];
  for (var index = 0; index < urls.length; index++) {
    final url = urls[index];
    if (url is! String || url.isEmpty) continue;
    out.add(GiovAttachment(
        url: url,
        preview: GiovAttachmentPreview.sanitize(
            index < list.length ? list[index] : null)));
  }
  return out;
}

/// A narrow token for downloading one conversation's files (`?at=`), stable for hours.
class AttachmentAccess {
  const AttachmentAccess({required this.token, required this.expiresAt});

  static final _pattern = RegExp(r'^[A-Za-z0-9._-]{16,256}$');

  /// Stop using a token this long before it expires.
  static const margin = Duration(minutes: 5);

  static AttachmentAccess? fromJson(Object? json) {
    if (json is! Map) return null;
    final token = json['token'], expiresAt = json['expiresAt'];
    if (token is! String ||
        !_pattern.hasMatch(token) ||
        expiresAt is! num ||
        !expiresAt.isFinite) {
      return null;
    }
    return AttachmentAccess(
        token: token,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt()));
  }

  final String token;

  /// Milliseconds in the wire format.
  final DateTime expiresAt;

  bool usableAt(DateTime now) => expiresAt.difference(now) > margin;

  /// Keeps the current token unless [incoming] expires no earlier.
  static AttachmentAccess? newer(
          AttachmentAccess? current, AttachmentAccess? incoming) =>
      incoming != null &&
              !(current != null &&
                  current.expiresAt.isAfter(incoming.expiresAt))
          ? incoming
          : current;
}

/// Adds exactly one credential: `at` when an access token is usable, else the visitor token.
String attachmentDisplayUrl(String url,
    {String? accessToken, String? visitorToken}) {
  final credential = accessToken != null
      ? 'at=$accessToken'
      : visitorToken != null
          ? 'token=${Uri.encodeQueryComponent(visitorToken)}'
          : '';
  if (credential.isEmpty) return url;
  return '$url${url.contains('?') ? '&' : '?'}$credential';
}

/// The placeholder fields an upload may carry: all three or none, as the server requires.
({String thumb, int width, int height})? uploadPreview(GiovPickedFile file) {
  if (!file.mimeType.startsWith('image/')) return null;
  final preview = GiovAttachmentPreview.sanitize(
      {'thumb': file.thumbnail, 'width': file.width, 'height': file.height});
  final thumb = preview?.thumb,
      width = preview?.width,
      height = preview?.height;
  if (thumb == null || width == null || height == null) return null;
  return (thumb: thumb, width: width, height: height);
}
