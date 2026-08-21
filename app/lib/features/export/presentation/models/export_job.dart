import 'package:flutter/widgets.dart';

enum ExportJobState { encoding, queued, completed }

/// One row of the export queue.
@immutable
class ExportJob {
  const ExportJob({
    required this.filename,
    required this.state,
    required this.progress,
    required this.status,
  });

  final String filename;
  final ExportJobState state;

  /// 0..1
  final double progress;
  final String status;
}

const sampleJobs = <ExportJob>[
  ExportJob(
    filename: 'Studio Tour Vertical.mp4',
    state: ExportJobState.encoding,
    progress: 0.62,
    status: 'Encoding · 62%  ·  48 fps · ETA 0:41',
  ),
  ExportJob(
    filename: 'Product Demo — v3.mp4',
    state: ExportJobState.queued,
    progress: 0,
    status: 'Queued  ·  Waiting…',
  ),
  ExportJob(
    filename: 'Get Ready With Me.mp4',
    state: ExportJobState.completed,
    progress: 1,
    status: 'Completed  ·  Done · 00:00:48',
  ),
];
