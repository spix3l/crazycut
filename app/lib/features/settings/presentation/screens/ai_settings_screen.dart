import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../ai/ai_settings.dart';
import '../../../../ai/core/llm_provider.dart';
import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/cc_dialog.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../app/session.dart';
import '../../../../state/editor_controller.dart';
import '../../../../state/speech_model.dart';

enum _SettingsSection { canvas, playback, audio, shortcuts, ai }

/// Application settings, with AI configuration kept as one focused section.
///
/// Says plainly which endpoint gets contacted and what is sent, because that
/// is the whole basis on which a user decides to turn any of this on.
@RoutePage(name: 'SettingsRoute')
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = AiSettings.instance;
  final _models = SpeechModelStore.instance;

  late AiProviderDescriptor _descriptor;
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();

  late String _speechModelId;
  bool _keyTouched = false;
  bool _testing = false;
  bool _saving = false;
  String? _testResult;
  bool _testOk = false;
  bool _modelInstalled = false;
  bool _aiTouched = false;
  late _SettingsSection _section;
  late PreviewZoom _previewZoom;
  late PreviewQuality _previewQuality;
  late bool _showSafeMargins;
  late bool _showCanvasGrid;
  late bool _generateProxies;
  late String _outputDevice;

  EditorController? get _editor =>
      AppSession.instance.hasProject ? AppSession.instance.editor : null;

  @override
  void initState() {
    super.initState();
    final config = _settings.config;
    _descriptor =
        config == null
            ? kAiProviders.first
            : (descriptorFor(config.providerId) ?? kAiProviders.first);
    _baseUrl.text = config?.baseUrl ?? _descriptor.defaultBaseUrl;
    _model.text = config?.model ?? _descriptor.defaultModel;
    _speechModelId = config?.speechModelId ?? 'base.en';
    final editor = _editor;
    _section = editor == null ? _SettingsSection.ai : _SettingsSection.canvas;
    _previewZoom = editor?.previewZoom ?? PreviewZoom.fit;
    _previewQuality = editor?.previewQuality ?? PreviewQuality.auto;
    _showSafeMargins = editor?.showSafeMargins ?? false;
    _showCanvasGrid = editor?.showCanvasGrid ?? false;
    _generateProxies = AppSession.instance.proxies.enabled;
    _outputDevice = editor?.outputDeviceName ?? '';
    _baseUrl.addListener(_markAiTouched);
    _model.addListener(_markAiTouched);
    _models.addListener(_onModels);
    _refreshModel();
  }

  @override
  void dispose() {
    _models.removeListener(_onModels);
    _baseUrl.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  void _onModels() => setState(() {});

  void _markAiTouched() => _aiTouched = true;

  Future<void> _refreshModel() async {
    final installed = await _models.isInstalled(
      speechModelById(_speechModelId),
    );
    if (mounted) setState(() => _modelInstalled = installed);
  }

  void _selectProvider(AiProviderDescriptor descriptor) {
    setState(() {
      _aiTouched = true;
      _descriptor = descriptor;
      _baseUrl.text = descriptor.defaultBaseUrl;
      _model.text = descriptor.defaultModel;
      _key.clear();
      _keyTouched = false;
      _testResult = null;
    });
  }

  AiConfig _draft() => AiConfig(
    providerId: _descriptor.id,
    baseUrl: _baseUrl.text.trim(),
    model: _model.text.trim(),
    speechModelId: _speechModelId,
  );

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final enteredKey = _key.text.trim();
    final provider = _settings.createDraftProvider(
      _draft(),
      apiKey: enteredKey.isEmpty ? null : enteredKey,
    );
    if (provider == null) {
      setState(() {
        _testing = false;
        _testOk = false;
        _testResult = 'That provider could not be built.';
      });
      return;
    }
    try {
      await provider.ping();
      if (mounted) {
        setState(() {
          _testOk = true;
          _testResult = 'Connected.';
        });
      }
    } on LlmError catch (e) {
      if (mounted) {
        setState(() {
          _testOk = false;
          _testResult = e.message;
        });
      }
    } finally {
      provider.dispose();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _testResult = null;
    });
    final editor = _editor;
    if (editor != null) {
      editor
        ..setPreviewZoom(_previewZoom)
        ..setPreviewQuality(_previewQuality)
        ..setShowSafeMargins(_showSafeMargins)
        ..setShowCanvasGrid(_showCanvasGrid);
      if (_outputDevice.isNotEmpty) editor.setOutputDevice(_outputDevice);
    }
    AppSession.instance.proxies.enabled = _generateProxies;
    final enteredKey = _key.text.trim();
    if (_settings.config != null ||
        _aiTouched ||
        _keyTouched ||
        enteredKey.isNotEmpty) {
      final result = await _settings.save(
        _draft(),
        apiKey: enteredKey.isEmpty ? null : enteredKey,
      );
      if (!result.ok) {
        if (mounted) {
          setState(() {
            _section = _SettingsSection.ai;
            _testOk = false;
            _testResult = result.error;
            _saving = false;
          });
        }
        return;
      }
    }
    if (mounted) context.router.maybePop();
  }

  Future<void> _turnOff() async {
    await _settings.clear();
    if (mounted) context.router.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final speech = speechModelById(_speechModelId);
    final downloading = _models.progress;

    return CcModalBarrier(
      onDismiss: () => context.router.maybePop(),
      child: _SettingsShell(
        selected: _section,
        onSelected: (section) => setState(() => _section = section),
        onClose: () => context.router.maybePop(),
        body: _section == _SettingsSection.ai ? null : _sectionBody(),
        sections: [
          const _Explainer(),
          _AiReadiness(
            providerReady: _settings.configured,
            modelReady: _modelInstalled,
            needsKey: _descriptor.needsKey,
            hasKey: _settings.hasKey,
          ),
          CcField(
            label: 'Provider',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final d in kAiProviders) ...[
                  _ProviderTile(
                    descriptor: d,
                    selected: d.id == _descriptor.id,
                    onTap: () => _selectProvider(d),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
          CcField(
            label: 'Endpoint',
            child: CcTextField(
              controller: _baseUrl,
              placeholder: _descriptor.defaultBaseUrl,
            ),
          ),
          CcField(
            label: 'Model',
            child: CcTextField(
              controller: _model,
              placeholder: _descriptor.defaultModel,
            ),
          ),
          if (_descriptor.needsKey)
            CcField(
              label: 'API key',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CcTextField(
                    controller: _key,
                    placeholder:
                        _settings.hasKey
                            ? 'Stored in your keychain — type to replace'
                            : 'Paste your key',
                    onSubmitted: (_) => setState(() => _keyTouched = true),
                    onTapOutside: (_) => setState(() => _keyTouched = true),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Kept in the system keychain. Never written to a project '
                    'file, a log, or the diagnostics bundle.',
                    style: CcType.style(size: 11, color: CcColors.textTertiary),
                  ),
                ],
              ),
            ),
          CcField(
            label: 'Speech model (transcription)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CcSegmented(
                  expand: true,
                  selectedIndex: kSpeechModels.indexWhere(
                    (m) => m.id == _speechModelId,
                  ),
                  onChanged: (i) {
                    setState(() {
                      _aiTouched = true;
                      _speechModelId = kSpeechModels[i].id;
                    });
                    _refreshModel();
                  },
                  children: [
                    for (final m in kSpeechModels)
                      Text(m.label, style: CcType.body),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  speech.blurb,
                  style: CcType.style(size: 11, color: CcColors.textTertiary),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    CcIcon(
                      _modelInstalled
                          ? LucideIcons.circleCheck
                          : LucideIcons.download,
                      size: 15,
                      color:
                          _modelInstalled
                              ? CcColors.success
                              : CcColors.textTertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _modelInstalled
                            ? '${speech.label} · installed'
                            : '${speech.label} · not installed '
                                '(${speech.sizeLabel})',
                        style: CcType.body,
                      ),
                    ),
                    if (downloading != null)
                      Text(
                        '${(downloading * 100).round()}%',
                        style: CcType.body,
                      )
                    else if (!_modelInstalled)
                      CcButton(
                        label: 'Download',
                        kind: CcButtonKind.secondary,
                        onPressed: () async {
                          await _models.download(speech);
                          await _refreshModel();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Transcription runs on this machine. It needs no provider '
                  'and no network once the model is downloaded.',
                  style: CcType.style(size: 11, color: CcColors.textTertiary),
                ),
                if (_models.error != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _models.error!,
                    style: CcType.style(size: 11, color: CcColors.error),
                  ),
                ],
              ],
            ),
          ),
          if (_testResult != null)
            Row(
              children: [
                CcIcon(
                  _testOk ? LucideIcons.circleCheck : LucideIcons.circleAlert,
                  size: 15,
                  color: _testOk ? CcColors.success : CcColors.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _testResult!,
                    style: CcType.style(
                      size: 12,
                      color: _testOk ? CcColors.success : CcColors.error,
                    ),
                  ),
                ),
              ],
            ),
        ],
        actions: [
          if (_section == _SettingsSection.ai && _settings.configured)
            CcButton(
              label: 'Turn off',
              kind: CcButtonKind.ghost,
              onPressed: _turnOff,
            ),
          if (_section == _SettingsSection.ai)
            CcButton(
              label: _testing ? 'Testing…' : 'Test connection',
              kind: CcButtonKind.secondary,
              onPressed: _testing ? null : _test,
            ),
          CcButton(
            label: _saving ? 'Saving…' : 'Save',
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }

  Widget _sectionBody() {
    final editor = _editor;
    if (editor == null &&
        (_section == _SettingsSection.canvas ||
            _section == _SettingsSection.audio)) {
      return const _ProjectRequired();
    }
    return switch (_section) {
      _SettingsSection.canvas => _SettingsGroup(
        children: [
          _SettingRow(
            title: 'Preview zoom',
            description: 'Choose how the sequence canvas fits the monitor.',
            control: CcSegmented(
              selectedIndex: PreviewZoom.values.indexOf(_previewZoom),
              onChanged:
                  (index) =>
                      setState(() => _previewZoom = PreviewZoom.values[index]),
              children: [
                for (final zoom in PreviewZoom.values)
                  Text(zoom.label, style: CcType.body),
              ],
            ),
          ),
          _ToggleSetting(
            title: 'Safe margins',
            description:
                'Show title-safe and action-safe guides over the canvas.',
            checked: _showSafeMargins,
            onChanged: (value) => setState(() => _showSafeMargins = value),
          ),
          _ToggleSetting(
            title: 'Canvas grid',
            description: 'Show a composition grid over the preview.',
            checked: _showCanvasGrid,
            onChanged: (value) => setState(() => _showCanvasGrid = value),
          ),
        ],
      ),
      _SettingsSection.playback => _SettingsGroup(
        children: [
          if (editor != null)
            _SettingRow(
              title: 'Preview quality',
              description: 'Balance playback smoothness against image detail.',
              control: CcSegmented(
                selectedIndex: PreviewQuality.values.indexOf(_previewQuality),
                onChanged:
                    (index) => setState(
                      () => _previewQuality = PreviewQuality.values[index],
                    ),
                children: [
                  for (final quality in PreviewQuality.values)
                    Text(quality.label, style: CcType.body),
                ],
              ),
            ),
          _ToggleSetting(
            title: 'Generate proxies automatically',
            description:
                'Create lighter playback copies for demanding video files.',
            checked: _generateProxies,
            onChanged: (value) => setState(() => _generateProxies = value),
          ),
        ],
      ),
      _SettingsSection.audio => _AudioSettings(
        controller: editor!,
        selectedDevice: _outputDevice,
        onSelected: (device) => setState(() => _outputDevice = device),
      ),
      _SettingsSection.shortcuts => const _ShortcutsSettings(),
      _SettingsSection.ai => const SizedBox.shrink(),
    };
  }
}

