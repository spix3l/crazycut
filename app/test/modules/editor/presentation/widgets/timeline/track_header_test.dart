import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/editor/presentation/widgets/timeline/track_header.dart';

void main() {
  testWidgets('bottom lane menu opens upward inside the viewport', (
    tester,
  ) async {
    final track = Track(
      id: 'a2',
      kind: 'audio',
      name: 'A2',
      index: 1,
      height: 64,
    );

    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, _) => builder(context),
        ),
        home: Stack(
          children: [
            Positioned(
              left: 0,
              bottom: 0,
              width: TrackHeaderTile.width,
              child: TrackHeaderTile(
                track: track,
                onRename: (_) {},
                onCycleHeight: () {},
                onReorder: (_) {},
                onRemove: () {},
              ),
            ),
          ],
        ),
      ),
    );

    final trigger = find.byWidgetPredicate(
      (widget) => widget is CcIcon && widget.icon == LucideIcons.ellipsis,
    );
    final triggerTop = tester.getTopLeft(trigger).dy;
    final tappable = tester.widget<CcTappable>(
      find.ancestor(of: trigger, matching: find.byType(CcTappable)).first,
    );
    tappable.onTap!();
    await tester.pump();

    final menuRect = tester.getRect(find.byType(CcMenu));
    final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(menuRect.top, lessThan(triggerTop));
    expect(menuRect.bottom, lessThanOrEqualTo(viewport.height - 20));
  });
}
