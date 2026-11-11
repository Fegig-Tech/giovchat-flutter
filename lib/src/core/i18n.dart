/// The SDK's own interface text in the five languages the Giov dashboard ships (en, fr, es, pt, de).
/// Text the business writes (greeting, placeholder, bot name) comes from the widget configuration and
/// is not translated. Pick the language with [resolveGiovStrings] (default: the device language) and
/// replace any string with [GiovChatStrings.copyWith].
///
/// Generated from the same wording as the React Native SDK (`packages/sdk-rn/src/i18n.ts`).
library;

import 'dart:ui' as ui;

import 'errors.dart';

String _n(num value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

/// Languages the SDK ships.
const giovLocales = <String>['en', 'fr', 'es', 'pt', 'de'];

class GiovChatStrings {
  const GiovChatStrings({
    required this.loading,
    required this.tryAgain,
    required this.retry,
    required this.closeChat,
    required this.connecting,
    required this.reconnecting,
    required this.statusPerson,
    required this.statusBot,
    required this.statusTeam,
    required this.composerPlaceholder,
    required this.messageInput,
    required this.sendMessage,
    required this.attachFile,
    required this.removeAttachment,
    required this.you,
    required this.agent,
    required this.automated,
    required this.botTyping,
    required this.teamTyping,
    required this.sending,
    required this.notSent,
    required this.tapToRetry,
    required this.discard,
    required this.uploading,
    required this.uploadFailed,
    required this.sessionExpired,
    required this.conversationEnded,
    required this.unavailable,
    required this.sendFailed,
    required this.busy,
    required this.attachmentsOff,
    required this.typeNotAllowed,
    required this.fileTooLarge,
    required this.tooManyFiles,
    required this.openAttachment,
    required this.attachment,
    required this.image,
    required this.preChatTitle,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phone,
    required this.required,
    required this.startChat,
    required this.privacy,
  });

  /// Shown while the configuration loads.
  final String loading;

  /// Button after a failure that needs a fresh start.
  final String tryAgain;

  /// Button on a message that was not sent.
  final String retry;

  /// Accessible label of the close button.
  final String closeChat;

  /// Shown while the first connection is made.
  final String connecting;

  /// Banner while the connection is being restored.
  final String reconnecting;

  /// Header status while a person has the conversation.
  final String statusPerson;

  /// Header status while GiovBot answers.
  final String statusBot;

  /// Header status before anyone has answered.
  final String statusTeam;

  /// Default composer placeholder (the workspace may set its own).
  final String composerPlaceholder;
  final String messageInput;
  final String sendMessage;
  final String attachFile;
  final String Function(String) removeAttachment;
  final String you;
  final String agent;
  final String automated;
  final String Function(String) botTyping;
  final String teamTyping;

  /// Under a message that has not been confirmed yet.
  final String sending;

  /// Under a message that failed.
  final String notSent;

  /// Hint on a failed message.
  final String tapToRetry;

  /// Button on a message that was not sent, to drop it.
  final String discard;
  final String Function(int) uploading;
  final String uploadFailed;

  /// Error: the stored session is gone.
  final String sessionExpired;

  /// Error: the conversation was closed or deleted.
  final String conversationEnded;

  /// Error: the server could not be reached.
  final String unavailable;

  /// Error: a message could not be delivered.
  final String sendFailed;

  /// Error: the workspace is at its plan's limit of open conversations.
  final String busy;
  final String attachmentsOff;
  final String Function(String) typeNotAllowed;
  final String Function(String, num) fileTooLarge;
  final String Function(int) tooManyFiles;
  final String Function(String) openAttachment;
  final String attachment;
  final String image;
  final String preChatTitle;
  final String firstName;
  final String lastName;
  final String email;
  final String phone;
  final String Function(String) required;
  final String startChat;

  /// The header link to the workspace's privacy policy.
  final String privacy;

  /// These strings with the given ones replaced. Empty strings are ignored.
  GiovChatStrings copyWith({
    String? loading,
    String? tryAgain,
    String? retry,
    String? closeChat,
    String? connecting,
    String? reconnecting,
    String? statusPerson,
    String? statusBot,
    String? statusTeam,
    String? composerPlaceholder,
    String? messageInput,
    String? sendMessage,
    String? attachFile,
    String Function(String)? removeAttachment,
    String? you,
    String? agent,
    String? automated,
    String Function(String)? botTyping,
    String? teamTyping,
    String? sending,
    String? notSent,
    String? tapToRetry,
    String? discard,
    String Function(int)? uploading,
    String? uploadFailed,
    String? sessionExpired,
    String? conversationEnded,
    String? unavailable,
    String? sendFailed,
    String? busy,
    String? attachmentsOff,
    String Function(String)? typeNotAllowed,
    String Function(String, num)? fileTooLarge,
    String Function(int)? tooManyFiles,
    String Function(String)? openAttachment,
    String? attachment,
    String? image,
    String? preChatTitle,
    String? firstName,
    String? lastName,
    String? email,
    String? phone,
    String Function(String)? required,
    String? startChat,
    String? privacy,
  }) =>
      GiovChatStrings(
        loading: _keep(loading) ?? this.loading,
        tryAgain: _keep(tryAgain) ?? this.tryAgain,
        retry: _keep(retry) ?? this.retry,
        closeChat: _keep(closeChat) ?? this.closeChat,
        connecting: _keep(connecting) ?? this.connecting,
        reconnecting: _keep(reconnecting) ?? this.reconnecting,
        statusPerson: _keep(statusPerson) ?? this.statusPerson,
        statusBot: _keep(statusBot) ?? this.statusBot,
        statusTeam: _keep(statusTeam) ?? this.statusTeam,
        composerPlaceholder:
            _keep(composerPlaceholder) ?? this.composerPlaceholder,
        messageInput: _keep(messageInput) ?? this.messageInput,
        sendMessage: _keep(sendMessage) ?? this.sendMessage,
        attachFile: _keep(attachFile) ?? this.attachFile,
        removeAttachment: removeAttachment ?? this.removeAttachment,
        you: _keep(you) ?? this.you,
        agent: _keep(agent) ?? this.agent,
        automated: _keep(automated) ?? this.automated,
        botTyping: botTyping ?? this.botTyping,
        teamTyping: _keep(teamTyping) ?? this.teamTyping,
        sending: _keep(sending) ?? this.sending,
        notSent: _keep(notSent) ?? this.notSent,
        tapToRetry: _keep(tapToRetry) ?? this.tapToRetry,
        discard: _keep(discard) ?? this.discard,
        uploading: uploading ?? this.uploading,
        uploadFailed: _keep(uploadFailed) ?? this.uploadFailed,
        sessionExpired: _keep(sessionExpired) ?? this.sessionExpired,
        conversationEnded: _keep(conversationEnded) ?? this.conversationEnded,
        unavailable: _keep(unavailable) ?? this.unavailable,
        sendFailed: _keep(sendFailed) ?? this.sendFailed,
        busy: _keep(busy) ?? this.busy,
        attachmentsOff: _keep(attachmentsOff) ?? this.attachmentsOff,
        typeNotAllowed: typeNotAllowed ?? this.typeNotAllowed,
        fileTooLarge: fileTooLarge ?? this.fileTooLarge,
        tooManyFiles: tooManyFiles ?? this.tooManyFiles,
        openAttachment: openAttachment ?? this.openAttachment,
        attachment: _keep(attachment) ?? this.attachment,
        image: _keep(image) ?? this.image,
        preChatTitle: _keep(preChatTitle) ?? this.preChatTitle,
        firstName: _keep(firstName) ?? this.firstName,
        lastName: _keep(lastName) ?? this.lastName,
        email: _keep(email) ?? this.email,
        phone: _keep(phone) ?? this.phone,
        required: required ?? this.required,
        startChat: _keep(startChat) ?? this.startChat,
        privacy: _keep(privacy) ?? this.privacy,
      );

  static String? _keep(String? value) =>
      value != null && value.trim().isNotEmpty ? value : null;
}

final GiovChatStrings _en = GiovChatStrings(
  loading: 'Loading…',
  tryAgain: 'Try again',
  retry: 'Retry',
  closeChat: 'Close chat',
  connecting: 'Connecting…',
  reconnecting: 'Connection lost. Reconnecting…',
  statusPerson: 'Live agent',
  statusBot: 'AI assistant · Online',
  statusTeam: 'We\'ll be with you shortly',
  composerPlaceholder: 'Type a message…',
  messageInput: 'Message',
  sendMessage: 'Send message',
  attachFile: 'Attach file',
  removeAttachment: (name) => 'Remove $name',
  you: 'You',
  agent: 'Agent',
  automated: 'Automated',
  botTyping: (name) => '$name is typing',
  teamTyping: 'Support team is typing',
  sending: 'Sending…',
  notSent: 'Not sent',
  tapToRetry: 'Tap to retry',
  discard: 'Discard',
  uploading: (percent) => 'Uploading $percent%',
  uploadFailed: 'File upload failed',
  sessionExpired: 'Chat session expired. Please start a new chat.',
  conversationEnded: 'This conversation has ended.',
  unavailable: 'Chat is unavailable. Please try again.',
  sendFailed: 'Message could not be sent.',
  busy: 'The team is busy right now. Please try again in a moment.',
  attachmentsOff: 'File attachments are turned off for this chat.',
  typeNotAllowed: (name) => '$name: this file type is not allowed.',
  fileTooLarge: (name, maxMb) =>
      '$name: files must be ${_n(maxMb)} MB or smaller.',
  tooManyFiles: (max) => 'You can attach up to $max files at a time.',
  openAttachment: (name) => 'Open $name',
  attachment: 'Attachment',
  image: 'Image',
  preChatTitle: 'Before we start…',
  firstName: 'First name',
  lastName: 'Last name',
  email: 'Email',
  phone: 'Phone',
  required: (label) => '$label *',
  startChat: 'Start chat',
  privacy: 'GDPR and privacy',
);

final GiovChatStrings _fr = GiovChatStrings(
  loading: 'Chargement…',
  tryAgain: 'Réessayer',
  retry: 'Réessayer',
  closeChat: 'Fermer le chat',
  connecting: 'Connexion…',
  reconnecting: 'Connexion perdue. Reconnexion…',
  statusPerson: 'Conseiller en ligne',
  statusBot: 'Assistant IA · En ligne',
  statusTeam: 'Nous vous répondons très vite',
  composerPlaceholder: 'Écrivez un message…',
  messageInput: 'Message',
  sendMessage: 'Envoyer le message',
  attachFile: 'Joindre un fichier',
  removeAttachment: (name) => 'Retirer $name',
  you: 'Vous',
  agent: 'Conseiller',
  automated: 'Automatique',
  botTyping: (name) => '$name écrit',
  teamTyping: 'L\'équipe écrit',
  sending: 'Envoi…',
  notSent: 'Non envoyé',
  tapToRetry: 'Touchez pour réessayer',
  discard: 'Supprimer',
  uploading: (percent) => 'Envoi $percent %',
  uploadFailed: 'Échec de l\'envoi du fichier',
  sessionExpired: 'La session de chat a expiré. Démarrez un nouveau chat.',
  conversationEnded: 'Cette conversation est terminée.',
  unavailable: 'Le chat est indisponible. Réessayez.',
  sendFailed: 'Le message n\'a pas pu être envoyé.',
  busy: 'L\'équipe est très occupée. Réessayez dans un instant.',
  attachmentsOff: 'Les pièces jointes sont désactivées pour ce chat.',
  typeNotAllowed: (name) => '$name : ce type de fichier n\'est pas autorisé.',
  fileTooLarge: (name, maxMb) =>
      '$name : les fichiers doivent faire ${_n(maxMb)} Mo maximum.',
  tooManyFiles: (max) =>
      'Vous pouvez joindre jusqu\'à $max fichiers à la fois.',
  openAttachment: (name) => 'Ouvrir $name',
  attachment: 'Pièce jointe',
  image: 'Image',
  preChatTitle: 'Avant de commencer…',
  firstName: 'Prénom',
  lastName: 'Nom',
  email: 'E-mail',
  phone: 'Téléphone',
  required: (label) => '$label *',
  startChat: 'Démarrer le chat',
  privacy: 'RGPD et confidentialité',
);

final GiovChatStrings _es = GiovChatStrings(
  loading: 'Cargando…',
  tryAgain: 'Reintentar',
  retry: 'Reintentar',
  closeChat: 'Cerrar chat',
  connecting: 'Conectando…',
  reconnecting: 'Conexión perdida. Reconectando…',
  statusPerson: 'Agente en vivo',
  statusBot: 'Asistente de IA · En línea',
  statusTeam: 'Te atenderemos en breve',
  composerPlaceholder: 'Escribe un mensaje…',
  messageInput: 'Mensaje',
  sendMessage: 'Enviar mensaje',
  attachFile: 'Adjuntar archivo',
  removeAttachment: (name) => 'Quitar $name',
  you: 'Tú',
  agent: 'Agente',
  automated: 'Automático',
  botTyping: (name) => '$name está escribiendo',
  teamTyping: 'El equipo está escribiendo',
  sending: 'Enviando…',
  notSent: 'No enviado',
  tapToRetry: 'Toca para reintentar',
  discard: 'Descartar',
  uploading: (percent) => 'Subiendo $percent %',
  uploadFailed: 'No se pudo subir el archivo',
  sessionExpired: 'La sesión de chat caducó. Inicia un chat nuevo.',
  conversationEnded: 'Esta conversación ha terminado.',
  unavailable: 'El chat no está disponible. Inténtalo de nuevo.',
  sendFailed: 'No se pudo enviar el mensaje.',
  busy: 'El equipo está ocupado ahora. Inténtalo de nuevo en un momento.',
  attachmentsOff: 'Los archivos adjuntos están desactivados en este chat.',
  typeNotAllowed: (name) => '$name: este tipo de archivo no está permitido.',
  fileTooLarge: (name, maxMb) =>
      '$name: los archivos deben pesar ${_n(maxMb)} MB o menos.',
  tooManyFiles: (max) => 'Puedes adjuntar hasta $max archivos a la vez.',
  openAttachment: (name) => 'Abrir $name',
  attachment: 'Archivo adjunto',
  image: 'Imagen',
  preChatTitle: 'Antes de empezar…',
  firstName: 'Nombre',
  lastName: 'Apellido',
  email: 'Correo electrónico',
  phone: 'Teléfono',
  required: (label) => '$label *',
  startChat: 'Iniciar chat',
  privacy: 'RGPD y privacidad',
);

final GiovChatStrings _pt = GiovChatStrings(
  loading: 'Carregando…',
  tryAgain: 'Tentar novamente',
  retry: 'Tentar novamente',
  closeChat: 'Fechar chat',
  connecting: 'Conectando…',
  reconnecting: 'Conexão perdida. Reconectando…',
  statusPerson: 'Atendente ao vivo',
  statusBot: 'Assistente de IA · Online',
  statusTeam: 'Responderemos em breve',
  composerPlaceholder: 'Digite uma mensagem…',
  messageInput: 'Mensagem',
  sendMessage: 'Enviar mensagem',
  attachFile: 'Anexar arquivo',
  removeAttachment: (name) => 'Remover $name',
  you: 'Você',
  agent: 'Atendente',
  automated: 'Automático',
  botTyping: (name) => '$name está digitando',
  teamTyping: 'A equipe está digitando',
  sending: 'Enviando…',
  notSent: 'Não enviada',
  tapToRetry: 'Toque para tentar novamente',
  discard: 'Descartar',
  uploading: (percent) => 'Enviando $percent%',
  uploadFailed: 'Falha ao enviar o arquivo',
  sessionExpired: 'A sessão do chat expirou. Inicie um novo chat.',
  conversationEnded: 'Esta conversa foi encerrada.',
  unavailable: 'O chat está indisponível. Tente novamente.',
  sendFailed: 'Não foi possível enviar a mensagem.',
  busy: 'A equipe está ocupada agora. Tente novamente em instantes.',
  attachmentsOff: 'Os anexos estão desativados neste chat.',
  typeNotAllowed: (name) => '$name: este tipo de arquivo não é permitido.',
  fileTooLarge: (name, maxMb) =>
      '$name: os arquivos devem ter até ${_n(maxMb)} MB.',
  tooManyFiles: (max) => 'Você pode anexar até $max arquivos por vez.',
  openAttachment: (name) => 'Abrir $name',
  attachment: 'Anexo',
  image: 'Imagem',
  preChatTitle: 'Antes de começar…',
  firstName: 'Nome',
  lastName: 'Sobrenome',
  email: 'E-mail',
  phone: 'Telefone',
  required: (label) => '$label *',
  startChat: 'Iniciar chat',
  privacy: 'Privacidade e RGPD',
);

final GiovChatStrings _de = GiovChatStrings(
  loading: 'Wird geladen…',
  tryAgain: 'Erneut versuchen',
  retry: 'Erneut versuchen',
  closeChat: 'Chat schließen',
  connecting: 'Verbindung wird hergestellt…',
  reconnecting: 'Verbindung unterbrochen. Neuer Versuch…',
  statusPerson: 'Live-Support',
  statusBot: 'KI-Assistent · Online',
  statusTeam: 'Wir sind gleich für dich da',
  composerPlaceholder: 'Nachricht schreiben…',
  messageInput: 'Nachricht',
  sendMessage: 'Nachricht senden',
  attachFile: 'Datei anhängen',
  removeAttachment: (name) => '$name entfernen',
  you: 'Du',
  agent: 'Support',
  automated: 'Automatisch',
  botTyping: (name) => '$name schreibt',
  teamTyping: 'Das Team schreibt',
  sending: 'Wird gesendet…',
  notSent: 'Nicht gesendet',
  tapToRetry: 'Tippen zum Wiederholen',
  discard: 'Verwerfen',
  uploading: (percent) => 'Wird hochgeladen: $percent %',
  uploadFailed: 'Datei konnte nicht hochgeladen werden',
  sessionExpired: 'Die Chat-Sitzung ist abgelaufen. Starte einen neuen Chat.',
  conversationEnded: 'Diese Unterhaltung ist beendet.',
  unavailable: 'Der Chat ist nicht verfügbar. Bitte versuche es erneut.',
  sendFailed: 'Die Nachricht konnte nicht gesendet werden.',
  busy:
      'Das Team ist gerade ausgelastet. Bitte versuche es gleich noch einmal.',
  attachmentsOff: 'Dateianhänge sind in diesem Chat deaktiviert.',
  typeNotAllowed: (name) => '$name: Dieser Dateityp ist nicht erlaubt.',
  fileTooLarge: (name, maxMb) =>
      '$name: Dateien dürfen höchstens ${_n(maxMb)} MB groß sein.',
  tooManyFiles: (max) => 'Du kannst bis zu $max Dateien auf einmal anhängen.',
  openAttachment: (name) => '$name öffnen',
  attachment: 'Anhang',
  image: 'Bild',
  preChatTitle: 'Bevor es losgeht…',
  firstName: 'Vorname',
  lastName: 'Nachname',
  email: 'E-Mail',
  phone: 'Telefon',
  required: (label) => '$label *',
  startChat: 'Chat starten',
  privacy: 'DSGVO und Datenschutz',
);

/// Every shipped language, by code.
final Map<String, GiovChatStrings> giovStrings = {
  'en': _en,
  'fr': _fr,
  'es': _es,
  'pt': _pt,
  'de': _de
};

/// "fr-CA" becomes "fr", "pt_BR" becomes "pt"; anything not shipped falls back to English.
String resolveGiovLocale(String? value) {
  final language =
      (value ?? '').trim().toLowerCase().split(RegExp('[-_]')).first;
  return giovLocales.contains(language) ? language : 'en';
}

/// The device language (BCP 47) from the platform, or "en".
String giovDeviceLocale() {
  try {
    final locale = ui.PlatformDispatcher.instance.locale;
    final tag = locale.toLanguageTag();
    return tag.isEmpty || tag == 'und' ? 'en' : tag;
  } on Object {
    return 'en';
  }
}

/// The strings for a locale (default: the device language) with the host's overrides on top.
GiovChatStrings resolveGiovStrings(
    {String? locale,
    GiovChatStrings Function(GiovChatStrings base)? override}) {
  final base = giovStrings[resolveGiovLocale(locale ?? giovDeviceLocale())]!;
  return override == null ? base : override(base);
}

/// The sentence a person sees for a failure; the SDK never shows server text.
extension GiovChatErrorText on GiovChatStrings {
  String describeError(Object error) => switch (error) {
        GiovSessionExpiredException() => sessionExpired,
        GiovConversationClosedException() => conversationEnded,
        GiovWorkspaceBusyException() => busy,
        GiovAttachmentRejectedException() => uploadFailed,
        GiovSendFailedException() => sendFailed,
        _ => unavailable,
      };
}
