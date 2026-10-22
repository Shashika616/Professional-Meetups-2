import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/widgets/empty_state_deck.dart';

/// Messages.
///
/// # THIS SCREEN IS A WAITING ROOM, NOT A FEATURE
///
/// Direct messaging is not built. The screen set draws this state as the
/// photo deck and a single line, the same shape as every other empty state
/// in the app, so that an unbuilt feature looks like "nothing here yet"
/// rather than like something broken or locked away from you.
///
/// It used to be a card with a padlock, a heading and a paragraph
/// explaining the rule. The padlock was wrong — nothing here is withheld
/// pending a verification step the way the locked intents are — and the
/// paragraph only said the heading again in more words.
class ChatsPage extends StatelessWidget {
  const ChatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Messages')),
      body: const Center(
        child: SingleChildScrollView(
          child: EmptyStateDeck(
            title: 'Chat unlocks after a mutual meetup',
            scenes: EmptyDeckScenes.inbox,
          ),
        ),
      ),
    );
  }
}
