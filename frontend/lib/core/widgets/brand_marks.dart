import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

// The sign-in providers' own logos, in their own colours.
//
// # WHY THESE ARE NOT JUST ICONS
//
// Material has no LinkedIn glyph and its "G" is a plain letter, so LinkedIn
// shipped with no mark and Google with something that read as a
// placeholder. Font Awesome fixed the shapes but not the colour: its brand
// icons are FONT GLYPHS, so they can only ever be one colour, and Google's
// mark is four.
//
// So Google's is drawn from vector paths and the other two are tinted
// glyphs — which is correct for them, since Apple's mark is monochrome by
// specification and LinkedIn's is a single blue.
//
// # BRAND COMPLIANCE
//
// Apple (HIG) and Google (Sign-In branding) both require their own logo on
// their own button, which is what this restores. The Google paths below are
// the standard 48x48 four-colour mark; if you want to be exact to the byte,
// drop Google's official asset in and point [GoogleMark] at it — the shape
// here is a faithful reproduction, not a file downloaded from them.
// Google's four-colour "G".
class GoogleMark extends StatelessWidget {
  const GoogleMark({super.key, this.size = 20});

  final double size;

  /// The canonical 48x48 mark: red top arc, blue right arc plus the crossbar,
  /// yellow left arc, green bottom arc.
  static const _svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>
  <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>
  <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>
  <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>
</svg>
''';

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(_svg, width: size, height: size);
  }
}

// Apple's mark. Monochrome by specification — it takes the button's own
// foreground colour so it stays legible on either theme.
class AppleMark extends StatelessWidget {
  const AppleMark({super.key, this.size = 20, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      FontAwesomeIcons.apple.data,
      size: size,
      color: color ?? DefaultTextStyle.of(context).style.color,
    );
  }
}

// LinkedIn's "in", in LinkedIn blue.
class LinkedInMark extends StatelessWidget {
  const LinkedInMark({super.key, this.size = 20});

  /// LinkedIn brand blue.
  static const brandBlue = Color(0xFF0A66C2);

  final double size;

  @override
  Widget build(BuildContext context) {
    return Icon(FontAwesomeIcons.linkedinIn.data, size: size, color: brandBlue);
  }
}
