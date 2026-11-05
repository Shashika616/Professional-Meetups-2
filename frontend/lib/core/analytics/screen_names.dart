import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/analytics/event_names.g.dart';

/// The one catalogue of screen names (plan 29E). Every route the app pushes
/// carries one of these as its `RouteSettings.name`, so the screen tracker
/// can tell where the user is. The values come from the backend registry
/// (`AnalyticsScreen`, generated), so the server accepts every one of them.
abstract final class ScreenNames {
  static const splash = AnalyticsScreen.splash;
  static const landing = AnalyticsScreen.landing;
  static const onboarding = AnalyticsScreen.onboarding;
  static const emailSignIn = AnalyticsScreen.emailSignIn;
  static const emailSignup = AnalyticsScreen.emailSignup;
  static const profileSetup = AnalyticsScreen.profileSetup;
  static const home = AnalyticsScreen.home;
  static const events = AnalyticsScreen.events;
  static const meetupDetail = AnalyticsScreen.meetupDetail;
  static const locationView = AnalyticsScreen.locationView;
  static const locationExplanation = AnalyticsScreen.locationExplanation;
  static const legalAcceptance = AnalyticsScreen.legalAcceptance;
  static const legalDocument = AnalyticsScreen.legalDocument;
  static const participants = AnalyticsScreen.participants;
  static const requestManagement = AnalyticsScreen.requestManagement;
  static const scheduleMeetup = AnalyticsScreen.scheduleMeetup;
  static const meetupReview = AnalyticsScreen.meetupReview;
  static const notifications = AnalyticsScreen.notifications;
  static const profile = AnalyticsScreen.profile;
  static const publicProfile = AnalyticsScreen.publicProfile;
  static const privacyControls = AnalyticsScreen.privacyControls;
  static const safety = AnalyticsScreen.safety;
  static const trustedContacts = AnalyticsScreen.trustedContacts;
  static const verificationChecklist = AnalyticsScreen.verificationChecklist;
  static const personalDetails = AnalyticsScreen.personalDetails;
  static const phoneVerification = AnalyticsScreen.phoneVerification;
  static const personalEmailVerification =
      AnalyticsScreen.personalEmailVerification;
  static const corporateEmailVerification =
      AnalyticsScreen.corporateEmailVerification;
  static const hostingUnlock = AnalyticsScreen.hostingUnlock;
  static const credits = AnalyticsScreen.credits;
  static const buyCredits = AnalyticsScreen.buyCredits;
  static const premium = AnalyticsScreen.premium;

  // Sheets and dialogs that count as a screen.
  static const scheduleConflict = AnalyticsScreen.scheduleConflict;
  static const joinConfirmation = AnalyticsScreen.joinConfirmation;
  static const shareWithContacts = AnalyticsScreen.shareWithContacts;
  static const participantReview = AnalyticsScreen.participantReview;
  static const accountClaim = AnalyticsScreen.accountClaim;
  static const sosConfirm = AnalyticsScreen.sosConfirm;

  /// Every screen above, for the tests that walk the catalogue. (The
  /// registry also lists `chats`, for the tab that is switched off; nothing
  /// routes to it.)
  static const all = [
    splash,
    landing,
    onboarding,
    emailSignIn,
    emailSignup,
    profileSetup,
    home,
    events,
    meetupDetail,
    locationView,
    locationExplanation,
    legalAcceptance,
    legalDocument,
    participants,
    requestManagement,
    scheduleMeetup,
    meetupReview,
    notifications,
    profile,
    publicProfile,
    privacyControls,
    safety,
    trustedContacts,
    verificationChecklist,
    personalDetails,
    phoneVerification,
    personalEmailVerification,
    corporateEmailVerification,
    hostingUnlock,
    credits,
    buyCredits,
    premium,
    scheduleConflict,
    joinConfirmation,
    shareWithContacts,
    participantReview,
    accountClaim,
    sosConfirm,
  ];

  /// The signed-in shell. Not a screen of its own: the tracker reports the
  /// tab that is showing instead ([tabs]).
  static const appShell = 'app_shell';

  /// The shell's tabs, in bottom-bar order (`currentTabIndexProvider`).
  static const tabs = [home, events, safety, profile];

  /// The tab at [index], or home for an index out of range.
  static String tab(int index) =>
      index >= 0 && index < tabs.length ? tabs[index] : home;
}

/// A [MaterialPageRoute] named [screen]: the one way the app pushes a page.
MaterialPageRoute<T> screenRoute<T>(String screen, WidgetBuilder builder) =>
    MaterialPageRoute<T>(
      settings: RouteSettings(name: screen),
      builder: builder,
    );
