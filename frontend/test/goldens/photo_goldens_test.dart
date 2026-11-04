import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/features/profile/profile_photo_sheet.dart';

const _fontRegular = '/System/Library/Fonts/Supplemental/Arial.ttf';
const _fontBold = '/System/Library/Fonts/Supplemental/Arial Bold.ttf';
final _canRun =
    Platform.isMacOS &&
    File(_fontRegular).existsSync() &&
    File(_fontBold).existsSync();

/// The photo sheet over the avatar, in the states plan 2.1 names.
Future<void> _shot(
  WidgetTester tester,
  String name, {
  required bool hasPhoto,
}) async {
  for (final mode in [AppThemeMode.dark, AppThemeMode.light]) {
    AppPalette.setMode(mode);
    tester.view.physicalSize = const Size(1170, 1400);
    tester.view.devicePixelRatio = 3.0;
    late BuildContext sheetContext;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: mode == AppThemeMode.light
              ? Brightness.light
              : Brightness.dark,
          useMaterial3: true,
          fontFamily: 'Roboto',
          scaffoldBackgroundColor: AppPalette.onyx,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              sheetContext = context;
              return const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ProfessionalAvatar(
                    size: 104,
                    name: 'Ada Lovelace',
                    ring: true,
                    showPresenceDot: true,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    showProfilePhotoSheet(sheetContext, hasPhoto: hasPhoto);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$name-${mode.name}.png'),
    );
    await tester.pumpWidget(const SizedBox());
  }
  AppPalette.setMode(AppThemeMode.dark);
  tester.view.reset();
}

void main() {
  setUpAll(() async {
    if (!_canRun) return;
    final loader = FontLoader('Roboto')
      ..addFont(
        Future.value(
          ByteData.sublistView(File(_fontRegular).readAsBytesSync()),
        ),
      )
      ..addFont(
        Future.value(ByteData.sublistView(File(_fontBold).readAsBytesSync())),
      );
    await loader.load();
  });

  testWidgets('photo sheet with initials and no photo', (tester) async {
    await _shot(tester, 'photo_sheet_empty', hasPhoto: false);
  }, skip: !_canRun);

  testWidgets('photo sheet with a photo to remove', (tester) async {
    await _shot(tester, 'photo_sheet_with_photo', hasPhoto: true);
  }, skip: !_canRun);
}
