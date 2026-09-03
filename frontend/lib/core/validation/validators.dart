/// Pure, side-effect-free validation rules.
/// IMPORTANT: client-side checks exist only for UX speed.
/// The server must re-validate every single input before acting on it.
abstract final class Validators {
  static final RegExp _phone = RegExp(r'^\+?[0-9\s-]{9,15}$');
  static final RegExp _otp = RegExp(r'^\d{6}$');
  static final RegExp _linkedin = RegExp(
    r'^(https?://)?(www\.)?linkedin\.com/in/[A-Za-z0-9_\-]{5,}/?$',
  );
  static final RegExp _email = RegExp(
    r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$',
  );

  static const Set<String> freeProviders = {
    'gmail.com',
    'yahoo.com',
    'hotmail.com',
    'outlook.com',
    'icloud.com',
    'proton.me',
    'protonmail.com',
    'aol.com',
    'zoho.com',
    'gmx.com',
  };

  static const Set<String> roleBasedPrefixes = {
    'info',
    'admin',
    'hr',
    'contact',
    'support',
    'careers',
    'jobs',
    'office',
    'sales',
    'hello',
  };

  static String? phone(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'Phone number is required.';
    if (!_phone.hasMatch(v)) return 'Enter a valid phone number.';
    return null;
  }

  /// Plain email-shape check — no free-provider/role-based-mailbox
  /// rejection (that's [corporateEmail]'s job, since only the work-email
  /// flow cares about it). Used for personal email verification and
  /// trusted-contact email fields (2026-08-31 review hardening — these
  /// screens previously did no client-side validation at all beyond a
  /// non-empty check).
  static String? email(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'Email is required.';
    if (!_email.hasMatch(v)) return 'Enter a valid email address.';
    return null;
  }

  static String? otp(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'OTP is required.';
    if (!_otp.hasMatch(v)) return 'Enter the 6 digit code.';
    return null;
  }

  static String? linkedin(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'LinkedIn profile is required.';
    if (!_linkedin.hasMatch(v)) {
      return 'Enter a valid linkedin.com/in profile URL.';
    }
    return null;
  }

  static String? corporateEmail(String value) {
    final v = value.trim().toLowerCase();
    if (v.isEmpty) return 'Work email is required.';
    if (!_email.hasMatch(v)) return 'Enter a valid email address.';
    final parts = v.split('@');
    final local = parts.first;
    final domain = parts.last;
    if (freeProviders.contains(domain)) {
      return 'Personal email domains are not accepted. Use your company email.';
    }
    if (roleBasedPrefixes.contains(local)) {
      return 'Role based mailboxes cannot be verified.';
    }
    return null;
  }
}
