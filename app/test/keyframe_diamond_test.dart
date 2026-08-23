import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/inspector/inspector_effects_tab.dart';

void main() {
  Widget harness({
    required bool animated,
    required bool atCurrentTime,
    ValueChanged<BuildContext>? onContextMenu,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Overlay(
        key: ValueKey('$animated-$atCurrentTime'),
        initialEntries: [
          OverlayEntry(
            builder: (_) => Center(
              child: KeyframeDiamond(
                animated: animated,
                atCurrentTime: atCurrentTime,
                onTap: () {},
                onContextMenu: onContextMenu,
              ),
            ),
          ),
        ],
      ),
    );
  }

  testWidgets('tooltip distinguishes static, animated, and keyed states', (
    tester,
  ) async {
    await tester.pumpWidget(harness(animated: false, atCurrentTime: false));
    expect(
      tester.widget<CcTooltip>(find.byType(CcTooltip)).message,
      'Add keyframe at playhead',
    );

    await tester.pumpWidget(harness(animated: true, atCurrentTime: false));
    expect(
      tester.widget<CcTooltip>(find.byType(CcTooltip)).message,
      'Animated · click to add a keyframe here',
    );

    await tester.pumpWidget(harness(animated: true, atCurrentTime: true));
    expect(
      tester.widget<CcTooltip>(find.byType(CcTooltip)).message,
      'Keyframe at playhead · right-click for options',
    );
  });

  testWidgets('secondary click opens keyframe options', (tester) async {
    BuildContext? openedAt;
    await tester.pumpWidget(
      harness(
        animated: true,
        atCurrentTime: false,
        onContextMenu: (anchor) => openedAt = anchor,
      ),
    );

    await tester.tap(find.byType(KeyframeDiamond), buttons: 2);
    expect(openedAt, isNotNull);
  });
}
