part of 'project.dart';

/// A viewing-only web reference. It deliberately cannot satisfy a clip's
/// `mediaId`: providers such as YouTube are shown through their official
/// player and are never decoded, cached, proxied, or exported by CrazyCut.
class MediaReference {
  MediaReference({
    required this.id,
    required this.provider,
    required this.url,
    required this.externalId,
    Rt? rangeIn,
    this.rangeOut,
  }) : rangeIn = rangeIn ?? Rt.zero();

  factory MediaReference.fromJson(Map<String, dynamic> json) => MediaReference(
    id: json['id'] as String,
    provider: json['provider'] as String,
    url: json['url'] as String,
    externalId: json['externalId'] as String,
    rangeIn: Rt.parse((json['in'] as String?) ?? '0/1'),
    rangeOut: json['out'] == null ? null : Rt.parse(json['out'] as String),
  );

  final String id;
  final String provider;
  String url;
  final String externalId;
  Rt rangeIn;
  Rt? rangeOut;

  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': provider,
    'url': url,
    'externalId': externalId,
    'in': rangeIn.toString(),
    if (rangeOut != null) 'out': rangeOut.toString(),
  };
}
