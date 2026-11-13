/// The pre-chat form: asks only for the contact fields the workspace requires and the host has not
/// supplied. The button stays disabled until every required field is valid.
library;

// Flutter 3.47 deprecates this import (Material moves to its own package); the SDK still supports Flutter 3.22.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../core/models.dart';
import 'look.dart';

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

class PreChatForm extends StatefulWidget {
  const PreChatForm(
      {super.key,
      required this.fields,
      required this.onSubmit,
      this.initialValues});

  final GiovRequestUserInfo fields;
  final GiovContact? initialValues;
  final void Function(GiovContact info) onSubmit;

  @override
  State<PreChatForm> createState() => _PreChatFormState();
}

class _PreChatFormState extends State<PreChatForm> {
  late final TextEditingController _first =
      TextEditingController(text: widget.initialValues?.firstName ?? '');
  late final TextEditingController _last =
      TextEditingController(text: widget.initialValues?.lastName ?? '');
  late final TextEditingController _email =
      TextEditingController(text: widget.initialValues?.email ?? '');
  late final TextEditingController _phone =
      TextEditingController(text: widget.initialValues?.phone ?? '');

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool get _valid =>
      (!widget.fields.firstName || _first.text.trim().isNotEmpty) &&
      (!widget.fields.lastName || _last.text.trim().isNotEmpty) &&
      (!widget.fields.email || _emailPattern.hasMatch(_email.text.trim())) &&
      (!widget.fields.phone || _phone.text.trim().isNotEmpty);

  void _submit() {
    if (!_valid) return;
    String? clean(TextEditingController controller) =>
        controller.text.trim().isEmpty ? null : controller.text.trim();
    widget.onSubmit(GiovContact(
        firstName: clean(_first),
        lastName: clean(_last),
        email: clean(_email),
        phone: clean(_phone)));
  }

  Widget _field(GiovLook look,
      {required String label,
      required TextEditingController controller,
      required String keyName,
      String? hint,
      TextInputType? type,
      TextCapitalization capitalization = TextCapitalization.none,
      TextInputAction action = TextInputAction.next,
      List<String>? autofill}) {
    final strings = look.strings;
    final inputStyle = look.style
        .text(TextStyle(fontSize: 14, color: look.text), look.style.input);
    final border = OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: look.inputBorder));
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The visible label names the field for assistive technology too (below), read once.
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                strings.required(label),
                style: look.style.text(
                    TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: look.secondaryText),
                    look.style.label),
              ),
            ),
          ),
          Semantics(
            label: strings.required(label),
            child: TextField(
              key: ValueKey('giov-field-$keyName'),
              controller: controller,
              keyboardType: type,
              textCapitalization: capitalization,
              textInputAction: action,
              autocorrect: false,
              autofillHints: autofill,
              onChanged: (_) => setState(() {}),
              onSubmitted:
                  action == TextInputAction.done ? (_) => _submit() : null,
              style: inputStyle,
              decoration: InputDecoration(
                isDense: true,
                hintText: hint ?? label,
                hintStyle: look.hintStyle,
                filled: true,
                fillColor: look.inputFill,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                enabledBorder: border,
                focusedBorder: border.copyWith(
                    borderSide: BorderSide(color: look.primary, width: 1.5)),
                border: border,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final look = GiovChatScope.of(context);
    final strings = look.strings;
    final fields = widget.fields;
    final valid = _valid;
    final order = [
      if (fields.firstName) 'first',
      if (fields.lastName) 'last',
      if (fields.email) 'email',
      if (fields.phone) 'phone',
    ];
    TextInputAction actionFor(String name) =>
        name == order.last ? TextInputAction.done : TextInputAction.next;
    return ColoredBox(
      key: const ValueKey('giov-pre-chat'),
      color: look.style.form ?? look.background,
      child: ListView(
        padding: const EdgeInsets.all(20),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Semantics(
              header: true,
              child: Text(strings.preChatTitle,
                  style: look.style.text(
                      TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: look.text),
                      look.style.formTitle)),
            ),
          ),
          if (fields.firstName)
            _field(look,
                label: strings.firstName,
                controller: _first,
                keyName: 'firstName',
                capitalization: TextCapitalization.words,
                action: actionFor('first'),
                autofill: const [AutofillHints.givenName]),
          if (fields.lastName)
            _field(look,
                label: strings.lastName,
                controller: _last,
                keyName: 'lastName',
                capitalization: TextCapitalization.words,
                action: actionFor('last'),
                autofill: const [AutofillHints.familyName]),
          if (fields.email)
            _field(look,
                label: strings.email,
                controller: _email,
                keyName: 'email',
                hint: 'you@example.com',
                type: TextInputType.emailAddress,
                action: actionFor('email'),
                autofill: const [AutofillHints.email]),
          if (fields.phone)
            _field(look,
                label: strings.phone,
                controller: _phone,
                keyName: 'phone',
                hint: '+1 555 000 0000',
                type: TextInputType.phone,
                action: actionFor('phone'),
                autofill: const [AutofillHints.telephoneNumber]),
          const SizedBox(height: 8),
          Semantics(
            button: true,
            enabled: valid,
            label: strings.startChat,
            excludeSemantics: true,
            child: Opacity(
              opacity: valid ? 1 : 0.45,
              child: Material(
                color: look.buttonColor,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  key: const ValueKey('giov-start-chat'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: valid ? _submit : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Center(
                        child: Text(strings.startChat,
                            style: look.buttonTextStyle.copyWith(
                                fontSize: 15, fontWeight: FontWeight.w700))),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
