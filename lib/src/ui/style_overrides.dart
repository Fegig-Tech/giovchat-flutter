/// Look-and-feel overrides for [GiovChat], comparable to the React Native SDK's
/// `GiovChatStyleOverrides`: fonts and colours only. Layout, sizes, spacing and the branding footer
/// stay SDK-controlled.
library;

import 'package:flutter/widgets.dart';

/// Typography and colour for one text slot.
@immutable
class GiovTextOverride {
  const GiovTextOverride(
      {this.fontFamily, this.fontWeight, this.fontStyle, this.color});

  final String? fontFamily;
  final FontWeight? fontWeight;
  final FontStyle? fontStyle;
  final Color? color;
}

/// Allowed overrides. Every field is optional; the dashboard's colours and the light/dark theme
/// apply wherever a slot is not set.
@immutable
class GiovChatStyleOverrides {
  const GiovChatStyleOverrides({
    this.fontFamily,
    this.container,
    this.header,
    this.headerTitle,
    this.headerSubtitle,
    this.agentBubble,
    this.visitorBubble,
    this.agentText,
    this.visitorText,
    this.composer,
    this.input,
    this.inputBackground,
    this.button,
    this.buttonText,
    this.form,
    this.formTitle,
    this.label,
    this.hint,
    this.errorText,
  });

  /// Default font family for all customizable text. Register the font in your app first.
  final String? fontFamily;

  /// Background of the chat surface.
  final Color? container;

  /// Header background.
  final Color? header;
  final GiovTextOverride? headerTitle;
  final GiovTextOverride? headerSubtitle;

  /// Agent, greeting and typing bubbles.
  final Color? agentBubble;

  /// The visitor's bubbles.
  final Color? visitorBubble;

  /// Message content (every formatted run), sender labels and timestamps; also the greeting and typing bubbles.
  final GiovTextOverride? agentText;
  final GiovTextOverride? visitorText;

  /// Composer row background.
  final Color? composer;

  /// Text of the composer and the pre-chat inputs.
  final GiovTextOverride? input;
  final Color? inputBackground;

  /// Send, start-chat and retry buttons.
  final Color? button;
  final GiovTextOverride? buttonText;

  /// Pre-chat form background, heading and field labels.
  final Color? form;
  final GiovTextOverride? formTitle;
  final GiovTextOverride? label;

  /// Loading hint, attachment chips, input placeholders.
  final GiovTextOverride? hint;
  final GiovTextOverride? errorText;

  /// [base] with this slot's overrides (and the global [fontFamily]) applied.
  TextStyle text(TextStyle base, GiovTextOverride? slot) => base.copyWith(
        fontFamily: slot?.fontFamily ?? fontFamily,
        fontWeight: slot?.fontWeight,
        fontStyle: slot?.fontStyle,
        color: slot?.color,
      );
}
