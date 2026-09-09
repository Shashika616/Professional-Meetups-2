import 'dart:async';

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/otp_box_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';

/// Shared 6-digit code entry — used identically by every OTP-based signup/
/// verification screen (phone/personal-email/corporate-email/email-signup)
/// so the input-plus-timer UI isn't built five times.
///
/// **Optimistic send (UX improvement)**: the caller mounts this widget the
/// instant the user taps "Send code" — before the network call even
/// starts, not after it resolves. [onSend] is called automatically once,
/// on mount, and the countdown is shown from the very first frame using
/// [resendCooldownSeconds] as an optimistic default. This replaces the
/// previous design, where the whole screen sat on a loading spinner until
/// the backend responded — a slow or degraded backend used to stall the
/// UI outright; now the user sees "code sent, resend in 60s" immediately,
/// and a slow backend is invisible to them.
///
/// [resendCooldownSeconds] matches the backend's real cooldown
/// (`otpResendCooldown`, `services/auth/internal/service/otp.go`) exactly
/// as of this writing — if [onSend] resolves with a different value (the
/// backend's cooldown changed, or diverged for this specific purpose), the
/// countdown reconciles to that real value instead, same "trust the
/// server" principle the old design had, just applied after an optimistic
/// first paint rather than before it.
///
/// **Fault tolerance**: if [onSend] fails (network error, transient
/// backend failure, a genuine rejection like an invalid target), the
/// countdown resets to 0 immediately rather than being left to run out the
/// full optimistic cooldown for a code that was never actually sent — the
/// user can tap "Resend code" right away instead of being stuck waiting on
/// a countdown for nothing. The failure is shown inline, using the same
/// error slot a wrong VERIFY attempt uses.
class OtpEntry extends StatefulWidget {
  const OtpEntry({super.key, required this.onSend, required this.onSubmit});

  /// Sends the code — called once automatically on mount (the "first
  /// send"), and again on every user-initiated "Resend code" tap. Every
  /// caller today uses the exact same underlying `Start*Verification` call
  /// for both, so this is intentionally one callback, not two.
  final Future<int> Function() onSend;
  final Future<void> Function(String code) onSubmit;

  /// The optimistic default shown before the first [onSend] call resolves.
  @visibleForTesting
  static const int resendCooldownSeconds = 60;

  @override
  State<OtpEntry> createState() => _OtpEntryState();
}

class _OtpEntryState extends State<OtpEntry> {
  final _codeController = TextEditingController();
  Timer? _timer;
  int _secondsRemaining = OtpEntry.resendCooldownSeconds;
  bool _submitting = false;
  bool _resending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startTimer();
    // OtpBoxField doesn't expose onChanged — listening on the controller
    // directly is what makes the VERIFY button react as digits are typed
    // (enabled only once all 6 are entered).
    _codeController.addListener(_onCodeChanged);
    _sendInitialCode();
  }

  void _onCodeChanged() => setState(() {});

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.removeListener(_onCodeChanged);
    _codeController.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_secondsRemaining > 0) _secondsRemaining--;
      });
      if (_secondsRemaining <= 0) _timer?.cancel();
    });
  }

  /// Fires [OtpEntry.onSend] in the background — the countdown is already
  /// running optimistically by the time this resolves either way.
  Future<void> _sendInitialCode() async {
    try {
      final resendAfterSeconds = await widget.onSend();
      if (!mounted) return;
      // Reconcile with the server's real value only if it differs — avoids
      // an unnecessary rebuild/visual jump in the (expected) common case
      // where it matches the optimistic default exactly.
      if (resendAfterSeconds != _secondsRemaining) {
        setState(() => _secondsRemaining = resendAfterSeconds);
      }
    } catch (error) {
      if (!mounted) return;
      _timer?.cancel();
      setState(() {
        _secondsRemaining = 0;
        _error = error is AuthException
            ? error.message
            : 'We couldn’t send your code. Tap Resend to try again.';
      });
    }
  }

  Future<void> _submit() async {
    if (_submitting || _codeController.text.length != 6) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_codeController.text);
      // On success the caller navigates away — nothing left to update here.
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // A wrong/expired code shows an error but deliberately does NOT
        // reset the countdown — a wrong guess shouldn't give a free timer
        // reset (frontend/PLAN.md's addendum, Step 4).
        _error = error is AuthException
            ? error.message
            : 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _resend() async {
    if (_resending || _secondsRemaining > 0) return;
    setState(() => _resending = true);
    try {
      final resendAfterSeconds = await widget.onSend();
      if (!mounted) return;
      setState(() {
        _secondsRemaining = resendAfterSeconds;
        _error = null;
        _codeController.clear();
      });
      _startTimer();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is AuthException
            ? error.message
            : 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canResend = _secondsRemaining <= 0 && !_resending;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // WAS a single centred text field with a '######' hint and wide
        // letter-spacing. One box per digit is what people expect from a
        // code screen, and the widget also brings OS one-time-code autofill
        // with it — see OtpBoxField for why it is one hidden field rather
        // than six real ones. Same controller, so every piece of logic
        // around it is untouched.
        OtpBoxField(controller: _codeController),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppPalette.danger, fontSize: 12),
          ),
        ],
        const SizedBox(height: 16),
        PrimaryButton(
          label: 'VERIFY',
          isLoading: _submitting,
          onPressed: _codeController.text.length == 6 ? _submit : null,
        ),
        const SizedBox(height: 14),
        Center(
          child: GestureDetector(
            onTap: canResend ? _resend : null,
            child: Text(
              canResend
                  ? 'Resend code'
                  : 'Resend code in ${_secondsRemaining}s',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: canResend
                    ? AppPalette.candyBlue
                    : AppPalette.textSecondary.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
