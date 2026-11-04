import 'dart:typed_data';

import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

/// Where a new profile photo comes from.
enum PhotoSource { camera, library }

/// Takes or chooses a picture and crops it on the phone (plan 2.1): the
/// square/circle crop with pinch and drag, at most 640 px, JPEG quality 85,
/// so uploads stay small and the phone does the work.
abstract interface class PhotoPicker {
  /// The cropped JPEG, or null if the person backed out at either step.
  Future<Uint8List?> pick(PhotoSource source);
}

/// The real one, over the platform pickers. [choose] and [crop] replace the
/// two platform steps in a test; each answers null when the person backs out.
class DevicePhotoPicker implements PhotoPicker {
  const DevicePhotoPicker({this.choose = _choose, this.crop = _crop});

  final Future<String?> Function(PhotoSource source) choose;
  final Future<Uint8List?> Function(String path) crop;

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    final path = await choose(source);
    return path == null ? null : crop(path);
  }

  static Future<String?> _choose(PhotoSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source == PhotoSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
    );
    return picked?.path;
  }

  static Future<Uint8List?> _crop(String path) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 85,
      maxWidth: 640,
      maxHeight: 640,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Your photo',
          cropStyle: CropStyle.circle,
          lockAspectRatio: true,
          hideBottomControls: true,
        ),
        IOSUiSettings(
          title: 'Your photo',
          cropStyle: CropStyle.circle,
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
      ],
    );
    return cropped?.readAsBytes();
  }
}
