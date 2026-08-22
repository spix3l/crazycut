import 'package:auto_route/auto_route.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../app/router/app_router.gr.dart';
import '../../../../app/session.dart';
import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/cc_dialog.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../data/autosave.dart';
import '../../../../data/repository.dart';
import '../models/project_summary.dart';
import '../widgets/browser_header.dart';
import '../widgets/project_card.dart';
import '../widgets/recovery_banner.dart';
import '../widgets/welcome_panel.dart';

/// Project browser. With no projects on disk it renders the first-launch
/// welcome screen instead of the card grid.
@RoutePage()
class ProjectBrowserScreen extends StatefulWidget {
  const ProjectBrowserScreen({super.key});

  @override
  State<ProjectBrowserScreen> createState() => _ProjectBrowserScreenState();
}

enum _Sort { lastOpened, name, created }

class _ProjectBrowserScreenState extends State<ProjectBrowserScreen> {
  List<ProjectSummary> _projects = const [];
  List<RecoveryCandidate> _recovery = const [];
  String _query = '';
  _Sort _sort = _Sort.lastOpened;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    await AppSession.instance.loadRecents();
    final entries = await ProjectRepository.listProjects();
    final recovery = await ProjectRecovery.scan();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _recovery = recovery;
      _projects = [
        for (final (file, doc) in entries)
          ProjectSummary.fromDoc(
            doc,
            path: file.path,
            modified: file.statSync().modified,
          ),
      ];
    });
  }

  List<ProjectSummary> get _visible {
    var list = _projects;
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list.where((p) => p.name.toLowerCase().contains(q)).toList();
    }
    final sorted = [...list];
    switch (_sort) {
      case _Sort.name:
        sorted.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case _Sort.created:
        sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _Sort.lastOpened:
        break;
    }
    return sorted;
  }

  Future<void> _open(ProjectSummary summary) async {
    final path = summary.path;
    if (path == null) return;
    await AppSession.instance.openPath(path);
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
          'svg',
        ],
      ),
    ];
    final files = await openFiles(acceptedTypeGroups: types);
    if (files.isEmpty || !mounted) return;
    final session = AppSession.instance;
    await session.createNew(
      name: 'Untitled',
      width: 1920,
      height: 1080,
      fps: 30,
    );
    await session.editor.importPaths(files.map((f) => f.path).toList());
    if (!mounted) return;
    await context.router.push(EditorRoute());
    await _reload();
  }

  // --- Card actions (PRJ-2) -------------------------------------------------

  void _cardMenu(ProjectSummary summary, Offset position) {
    final path = summary.path;
    if (path == null) return;
    showCcMenu(context, position, [
      CcMenuItem('Open', onTap: () => _open(summary)),
      CcMenuItem('Duplicate', onTap: () => _duplicate(path)),
      CcMenuItem('Rename…', onTap: () => _rename(summary, path)),
      CcMenuItem('Show in folder', onTap: () => revealInFileManager(path)),
      CcMenuItem(
        'Move to Trash',
        danger: true,
        separatorBefore: true,
        onTap: () => _delete(summary, path),
      ),
    ]);
  }

  Future<void> _duplicate(String path) async {
    await ProjectRepository.duplicate(path);
    await _reload();
  }

  Future<void> _rename(ProjectSummary summary, String path) async {
    final name = await promptForText(
      context,
      title: 'Rename project',
      initialValue: summary.name,
    );
    if (name == null || name.isEmpty) return;
    await ProjectRepository.rename(path, name);
    await _reload();
  }

  Future<void> _delete(ProjectSummary summary, String path) async {
    final confirmed = await confirmAction(
      context,
      title: 'Move “${summary.name}” to Trash?',
      message: 'The project file and its backups are removed. '
          'Your media files are never touched.',
      confirmLabel: 'Move to Trash',
    );
    if (!confirmed) return;
    await ProjectRepository.delete(path);
    await _reload();
  }

  // --- Recovery (PRJ-8) -----------------------------------------------------

  Future<void> _review(RecoveryCandidate candidate) async {
    final backups = await ProjectRepository.backupsFor(candidate.projectPath);
    if (!mounted) return;
    final choice = await showRecoveryChooser(
      context,
      candidate: candidate,
      backups: backups,
    );
    if (choice == null) return;
    switch (choice) {
      case RecoveryChoice.restoreAutosave:
        await ProjectRecovery.restore(candidate.projectPath);
      case RecoveryChoice.openSaved:
        await ProjectRecovery.discard(candidate.projectPath);
      case RecoveryChoice.openBackup:
        break;
    }
    await _reload();
  }

  Future<void> _openBackup(
    RecoveryCandidate candidate,
    String backupPath,
  ) async {
    await ProjectRecovery.openBackup(backupPath, candidate.projectPath);
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
            sortLabel: switch (_sort) {
              _Sort.lastOpened => 'Last opened',
              _Sort.name => 'Name',
              _Sort.created => 'Created',
            },
            onSortTapped: (position) => showCcMenu(context, position, [
              CcMenuItem(
                'Last opened',
                checked: _sort == _Sort.lastOpened,
                onTap: () => setState(() => _sort = _Sort.lastOpened),
              ),
              CcMenuItem(
                'Name',
                checked: _sort == _Sort.name,
                onTap: () => setState(() => _sort = _Sort.name),
              ),
              CcMenuItem(
                'Created',
                checked: _sort == _Sort.created,
                onTap: () => setState(() => _sort = _Sort.created),
              ),
            ]),
            onNewProject: _newProject,
          ),
          if (_recovery.isNotEmpty)
            RecoveryBanner(
              candidates: _recovery,
              onReview: _review,
              onOpenBackup: _openBackup,
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
                    : _ProjectGrid(
                        projects: projects,
                        onOpen: _open,
                        onMenu: _cardMenu,
                      ),
          ),
        ],
      ),
    );
  }
}

class _ProjectGrid extends StatelessWidget {
  const _ProjectGrid({
    required this.projects,
    required this.onOpen,
    required this.onMenu,
  });

  final List<ProjectSummary> projects;
  final ValueChanged<ProjectSummary> onOpen;
  final void Function(ProjectSummary summary, Offset position) onMenu;

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
                  CcIcon(
                    LucideIcons.layoutGrid,
                    size: 14,
                    color: CcColors.textPrimary,
                  ),
                  CcIcon(
                    LucideIcons.list,
                    size: 14,
                    color: CcColors.textTertiary,
                  ),
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
                  ((constraints.maxWidth + gap) / (idealWidth + gap))
                      .floor()
                      .clamp(1, 6);
              final cardWidth =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final project in projects)
                    SizedBox(
                      width: cardWidth,
                      child: ProjectCard(
                        project: project,
                        onOpen: () => onOpen(project),
                        onMenu: (position) => onMenu(project, position),
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
