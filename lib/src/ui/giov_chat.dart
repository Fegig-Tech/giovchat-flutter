/// [GiovChat]: the ready-made chat screen. Embed it in any route, sheet or tab.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:http/http.dart' as http;

import '../core/attachments.dart';
import '../core/client.dart'
    show GiovPushOptions, GiovPushPlatform, GiovPushResult, giovDefaultBaseUrl;
import '../core/controller.dart';
import '../core/errors.dart';
import '../core/i18n.dart';
import '../core/identity.dart';
import '../core/models.dart';
import '../core/session_store.dart';
import '../core/socket.dart';
import 'bubbles.dart';
import 'chat_markdown.dart';
import 'composer.dart';
import 'header.dart';
import 'look.dart';
import 'pre_chat_form.dart';
import 'style_overrides.dart';

/// Where the header's privacy button goes when the workspace set no `privacyPolicyUrl` (as on the web).
const giovPrivacyPolicyUrl = 'https://giovchat.app/privacy';

/// The full chat screen on top of a [GiovChatController].
///
/// Either pass a [controller] you own (you create, start-up options, and dispose it), or pass
/// [tenantKey] (and the other options) and the widget creates, starts and disposes its own.
///
/// ```dart
/// GiovChat(tenantKey: 'ws_123', onClose: () => Navigator.pop(context))
/// ```
///
/// The widget draws every phase of the session (loading, pre-chat form, greeting, connecting,
/// active conversation, error with retry), forwards app lifecycle changes to the controller, and
/// tells it when the chat is visible. The dashboard's colour and theme apply unless overridden.
class GiovChat extends StatefulWidget {
  const GiovChat({
    super.key,
    this.controller,
    this.tenantKey,
    this.baseUrl = giovDefaultBaseUrl,
    this.contact,
    this.sessionKey,
    this.sessionStore,
    this.keepConnected = false,
    this.visible = true,
    this.autoStart = true,
    this.onClose,
    this.theme,
    this.primaryColor,
    this.styleOverrides = const GiovChatStyleOverrides(),
    this.locale,
    this.strings,
    this.attachmentPicker,
    this.onOpenUrl,
    this.safeArea = true,
    this.onError,
    this.onConversationStart,
    this.onConnectionStatusChange,
    this.onUnreadCountChange,
    this.httpClient,
    this.socketFactory,
  }) : assert((controller == null) != (tenantKey == null),
            'Pass either a controller or a tenantKey.');

  /// A controller you manage. The widget never disposes it. When it is unmounted the chat is marked
  /// not visible (so a `keepConnected` controller counts unread replies). Interface language comes
  /// from the controller unless [locale] or [strings] is set here.
  final GiovChatController? controller;

  /// The workspace key; the widget then creates and owns its controller.
  final String? tenantKey;

  /// Options for the controller the widget creates (ignored when [controller] is given, except
  /// [contact], which also pre-fills the pre-chat form).
  final String baseUrl;
  final GiovContact? contact;
  final String? sessionKey;

  /// Back this with secure storage to resume the conversation across launches.
  final GiovSessionStore? sessionStore;
  final bool keepConnected;
  final void Function(GiovChatException error)? onError;
  final void Function(String conversationId)? onConversationStart;
  final void Function(GiovConnectionStatus status)? onConnectionStatusChange;
  final void Function(int count)? onUnreadCountChange;

  /// For tests and proxies.
  final http.Client? httpClient;
  final GiovSocketFactory? socketFactory;

  /// Whether the chat is on screen. Hidden chats disconnect (unless [keepConnected]); showing one
  /// clears unread replies.
  final bool visible;

  /// Start the controller when the widget mounts. [GiovChatController.start] does nothing on a
  /// controller that is already started, so this is safe with one you own (its socket stays).
  final bool autoStart;

  /// Shows a close button in the header when set.
  final VoidCallback? onClose;

  /// Overrides the dashboard's theme; auto follows the device.
  final GiovThemeMode? theme;

  /// Overrides the dashboard's brand colour.
  final Color? primaryColor;

  /// Fonts and colours per surface. Layout and the branding footer stay SDK-controlled.
  final GiovChatStyleOverrides styleOverrides;

  /// Interface language ("fr", "pt-BR", …); defaults to the device language.
  final String? locale;

  /// Replace any interface string: `strings: (base) => base.copyWith(sendMessage: 'Envoyer')`.
  final GiovChatStrings Function(GiovChatStrings base)? strings;

