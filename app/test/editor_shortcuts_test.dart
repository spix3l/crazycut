import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/features/editor/presentation/screens/editor_screen.dart';

void main() {
  test('auto-repeat is consumed for edit commands, but not navigation', () {
    expect(isRepeatableEditorKey(LogicalKeyboardKey.arrowLeft), isTrue);
    expect(isRepeatableEditorKey(LogicalKeyboardKey.pageDown), isTrue);
    expect(isRepeatableEditorKey(LogicalKeyboardKey.equal), isTrue);

    expect(isRepeatableEditorKey(LogicalKeyboardKey.keyD), isFalse);
    expect(isRepeatableEditorKey(LogicalKeyboardKey.keyV), isFalse);
    expect(isRepeatableEditorKey(LogicalKeyboardKey.keyS), isFalse);
    expect(isRepeatableEditorKey(LogicalKeyboardKey.space), isFalse);

    expect(
      isOneShotEditorKeyRepeat(
        KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.keyD,
          logicalKey: LogicalKeyboardKey.keyD,
          timeStamp: Duration.zero,
        ),
      ),
      isTrue,
    );
    expect(
      isOneShotEditorKeyRepeat(
        KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.arrowLeft,
          logicalKey: LogicalKeyboardKey.arrowLeft,
          timeStamp: Duration.zero,
        ),
      ),
      isFalse,
    );
  });
}
