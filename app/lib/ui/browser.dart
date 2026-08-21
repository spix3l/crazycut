import 'dart:io';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/state/editor_controller.dart';
import 'package:crazycut_app/ui/editor.dart';
import 'package:flutter/material.dart';

class ProjectBrowserScreen extends StatefulWidget {
  const ProjectBrowserScreen({super.key});

  @override
  State<ProjectBrowserScreen> createState() => _ProjectBrowserScreenState();
}

class _ProjectBrowserScreenState extends State<ProjectBrowserScreen> {
  List<(File, ProjectDoc)> _projects = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final projects = await ProjectRepository.listProjects();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _loading = false;
    });
  }

  Future<void> _newProject() async {
    final result = await showDialog<_NewProjectResult>(
      context: context,
      builder: (_) => const _NewProjectDialog(),
    );
    if (result == null) return;
    final doc = ProjectDoc.empty(
      result.name,
      width: result.width,
      height: result.height,
      fps: result.fps,
    );
    await ProjectRepository.save(doc);
    if (!mounted) return;
    await _open(doc);
  }

  Future<void> _open(ProjectDoc doc) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EditorScreen(controller: EditorController(doc)),
    ));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('CrazyCut',
                    style: Theme.of(context).textTheme.headlineMedium),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _newProject,
                  icon: const Icon(Icons.add),
                  label: const Text('New Project'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Projects are stored in your Documents folder.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.white38)),
            const SizedBox(height: 16),
            Expanded(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_projects.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_creation_outlined,
                size: 64, color: Colors.white24),
            const SizedBox(height: 12),
            const Text('No projects yet'),
            const SizedBox(height: 12),
            FilledButton(onPressed: _newProject, child: const Text('Create one')),
          ],
        ),
      );
    }
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.35,
      ),
      itemCount: _projects.length,
      itemBuilder: (context, i) => _ProjectCard(
        file: _projects[i].$1,
        doc: _projects[i].$2,
        onOpen: () => _open(_projects[i].$2),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.file, required this.doc, required this.onOpen});

  final File file;
  final ProjectDoc doc;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final modified = file.statSync().modified;
    String ago;
    final diff = DateTime.now().difference(modified);
    if (diff.inMinutes < 1) {
      ago = 'just now';
    } else if (diff.inHours < 1) {
      ago = '${diff.inMinutes} min ago';
    } else if (diff.inDays < 1) {
      ago = '${diff.inHours} h ago';
    } else {
      ago = '${diff.inDays} d ago';
    }
    return Card(
      color: Colors.white.withValues(alpha: 0.04),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2E36),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${doc.settings.width}×${doc.settings.height} · '
                      '${doc.settings.fpsValue.toStringAsFixed(doc.settings.fpsValue.truncateToDouble() == doc.settings.fpsValue ? 0 : 2)}',
                      style: const TextStyle(fontSize: 11, color: Colors.white60),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                doc.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              const SizedBox(height: 4),
              Text('${doc.clips.length} clips · edited $ago',
                  style: const TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewProjectResult {
  _NewProjectResult(this.name, this.width, this.height, this.fps);
  final String name;
  final int width;
  final int height;
  final double fps;
}

class _NewProjectDialog extends StatefulWidget {
  const _NewProjectDialog();

  @override
  State<_NewProjectDialog> createState() => __NewProjectDialogState();
}

class __NewProjectDialogState extends State<_NewProjectDialog> {
  final _nameController = TextEditingController(text: 'Untitled');
  (int, int, double) _selected = (1920, 1080, 30);

  static const presets = <String, (int, int, double)>{
    'YouTube 1080p': (1920, 1080, 30),
    'YouTube 4K': (3840, 2160, 30),
    'Shorts / TikTok': (1080, 1920, 30),
    'Square': (1080, 1080, 30),
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Project'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: presets.entries.map((e) {
                final selected = _selected == e.value;
                return ChoiceChip(
                  label: Text(e.key),
                  selected: selected,
                  onSelected: (_) => setState(() => _selected = e.value),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
              context,
              _NewProjectResult(
                  _nameController.text.trim().isEmpty
                      ? 'Untitled'
                      : _nameController.text.trim(),
                  _selected.$1,
                  _selected.$2,
                  _selected.$3)),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
