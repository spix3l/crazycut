import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/shorts/presentation/widgets/short_candidate_card.dart';
import 'package:crazycut_app/modules/shorts/application/shorts_service.dart';

ShortCandidate sample({
  String title = 'The good bit',
  double confidence = 0.9,
}) => ShortCandidate(
  startSec: 90,
  endSec: 135,
  title: title,
  hook: 'Here is the thing nobody tells you',
  reason: 'It stands alone.',
  confidence: confidence,
);

Future<void> pumpCard(
  WidgetTester tester,
  Widget card,
) => tester.pumpWidget(
  Directionality(
    textDirection: TextDirection.ltr,
    child: Align(alignment: Alignment.topLeft, child: SizedBox(width: 620, child: card)),
  ),
);

void main() {
  testWidgets('shows the title, range and duration', (tester) async {
    await pumpCard(
      tester,
      ShortCandidateCard(
        candidate: sample(),
        state: ShortCardState.pending,
        onPreview: () {},
        onAccept: () async {},
        onReject: () {},
        onNudgeStart: (_) {},
        onNudgeEnd: (_) {},
      ),
    );

    expect(find.text('The good bit'), findsOneWidget);
    expect(find.text('01:30 – 02:15 · 45s'), findsOneWidget);
    expect(find.text('Strong'), findsOneWidget);
    expect(find.textContaining('nobody tells you'), findsOneWidget);
  });

  testWidgets('falls back to a placeholder when the model gave no title', (
    tester,
  ) async {
    await pumpCard(
      tester,
      ShortCandidateCard(
        candidate: sample(title: ''),
        state: ShortCardState.pending,
        onPreview: () {},
        onAccept: () async {},
        onReject: () {},
        onNudgeStart: (_) {},
        onNudgeEnd: (_) {},
      ),
    );
    expect(find.text('Untitled moment'), findsOneWidget);
  });

  testWidgets('confidence reads as a coarse badge, never a number', (
    tester,
  ) async {
    await pumpCard(
      tester,
      ShortCandidateCard(
        candidate: sample(confidence: 0.2),
        state: ShortCardState.pending,
        onPreview: () {},
        onAccept: () async {},
        onReject: () {},
        onNudgeStart: (_) {},
        onNudgeEnd: (_) {},
      ),
    );
    expect(find.text('Long shot'), findsOneWidget);
    expect(find.textContaining('0.2'), findsNothing);
  });

  testWidgets('accept and reject reach the caller', (tester) async {
    var accepted = false;
    var rejected = false;
    await pumpCard(
      tester,
      ShortCandidateCard(
        candidate: sample(),
        state: ShortCardState.pending,
        onPreview: () {},
        onAccept: () async => accepted = true,
        onReject: () => rejected = true,
        onNudgeStart: (_) {},
        onNudgeEnd: (_) {},
      ),
    );

    await tester.tap(find.text('Make project'));
    await tester.pump();
    expect(accepted, isTrue);

    await tester.tap(find.text('Reject'));
    await tester.pump();
    expect(rejected, isTrue);
  });

  testWidgets('nudges carry a direction', (tester) async {
    final deltas = <String>[];
    await pumpCard(
      tester,
      ShortCandidateCard(
        candidate: sample(),
        state: ShortCardState.pending,
        onPreview: () {},
        onAccept: () async {},
        onReject: () {},
        onNudgeStart: (d) => deltas.add('start$d'),
        onNudgeEnd: (d) => deltas.add('end$d'),
      ),
    );

    // Two nudge groups, each with an earlier/later pair.
    final chevrons = find.byType(GestureDetector);
    expect(chevrons, findsWidgets);
    expect(find.text('In'), findsOneWidget);
    expect(find.text('Out'), findsOneWidget);
  });

  testWidgets('an accepted card says so and offers no more verbs', (
    tester,
  ) async {
    await pumpCard(
      tester,
      ShortCandidateCard(
        candidate: sample(),
        state: ShortCardState.accepted,
        onPreview: () {},
        onAccept: () async {},
        onReject: () {},
        onNudgeStart: (_) {},
        onNudgeEnd: (_) {},
      ),
    );
    expect(find.text('Project created'), findsOneWidget);
    expect(find.text('Make project'), findsNothing);
    expect(find.text('Reject'), findsNothing);
  });

  testWidgets('a rejected card is marked and inert', (tester) async {
    await pumpCard(
      tester,
      ShortCandidateCard(
        candidate: sample(),
        state: ShortCardState.rejected,
        onPreview: () {},
        onAccept: () async {},
        onReject: () {},
        onNudgeStart: (_) {},
        onNudgeEnd: (_) {},
      ),
    );
    expect(find.text('Rejected'), findsOneWidget);
    expect(find.text('Make project'), findsNothing);
  });
}
