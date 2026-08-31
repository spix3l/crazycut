part of 'engine.dart';

class ProjectValidationReport {
  ProjectValidationReport(this.json);
  final Map<String, dynamic> json;
  bool get valid => json['valid'] as bool? ?? false;
  List<dynamic> get issues => json['issues'] as List<dynamic>? ?? const [];
  double get durationSeconds {
    final value = json['duration'] as String? ?? '0/1';
    final parts = value.split('/');
    if (parts.length != 2) return 0;
    return (int.tryParse(parts[0]) ?? 0) / (int.tryParse(parts[1]) ?? 1);
  }
}