class _SettingsShell extends StatelessWidget {
  const _SettingsShell({
    required this.selected,
    required this.onSelected,
    required this.sections,
    required this.actions,
    required this.onClose,
    this.body,
  });

  final _SettingsSection selected;
  final ValueChanged<_SettingsSection> onSelected;
  final List<Widget> sections;
  final List<Widget> actions;
  final VoidCallback onClose;
  final Widget? body;

  static String _label(_SettingsSection section) => switch (section) {
    _SettingsSection.canvas => 'Canvas',
    _SettingsSection.playback => 'Playback',
    _SettingsSection.audio => 'Audio',
    _SettingsSection.shortcuts => 'Shortcuts',
    _SettingsSection.ai => 'AI assist',
  };

  static String _description(_SettingsSection section) => switch (section) {
    _SettingsSection.canvas => 'Preview framing and composition guides',
    _SettingsSection.playback => 'Performance and media proxies',
    _SettingsSection.audio => 'Monitoring output',
    _SettingsSection.shortcuts => 'Keyboard controls',
    _SettingsSection.ai => 'Providers, models, and privacy',
  };

  static IconData _icon(_SettingsSection section) => switch (section) {
    _SettingsSection.canvas => LucideIcons.monitor,
    _SettingsSection.playback => LucideIcons.film,
    _SettingsSection.audio => LucideIcons.volume2,
    _SettingsSection.shortcuts => LucideIcons.sliders,
    _SettingsSection.ai => LucideIcons.sparkles,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 880,
      height: 680,
      decoration: BoxDecoration(
        color: CcColors.panel,
        borderRadius: CcRadius.brLg,
        border: CcBorders.allStrong,
        boxShadow: CcDeco.dialogShadow,
      ),
      child: Column(
        children: [
          Container(
            height: 59,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: const BoxDecoration(border: CcBorders.bottom),
            child: Row(
              children: [
                Text('Settings', style: CcType.dialogTitle),
                const Spacer(),
                CcTappable(
                  onTap: onClose,
                  child: const CcIcon(LucideIcons.x, size: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 190,
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(border: CcBorders.right),
                  child: Column(
                    children: [
                      for (final section in _SettingsSection.values) ...[
                        _SettingsNavItem(
                          label: _label(section),
                          icon: _icon(section),
                          selected: section == selected,
                          onTap: () => onSelected(section),
                        ),
                        const SizedBox(height: 4),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(28, 24, 28, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_label(selected), style: CcType.title),
                            const SizedBox(height: 5),
                            Text(_description(selected), style: CcType.small),
                          ],
                        ),
                      ),
                      const SizedBox(
                        height: 1,
                        child: ColoredBox(color: CcColors.border),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(28),
                          child:
                              body ??
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var i = 0; i < sections.length; i++) ...[
                                    if (i > 0) const SizedBox(height: 20),
                                    sections[i],
                                  ],
                                ],
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 66,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: const BoxDecoration(border: CcBorders.top),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  actions[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsNavItem extends StatelessWidget {
  const _SettingsNavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      builder:
          (context, hovered, child) => Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color:
                  selected
                      ? CcColors.elevated2
                      : hovered
                      ? CcColors.elevated
                      : null,
              borderRadius: CcRadius.brMd,
            ),
            child: child,
          ),
      child: Row(
        children: [
          CcIcon(
            icon,
            size: 15,
            color: selected ? CcColors.accent : CcColors.textTertiary,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: CcType.style(
              size: 12,
              weight: selected ? CcType.semibold : CcType.medium,
              color: selected ? CcColors.textPrimary : CcColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brMd,
        border: CcBorders.all,
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const SizedBox(
                height: 1,
                child: ColoredBox(color: CcColors.border),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.description,
    required this.control,
  });

  final String title;
  final String description;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: CcType.bodyStrong),
                const SizedBox(height: 4),
                Text(description, style: CcType.tiny),
              ],
            ),
          ),
          const SizedBox(width: 20),
          control,
        ],
      ),
    );
  }
}

class _ToggleSetting extends StatelessWidget {
  const _ToggleSetting({
    required this.title,
    required this.description,
    required this.checked,
    required this.onChanged,
  });

  final String title;
  final String description;
  final bool checked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _SettingRow(
      title: title,
      description: description,
      control: CcCheckbox(checked: checked, onTap: () => onChanged(!checked)),
    );
  }
}

class _ProjectRequired extends StatelessWidget {
  const _ProjectRequired();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brMd,
      ),
      child: Text(
        'Open a project to change these settings. They apply to the current editing session.',
        style: CcType.style(
          size: 12,
          color: CcColors.textSecondary,
          height: 1.45,
        ),
      ),
    );
  }
}

