"""The TieHere screen inventory and flow, read off the Flutter code on
2026-09-17 (frontend/lib/features/**). One source for both wireframe
outputs: `build.py` turns this into an Excalidraw board and a clickable
HTML flow, so the two can never disagree with each other.

Every label below is the exact string the app shows. Every arrow is a
Navigator.push / pushReplacement in the code, with its gate where one
exists. Trust levels: L0 guest (view only), L1 signed up, L2 verified
(phone + personal email + personal details: can join), L3 hosting
(organisation + work email: can host), L4 reserved (ride share, dating:
"coming soon").
"""

AREAS = [
    ("auth", "Entry and sign-in"),
    ("main", "The four tabs"),
    ("meetup", "A meetup"),
    ("host", "Hosting"),
    ("verify", "Verification and settings"),
]

# Item kinds:
#   ("bar", title)                    app bar with a back arrow
#   ("h", text) / ("p", text)         heading / paragraph
#   ("btn", label, target)            filled button; target = screen id, None,
#                                     or a list of (condition, screen id)
#   ("sec", label, target)            outlined button
#   ("link", label, target)           text link
#   ("input", placeholder)            text field
#   ("otp",)                          six code boxes
#   ("check", text)                   checkbox row
#   ("tabs", [labels], selected_idx)  text tabs
#   ("chips", [labels])               chip row
#   ("card", [lines], target)         a tappable card
#   ("row", label, detail, target)    a list row with chevron
#   ("state", text)                   a note about an alternative state
#   ("sheet", title, [items])         a bottom sheet over this screen
#   ("nav", active_idx)               HOME / EVENTS / SAFETY / PROFILE bar

NAV = ["HOME", "EVENTS", "SAFETY", "PROFILE"]
NAV_TARGETS = ["home", "events", "safety", "profile"]

