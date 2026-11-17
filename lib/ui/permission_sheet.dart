import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../services/permissions.dart';

const _indigo = Color(0xFF4F5BFF);
const _violet = Color(0xFF9B5CFF);
const _green = Color(0xFF22B573);

/// The app's own "Allow access" screen, shown before macOS's system prompts. It explains
/// what each permission is for; only "Allow" brings the system prompts up, one after
/// another. Returns once the user is done (whatever they chose).
Future<void> showPermissionSheet(BuildContext context, AppController c) async {
  if (!hasSystemPrompts) return;
  final speech = await speechAccess();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => _PermissionDialog(controller: c, speech: speech),
  );
}

/// On launch: shown once to people who haven't seen it (e.g. after an update).
Future<void> maybeShowPermissionSheet(BuildContext context, AppController c) async {
  if (!hasSystemPrompts || c.store.permissionsAsked) return;
  await showPermissionSheet(context, c);
}

class _PermissionDialog extends StatefulWidget {
  const _PermissionDialog({required this.controller, required this.speech});
  final AppController controller;
  final SpeechAccess speech;

  @override
  State<_PermissionDialog> createState() => _PermissionDialogState();
}

enum _Step { choose, asking }

class _PermissionDialogState extends State<_PermissionDialog> {
  late bool _wantSpeech = widget.speech == SpeechAccess.notAsked || widget.speech == SpeechAccess.granted;
  _Step _step = _Step.choose;
  String _waitingFor = '';

  AppController get c => widget.controller;

  Future<void> _allow() async {
    setState(() => _step = _Step.asking);
    final folders = c.personalRoots.where((r) => !r.userAdded).toList();
    for (final r in folders) {
      if (!mounted) return;
      setState(() => _waitingFor = r.label);
      await requestFolderAccess([r.path]);
    }
    var speechGranted = false;
    if (_wantSpeech && widget.speech == SpeechAccess.notAsked) {
      if (mounted) setState(() => _waitingFor = 'speech recognition');
      speechGranted = await requestSpeechAccess();
    }
    c.permissionsAnswered(speechGranted: speechGranted);
    if (mounted) Navigator.of(context).pop();
  }

  void _later() {
    c.permissionsAnswered(speechGranted: false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final asking = _step == _Step.asking;
    final folderNames = [for (final r in c.personalRoots.where((r) => !r.userAdded)) r.label];

    return Dialog(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                      colors: [_indigo, _violet], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  boxShadow: [
                    BoxShadow(color: _indigo.withValues(alpha: 0.25), blurRadius: 18, offset: const Offset(0, 6)),
                  ],
                ),
                child: const Icon(Icons.verified_user_outlined, color: Colors.white, size: 28),
              ),
            ),
            const SizedBox(height: 16),
            Text('Allow access',
                textAlign: TextAlign.center,
                style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            const SizedBox(height: 6),
            Text(
              'Smart Search reads your files on this Mac to make them searchable. Nothing leaves your device.',
              textAlign: TextAlign.center,
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 22),
            _PermissionRow(
              icon: Icons.folder_open_rounded,
              title: 'Your folders',
              text: folderNames.isEmpty
                  ? 'To find your files and read what is inside them.'
                  : '${_list(folderNames)} – to find your files and read what is inside them.',
              trailing: const _Badge('Needed'),
            ),
            const SizedBox(height: 10),
            _PermissionRow(
              icon: Icons.record_voice_over_outlined,
              title: 'Speech in videos',
              text: switch (widget.speech) {
                SpeechAccess.denied =>
                  'Turned off. To use it, allow Smart Search in System Settings › Privacy & Security › Speech Recognition.',
                SpeechAccess.unavailable => 'Not available on this Mac.',
                _ => 'Search words spoken in your videos and jump straight to that moment.',
              },
              trailing: switch (widget.speech) {
                SpeechAccess.granted => const _Badge('Allowed', done: true),
                SpeechAccess.notAsked => Switch.adaptive(
                    value: _wantSpeech,
                    activeTrackColor: _indigo,
                    onChanged: asking ? null : (v) => setState(() => _wantSpeech = v),
                  ),
                _ => const _Badge('Off'),
              },
            ),
            const SizedBox(height: 18),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: asking
                  ? Row(key: const ValueKey('wait'), mainAxisAlignment: MainAxisAlignment.center, children: [
                      const SizedBox(
                          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _indigo)),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text('Confirm in the macOS window · $_waitingFor',
                            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ),
                    ])
                  : Text(
                      key: const ValueKey('hint'),
                      'macOS asks you to confirm each one next.',
                      textAlign: TextAlign.center,
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: asking ? null : _allow,
                style: FilledButton.styleFrom(
                  backgroundColor: _indigo,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                child: const Text('Allow'),
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: asking ? null : _later,
              child: Text('Not now', style: TextStyle(color: cs.onSurfaceVariant)),
            ),
          ]),
        ),
      ),
    );
  }

  static String _list(List<String> names) =>
      names.length <= 1 ? names.join() : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.icon, required this.title, required this.text, required this.trailing});
  final IconData icon;
  final String title, text;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: _indigo.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(11)),
          child: Icon(icon, size: 19, color: _indigo),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(text, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.35)),
          ]),
        ),
        const SizedBox(width: 8),
        trailing,
      ]),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.done = false});
  final String text;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = done ? _green : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (done) ...[const Icon(Icons.check_rounded, size: 12, color: _green), const SizedBox(width: 3)],
        Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }
}
