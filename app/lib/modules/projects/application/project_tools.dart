import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/modules/export/application/export_service.dart';

part 'collect_plan.dart';
part 'collect_result.dart';

/// Project-level maintenance actions that touch the filesystem: collecting
/// media next to the project, and gathering a diagnostics bundle.
class ProjectTools {
  ProjectTools._();

  /// The folder collected media lives in, beside the `.crazycut` file.
  static Directory mediaFolder(String projectPath) => Directory(
    '${File(projectPath).parent.path}${Platform.pathSeparator}Media',
  );

  /// Inspects what a collect would do, without touching anything (PRJ-14).
  static CollectPlan planCollect(ProjectDoc doc, String projectPath) {
    final target = mediaFolder(projectPath).path;
    final assets = <MediaAsset>[];
    final missing = <MediaAsset>[];
    var bytes = 0;
    var local = 0;
    var remote = 0;

    for (final asset in doc.media) {
      if (asset.isRemote) {
        assets.add(asset);
        bytes += asset.remoteContentLength ?? 0;
        remote++;
        continue;
      }
      final file = File(asset.path);
      if (!file.existsSync()) {
        missing.add(asset);
        continue;
      }
      if (asset.path.startsWith('$target${Platform.pathSeparator}')) {
        local++;
        continue;
      }
      assets.add(asset);
      bytes += file.lengthSync();
    }
    return CollectPlan(
      assets: assets,
      totalBytes: bytes,
      alreadyLocal: local,
      missing: missing,
      remote: remote,
    );
  }

  /// Copies referenced media into `<project>/Media/` and repoints the document
  /// at the copies, making the project folder portable (PRJ-14). Explicit and
  /// undoable only by not saving: the document is marked dirty by the caller.
  static Future<CollectResult> collect(
    ProjectDoc doc,
    String projectPath, {
    void Function(int done, int total)? onProgress,
  }) async {
    final plan = planCollect(doc, projectPath);
    if (plan.isEmpty) {
      return CollectResult(copied: 0, skipped: plan.alreadyLocal);
    }
    final target = mediaFolder(projectPath);
    try {
      await target.create(recursive: true);
    } catch (e) {
      return CollectResult(
        copied: 0,
        skipped: 0,
        error: 'cannot create $target: $e',
      );
    }

    var copied = 0;
    for (final asset in plan.assets) {
      var destination = '${target.path}${Platform.pathSeparator}${asset.name}';
      // Two sources can share a filename; never clobber one with the other.
      destination = ExportService.uniquePath(destination);
      try {
        if (asset.isRemote) {
          await _download(asset.path, destination);
        } else {
          await File(asset.path).copy(destination);
        }
        asset.path = destination;
        asset
          ..sourceKind = MediaSourceKind.file
          ..remoteEtag = null
          ..remoteLastModified = null
          ..remoteContentLength = null;
        copied++;
        onProgress?.call(copied, plan.assets.length);
      } catch (e) {
        debugPrint('collect failed for ${asset.path}: $e');
        return CollectResult(
          copied: copied,
          skipped: plan.alreadyLocal,
          error: 'copying ${asset.name} failed: $e',
        );
      }
    }
    return CollectResult(copied: copied, skipped: plan.alreadyLocal);
  }

  static Future<void> _download(String url, String destination) async {
    final partial = File('$destination.part');
    final client =
        HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      final sink = partial.openWrite();
      try {
        await response.pipe(sink);
      } on Object {
        await sink.close();
        rethrow;
      }
      await partial.rename(destination);
    } finally {
      client.close(force: true);
      if (partial.existsSync()) {
        try {
          partial.deleteSync();
        } on Object {
          // A failed partial is harmless and is retried from scratch.
        }
      }
    }
  }

  /// A support bundle: versions, environment, project shape and the recent
  /// export logs. Written next to the project so the user can attach it.
  static Future<File> writeDiagnostics({
    required ProjectDoc doc,
    required String projectPath,
    String? engineLib,
  }) async {
    final report = <String, dynamic>{
      'generatedAt': DateTime.now().toIso8601String(),
      'app': {
        'version':
            (jsonDecode(doc.encode(touchModified: false))
                as Map<String, dynamic>)['appVersion'],
        'platform': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'dartVersion': Platform.version,
        'locale': Platform.localeName,
        'processors': Platform.numberOfProcessors,
      },
      'engine': {
        'library': engineLib,
        'workerFound': PlatformHelper.workerBinary() != null,
      },
      'project': {
        'path': projectPath,
        'name': doc.name,
        'settings': doc.settings.toJson(),
        'counts': {
          'media': doc.media.length,
          'clips': doc.clips.length,
          'tracks': doc.tracks.length,
          'transitions': doc.transitions.length,
          'markers': doc.markers.length,
        },
        'offlineMedia': [
          for (final asset in doc.media.where((a) => a.offline)) asset.path,
        ],
      },
      'exports': [
        for (final job in ExportService.instance.jobs)
          {
            'name': job.name,
            'state': job.state.name,
            'frames': '${job.framesDone}/${job.totalFrames}',
            'error': job.error,
            'log':
                job.log.length > 20
                    ? job.log.sublist(job.log.length - 20)
                    : job.log,
          },
      ],
    };

    final stamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final path =
        '${File(projectPath).parent.path}'
        '${Platform.pathSeparator}crazycut-diagnostics-$stamp.json';
    final file = File(path);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    return file;
  }
}