  /// Enables attachments with the host's own picker; without it the attach button is hidden.
  final GiovAttachmentPicker? attachmentPicker;

  /// How links and attachments open (default: `url_launcher`, external application). Only http(s)
  /// and mailto links reach it.
  final GiovUrlOpener? onOpenUrl;

  /// Keep content clear of notches and the home indicator. Turn off inside a sheet that already does.
  final bool safeArea;

  @override
  State<GiovChat> createState() => GiovChatState();
}

class GiovChatState extends State<GiovChat> with WidgetsBindingObserver {
  GiovChatController? _owned;
  late GiovChatController _controller;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<GiovPickedFile> _files = [];
  String? _problem;
  bool _busy = false;
  bool _stick = true;
  bool _scrollQueued = false;
  (int, int, bool, GiovChatPhase)? _signature;

  /// The last live reply read out to screen readers.
  GiovMessage? _announced;

  /// The controller in use (the one passed in, or the one the widget created).
  GiovChatController get controller => _controller;

  /// Forgets the conversation and starts fresh (sign-out, "new chat").
  Future<void> reset() async {
    _input.clear();
    setState(() {
      _files = [];
      _problem = null;
    });
    await _controller.reset();
  }

  /// See [GiovChatController.registerPushToken].
  Future<GiovPushResult> registerPushToken(
          String token, GiovPushPlatform platform,
          {GiovPushOptions options = const GiovPushOptions()}) =>
      _controller.registerPushToken(token, platform, options: options);

  String get _scope => giovSessionScope(widget.baseUrl, widget.tenantKey ?? '',
      contact: widget.contact, sessionKey: widget.sessionKey);

  GiovChatController _create() => GiovChatController(
        tenantKey: widget.tenantKey!,
        baseUrl: widget.baseUrl,
        contact: widget.contact,
        sessionKey: widget.sessionKey,
        sessionStore: widget.sessionStore,
        keepConnected: widget.keepConnected,
        visible: widget.visible,
        locale: widget.locale,
        overrideStrings: widget.strings,
        onError: widget.onError,
        onConversationStart: widget.onConversationStart,
        onConnectionStatusChange: widget.onConnectionStatusChange,
        onUnreadCountChange: widget.onUnreadCountChange,
        httpClient: widget.httpClient,
        socketFactory: widget.socketFactory,
      );

