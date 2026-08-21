import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../app/router/app_router.gr.dart';
import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../models/project_summary.dart';
import '../widgets/browser_header.dart';
import '../widgets/project_card.dart';
import '../widgets/welcome_panel.dart';

/// Project browser. With [empty] it renders the first-launch welcome screen
/// instead of the card grid.
@RoutePage()
class ProjectBrowserScreen extends StatelessWidget {
  const ProjectBrowserScreen({super.key, @QueryParam('empty') this.empty = false});

  final bool empty;

  @override
  Widget build(BuildContext context) {
    final projects = empty ? const <ProjectSummary>[] : sampleProjects;

    return ColoredBox(
      color: CcColors.bg,
      child: Column(
        children: [
          BrowserHeader(
            showSearch: projects.isNotEmpty,
            onNewProject: () => context.router.push(const NewProjectRoute()),
          ),
          Expanded(
            child: projects.isEmpty
                ? WelcomePanel(
                    onNewProject: () => context.router.push(const NewProjectRoute()),
                    onOpenSample: () => context.router.push(EditorRoute()),
                    onImportFiles: () => context.router.push(EditorRoute(empty: true)),
                  )
                : _ProjectGrid(projects: projects),
          ),
        ],
      ),
    );
  }
}

class _ProjectGrid extends StatelessWidget {
  const _ProjectGrid({required this.projects});

  final List<ProjectSummary> projects;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Your projects', style: CcType.title),
              const Spacer(),
              CcSegmented(
                height: 30,
                selectedIndex: 0,
                children: const [
                  CcIcon(LucideIcons.layoutGrid, size: 14, color: CcColors.textPrimary),
                  CcIcon(LucideIcons.list, size: 14, color: CcColors.textTertiary),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 20.0;
              const idealWidth = 320.0;
              final columns =
                  ((constraints.maxWidth + gap) / (idealWidth + gap)).floor().clamp(1, 6);
              final cardWidth = (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final project in projects)
                    SizedBox(
                      width: cardWidth,
                      child: ProjectCard(
                        project: project,
                        onOpen: () => context.router.push(EditorRoute()),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