SCREENS = [
    # ---------------------------------------------------------------- auth
    dict(
        id="splash", area="auth", title="Splash",
        file="splash/splash_screen.dart",
        items=[
            ("h", "TieHere"),
            ("p", "Connect with who's here"),
            ("state", "Restores a saved session while the mark shows."),
            ("btn", "session found", "home"),
            ("sec", "no session", "landing"),
        ],
    ),
    dict(
        id="landing", area="auth", title="Landing",
        file="landing/landing_page.dart",
        items=[
            ("state", "Scrolling collage of meetup scenes behind the title."),
            ("h", "TieHere"),
            ("p", "Connect with who's here"),
            ("btn", "GET STARTED", "signup_age"),
            ("link", "ALREADY A MEMBER?  SIGN IN", "signin_method"),
        ],
    ),
    dict(
        id="signup_age", area="auth", title="Sign up: age",
        file="onboarding/age_confirmation_step.dart",
        items=[
            ("h", "You must be 18 or older to use TieHere."),
            ("p", "We verify professional identity and give you tools to plan safer in-person meetups. But only you can confirm your age."),
            ("check", "I confirm I am 18 years of age or older."),
            ("btn", "CONTINUE", "signup_method"),
        ],
    ),
    dict(
        id="signup_method", area="auth", title="Sign up: method",
        file="onboarding/onboarding_flow.dart",
        items=[
            ("h", "Connect Beyond The Office."),
            ("p", "Meet verified professionals in real life. Your next coffee, mentor, or co-founder is nearby."),
            ("btn", "CONTINUE WITH GOOGLE  (Android)  /  APPLE  (iOS)", [
                ("new account", "profile_setup"),
                ("returning member", "home"),
            ]),
            ("btn", "CONTINUE WITH LINKEDIN", [
                ("new account", "profile_setup"),
                ("returning member", "home"),
            ]),
            ("p", "or"),
            ("sec", "SIGN UP WITH EMAIL", "signup_email"),
            ("sec", "CONTINUE AS GUEST", [("L0, view only", "home")]),
            ("state", "While a provider runs: the page blurs behind \"Setting up your account\"."),
        ],
    ),
    dict(
        id="signup_email", area="auth", title="Sign up: email",
        file="onboarding/email_signup_step.dart",
        items=[
            ("bar", "SIGN UP WITH EMAIL"),
            ("h", "What's your email?"),
            ("input", "you@example.com"),
            ("btn", "SEND CODE", None),
            ("p", "Enter the code we sent to you@example.com"),
            ("otp",),
            ("btn", "VERIFY", "profile_setup"),
        ],
    ),
    dict(
        id="profile_setup", area="auth", title="Complete your profile",
        file="onboarding/profile_setup_screen.dart",
        items=[
            ("bar", "COMPLETE YOUR PROFILE"),
            ("h", "Tell us about yourself"),
            ("input", "Full name"),
            ("p", "COMPANY OR ORGANIZATION (OPTIONAL)"),
            ("input", "Company / Organisation"),
            ("input", "Company / Organisation Email"),
            ("sec", "VERIFY", None),
            ("state", "Work email verified  (after the code)"),
            ("btn", "CONTINUE", "home"),
            ("link", "Skip for now", "home"),
        ],
    ),
    dict(
        id="signin_method", area="auth", title="Sign in",
        file="auth/email_login_page.dart",
        items=[
            ("bar", "SIGN IN"),
            ("h", "Welcome back"),
            ("check", "I confirm I am 18 years of age or older."),
            ("btn", "CONTINUE WITH GOOGLE  (Android)  /  APPLE  (iOS)", [
                ("returning member", "home"),
                ("new account", "profile_setup"),
            ]),
            ("btn", "CONTINUE WITH LINKEDIN", [
                ("returning member", "home"),
                ("new account", "profile_setup"),
            ]),
            ("p", "or"),
            ("sec", "CONTINUE WITH EMAIL", "signin_email"),
            ("state", "While a provider runs: the page blurs behind \"Signing you in\"; only the tapped button spins."),
        ],
    ),
    dict(
        id="signin_email", area="auth", title="Sign in: email",
        file="auth/email_login_page.dart",
        items=[
            ("bar", "SIGN IN"),
            ("h", "Sign in with email"),
            ("p", "We will send a one-time code to the email you signed up with."),
            ("input", "you@example.com"),
            ("btn", "SEND CODE", "signin_otp"),
        ],
    ),
    dict(
        id="signin_otp", area="auth", title="Sign in: code",
        file="auth/email_login_page.dart",
        items=[
            ("bar", "SIGN IN"),
            ("h", "Enter the code we sent to you@example.com"),
            ("otp",),
            ("btn", "VERIFY", "home"),
            ("link", "Resend code in 54s", None),
        ],
    ),
    # ---------------------------------------------------------------- main
    dict(
        id="home", area="main", title="Home",
        file="home/home_page.dart",
        items=[
            ("h", "Good morning, Test L3 Alpha"),
            ("row", "bell", "notifications", "notifications"),
            ("p", "WAITING FOR YOUR REVIEW"),
            ("card", ["REVIEW  ·  MEAL: LUNCH", "Test L3 Alpha  ·  YOU HOSTED", "Share your thoughts about this meetup  ›"], "review"),
            ("p", "HAPPENING NOW  /  CANCELLED  /  ACTIVE MEETUPS"),
            ("card", ["NETWORKING  ·  YOU'RE HOSTING", "Colombo Fort Cafe  ·  21 MON 1:41 PM"], "meetup_host"),
            ("p", "HAPPENING SOON"),
            ("tabs", ["ALL", "COFFEE", "MEAL", "NETWORKING", "MENTORSHIP", "EVENTS", "OUTING", "RIDE SHARE (locked)", "DATING (locked)"], 0),
            ("card", ["Test L3 Bravo  ·  HOST  ·  L3 Trust", "Sep 19, 12:13 - 1:13 AM  ·  Barefoot Garden Cafe", "COFFEE  ·  0/3 JOINED"], "meetup_join"),
            ("btn", "I'M INTERESTED", [
                ("L2 or higher", "join_sheet"),
                ("L0 / L1", "verify_checklist"),
            ]),
            ("sec", "VIEW LOCATION", "location"),
            ("state", "Other states of this section: skeleton while locating; location card (OPEN LOCATION SETTINGS / TRY AGAIN); empty (balcony picture: \"No meetups near you this week\"); failure (rain picture, TRY AGAIN)."),
            ("btn", "HOST YOUR OWN MEETUP", [
                ("L3 or higher", "schedule_intent"),
                ("below L3", "hosting_unlock"),
            ]),
            ("nav", 0),
        ],
    ),
    dict(
        id="notifications", area="main", title="Notifications",
        file="notifications/notifications_page.dart",
        items=[
            ("bar", "NOTIFICATIONS"),
            ("p", "TODAY"),
            ("row", "Not this time", "The coffee meetup was not the right fit this round...", "meetup_declined"),
            ("row", "New join request", "Ada wants to join your coffee meetup", "requests"),
            ("row", "Meetup starting soon", "Your coffee meetup starts soon. Review your safety checklist.", "meetup_accepted"),
            ("state", "Empty: \"All quiet for now\" with the inbox card deck."),
        ],
    ),
    dict(
        id="events", area="main", title="Events",
        file="meetups/events_page.dart",
        items=[
            ("bar", "EVENTS"),
            ("tabs", ["My Meetings", "Requested Meetings"], 0),
            ("chips", ["Open meetups", "History"]),
            ("card", ["NETWORKING  ·  L3 Trust", "Sep 21, 1:41 - 2:41 PM  ·  Colombo Fort Cafe", "0/3 confirmed"], "requests"),
            ("sec", "VIEW REQUESTS", "requests"),
            ("state", "History card → meetup page (review). Requested tab card → meetup page; chip reads REQUEST PENDING / YOU'RE IN / NOT THIS TIME / FILLED UP BEFORE YOUR TURN / WITHDRAWN."),
            ("state", "Empty: card deck, \"Nothing on your calendar yet\" + HOST A MEETUP."),
            ("btn", "HOST A MEETUP", [
                ("L3 or higher", "schedule_intent"),
                ("below L3", "hosting_unlock"),
            ]),
            ("nav", 1),
        ],
    ),
    dict(
        id="requests", area="main", title="Requests (host)",
        file="meetups/events_page.dart",
        items=[
            ("bar", "REQUESTS"),
            ("tabs", ["PENDING", "ACCEPTED", "REJECTED"], 0),
            ("card", ["TB  Test L2 Bravo  ·  L2 Trust  ·  New"], "public_profile"),
            ("btn", "ACCEPT", None),
            ("sec", "REJECT", None),
            ("state", "Accept → requester is notified \"Request accepted\" and gets a safety checklist. Reject → requester is notified \"Not this time\". Filling the last seat auto-declines the rest (\"That one filled up fast\")."),
            ("sec", "CLOSE MEETUP  /  CANCEL MEETUP", None),
        ],
    ),
    dict(
        id="safety", area="main", title="Safety Center",
        file="safety/safety_page.dart",
        items=[
            ("bar", "SAFETY CENTER"),
            ("p", "PRE MEETUP CHECKLIST"),
            ("check", "Meet in a public place"),
            ("check", "Tell a trusted contact where you are going"),
            ("check", "Keep first meetings short"),
            ("check", "Never share OTP codes"),
            ("check", "Never send money"),
            ("p", "TRUSTED CONTACTS"),
            ("row", "Add a contact · 0 of 3 added", "", "contacts"),
            ("btn", "TRIGGER SOS", [
                ("L2 or higher", "safety"),
                ("below L2: UNLOCK SAFETY FEATURES", "verify_checklist"),
            ]),
            ("state", "SOS: \"EMERGENCY SOS. This will share your live location with your trusted contacts.\" CANCEL / CONFIRM, then CALL EMERGENCY SERVICES."),
            ("nav", 2),
        ],
    ),
    dict(
        id="profile", area="main", title="Profile",
        file="profile/profile_page.dart",
        items=[
            ("state", "Full-bleed deep-blue band: avatar, name, standing, badges, MEETUPS / RATING / TRUST counts, edit (Edit Name)."),
            ("p", "VERIFICATION"),
            ("row", "Phone", "Verified", "verify_phone"),
            ("row", "LinkedIn", "Connect LinkedIn", None),
            ("row", "Personal Email", "Verified", "verify_email"),
            ("row", "Personal Details", "Verified", "verify_details"),
            ("row", "Work Email", "Verified", "verify_work_email"),
            ("p", "PREFERENCES"),
            ("row", "Premium", "Upgrade for more", "premium"),
            ("row", "Privacy Controls", "Visibility and location", "privacy"),
            ("row", "Notifications", "Last 7 days", "notifications"),
            ("row", "Safety Center", "Trusted contacts and SOS", "safety"),
            ("row", "Appearance", "Light / Dark", None),
            ("sec", "SIGN OUT", "landing"),
            ("state", "Sign out: \"Sign out of TieHere?\" CANCEL / SIGN OUT; local first, one background logout request."),
            ("nav", 3),
        ],
    ),
    # -------------------------------------------------------------- meetup
    dict(
        id="meetup_join", area="meetup", title="Meetup (viewer)",
        file="meetups/meetup_detail_page.dart",
        items=[
            ("bar", "MEETUP"),
            ("card", ["COFFEE", "Sep 19, 12:13 - 1:13 AM", "Barefoot Garden Cafe", "Hosted by Test L3 Bravo • L3 Trust  ›", "0/3 confirmed", "TB  1 going · join to see who  ›"], "public_profile"),
            ("row", "LOCATION", "Map, address and directions", "location"),
            ("btn", "I'M INTERESTED", [
                ("L2 or higher", "join_sheet"),
                ("L0 / L1", "verify_checklist"),
            ]),
            ("state", "\"1 going\" row → Who's coming (verified) or its verify prompt."),
        ],
    ),
    dict(
        id="join_sheet", area="meetup", title="Confirm interest (sheet)",
        file="meetups/widgets/join_confirmation_sheet.dart",
        items=[
            ("sheet", "YOUR HOST", [
                ("p", "Test L3 Bravo  ·  L3 Trust  ·  COFFEE · Sep 19, 12:13 - 1:13 AM"),
                ("btn", "CONFIRM YOUR INTEREST", [
                    ("no overlap", "meetup_pending"),
                    ("overlaps another meetup you hold", "conflict_sheet"),
                ]),
                ("sec", "NOT NOW", "meetup_join"),
            ]),
        ],
    ),
    dict(
        id="conflict_sheet", area="meetup", title="One meetup at a time (sheet)",
        file="meetups/widgets/schedule_conflict_sheet.dart",
        items=[
            ("sheet", "ONE MEETUP AT A TIME", [
                ("p", "Wait until it ends at 2:41 PM, or withdraw from it to free the time."),
                ("card", ["NETWORKING  ·  Colombo Fort Cafe", "Sep 21, 1:41 - 2:41 PM"], None),
                ("btn", "OPEN THAT MEETUP", "meetup_host"),
                ("sec", "I'LL WAIT", None),
            ]),
            ("state", "Also raised by the schedule flow's time step (advisory check) and on the server (409 schedule_conflict)."),
        ],
    ),
    dict(
        id="meetup_pending", area="meetup", title="Meetup (request pending)",
        file="meetups/meetup_detail_page.dart",
        items=[
            ("bar", "MEETUP"),
            ("card", ["COFFEE  ·  Sep 19, 12:13 - 1:13 AM", "Barefoot Garden Cafe  ·  Hosted by Test L3 Bravo"], None),
            ("row", "LOCATION", "Map, address and directions", "location"),
            ("state", "REQUEST PENDING  ·  Waiting for the host to respond. We will notify you."),
            ("sec", "CANCEL REQUEST", "meetup_join"),
            ("state", "Host accepts → this page becomes \"YOU'RE IN\". Host declines → \"NOT THIS TIME\"."),
        ],
    ),
    dict(
        id="meetup_accepted", area="meetup", title="Meetup (you're in)",
        file="meetups/meetup_detail_page.dart",
        items=[
            ("bar", "MEETUP"),
            ("card", ["COFFEE  ·  Sep 19, 12:13 - 1:13 AM", "Barefoot Garden Cafe  ·  Hosted by Test L3 Bravo", "TB  2 going  ›"], "participants"),
            ("row", "LOCATION", "Map, address and directions", "location"),
            ("state", "YOU'RE IN  ·  The host accepted your request. See you there."),
            ("sec", "WITHDRAW REQUEST", "meetup_join"),
            ("p", "SAFETY GATE  ·  Before you go"),
            ("btn", "I UNDERSTAND", None),
            ("row", "Tell a trusted contact", "Send someone you trust the time and place of this meetup.", "contacts"),
            ("state", "After the window ends: review section (SHARE YOUR THOUGHTS)."),
        ],
    ),
    dict(
        id="meetup_declined", area="meetup", title="Meetup (not this time)",
        file="meetups/meetup_detail_page.dart",
        items=[
            ("bar", "MEETUP"),
            ("card", ["COFFEE  ·  Sep 19, 12:13 - 1:13 AM", "Barefoot Garden Cafe  ·  Hosted by Test L3 Bravo"], None),
            ("row", "LOCATION", "Map, address and directions", "location"),
            ("state", "NOT THIS TIME  ·  Hosts keep their groups small, so not every request can fit. There are more meetups near you."),
            ("p", "OTHERS HAPPENING SOON"),
            ("row", "NETWORKING  ·  Test L2 Bravo", "Sep 20, 12:13 - 2:13 AM at Hatch Colombo", "meetup_join"),
            ("sec", "SEE ALL NEARBY", "home"),
            ("state", "Nothing else on / location off: \"New meetups go up every day...\" + BROWSE MEETUPS → Home."),
        ],
    ),
    dict(
        id="meetup_host", area="meetup", title="Meetup (you host)",
        file="meetups/meetup_detail_page.dart",
        items=[
            ("bar", "MEETUP"),
            ("card", ["NETWORKING  ·  Sep 21, 1:41 - 2:41 PM", "Colombo Fort Cafe  ·  Hosted by Test L3 Alpha", "0/3 confirmed  ·  TA  1 going  ›"], "participants"),
            ("row", "LOCATION", "Map, address and directions", "location"),
            ("row", "VIEW REQUESTS", "See who asked to join, accept or pass", "requests"),
            ("sec", "CANCEL MEETUP", None),
            ("state", "Cancel: \"Cancel this meetup? This can't be undone...\" + reason (required). Once the window has started: CLOSE MEETUP (\"Mark this meetup as done?\")."),
        ],
    ),
    dict(
        id="location", area="meetup", title="Location",
        file="meetups/location_view_page.dart",
        items=[
            ("bar", "LOCATION"),
            ("state", "Map (MapLibre on Android, Apple Maps on iOS) with the pin, label and address."),
            ("btn", "GET DIRECTIONS", None),
            ("state", "Opens Google Maps / Apple Maps directions. Below L2 the button is gated with a toast."),
        ],
    ),
    dict(
        id="participants", area="meetup", title="Who's coming",
        file="meetups/participants_page.dart",
        items=[
            ("bar", "WHO'S COMING"),
            ("p", "PEOPLE"),
            ("row", "Test L3 Bravo  ·  HOST", "L3 Trust", "public_profile"),
            ("row", "Test L3 Alpha  ·  YOU", "JOINED", None),
            ("state", "Not joined: \"Join to see who's coming\". Below L2: \"Verify to see who's coming\" + GET VERIFIED → checklist."),
        ],
    ),
    dict(
        id="public_profile", area="meetup", title="Public profile",
        file="profile/public_profile_page.dart",
        items=[
            ("bar", "MEMBER"),
            ("state", "Avatar, name, trust level, badges (Professional, Official), rating, meetups hosted / joined."),
        ],
    ),
    dict(
        id="review", area="meetup", title="Share your thoughts",
        file="meetups/review/meetup_review_page.dart",
        items=[
            ("bar", "SHARE YOUR THOUGHTS"),
            ("p", "What were they like? (up to 3)"),
            ("chips", ["POSITIVE", "NEGATIVE"]),
            ("input", "Describe in detail (optional)"),
            ("btn", "CONFIRM", "home"),
            ("state", "Cancelled meetup: banner \"THIS MEETUP WAS CANCELLED BY THE HOST\", rate the host only."),
        ],
    ),
    # ---------------------------------------------------------------- host
    dict(
        id="schedule_intent", area="host", title="Schedule 1 of 5: intent",
        file="meetups/schedule_flow.dart",
        items=[
            ("bar", "SCHEDULE A MEETUP  ·  STEP 1 OF 5"),
            ("h", "What kind of meetup?"),
            ("chips", ["COFFEE", "MEAL", "NETWORKING", "MENTORSHIP", "EVENTS", "OUTING", "RIDE SHARE · COMING SOON", "DATING · COMING SOON"]),
            ("btn", "(tap a tile)", "schedule_when"),
        ],
    ),
    dict(
        id="schedule_when", area="host", title="Schedule 2 of 5: when",
        file="meetups/schedule_flow.dart",
        items=[
            ("bar", "SCHEDULE A MEETUP  ·  STEP 2 OF 5"),
            ("h", "When should it happen?"),
            ("row", "DATE", "Today · Thu 17 Sep  ·  Tap to change", None),
            ("input", "FROM 22:00      TO 23:00   (24-hour format)"),
            ("state", "22:00 → 23:00 · 1 h"),
            ("btn", "CONTINUE", [
                ("no overlap", "schedule_where"),
                ("overlaps a meetup you hold", "conflict_sheet"),
            ]),
        ],
    ),
    dict(
        id="schedule_where", area="host", title="Schedule 3 of 5: where",
        file="meetups/widgets/android_map_location_step.dart",
        items=[
            ("bar", "SCHEDULE A MEETUP  ·  STEP 3 OF 5"),
            ("h", "Where?"),
            ("input", "Search for a place"),
            ("state", "Map with a draggable pin. Choose a public place: a cafe, restaurant, or well-known venue."),
            ("sec", "USE MY CURRENT LOCATION", None),
            ("state", "While locating: ring sweeps around the crosshair, \"FINDING YOU...\""),
            ("btn", "CONTINUE", "schedule_capacity"),
        ],
    ),
    dict(
        id="schedule_capacity", area="host", title="Schedule 4 of 5: capacity",
        file="meetups/schedule_flow.dart",
        items=[
            ("bar", "SCHEDULE A MEETUP  ·  STEP 4 OF 5"),
            ("h", "How many people?"),
            ("state", "-   3   +     Including you   (1 to 20)"),
            ("btn", "CONTINUE", "schedule_review"),
        ],
    ),
    dict(
        id="schedule_review", area="host", title="Schedule 5 of 5: review",
        file="meetups/schedule_flow.dart",
        items=[
            ("bar", "SCHEDULE A MEETUP  ·  STEP 5 OF 5"),
            ("h", "Review & confirm"),
            ("row", "INTENT", "Coffee", None),
            ("row", "WHEN", "Today, 10:00 - 11:00 PM", None),
            ("row", "LOCATION", "Barefoot Garden Cafe", None),
            ("row", "CAPACITY", "3, including you", None),
            ("btn", "CONFIRM & SCHEDULE", [
                ("created", "home"),
                ("server 409 schedule_conflict", "conflict_sheet"),
            ]),
        ],
    ),
    dict(
        id="hosting_unlock", area="host", title="Unlock hosting",
        file="verification/hosting_unlock_page.dart",
        items=[
            ("bar", "UNLOCK HOSTING MEETUPS"),
            ("p", "Hosting a meetup means taking responsibility for a real gathering, so we ask hosts to show who they are."),
            ("p", "YOUR ORGANISATION"),
            ("row", "Company / Organisation", "", None),
            ("row", "Company / Organisation Email", "ADD", "verify_work_email"),
            ("state", "Still needed: organisation, work email.  COMPLETE once both are set."),
            ("link", "Unlock joining meetups →", "verify_checklist"),
        ],
    ),
    # -------------------------------------------------------------- verify
    dict(
        id="verify_checklist", area="verify", title="Verification checklist",
        file="verification/verification_checklist_page.dart",
        items=[
            ("bar", "UNLOCK JOINING MEETUPS"),
            ("p", "REMAINING STEPS"),
            ("row", "Phone", "VERIFY", "verify_phone"),
            ("row", "Personal Email", "VERIFY", "verify_email"),
            ("row", "Personal Details", "VERIFY", "verify_details"),
            ("state", "All three done → L2 → COMPLETE. Reached from I'M INTERESTED (L0/L1), TRIGGER SOS (below L2), GET VERIFIED, Unlock hosting."),
        ],
    ),
    dict(
        id="verify_phone", area="verify", title="Verify your phone",
        file="verification/phone_verification_page.dart",
        items=[
            ("bar", "Verify Your Phone"),
            ("input", "+94 7X XXX XXXX"),
            ("btn", "SEND CODE", None),
            ("otp",),
            ("btn", "VERIFY", "verify_checklist"),
        ],
    ),
    dict(
        id="verify_email", area="verify", title="Verify your email",
        file="verification/personal_email_verification_page.dart",
        items=[
            ("bar", "Verify Your Email"),
            ("input", "you@example.com"),
            ("btn", "SEND CODE", None),
            ("otp",),
            ("btn", "VERIFY", "verify_checklist"),
        ],
    ),
    dict(
        id="verify_details", area="verify", title="Personal details",
        file="verification/personal_details_page.dart",
        items=[
            ("bar", "Personal Details"),
            ("input", "Full name"),
            ("input", "Date of birth"),
            ("btn", "CONTINUE", "verify_checklist"),
        ],
    ),
    dict(
        id="verify_work_email", area="verify", title="Work email",
        file="verification/corporate_email_verification_page.dart",
        items=[
            ("bar", "Company / Organisation Email"),
            ("input", "you@yourcompany.com"),
            ("p", "We don't store this email, only that it proved you belong to the organisation."),
            ("btn", "SEND CODE", None),
            ("otp",),
            ("btn", "VERIFY", "hosting_unlock"),
            ("state", "A personal-looking address is refused: \"This looks like a personal email address.\""),
        ],
    ),
    dict(
        id="contacts", area="verify", title="Trusted contacts",
        file="safety/manage_trusted_contacts_page.dart",
        items=[
            ("bar", "TRUSTED CONTACTS"),
            ("state", "Empty: card deck, \"Nobody on your list yet\". Up to 3 contacts; a phone number is required."),
            ("input", "Name"),
            ("input", "Phone"),
            ("input", "Email (optional)"),
            ("btn", "SAVE", "safety"),
            ("sec", "REMOVE CONTACT", None),
        ],
    ),
    dict(
        id="privacy", area="verify", title="Privacy controls",
        file="privacy/privacy_controls_page.dart",
        items=[
            ("bar", "PRIVACY CONTROLS"),
            ("p", "WHAT WE DO TODAY"),
            ("row", "Who can see you", "", None),
            ("row", "Your location", "", None),
            ("row", "Trusted contacts", "", None),
            ("row", "Ratings you give", "", None),
            ("state", "Controls are coming. Settings to change any of the above will appear here."),
        ],
    ),
    dict(
        id="premium", area="verify", title="Premium plans",
        file="premium/premium_plans_page.dart",
        items=[
            ("p", "Try TieHere Premium free"),
            ("h", "Unlock all features"),
            ("card", ["Rs xxxx /month      Rs xxxx /year", "Premium Annual Plan", "Host up to three meetups a day · Filter by company and industry · Premium mark · Priority help"], None),
            ("chips", ["Monthly  Rs xxxx", "Annual  Rs xxxx  · Popular"]),
            ("p", "Cancel any time. Prices are placeholders until billing goes live."),
            ("btn", "START 7 DAYS FREE TRIAL", None),
            ("state", "UI only today; the tap shows \"Premium is coming soon\"."),
        ],
    ),
]

BY_ID = {s["id"]: s for s in SCREENS}


def edges():
    """Every (from, to, label) the items imply, plus the tab bar."""
    out = []
    for s in SCREENS:
        def walk(items):
            for it in items:
                kind = it[0]
                if kind in ("btn", "sec", "link"):
                    _, label, target = it
                    if isinstance(target, list):
                        for cond, tid in target:
                            out.append((s["id"], tid, f"{label}  ·  {cond}"))
                    elif target:
                        out.append((s["id"], target, label))
                elif kind == "card" and it[2]:
                    out.append((s["id"], it[2], "tap card"))
                elif kind == "row" and it[3]:
                    out.append((s["id"], it[3], it[1]))
                elif kind == "sheet":
                    walk(it[2])
        walk(s["items"])
    return out


for _s in SCREENS:
    for _f, _t, _l in edges():
        assert _t in BY_ID, (_f, _t, _l)
