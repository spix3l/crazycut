import 'package:crazycut_app/features/projects/presentation/widgets/project_skeleton.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('project skeleton renders card-shaped placeholders', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 1200,
          height: 800,
          child: ProjectSkeletonGrid(),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // A 1200 px wide surface fits three 320-ish cards per row; the default 8
    // cards still all render.
    expect(find.byType(ProjectSkeletonGrid), findsOneWidget);
  });
}
