import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/photo_auth.dart';
import 'package:professional_connections_platform/core/services/photo_picker.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/features/profile/profile_page.dart';

import 'support/fake_secure_storage_platform.dart';

const _path = '/v1/users/user-1/photo?v=new';

class _Auth extends MockAuthService {
  _Auth({this.photo = ''});

  String photo;
  Object? failure;
  final uploads = <Uint8List>[];
  int deletes = 0;

  @override
  Future<UserProfile> getProfile() async => UserProfile(
    id: 'user-1',
    fullName: 'Ada Lovelace',
    profilePhotoUrl: photo,
    trustLevel: 1,
  );

  @override
  Future<String> uploadProfilePhoto(Uint8List jpeg) async {
    uploads.add(jpeg);
    final error = failure;
    if (error != null) throw error;
    return _path;
  }

  @override
  Future<void> deleteProfilePhoto() async {
    deletes++;
    final error = failure;
    if (error != null) throw error;
  }
}

class _Picker implements PhotoPicker {
  _Picker(this.result);

  final Uint8List? result;
  final sources = <PhotoSource>[];

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    sources.add(source);
    return result;
  }
}

final _bytes = Uint8List.fromList([1, 2, 3]);

Future<void> _open(
  WidgetTester tester,
  _Auth auth,
  PhotoPicker picker, {
  String sessionPhoto = '',
}) async {
  await SecureSessionStorage(storage: const FlutterSecureStorage()).saveSession(
    AuthSession(
      userId: 'user-1',
      accessToken: 'a.b.c',
      refreshToken: 'refresh',
      trustLevel: 1,
      isNewUser: false,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Ada Lovelace',
      profilePhotoUrl: sessionPhoto,
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authServiceProvider.overrideWithValue(auth),
        photoPickerProvider.overrideWithValue(picker),
        sessionStorageProvider.overrideWithValue(
          SecureSessionStorage(storage: const FlutterSecureStorage()),
        ),
      ],
      child: const MaterialApp(home: ProfilePage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _choose(WidgetTester tester, String option) async {
  await tester.tap(find.byKey(const Key('profile-avatar')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.text(option));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

String? _heroPhoto(WidgetTester tester) => tester
    .widget<ProfessionalAvatar>(
      find
          .descendant(
            of: find.byKey(const Key('profile-avatar')),
            matching: find.byType(ProfessionalAvatar),
          )
          .first,
    )
    .imageUrl;

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    PhotoAuth.accessToken = null;
  });

  testWidgets('backing out of the picker uploads nothing', (tester) async {
    final auth = _Auth();
    final picker = _Picker(null);
    await _open(tester, auth, picker);
    await _choose(tester, 'Take photo');
    expect(picker.sources, [PhotoSource.camera]);
    expect(auth.uploads, isEmpty);
    expect(find.textContaining('Photo updated'), findsNothing);
  });

  test('backing out of the cropper picks nothing', () async {
    var cropped = false;
    final cancelled = DevicePhotoPicker(
      choose: (_) async => '/tmp/a.jpg',
      crop: (_) async {
        cropped = true;
        return null;
      },
    );
    expect(await cancelled.pick(PhotoSource.library), isNull);
    expect(cropped, isTrue);

    final notChosen = DevicePhotoPicker(
      choose: (_) async => null,
      crop: (_) async => fail('nothing was chosen to crop'),
    );
    expect(await notChosen.pick(PhotoSource.camera), isNull);
  });

  testWidgets('a successful upload updates the avatar and the saved session', (
    tester,
  ) async {
    final auth = _Auth();
    await _open(tester, auth, _Picker(_bytes));
    expect(_heroPhoto(tester), isNull);
    await _choose(tester, 'Choose from library');
    expect(auth.uploads, [_bytes]);
    expect(_heroPhoto(tester), _path);
    expect(find.text('Photo updated.'), findsOneWidget);
    final saved = await SecureSessionStorage(
      storage: const FlutterSecureStorage(),
    ).loadSession();
    expect(saved?.profilePhotoUrl, _path);
  });

  testWidgets('a failed upload says so and keeps the old photo', (
    tester,
  ) async {
    const old = '/v1/users/user-1/photo?v=old';
    final auth = _Auth(photo: old)
      ..failure = const AuthNetworkException('That photo is too large.');
    await _open(tester, auth, _Picker(_bytes), sessionPhoto: old);
    await _choose(tester, 'Take photo');
    expect(find.text('That photo is too large.'), findsOneWidget);
    expect(_heroPhoto(tester), old);
  });

  testWidgets('a picker that refuses gets a plain message', (tester) async {
    await _open(tester, _Auth(), const _RefusingPicker());
    await _choose(tester, 'Take photo');
    expect(
      find.text('We couldn’t change your photo. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets('remove goes back to initials', (tester) async {
    const old = '/v1/users/user-1/photo?v=old';
    final auth = _Auth(photo: old);
    await _open(tester, auth, _Picker(null), sessionPhoto: old);
    await _choose(tester, 'Remove photo');
    expect(auth.deletes, 1);
    expect(_heroPhoto(tester), isNull);
    expect(find.text('Photo removed.'), findsOneWidget);
  });

  testWidgets('remove is not offered without a photo', (tester) async {
    await _open(tester, _Auth(), _Picker(null));
    await tester.tap(find.byKey(const Key('profile-avatar')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Remove photo'), findsNothing);
  });

  group('ProfessionalAvatar', () {
    Future<void> pump(WidgetTester tester, String? url) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfessionalAvatar(name: 'Ada Lovelace', imageUrl: url),
        ),
      ),
    );

    testWidgets('sends the token, to our own gateway only', (tester) async {
      PhotoAuth.accessToken = 'token-1';
      await pump(tester, '/v1/users/u1/photo?v=abc');
      final resized =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      final network = resized.imageProvider as NetworkImage;
      expect(
        network.url,
        '${AppConfig.gatewayBaseUrl}/v1/users/u1/photo?v=abc',
      );
      expect(network.headers?['Authorization'], 'Bearer token-1');
    });

    testWidgets('an empty photo (what a Level 0 viewer gets) shows initials', (
      tester,
    ) async {
      PhotoAuth.accessToken = 'token-1';
      await pump(tester, '');
      expect(find.byType(Image), findsNothing);
      expect(find.text('AL'), findsOneWidget);
    });

    testWidgets('an outside address is never fetched', (tester) async {
      PhotoAuth.accessToken = 'token-1';
      for (final url in [
        'https://media.licdn.com/a.jpg',
        '//evil.example/v1/a',
        'v1/users/u1/photo',
      ]) {
        await pump(tester, url);
        expect(find.byType(Image), findsNothing, reason: url);
        expect(find.text('AL'), findsOneWidget, reason: url);
      }
    });

    testWidgets('a photo that fails to load falls back to initials', (
      tester,
    ) async {
      await pump(tester, '/v1/users/u1/photo?v=abc');
      // The test binding answers every HTTP request with an error.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.text('AL'), findsOneWidget);
    });
  });
}

class _RefusingPicker implements PhotoPicker {
  const _RefusingPicker();

  @override
  Future<Uint8List?> pick(PhotoSource source) async =>
      throw StateError('camera permission denied');
}
