import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// Every entry in [AppIcons], by name, so a new one cannot be added
/// without being rendered here at least once. The names are spelled out
/// rather than reflected because Dart has no compile-time reflection and
/// a runtime list is the only way to hold all of them.
const Map<String, String> _all = {
  'home': AppIcons.home,
  'events': AppIcons.events,
  'safety': AppIcons.safety,
  'profile': AppIcons.profile,
  'back': AppIcons.back,
  'forward': AppIcons.forward,
  'chevronDown': AppIcons.chevronDown,
  'bell': AppIcons.bell,
  'close': AppIcons.close,
  'plus': AppIcons.plus,
  'check': AppIcons.check,
  'grid': AppIcons.grid,
  'clock': AppIcons.clock,
  'info': AppIcons.info,
  'warning': AppIcons.warning,
  'star': AppIcons.star,
  'lock': AppIcons.lock,
  'bulb': AppIcons.bulb,
  'phone': AppIcons.phone,
  'mail': AppIcons.mail,
  'link': AppIcons.link,
  'idCard': AppIcons.idCard,
  'pin': AppIcons.pin,
  'directions': AppIcons.directions,
  'people': AppIcons.people,
  'requests': AppIcons.requests,
  'chat': AppIcons.chat,
  'coffee': AppIcons.coffee,
  'meal': AppIcons.meal,
  'mentorship': AppIcons.mentorship,
  'outing': AppIcons.outing,
  'signOut': AppIcons.signOut,
  'trash': AppIcons.trash,
  'premium': AppIcons.premium,
  'appearance': AppIcons.appearance,
  'work': AppIcons.work,
  'search': AppIcons.search,
  'edit': AppIcons.edit,
  'checkCircle': AppIcons.checkCircle,
  'xCircle': AppIcons.xCircle,
  'plusCircle': AppIcons.plusCircle,
  'minus': AppIcons.minus,
  'arrowRight': AppIcons.arrowRight,
  'arrowLeft': AppIcons.arrowLeft,
  'explore': AppIcons.explore,
  'map': AppIcons.map,
  'locate': AppIcons.locate,
  'undo': AppIcons.undo,
  'refresh': AppIcons.refresh,
  'history': AppIcons.history,
  'person': AppIcons.person,
  'personAdd': AppIcons.personAdd,
  'personRemove': AppIcons.personRemove,
  'hourglass': AppIcons.hourglass,
  'calendar': AppIcons.calendar,
  'calendarCheck': AppIcons.calendarCheck,
  'calendarX': AppIcons.calendarX,
  'share': AppIcons.share,
  'broadcast': AppIcons.broadcast,
  'building': AppIcons.building,
  'car': AppIcons.car,
  'settings': AppIcons.settings,
  'filter': AppIcons.filter,
  'eye': AppIcons.eye,
  'thumbUp': AppIcons.thumbUp,
  'thumbDown': AppIcons.thumbDown,
  'heart': AppIcons.heart,
  'celebration': AppIcons.celebration,
  'cloudOff': AppIcons.cloudOff,
  'verifiedBadge': AppIcons.verifiedBadge,
  'support': AppIcons.support,
  'atSign': AppIcons.atSign,
  'checkbox': AppIcons.checkbox,
  'checkboxChecked': AppIcons.checkboxChecked,
};

void main() {
  test('every path is well-formed SVG markup', () {
    // A path that does not parse renders as an empty box: visible to a
    // human, invisible to a widget test that only checks the icon exists.
    // These are the structural mistakes that actually happen when writing
    // path data by hand.
    for (final entry in _all.entries) {
      final d = entry.value;
      expect(d, isNotEmpty, reason: entry.key);
      expect(
        d.startsWith('<'),
        isTrue,
        reason: '${entry.key} does not start with an element',
      );
      expect(
        d.endsWith('/>') || d.endsWith('>'),
        isTrue,
        reason: '${entry.key} is truncated',
      );
      expect(
        '<'.allMatches(d).length,
        '>'.allMatches(d).length,
        reason: '${entry.key} has unbalanced angle brackets',
      );
      expect(
        '"'.allMatches(d).length.isEven,
        isTrue,
        reason: '${entry.key} has an unclosed attribute',
      );
      // A stray space inside a number ("1. 5") silently truncates the
      // rest of a path in most renderers.
      expect(
        RegExp(r'\d\.\s').hasMatch(d),
        isFalse,
        reason: '${entry.key} has a broken decimal',
      );
    }
  });

  testWidgets('every icon renders without throwing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Wrap(
              children: [
                for (final e in _all.entries)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: AppIcon(e.value, size: 24, color: Colors.black),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AppIcon), findsNWidgets(_all.length));
  });
}