class _AudioSettings extends StatelessWidget {
  const _AudioSettings({
    required this.controller,
    required this.selectedDevice,
    required this.onSelected,
  });

  final EditorController controller;
  final String selectedDevice;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final devices = controller.audioOutputDevices();
    if (devices.isEmpty) {
      return const _SettingsGroup(
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('No audio output device found.'),
            ),
          ),
        ],
      );
    }
    final current = selectedDevice.isEmpty ? devices.first : selectedDevice;
    return _SettingsGroup(
      children: [
        _SettingRow(
          title: 'Output device',
          description: 'Choose where CrazyCut plays sequence audio.',
          control: Builder(
            builder:
                (anchorContext) => CcDropdown(
                  value: current,
                  width: 230,
                  onTap:
                      () => showCcMenu(anchorContext, [
                        for (final device in devices)
                          CcMenuItem(
                            device,
                            checked: device == current,
                            onTap: () => onSelected(device),
                          ),
                      ]),
                ),
          ),
        ),
      ],
    );
  }
}

class _ShortcutsSettings extends StatelessWidget {
  const _ShortcutsSettings();

  static const shortcuts = <(String, String)>[
    ('Play / pause', 'Space'),
    ('Shuttle backward / stop / forward', 'J  K  L'),
    ('Step one frame', '←  →'),
    ('Set in / out', 'I  O'),
    ('Split at playhead', 'S'),
    ('Add marker', 'M'),
    ('Preview fullscreen', 'F'),
    ('Zoom timeline', '⌘=  ⌘−'),
    ('Zoom timeline to fit', '\\'),
    ('Export', '⌘E'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: CcColors.elevated,
            borderRadius: CcRadius.brMd,
          ),
          child: Text(
            'Shortcut editing is planned for a later release. This is the active default map.',
            style: CcType.style(
              size: 12,
              color: CcColors.textSecondary,
              height: 1.45,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SettingsGroup(
          children: [
            for (final shortcut in shortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(shortcut.$1, style: CcType.body)),
                    Text(
                      shortcut.$2,
                      style: CcType.style(
                        size: 12,
                        weight: CcType.semibold,
                        color: CcColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _AiReadiness extends StatelessWidget {
  const _AiReadiness({
    required this.providerReady,
    required this.modelReady,
    required this.needsKey,
    required this.hasKey,
  });

  final bool providerReady;
  final bool modelReady;
  final bool needsKey;
  final bool hasKey;

  @override
  Widget build(BuildContext context) {
    final ready = providerReady && modelReady;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ready ? CcColors.audioPlate : CcColors.elevated,
        borderRadius: CcRadius.brMd,
        border: Border.all(
          color: ready ? CcColors.success : CcColors.borderStrong,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReadinessRow(
            ready: providerReady,
            label:
                providerReady
                    ? 'Provider configured'
                    : needsKey && !hasKey
                    ? 'API key is not stored'
                    : 'Provider setup is incomplete',
          ),
          const SizedBox(height: 8),
          _ReadinessRow(
            ready: modelReady,
            label:
                modelReady
                    ? 'Speech model installed'
                    : 'Speech model download required',
          ),
          const SizedBox(height: 10),
          Text(
            ready
                ? 'Ready. Open a project containing a clip with audio and use Auto-cut shorts from the editor toolbar.'
                : 'Both items are required before CrazyCut can run Auto-cut shorts.',
            style: CcType.style(
              size: 11,
              color: ready ? CcColors.success : CcColors.textTertiary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadinessRow extends StatelessWidget {
  const _ReadinessRow({required this.ready, required this.label});

  final bool ready;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CcIcon(
          ready ? LucideIcons.circleCheck : LucideIcons.circleAlert,
          size: 15,
          color: ready ? CcColors.success : CcColors.warning,
        ),
        const SizedBox(width: 8),
        Text(label, style: CcType.body),
      ],
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CrazyCut has no AI account and no key of its own.',
            style: CcType.style(size: 12, weight: CcType.semibold),
          ),
          const SizedBox(height: 6),
          Text(
            'You pick where requests go. Only transcript text and project '
            'details are ever sent — never your video or audio. Pick Ollama '
            'to keep everything on this machine. Results depend on the model '
            'you choose.',
            style: CcType.style(
              size: 12,
              color: CcColors.textSecondary,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.descriptor,
    required this.selected,
    required this.onTap,
  });

  final AiProviderDescriptor descriptor;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? CcColors.accentDim : CcColors.elevated,
          borderRadius: CcRadius.brMd,
          border: Border.all(
            color: selected ? CcColors.accent : CcColors.border,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CcIcon(
              selected ? LucideIcons.circleDot : LucideIcons.circle,
              size: 15,
              color: selected ? CcColors.accent : CcColors.textTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        descriptor.name,
                        style: CcType.style(size: 13, weight: CcType.semibold),
                      ),
                      if (!descriptor.needsKey) ...[
                        const SizedBox(width: 8),
                        const CcBadge('No key needed'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    descriptor.blurb,
                    style: CcType.style(
                      size: 11,
                      color: CcColors.textTertiary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
