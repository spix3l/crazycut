import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/dependencies.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Sandbox grants have to be reopened before anything looks at the disk,
  // or the first existence check of the run decides a reachable file is
  // missing and everything downstream inherits that answer.
  final dependencies = AppDependencies.production();
  await dependencies.sandbox.restoreAll();
  runApp(CrazyCutApp(dependencies: dependencies));
}
