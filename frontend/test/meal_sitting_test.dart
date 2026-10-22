import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';

/// One meal intent, named by the clock (2026-09-15): the host picks a time,
/// never a meal, and the label follows. The bands are the product's; the
/// boundaries are pinned because "11:00 is lunch, 10:59 is breakfast" is
/// exactly the kind of thing that drifts.
void main() {
  DateTime at(int hour, [int minute = 0]) =>
      DateTime(2026, 9, 15, hour, minute);

  test('each band, including its edges', () {
    final cases = <DateTime, MealSitting>{
      at(4): MealSitting.breakfast,
      at(10, 59): MealSitting.breakfast,
      at(11): MealSitting.lunch,
      at(13, 59): MealSitting.lunch,
      at(14): MealSitting.eveningMeal,
      at(17, 59): MealSitting.eveningMeal,
      at(18): MealSitting.dinner,
      at(21, 59): MealSitting.dinner,
      at(22): MealSitting.lateNight,
      at(0): MealSitting.lateNight,
      at(3, 59): MealSitting.lateNight,
    };
    cases.forEach((start, want) {
      expect(MealSitting.at(start), want, reason: '$start');
    });
  });

  test('labelFor names the sitting for the meal intent only', () {
    expect(IntentType.lunch.label, 'Meal');
    expect(IntentType.lunch.labelFor(at(8)), 'Meal: Breakfast');
    expect(IntentType.lunch.labelFor(at(12, 30)), 'Meal: Lunch');
    expect(IntentType.lunch.labelFor(at(16)), 'Meal: Evening meal');
    expect(IntentType.lunch.labelFor(at(19)), 'Meal: Dinner');
    expect(IntentType.lunch.labelFor(at(23)), 'Meal: Late night meal');
    // A locked meetup hides its window: the plain name, never a guess.
    expect(IntentType.lunch.labelFor(null), 'Meal');
    expect(IntentType.coffee.labelFor(at(8)), 'Coffee');
  });

  test('the wire value is unchanged: the server enum is still lunch', () {
    expect(IntentType.lunch.wireValue, 'lunch');
    expect(IntentType.fromWire('lunch'), IntentType.lunch);
  });
}
