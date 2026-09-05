import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/cc_toast.dart';
import 'package:crazycut_app/modules/export/application/export_service.dart';
import 'package:crazycut_app/modules/updates/application/update_status.dart';
import 'package:crazycut_app/modules/updates/presentation/update_dialogs.dart';
import 'dependencies.dart';
import 'platform_menu.dart';
import 'router/app_router.dart';

/// Application root. Deliberately not a `MaterialApp`: CrazyCut ships its own
/// design system, so it only needs the plumbing `WidgetsApp` provides.
class CrazyCutApp extends StatefulWidget {
  const CrazyCutApp({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<CrazyCutApp> createState() => _CrazyCutAppState();
}

class _CrazyCutAppState extends State<CrazyCutApp> {
  final _router = AppRouter();

  /// Tags already presented as ready-to-install this run, so a background
  /// download surfaces exactly one prompt per release.
  String? _readyShownFor;

  /// Export jobs already toasted about, so each finished job notifies once.
  /// Seeded with whatever is already finished at startup: those are old news.
  final Set<String> _exportToasted = {};

  bool _exportsHooked = false;

  @override
  void initState() {
    super.initState();
    // Read the AI configuration once at startup so the editor knows whether to
    // show any AI affordance at all (AI-1). A failure here leaves AI off,
    // which is exactly the behaviour we want.
    widget.dependencies.aiSettings.load().whenComplete(() {
      if (mounted) setState(() {});
    });
    widget.dependencies.preferences.load().then((_) {
      widget.dependencies.session.proxies.enabled =
          widget.dependencies.preferences.generateProxies;
      _startBackgroundUpdateCheck();
    });
    for (final job in widget.dependencies.exports.jobs) {
      if (job.state == ExportState.completed ||
          job.state == ExportState.failed) {
        _exportToasted.add(job.id);
      }
    }
    widget.dependencies.exports.addListener(_maybeShowExportToast);
    _exportsHooked = true;
  }

  @override
  void dispose() {
    widget.dependencies.updates.removeListener(_maybeShowReady);
    if (_exportsHooked) {
      widget.dependencies.exports.removeListener(_maybeShowExportToast);
    }
    super.dispose();
  }

  /// A little toast when an export job finishes, wherever the user is. The
  /// queue panel only exists inside the export dialog, so without this a job
  /// that completes after the dialog was closed finishes silently.
  void _maybeShowExportToast() {
    final exports = widget.dependencies.exports;
    for (final job in exports.jobs) {
      if (_exportToasted.contains(job.id)) continue;
      if (job.state != ExportState.completed &&
          job.state != ExportState.failed) {
        continue;
      }
      _exportToasted.add(job.id);
      final context = _router.navigatorKey.currentContext;
      final overlay = _router.navigatorKey.currentState?.overlay;
      if (context == null || overlay == null) continue;
      if (job.state == ExportState.completed) {
        showCcToast(
          context,
          message: 'Export finished: ${job.name}',
          icon: LucideIcons.circleCheck,
          color: CcColors.success,
          overlay: overlay,
        );
      } else {
        showCcToast(
          context,
          message: 'Export failed: ${job.error ?? job.name}',
          icon: LucideIcons.circleAlert,
          color: CcColors.error,
          overlay: overlay,
        );
      }
    }
  }

  /// Silent check after first frame: never blocks launch, never dialogs on
  /// failure. Only a verified, fully downloaded update prompts, via
  /// [_maybeShowReady].
  void _startBackgroundUpdateCheck() {
    final updates = widget.dependencies.updates;
    updates.addListener(_maybeShowReady);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ignore: discarded_futures
      updates.checkNow().catchError((Object _) {});
    });
  }

  void _maybeShowReady() {
    final updates = widget.dependencies.updates;
    if (updates.status != UpdateStatus.ready) return;
    final tag = updates.release?.tag;
    if (tag == null || tag == _readyShownFor) return;
    _readyShownFor = tag;
    final context = _router.navigatorKey.currentContext;
    final overlay = _router.navigatorKey.currentState?.overlay;
    if (context == null || overlay == null) return;
    // ignore: discarded_futures
    showUpdateReadyDialog(context, updates, overlay: overlay);
  }

  @override
  Widget build(BuildContext context) {
    final app = WidgetsApp.router(
      title: 'CrazyCut',
      color: CcColors.accent,
      routerConfig: _router.config(),
      textStyle: CcType.base,
      debugShowCheckedModeBanner: false,
      builder:
          (context, child) => ColoredBox(
            color: CcColors.bg,
            child: child ?? const SizedBox.shrink(),
          ),
    );

    return AppDependenciesScope(
      dependencies: widget.dependencies,
      child: CrazyCutMenuBar(
        router: _router,
        session: widget.dependencies.session,
        child: app,
      ),
    );
  }
}
