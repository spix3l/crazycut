import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/engine/native_playback.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.controller});

  final EditorController controller;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late EditorController _c;
  String _saveStatus = '';
  bool _nativeActive = false;
  bool _nativePlaying = false;
  Timer? _nativePoll;
  Clip? _activeClip;

  @override
  void initState() {
    super.initState();
    _c = widget.controller;
    _c.addListener(_onChange);
    _c.onSaved = () {
      if (mounted) setState(() => _saveStatus = 'Saved');
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _c.updatePreviewFrame());
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _nativePoll?.cancel();
    NativePlayback.disposePlayer();
    _c.removeListener(_onChange);
    super.dispose();
  }

  bool get _isActuallyPlaying => _c.playing || (_nativeActive && _nativePlaying);

  Future<void> _leaveNativeMode() async {
    if (!_nativeActive) return;
    await NativePlayback.pause();
    _nativePoll?.cancel();
    _nativePoll = null;
    if (mounted) {
      setState(() {
        _nativePlaying = false;
        _nativeActive = false;
      });
    }
  }

  Future<void> _handlePlayPause() async {
    if (_c.playing) {
      _c.stopPlayback();
      return;
    }
    if (_nativeActive && _nativePlaying) {
      await NativePlayback.pause();
      if (mounted) setState(() => _nativePlaying = false);
      return;
    }

    final clip = _nativeActive ? _activeClip : _c.clipUnderPlayhead();
    if (clip == null) return;
    final asset = _c.doc.assetById(clip.mediaId);
    if (asset == null) return;

    if (NativePlayback.supported) {
      final offset = _c.playhead.minus(clip.start).seconds;
      final needOpen =
          NativePlayback.openedMedia != asset.path || NativePlayback.textureId == null;
      if (needOpen) {
        await _leaveNativeMode();
        final ok = await NativePlayback.open(asset.path);
        if (!ok) {
          _showError('Realtime engine preview unavailable — using step preview.');
          _startStepping();
          return;
        }
      } else {
        await NativePlayback.seek(offset.clamp(0.0, clip.duration.seconds));
      }
      _activeClip = clip;
      await NativePlayback.play();
      if (mounted) {
        setState(() {
          _nativeActive = true;
          _nativePlaying = true;
        });
      }
      _startPositionPoll(clip);
      return;
    }
    _startStepping();
  }

  void _startStepping() {
    _c.togglePlay();
    if (_c.playing) _c.updatePreviewFrame();
  }

  void _startPositionPoll(Clip clip) {
    _nativePoll?.cancel();
    _nativePoll = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final pos = await NativePlayback.position();
      if (!mounted) return;
      if (pos >= clip.duration.seconds - 0.03) {
        await NativePlayback.pause();
        _nativePoll?.cancel();
        _nativePoll = null;
        if (mounted) {
          setState(() => _nativePlaying = false);
        }
        _c.seekTo(clip.start.plus(clip.duration));
        return;
      }
      _c.seekTo(clip.start.plus(Rt.fromSeconds(pos)));
    });
  }

  Future<void> _import() async {
    const typeGroup = XTypeGroup(label: 'Media', extensions: [
      'mp4', 'mov', 'mkv', 'webm', 'm4v', 'mp3', 'm4a', 'wav', 'flac',
      'png', 'jpg', 'jpeg', 'webp'
    ]);
    final files = await openFiles(acceptedTypeGroups: [typeGroup]);
    if (files.isEmpty) return;
    try {
      await _c.importFiles(files.map((f) => f.path).toList());
      await _c.updatePreviewFrame();
    } on EngineException catch (e) {
      _showError('Engine error: ${e.message}');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: const Color(0xFF8B2E2E),
    ));
  }

  Future<void> _export() async {
    final clips = _c.doc.clips;
    if (clips.isEmpty) {
      _showError('Timeline is empty — add a clip first.');
      return;
    }
    final firstClip = clips.reduce((a, b) => a.start < b.start ? a : b);
    final asset = _c.doc.assetById(firstClip.mediaId);
    if (asset == null) return;

    await showDialog(
      context: context,
      builder: (_) => _ExportDialog(controller: _c, asset: asset),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: Row(
              children: [
                _buildPoolPanel(),
                const VerticalDivider(width: 1),
                Expanded(child: _buildPreview()),
                Container(width: 260, color: const Color(0xFF191B1F), child: _buildInspector()),
              ],
            ),
          ),
          _buildTimeline(),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 48,
      color: const Color(0xFF141518),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          Text(_c.doc.name,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text(_saveStatus, style: const TextStyle(fontSize: 11, color: Colors.white38)),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: () async {
              await _c.saveNow();
            },
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('Save'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _import,
            icon: const Icon(Icons.file_open_outlined, size: 16),
            label: const Text('Import'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _export,
            icon: const Icon(Icons.ios_share, size: 16),
            label: const Text('Export'),
          ),
        ],
      ),
    );
  }

  Widget _buildPoolPanel() {
    final assets = _c.pool.values.toList();
    return Container(
      width: 240,
      color: const Color(0xFF17181C),
      child: DropTarget(
        onDragDone: (details) async {
          try {
            await _c.importFiles(details.files.map((f) => f.path).toList());
            await _c.updatePreviewFrame();
          } on EngineException catch (e) {
            _showError('Engine error: ${e.message}');
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                const Text('MEDIA POOL',
                    style: TextStyle(fontSize: 11, letterSpacing: 1.2, color: Colors.white38)),
                const Spacer(),
                InkWell(onTap: _import, child: const Icon(Icons.add, size: 18, color: Colors.white54)),
              ]),
            ),
            Expanded(
              child: assets.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Drop media here\nor click + to import',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white24)),
                      ),
                    )
                  : ListView.builder(
                      itemCount: assets.length,
                      itemBuilder: (context, i) => _poolTile(assets[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _poolTile(PoolItem item) {
    return FutureBuilder<Uint8List?>(
      future: _thumbFuture(item),
      builder: (context, snap) {
        final thumb = snap.data;
        return ListTile(
          dense: true,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              width: 56,
              height: 34,
              color: Colors.black,
              child: thumb != null
                  ? Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true)
                  : item.status == ImportStatus.probing
                      ? const Center(child: SizedBox(
                          width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                      : const Icon(Icons.videocam_off_outlined, size: 16),
            ),
          ),
          title: Text(item.asset.name,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
          subtitle: Text(
            '${item.asset.width ?? '?'}×${item.asset.height ?? '?'} · '
            '${item.asset.duration.seconds.toStringAsFixed(1)}s'
            '${item.asset.vfr ? ' · vfr' : ''}'
            '${item.asset.hdr != 'none' ? ' · ${item.asset.hdr}' : ''}',
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.playlist_add, size: 16, color: Colors.white54),
            tooltip: 'Append to timeline',
            onPressed: () async {
              await _c.appendClip(item.asset.id);
              await _c.updatePreviewFrame();
            },
          ),
        );
      },
    );
  }

  final Map<String, Future<Uint8List?>> _thumbCache = {};

  Future<Uint8List?> _thumbFuture(PoolItem item) {
    return _thumbCache.putIfAbsent(item.asset.id, () => _c.loadThumbnail(item.asset));
  }

  Widget _buildPreview() {
    return Container(
      color: Colors.black,
      child: Column(
        children: [
          Expanded(child: Center(child: _previewImage())),
          _buildTransport(),
        ],
      ),
    );
  }

  Widget _previewImage() {
    if (_nativeActive && NativePlayback.textureId != null) {
      return AspectRatio(
        aspectRatio: _c.doc.settings.width / _c.doc.settings.height,
        child: Texture(textureId: NativePlayback.textureId!),
      );
    }
    final frame = _c.previewFrame;
    if (frame == null) {
      return const Text('No frame — add a clip and move the playhead',
          style: TextStyle(color: Colors.white24));
    }
    return Image.memory(frame, gaplessPlayback: true, filterQuality: FilterQuality.medium);
  }

  Widget _buildTransport() {
    final fpsV = _c.fps;
    return Container(
      height: 52,
      decoration: const BoxDecoration(color: Color(0xFF17181C)),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: () async {
              await _leaveNativeMode();
              _c.stopPlayback();
              _c.seekTo(Rt.zero());
              _c.updatePreviewFrame();
            },
            icon: const Icon(Icons.skip_previous_outlined, size: 20),
          ),
          IconButton.filled(
            style: IconButton.styleFrom(backgroundColor: Colors.white12),
            onPressed: _handlePlayPause,
            icon: Icon(_isActuallyPlaying ? Icons.pause : Icons.play_arrow, size: 22),
          ),
          const SizedBox(width: 16),
          Text('${Rt.toTimecode(_c.playhead, fpsV)} / '
              '${Rt.toTimecode(_c.doc.sequenceDuration, fpsV)}',
              style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildInspector() {
    final clip = _c.clipUnderPlayhead();
    final asset = clip == null ? null : _c.doc.assetById(clip.mediaId);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('INSPECTOR',
              style: TextStyle(fontSize: 11, letterSpacing: 1.2, color: Colors.white38)),
          const SizedBox(height: 12),
          if (clip == null)
            const Text('Nothing under playhead.',
                style: TextStyle(color: Colors.white24, fontSize: 12))
          else ...[
            Text(asset?.name ?? clip.label,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            _row('Start', clip.start.seconds.toStringAsFixed(3)),
            _row('Duration', clip.duration.seconds.toStringAsFixed(3)),
            if (asset != null) ...[
              _row('Codec', asset.codec ?? '—'),
              _row('FPS', asset.fps ?? '—'),
              if (asset.rotation != 0) _row('Rotation', '${asset.rotation}°'),
              if (asset.vfr) _row('Timing', 'Variable (conforms at export)'),
              if (asset.hdr != 'none') _row('Range', asset.hdr.toUpperCase()),
            ],
            const Spacer(),
            TextButton.icon(
              onPressed: () {
                _c.stopPlayback();
                _c.seekTo(Rt.zero());
                _c.updatePreviewFrame();
              },
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Back to start'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: 80,
              child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.white38))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 11))),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    return Container(
      height: 150,
      color: const Color(0xFF131417),
      child: Column(
        children: [
          Container(
            height: 28,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('TIMELINE · V1',
                style: TextStyle(fontSize: 11, letterSpacing: 1.2, color: Colors.white38)),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              return _timelineBody(constraints.maxWidth);
            }),
          ),
        ],
      ),
    );
  }

  Widget _timelineBody(double width) {
    final total = _c.doc.sequenceDuration;
    final durationSecs = total.isZero ? 1.0 : total.seconds;
    double xFor(Rt t) => (t.seconds / durationSecs) * width;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        final secs = (d.localPosition.dx / width) * durationSecs;
        _c.stopPlayback();
        _leaveNativeMode();
        _c.seekTo(Rt.fromSeconds(secs));
        _c.updatePreviewFrame();
      },
      onHorizontalDragUpdate: (d) {
        final secs = (d.localPosition.dx / width) * durationSecs;
        _c.stopPlayback();
        _leaveNativeMode();
        _c.seekTo(Rt.fromSeconds(secs.clamp(0.0, durationSecs)));
        _c.updatePreviewFrame();
      },
      child: Stack(
        children: [
          for (final track in _c.doc.tracks.where((t) => t.kind == 'video'))
            Positioned(
              left: 0,
              right: 0,
              top: 8,
              height: 64,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Stack(
                  children: [
                    for (final clip in _c.doc.clips.where((c) => c.trackId == track.id))
                      Positioned(
                        left: xFor(clip.start),
                        width:
                            ((clip.duration.seconds / durationSecs) * width)
                                .clamp(4.0, width),
                        top: 4,
                        bottom: 4,
                        child: Material(
                          color: const Color(0xFF315A7D),
                          borderRadius: BorderRadius.circular(4),
                          child: InkWell(
                            onTap: () => _c.selectClip(clip.id),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(clip.label,
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 10)),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Positioned(
            left: xFor(_c.playhead),
            top: 0,
            bottom: 0,
            child: Container(
              width: 2,
              color: const Color(0xFFFF5A5F),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.controller, required this.asset});

  final EditorController controller;
  final MediaAsset asset;

  @override
  State<_ExportDialog> createState() => __ExportDialogState();
}

class __ExportDialogState extends State<_ExportDialog> {
  int crf = 18;
  bool running = false;
  double percent = 0;
  String? outputPath;
  String? error;
  Process? _process;

  static const qualities = {'Master (CRF 18)': 18, 'Web (CRF 23)': 23, 'Draft (CRF 28)': 28};

  File? findWorker() {
    for (final candidate in PlatformHelper.workerBinCandidates()) {
      if (candidate.isEmpty) continue;
      final f = File(candidate);
      if (f.existsSync()) return f;
    }
    return null;
  }

  Future<void> _start() async {
    final worker = findWorker();
    if (worker == null) {
      setState(() => error =
          'crazycut_worker not found. Build the engine or pass CRAZYCUT_WORKER_BIN.');
      return;
    }
    final job = {
      'input': widget.asset.path,
      'output': outputPath!,
      'video': {'codec': 'h264', 'crf': crf, 'preset': 'medium'},
      'audio': {'codec': 'aac', 'bitrate': 320000},
      'faststart': true,
    };
    final tmpJob = File(
        '${Directory.systemTemp.path}/cc-job-${DateTime.now().millisecondsSinceEpoch}.json');
    await tmpJob.writeAsString(jsonEncode(job), flush: true);

    setState(() {
      running = true;
      percent = 0;
      error = null;
    });

    try {
      final process = await Process.start(worker.path, ['--job', tmpJob.path]);
      _process = process;
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.isEmpty) return;
        try {
          final msg = jsonDecode(line) as Map<String, dynamic>;
          switch (msg['type']) {
            case 'progress':
              if (mounted) setState(() => percent = (msg['percent'] as num).toDouble());
              break;
            case 'done':
              if (mounted) {
                setState(() {
                  running = false;
                  percent = 100;
                });
              }
              break;
            case 'fail':
              if (mounted) {
                setState(() {
                  running = false;
                  error = (msg['error'] as String?) ?? 'export failed';
                });
              }
              break;
          }
        } catch (_) {}
      });
      process.stderr.drain<void>();
      final code = await process.exitCode;
      if (!running && mounted && code == 0) return;
      if (mounted && code != 0 && error == null) {
        setState(() => error = 'worker exited with code $code');
        running = false;
      }
    } catch (e) {
      setState(() {
        running = false;
        error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _process?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.controller.doc.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return AlertDialog(
      title: const Text('Export'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              enabled: !running,
              onChanged: (v) => outputPath = v,
              decoration: InputDecoration(
                labelText: 'Output file',
                helperText: 'MP4 · H.264 · AAC',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.folder_open, size: 18),
                  onPressed: running
                      ? null
                      : () async {
                          final location = await getSaveLocation(
                              suggestedName: '$name.mp4',
                              acceptedTypeGroups: const [XTypeGroup(label: 'MP4', extensions: ['mp4'])]);
                          if (location != null) {
                            setState(() => outputPath = location.path);
                          }
                        },
                ),
                hintText: '$name.mp4',
              ),
              controller: TextEditingController(text: outputPath ?? ''),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: crf,
              decoration: const InputDecoration(labelText: 'Quality'),
              items: qualities.entries
                  .map((e) => DropdownMenuItem(value: e.value, child: Text(e.key)))
                  .toList(),
              onChanged: running
                  ? null
                  : (v) => setState(() => crf = v ?? 18),
            ),
            const SizedBox(height: 16),
            if (running || percent > 0) LinearProgressIndicator(value: percent / 100),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error!, style: const TextStyle(color: Color(0xFFE57373), fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        if (!running)
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(
          onPressed: running
              ? null
              : () {
                  if (outputPath == null || outputPath!.isEmpty) {
                    setState(() => error = 'Choose an output file first.');
                    return;
                  }
                  _start();
                },
          child: Text(running ? 'Exporting… ${percent.round()}%' : 'Export'),
        ),
      ],
    );
  }
}
