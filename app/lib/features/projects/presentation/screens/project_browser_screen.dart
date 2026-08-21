import 'package:auto_route/auto_route.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../app/router/app_router.gr.dart';
import '../../../../app/session.dart';
import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../data/repository.dart';
import '../models/project_summary.dart';
import '../widgets/browser_header.dart';
import '../widgets/project_card.dart';
import '../widgets/welcome_panel.dart';

/// Project browser. With no projects on disk it renders the first-launch
/// welcome screen instead of the card grid.
@RoutePage()
class ProjectBrowserScreen extends StatefulWidget {
  const ProjectBrowserScreen({super.key});

  @override
  State<ProjectBrowserScreen> createState() => _ProjectBrowserScreenState();
}

class _ProjectBrowserScreenState extends State<ProjectBrowserScreen> {
  List<ProjectSummary> _projects = const [];
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final entries = await ProjectRepository.listProjects();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _projects = [
        for (final (file, doc) in entries)
          ProjectSummary.fromDoc(doc, path: file.path, modified: file.statSync().modified),
      ];
    });
  }

  List<ProjectSummary> get _visible {
    if (_query.isEmpty) return _projects;
    final q = _query.toLowerCase();
    return _projects.where((p) => p.name.toLowerCase().contains(q)).toList();
  }

  Future<void> _open(ProjectSummary summary) async {
    final path = summary.path;
    if (path == null) return;
    AppSession.instance.open(ProjectRepository.load(path));
    if (!mounted) return;
    await context.router.push(EditorRoute());
    await _reload();
  }

  Future<void> _newProject() async {
    await context.router.push(const NewProjectRoute());
    await _reload();
  }

  /// Start-from-media path: makes a default 1080p project, imports the picked
  /// files into it and drops straight into the editor.
  Future<void> _importIntoNewProject() async {
    const types = [
      XTypeGroup(
        label: 'Media',
        extensions: [
          'mp4',
          'mov',
          'm4v',
          'mkv',
          'wav',
          'mp3',
          'aac',
          'm4a',
          'png',
          'jpg',
          'jpeg',
        ],
      ),
    ];
    final files = await openFiles(acceptedTypeGroups: types);
    if (files.isEmpty || !mounted) return;
    final session = AppSession.instance;
    await session.createNew(name: 'Untitled', width: 1920, height: 1080, fps: 30);
    await session.editor.importFiles(files.map((f) => f.path).toList());
    if (!mounted) return;
    await context.router.push(EditorRoute());
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final projects = _visible;
    return ColoredBox(
      color: CcColors.bg,
      child: Column(
        children: [
          BrowserHeader(
            showSearch: _projects.isNotEmpty,
            onSearchChanged: (value) => setState(() => _query = value),
            onNewProject: _newProject,
          ),
          Expanded(
            child: _loading
                ? const SizedBox.shrink()
                : _projects.isEmpty
                ? WelcomePanel(
                    onNewProject: _newProject,
                    // The bundled sample project lands with onboarding
                    // (UIX-7, M5); until then this is just "new project".
                    onOpenSample: _newProject,
                    onImportFiles: _importIntoNewProject,
                  )
                : _ProjectGrid(projects: projects, onOpen: _open),
          ),
        ],
      ),
    );
  }
}

class _ProjectGrid extends StatelessWidget {
  const _ProjectGrid({required this.projects, required this.onOpen});

  final List<ProjectSummary> projects;
  final ValueChanged<ProjectSummary> onOpen;

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
              final columns = ((constraints.maxWidth + gap) / (idealWidth + gap)).floor().clamp(
                1,
                6,
              );
              final cardWidth = (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final project in projects)
                    SizedBox(
                      width: cardWidth,
                      child: ProjectCard(project: project, onOpen: () => onOpen(project)),
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
