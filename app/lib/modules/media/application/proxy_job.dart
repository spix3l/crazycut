part of 'proxy_service.dart';

class ProxyJob {
  ProxyJob(this.assetId, {this.state = ProxyState.queued});
  final String assetId;
  ProxyState state;
  double progress = 0;
  String? error;
}
