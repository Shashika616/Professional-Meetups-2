import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/empty_state_deck.dart';
import 'package:professional_connections_platform/features/chats/chats_page.dart';

void main() {
  // Chat is not built yet. The tab must say when it unlocks rather than show
  // an empty inbox that looks broken.
  testWidgets('explains that chat unlocks after a mutual meetup', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ChatsPage()));
    await tester.pumpAndSettle();

    expect(find.text('Messages'), findsOneWidget);
    expect(find.byType(EmptyStateDeck), findsOneWidget);
    expect(find.text('Chat unlocks after a mutual meetup'), findsOneWidget);
  });

  testWidgets('fits a small phone without overflowing', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 568 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: ChatsPage()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
