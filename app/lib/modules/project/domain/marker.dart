part of 'project.dart';

class Marker {
  Marker({
    required this.id,
    required this.time,
    this.name = '',
    this.color = '#F5C451',
  });

  factory Marker.fromJson(Map<String, dynamic> j) => Marker(
    id: j['id'] as String,
    time: Rt.parse(j['time'] as String),
    name: (j['name'] as String?) ?? '',
    color: (j['color'] as String?) ?? '#F5C451',
  );

  final String id;
  Rt time;
  String name;
  String color;

  Marker copy() => Marker(id: id, time: time, name: name, color: color);

  Map<String, dynamic> toJson() => {
    'id': id,
    'time': time.toString(),
    'name': name,
    'color': color,
  };
}
