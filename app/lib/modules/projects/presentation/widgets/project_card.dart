import 'package:crazycut_app/app/dependencies.dart';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/projects/presentation/models/project_summary.dart';

/// 320×245 card: poster-frame thumbnail (gradient until one renders), with
/// badges, then name + meta row.
class ProjectCard extends StatefulWidget {
  const ProjectCard({
    super.key,
    required this.project,
    this.onOpen,
    this.onMenu,
  });

  final ProjectSummary project;
  final VoidCallback? onOpen;

  /// Anchors the ⋯ menu to the ⋯ button itself.
  final ValueChanged<BuildContext>? onMenu;

  @override
  State<ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends State<ProjectCard> {
  File? _poster;

  @override
  void initState() {
    super.initState();
    _loadPoster();
  }

  @override
  void didUpdateWidget(covariant ProjectCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.doc != widget.project.doc) {
      _poster = null;
      _loadPoster();
    }
  }

  Future<void> _loadPoster() async {
    final doc = widget.project.doc;
    if (doc == null) return;
    final posterCache = AppDependenciesScope.read(context).posterCache;
    var file = await posterCache.cached(doc);
    file ??= await posterCache.ensure(doc);
    if (!mounted || file == null) return;
    setState(() => _poster = file);
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final onOpen = widget.onOpen;
    final onMenu = widget.onMenu;
    final poster = _poster;
    return CcTappable(
      onTap: onOpen,
      builder:
          (context, hovered, child) => AnimatedContainer(
            duration:
                MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: CcColors.panel,
              borderRadius: CcRadius.brLg,
              border: Border.all(
                color: hovered ? CcColors.borderStrong : CcColors.border,
              ),
            ),
            child: child,
          ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 320 / 180,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(CcRadius.lg),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: poster == null ? project.thumbnail : null,
                  color: poster == null ? null : CcColors.panel,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (poster != null) Image.file(poster, fit: BoxFit.cover),
                    Positioned(
                      left: 12,
                      top: 12,
                      child: CcBadge(project.resolutionLabel),
                    ),
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: CcBadge(project.duration),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.cardTitle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Builder(
                      builder:
                          (buttonContext) => GestureDetector(
                            onTapDown:
                                onMenu == null
                                    ? null
                                    : (_) => onMenu(buttonContext),
                            child: const CcIcon(LucideIcons.ellipsis, size: 16),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(project.lastOpened, style: CcType.small),
                    const SizedBox(width: 6),
                    Text(
                      '·',
                      style: CcType.style(
                        size: 12,
                        color: CcColors.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      project.aspect,
                      style: CcType.style(
                        size: 12,
                        color: CcColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
