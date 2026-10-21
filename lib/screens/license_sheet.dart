// screens/license_sheet.dart — Pro unlock (simulated activation).
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../l10n/app_strings.dart';
import '../state/recovery_session.dart';
import '../widgets/core.dart';

Future<void> showLicenseSheet(BuildContext context, RecoverySession session) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: FrfColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(FrfRadius.sheet)),
    ),
    builder: (_) => _LicenseSheet(session: session),
  );
}

class _LicenseSheet extends StatefulWidget {
  final RecoverySession session;
  const _LicenseSheet({required this.session});

  @override
  State<_LicenseSheet> createState() => _LicenseSheetState();
}

class _LicenseSheetState extends State<_LicenseSheet> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _activate() {
    final ok = widget.session.activateLicense(_controller.text);
    if (ok) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(S.licenseOk,
                style: TextStyle(color: Colors.white)),
            backgroundColor: FrfColors.ok,
          ),
        );
      }
    } else {
      setState(() => _error = S.licenseBadKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: FrfSpacing.xl,
        right: FrfSpacing.xl,
        top: FrfSpacing.xl,
        bottom: MediaQuery.viewInsetsOf(context).bottom + FrfSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: FrfColors.rescue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(FrfRadius.control),
              ),
              child: const Icon(Icons.workspace_premium,
                  color: Color(0xFF7A5205)),
            ),
            const SizedBox(width: FrfSpacing.m),
            const Text(S.licenseTitle,
                style: TextStyle(
                    fontSize: FrfType.title,
                    fontWeight: FontWeight.w800,
                    color: FrfColors.brandDark)),
            const Spacer(),
            const Text(S.priceLabel,
                style: TextStyle(
                    fontSize: FrfType.title,
                    fontWeight: FontWeight.w800,
                    color: FrfColors.brandPrimary)),
          ]),
          const SizedBox(height: FrfSpacing.m),
          const Text(S.licenseExplainer,
              style: TextStyle(
                  fontSize: FrfType.body,
                  color: FrfColors.mutedOnLight)),
          const SizedBox(height: FrfSpacing.l),
          TextField(
            controller: _controller,
            textCapitalization: TextCapitalization.characters,
            autofocus: true,
            decoration: InputDecoration(
              labelText: S.licenseField,
              errorText: _error,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(FrfRadius.control)),
            ),
            onSubmitted: (_) => _activate(),
          ),
          const SizedBox(height: FrfSpacing.l),
          SizedBox(
            width: double.infinity,
            child: PrimaryCta(S.licenseActivate, onPressed: _activate),
          ),
        ],
      ),
    );
  }
}