  void _attach() {
    final external = widget.controller;
    if (external != null) {
      _owned = null;
      _controller = external;
    } else {
      _controller = _owned = _create();
    }
    _controller.addListener(_changed);
    _announced = _controller.lastIncoming;
    // start() does nothing on a controller that is already started, so the connection stays.
    if (widget.autoStart) unawaited(_controller.start());
    if (external != null && external.visible != widget.visible) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => external.setVisible(widget.visible));
    }
  }

  void _detach() {
    _controller.removeListener(_changed);
    final owned = _owned;
    if (owned != null) {
      owned.dispose();
    } else {
      // The chat is gone from the screen: a keepConnected controller keeps counting unread replies.
      final external = _controller;
      scheduleMicrotask(() => external.setVisible(false));
    }
    _owned = null;
  }

  void _changed() {
    if (!mounted) return;
    _announceIncoming();
    setState(() {});
  }

  /// A reply that arrives while the chat is on screen is read out once (the saved copy, not each
  /// streamed word).
  void _announceIncoming() {
    final incoming = _controller.lastIncoming;
    if (incoming == null || identical(incoming, _announced)) return;
    _announced = incoming;
    if (!widget.visible) return;
    final look = _look(context, _controller.config);
    final text = chatMarkdownPlainText(incoming.content);
    final label = messageSenderLabel(incoming, look.strings,
        botName: look.botName, agentName: _controller.currentAgentName);
    // `announce` is deprecated from Flutter 3.35 in favour of `sendAnnouncement`, which 3.22 (the
    // minimum supported version) does not have.
    // ignore: deprecated_member_use
    unawaited(SemanticsService.announce(text.isEmpty ? label : '$label: $text',
        Directionality.maybeOf(context) ?? TextDirection.ltr));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach();
  }

  @override
  void didUpdateWidget(GiovChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    final replaced = widget.controller != oldWidget.controller ||
        (widget.controller == null &&
            (widget.tenantKey != oldWidget.tenantKey ||
                _scopeOf(oldWidget) != _scope));
    if (replaced) {
      _detach();
      _input.clear();
      _files = [];
      _problem = null;
      _attach();
    } else if (widget.visible != oldWidget.visible) {
      final controller = _controller;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => controller.setVisible(widget.visible));
    }
  }

  static String _scopeOf(GiovChat w) =>
      giovSessionScope(w.baseUrl, w.tenantKey ?? '',
          contact: w.contact, sessionKey: w.sessionKey);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _controller.handleLifecycle(state);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detach();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------------------------
  // Actions

  GiovChatStrings get _strings =>
      widget.locale != null || widget.strings != null
          ? resolveGiovStrings(locale: widget.locale, override: widget.strings)
          : _controller.strings;

  String _problemText(AttachmentProblem problem, GiovChatStrings strings) =>
      switch (problem) {
        AttachmentsDisabled() => strings.attachmentsOff,
        AttachmentTypeNotAllowed() => strings.typeNotAllowed(problem.name),
        AttachmentTooLarge() =>
          strings.fileTooLarge(problem.name, problem.maxSizeMb),
        TooManyAttachments() => strings.tooManyFiles(problem.max),
      };

  bool get _composing {
    final phase = _controller.phase;
    return phase == GiovChatPhase.ready ||
        phase == GiovChatPhase.connecting ||
        phase == GiovChatPhase.active;
  }

  bool get _canSend =>
      _composing &&
      !_controller.sending &&
      !_busy &&
      (_input.text.trim().isNotEmpty || _files.isNotEmpty);

  Future<void> _send() async {
    if (!_canSend) return;
    final text = _input.text.trim();
    final sent = List<GiovPickedFile>.of(_files);
    _stick = true;
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await _controller.send(text, files: sent);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!ok || !mounted) return;
    if (_input.text.trim() == text) _input.clear();
    setState(() {
      if (_files.length == sent.length &&
          Iterable<int>.generate(sent.length)
              .every((i) => identical(_files[i], sent[i]))) {
        _files = [];
      }
      _problem = null;
    });
  }

  Future<void> _attachFiles() async {
    final picker = widget.attachmentPicker;
    final config = _controller.config;
    if (picker == null) return;
    final policy =
        config?.attachmentPolicy ?? GiovAttachmentPolicy.defaultPolicy;
    setState(() => _problem = null);
    try {
      final picked = await picker(GiovPickerRequest(
        allowedTypes: policy.allowedTypes,
        maxFiles: math.max(1, maxAttachedFiles - _files.length),
        maxSizeMb: policy.maxSizeMb,
      ));
      if (!mounted) return;
      final checked =
          _controller.checkFiles(picked, alreadyAttached: _files.length);
      final strings = _strings;
      setState(() {
        if (checked.accepted.isNotEmpty) {
          _files = [..._files, ...checked.accepted];
        }
        if (checked.problems.isNotEmpty) {
          _problem = checked.problems
              .map((problem) => _problemText(problem, strings))
              .join(' ');
        }
      });
    } on Object {
      // The picker was dismissed or failed; nothing changes.
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Scrolling

  /// After new content, follow it only when the visitor is already at the bottom (or just sent).
  void _followNewest({required bool animate}) {
    if (_scrollQueued) return;
    _scrollQueued = true;
    var attempts = 3;
    void step(Duration _) {
      if (!mounted || !_scroll.hasClients) {
        _scrollQueued = false;
        return;
      }
      final target = _scroll.position.maxScrollExtent;
      if ((target - _scroll.position.pixels).abs() > 0.5) {
        if (animate &&
            attempts == 3 &&
            !MediaQuery.disableAnimationsOf(context)) {
          unawaited(_scroll.animateTo(target,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut));
        } else {
          _scroll.jumpTo(target);
        }
      }
      // A lazy list estimates its extent; check once more after the frame it laid out.
      if (--attempts > 0) {
        WidgetsBinding.instance.addPostFrameCallback(step);
      } else {
        _scrollQueued = false;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback(step);
  }

  // ---------------------------------------------------------------------------------------------
  // Build

  GiovLook _look(BuildContext context, GiovWidgetConfig? config) {
    final mode = widget.theme ?? config?.theme ?? GiovThemeMode.light;
    final platform =
        MediaQuery.maybePlatformBrightnessOf(context) ?? Brightness.light;
    final dark = mode == GiovThemeMode.dark ||
        (mode == GiovThemeMode.auto && platform == Brightness.dark);
    final header = _controller.header;
    return GiovLook(
      dark: dark,
      primary: widget.primaryColor ?? parseBrandColor(config?.primaryColor),
      strings: _strings,
      style: widget.styleOverrides,
      openUrl: widget.onOpenUrl ?? defaultGiovUrlOpener,
      attachmentUrl: _controller.attachmentUrl,
      botName: config?.botName ??
          (header?.kind == GiovHeaderKind.bot ? header?.title : null),
      config: config,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final config = controller.config;
    final look = _look(context, config);
    final strings = look.strings;
    final phase = controller.phase;
    final identity = controller.header;
    final subtitle =
        phase == GiovChatPhase.active || phase == GiovChatPhase.ready
            ? identity?.status(strings)
            : phase == GiovChatPhase.connecting
                ? strings.connecting
                : null;
    final bottomInset = math.max(MediaQuery.viewInsetsOf(context).bottom,
        widget.safeArea ? MediaQuery.paddingOf(context).bottom : 0.0);

    Widget body() => switch (phase) {
          GiovChatPhase.loading ||
          GiovChatPhase.idle =>
            _Skeleton(label: strings.loading),
          GiovChatPhase.error => _ErrorView(
              text: controller.error != null
                  ? strings.describeError(controller.error!)
                  : strings.unavailable,
              onRetry: controller.retry,
            ),
          GiovChatPhase.preChat => PreChatForm(
              fields: controller.requiredFields,
              initialValues: widget.contact,
              onSubmit: (info) => unawaited(controller.submitContact(info))),
          _ => _conversation(look),
        };

    Widget content = Material(
      color: look.background,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          children: [
            ColoredBox(
              color: look.headerColor,
              child: SafeArea(
                bottom: false,
                top: widget.safeArea,
                child: ChatHeader(
                  title: identity?.title ?? config?.title ?? 'Chat',
                  subtitle: subtitle,
                  avatarUrl: identity?.avatar,
                  kind: identity?.kind,
                  onClose: widget.onClose,
                  onPrivacy: config == null
                      ? null
                      : () => unawaited(openGiovLink(look.openUrl,
                          config.privacyPolicyUrl ?? giovPrivacyPolicyUrl)),
                ),
              ),
            ),
            Expanded(child: SafeArea(top: false, bottom: false, child: body())),
            if (config?.showBranding != false) _Branding(onOpen: look.openUrl),
          ],
        ),
      ),
    );
    content =
        MediaQuery.withClampedTextScaling(maxScaleFactor: 2.0, child: content);
    content = GiovChatScope(look: look, child: content);
    if (Localizations.of<MaterialLocalizations>(
            context, MaterialLocalizations) ==
        null) {
      content = Localizations(
        locale: const Locale('en'),
        delegates: const [
          DefaultMaterialLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate
        ],
        child: content,
      );
    }
    return content;
  }

  Widget _conversation(GiovLook look) {
    final controller = _controller;
    final config = controller.config;
    final strings = look.strings;
    final messages = controller.messages;
    final typing = controller.agentTyping;
    final signature = (
      messages.length,
      messages.isEmpty ? 0 : messages.last.content.length,
      typing,
      controller.phase
    );
    if (signature != _signature) {
      _signature = signature;
      if (_stick) {
        _followNewest(animate: messages.isEmpty || !messages.last.isStreaming);
      }
    }
    final count = 1 + messages.length + (typing ? 1 : 0);
    final canAttach = widget.attachmentPicker != null &&
        controller.hasConversation &&
        (config?.attachmentPolicy ?? GiovAttachmentPolicy.defaultPolicy)
            .enabled &&
        (config?.attachmentPolicy ?? GiovAttachmentPolicy.defaultPolicy)
            .allowedTypes
            .isNotEmpty;
    final error = controller.error;
    // While a lost connection is restored, say so (a busy workspace or a refusal keeps its own text).
    final restoring = controller.reconnecting &&
        (error == null ||
            error is GiovNetworkException ||
            error is GiovServerException);
    final notice = restoring
        ? strings.reconnecting
        : (error != null ? strings.describeError(error) : null);
    return Column(
      children: [
        if (notice != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(notice,
                  key: ValueKey(restoring ? 'giov-reconnecting' : 'giov-error'),
                  textAlign: TextAlign.center,
                  style: look.errorStyle),
            ),
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.depth == 0 &&
                  (notification is ScrollUpdateNotification ||
                      notification is ScrollEndNotification)) {
                _stick = notification.metrics.extentAfter < 80;
              }
              return false;
            },
            child: ListView.builder(
              key: const ValueKey('giov-messages'),
              controller: _scroll,
              padding: const EdgeInsets.only(bottom: 12),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              itemCount: count,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return config == null
                      ? const SizedBox.shrink()
                      : GreetingBubble(
                          key: const ValueKey('giov-greeting'),
                          text: config.greetingText);
                }
                if (index - 1 < messages.length) {
                  final message = messages[index - 1];
                  final id = message.clientMessageId;
                  return MessageBubble(
                    key: ValueKey(message.key),
                    message: message,
                    onRetry:
                        id == null ? null : (_) => _controller.retryMessage(id),
                    onDiscard: id == null
                        ? null
                        : (_) => _controller.discardMessage(id),
                  );
                }
                return TypingIndicator(
                    key: const ValueKey('giov-typing-row'),
                    isBot: controller.agentTypingIsBot);
              },
            ),
          ),
        ),
        if (_files.isNotEmpty || _problem != null)
          PendingFiles(
              files: _files,
              uploads: controller.uploads,
              sending: controller.sending,
              problem: _problem,
              onRemove: (index) =>
                  setState(() => _files = [..._files]..removeAt(index))),
        Composer(
          textController: _input,
          placeholder: config?.textArea ?? strings.composerPlaceholder,
          // The visitor can keep typing while files upload; only Send waits.
          enabled: _composing,
          canSend: _canSend,
          onSend: () => unawaited(_send()),
          onChanged: (value) {
            setState(() {});
            if (value.trim().isNotEmpty) controller.notifyTyping();
          },
          onAttach: canAttach ? () => unawaited(_attachFiles()) : null,
          attachEnabled:
              !controller.sending && _files.length < maxAttachedFiles,
        ),
      ],
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final fill = look.dark ? const Color(0xFF1C1C1C) : const Color(0xFFF0F0F0);
    Widget bar(double width, double height, {bool right = false}) => Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: width,
            height: height,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
                color: fill, borderRadius: BorderRadius.circular(16)),
          ),
        );
    return Semantics(
      label: label,
      liveRegion: true,
      child: Padding(
        key: const ValueKey('giov-loading'),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            bar(220, 44),
            bar(150, 36, right: true),
            bar(250, 60),
            const Spacer(),
            Center(child: Text(label, style: look.hintStyle)),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.text, required this.onRetry});

  final String text;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
                liveRegion: true,
                child: Text(text,
                    key: const ValueKey('giov-error'),
                    textAlign: TextAlign.center,
                    style: look.errorStyle)),
            const SizedBox(height: 14),
            Semantics(
              button: true,
              label: look.strings.tryAgain,
              excludeSemantics: true,
              child: Material(
                color: look.buttonColor,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  key: const ValueKey('giov-try-again'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => unawaited(onRetry()),
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(minHeight: 44, minWidth: 44),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 11),
                      child: Text(look.strings.tryAgain,
                          textAlign: TextAlign.center,
                          style: look.buttonTextStyle),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Powered by GiovChat". Deliberately isolated from the style overrides, like the other SDKs.
class _Branding extends StatelessWidget {
  const _Branding({required this.onOpen});

  final GiovUrlOpener onOpen;

  @override
  Widget build(BuildContext context) => Semantics(
        link: true,
        label: 'Powered by GiovChat',
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('giov-branding'),
          onTap: () => unawaited(onOpen(Uri.parse(
                  'https://giovchat.app/?utm_source=flutter_widget&utm_medium=powered_by'))
              .catchError((Object _) => false)),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: const BoxDecoration(
                color: Color(0xFFFFFFFF),
                border: Border(
                    top: BorderSide(color: Color(0xFFEBEBEB), width: 0.5))),
            child: const Text.rich(
              TextSpan(
                style: TextStyle(color: Color(0xFF52525B), fontSize: 12),
                children: [
                  TextSpan(text: 'Powered by '),
                  TextSpan(
                      text: 'GiovChat',
                      style: TextStyle(
                          color: Color(0xFF7C3AED),
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ),
      );
}
