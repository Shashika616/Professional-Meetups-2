"""The real-UI flow: every screenshot in shots/, what it is, and where each
control on it leads. Captured from the debug build on a Pixel 8 emulator
(1080x2400) on 2026-09-17 against the local stack, in light mode unless
the id starts with 9.

Hotspots are resolved from the accessibility dumps in dumps/ (uiautomator,
taken on the same screens), so every clickable region is the control's
real bounds. `links` are (label substring, target screen id, gate). A
screen with no dump of its own names `dump` to borrow a sibling's layout.
"""
import re
import os

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 1080, 2400

AREAS = [
    ("auth", "Entry and sign-in"),
    ("home", "Home"),
    ("meetup", "A meetup"),
    ("host", "Hosting"),
    ("tabs", "Events, Safety, Profile, Notifications"),
    ("verify", "Verification"),
    ("dark", "Dark mode"),
]

# Tab bar on every tab screen: (label, target)
TABS = [("HOME", "10-home-top"), ("EVENTS", "30-events-my-meetings"),
        ("SAFETY", "46b-safety-center-with-contact"), ("PROFILE", "40-profile-top")]


def S(id, area, title, links=(), note="", dump=None, tabs=False, extra=()):
    return dict(id=id, area=area, title=title, links=list(links), note=note,
                dump=dump or id, tabs=tabs, extra=list(extra))


SCREENS = [
    # ---------------------------------------------------------------- auth
    S("00-splash", "auth", "Splash", note="Restores a saved session; then Home, or Landing when signed out.",
      extra=[("session found", "10-home-top", (0, 1400, 1080, 1700)), ("no session", "01-landing", (0, 1700, 1080, 2000))]),
    S("01-landing", "auth", "Landing", [("GET STARTED", "02-signup-age", ""), ("ALREADY A MEMBER", "06-signin-method", "")]),
    S("02-signup-age", "auth", "Sign up: age gate", [("I confirm", "02b-signup-age-checked", "")]),
    S("02b-signup-age-checked", "auth", "Sign up: age confirmed", [("CONTINUE", "03-signup-method", "")], dump="02-signup-age"),
    S("03-signup-method", "auth", "Sign up: choose a method",
      [("CONTINUE WITH GOOGLE", "05-profile-setup", "new account; returning → Home"),
       ("CONTINUE WITH LINKEDIN", "05-profile-setup", "new account; returning → Home"),
       ("SIGN UP WITH EMAIL", "04-signup-email", ""), ("CONTINUE AS GUEST", "17-home-guest-L0", "L0, view only")]),
    S("04-signup-email", "auth", "Sign up with email", [("SEND CODE", "04b-signup-email-code", "")]),
    S("04b-signup-email-code", "auth", "Sign up: enter the code", [("VERIFY", "04c-signup-code-entered", "")]),
    S("04c-signup-code-entered", "auth", "Sign up: code entered", [("VERIFY", "05-profile-setup", "")], dump="04b-signup-email-code"),
    S("05-profile-setup", "auth", "Complete your profile", [("CONTINUE", "05b-profile-setup-filled", ""), ("Skip for now", "15-home-L1", "")]),
    S("05b-profile-setup-filled", "auth", "Complete your profile: filled", [("CONTINUE", "40b-profile-new-account-L1", "")], dump="05-profile-setup"),
    S("06-signin-method", "auth", "Sign in", [("I confirm", "06b-signin-method-age-checked", "")]),
    S("06b-signin-method-age-checked", "auth", "Sign in: age confirmed",
      [("CONTINUE WITH GOOGLE", "09-signin-overlay", ""), ("CONTINUE WITH LINKEDIN", "09-signin-overlay", ""),
       ("CONTINUE WITH EMAIL", "07-signin-email", "")], dump="06-signin-method"),
    S("07-signin-email", "auth", "Sign in with email", [("SEND CODE", "07b-signin-email-filled", "")]),
    S("07b-signin-email-filled", "auth", "Sign in: email typed", [("SEND CODE", "08-signin-code", "")], dump="07-signin-email"),
    S("08-signin-code", "auth", "Sign in: enter the code", [("VERIFY", "08b-signin-code-entered", "")]),
    S("08b-signin-code-entered", "auth", "Sign in: code entered", [("VERIFY", "10-home-top", "")], dump="08-signin-code"),
    S("09-signin-overlay", "auth", "Signing you in", note="Shown from the first frame while a provider runs; the page is blurred and takes no taps. Returns to Home (or profile setup for a new account).",
      dump="06-signin-method", extra=[("provider done", "10-home-top", (0, 900, 1080, 1500))]),
    # ---------------------------------------------------------------- home
    S("10-home-top", "home", "Home (L3, hosting)",
      [("Good", "40-profile-top", "avatar"), ("REVIEW", "50-review-page", ""), ("Test L3 Alpha&#10;NETWORKING", "20-meetup-host", "")],
      extra=[("bell", "45b-notifications-list", (760, 130, 900, 300))], tabs=True),
    S("11-home-happening-soon", "home", "Home: Happening Soon",
      [("TB&#10;Test L3 Bravo", "26-meetup-viewer", ""), ("I'M INTERESTED", "27-join-sheet", "L2 or higher"), ("VIEW LOCATION", "21-location-page", ""),
       ("HOST YOUR OWN MEETUP", "60-schedule-1-intent", "L3 or higher")], tabs=True),
    S("11b-home-active-two", "home", "Home: two active meetups", note="After scheduling a second meetup.", dump="11-home-happening-soon", tabs=True),
    S("12-home-bottom", "home", "Home: bottom", [("HOST YOUR OWN MEETUP", "60-schedule-1-intent", "L3 or higher")], tabs=True),
    S("13-home-loading-skeleton", "home", "Home: loading", note="Shimmer while the session and the location are fetched.", dump="10-home-top", tabs=True),
    S("14-home-location-off", "home", "Home: location off", [("OPEN LOCATION SETTINGS", "14-home-location-off", "system settings"), ("TRY AGAIN", "11-home-happening-soon", "")], tabs=True),
    S("14b-home-offline", "home", "Home: offline", note="The rain picture with TRY AGAIN.", dump="14-home-location-off", tabs=True),
    S("15-home-L1", "home", "Home as a new account (L1)", tabs=True, note="Signed up by email, LinkedIn not connected: view only."),
    S("15b-home-L1-cards", "home", "Home (L1): cards", [("I'M INTERESTED", "70-verification-checklist", "below L2"), ("HOST YOUR OWN MEETUP", "67-hosting-unlock", "below L3")], tabs=True),
    S("16-home-L2", "home", "Home as a verified member (L2)", tabs=True),
    S("16b-home-L2-happening-soon", "home", "Home (L2): Happening Soon", [("I'M INTERESTED", "27-join-sheet", ""), ("HOST YOUR OWN MEETUP", "67-hosting-unlock", "below L3")], tabs=True),
    S("16c-home-L2-coffee-filter", "home", "Home: COFFEE tab", dump="16b-home-L2-happening-soon", tabs=True),
    S("16d-home-L2-empty-intent", "home", "Home: empty intent (balcony)", [("HOST YOUR OWN MEETUP", "67-hosting-unlock", "below L3")], dump="16b-home-L2-happening-soon", tabs=True),
    S("17-home-guest-L0", "home", "Home as a guest (L0)", tabs=True),
    S("17b-home-guest-L0-cards", "home", "Home (guest): cards", [("I'M INTERESTED", "70c-verification-checklist-guest", "L0")], tabs=True),
    # -------------------------------------------------------------- meetup
    S("26-meetup-viewer", "meetup", "Meetup page (viewer)", [("Hosted by", "23-public-profile", ""), ("LOCATION", "21-location-page", ""), ("I'M INTERESTED", "27-join-sheet", "L2 or higher")]),
    S("27-join-sheet", "meetup", "Confirm your interest (sheet)", [("CONFIRM YOUR INTEREST", "28-meetup-pending", "no overlap; overlap → conflict"), ("NOT NOW", "26-meetup-viewer", "")]),
    S("27b-conflict-sheet", "meetup", "One meetup at a time (sheet)", [("OPEN THAT MEETUP", "20-meetup-host", ""), ("I'LL WAIT", "26-meetup-viewer", "")]),
    S("28-meetup-pending", "meetup", "Meetup page: request pending", [("LOCATION", "21-location-page", ""), ("CANCEL REQUEST", "29-cancel-request-dialog", "")]),
    S("29-cancel-request-dialog", "meetup", "Take back your request?", [("KEEP IT", "28-meetup-pending", ""), ("CANCEL REQUEST", "26-meetup-viewer", "")]),
    S("28c-meetup-youre-in", "meetup", "Meetup page: you're in", [("TA&#10;TB", "22b-whos-coming-participant", ""), ("LOCATION", "21-location-page", ""), ("WITHDRAW REQUEST", "28g-withdraw-dialog", "")],
      note="Below the fold: the safety gate with I UNDERSTAND.", extra=[("I UNDERSTAND (below)", "28e-meetup-safety-acknowledged", (53, 1539, 1028, 2337))]),
    S("28e-meetup-safety-acknowledged", "meetup", "Meetup page: safety gate done", [("TELL SOMEONE", "28f-tell-someone-sheet", ""), ("WITHDRAW REQUEST", "28g-withdraw-dialog", "")]),
    S("28f-tell-someone-sheet", "meetup", "Tell a trusted contact (sheet)", [("ADD A TRUSTED CONTACT", "48-trusted-contacts-empty", "")]),
    S("28g-withdraw-dialog", "meetup", "Withdraw your request?", [("BACK", "28c-meetup-youre-in", ""), ("WITHDRAW", "26-meetup-viewer", "")]),
    S("25-meetup-not-this-time", "meetup", "Meetup page: not this time", [("LOCATION", "21-location-page", "")]),
    S("25b-meetup-not-this-time-suggestions", "meetup", "Not this time: others nearby", [("SEE ALL NEARBY", "11-home-happening-soon", "")],
      extra=[("suggested meetup", "26-meetup-viewer", (53, 1420, 1028, 1730))]),
    S("20-meetup-host", "meetup", "Meetup page (you host)", [("Hosted by", "23-public-profile", ""), ("TA&#10;TB", "22-whos-coming", ""), ("LOCATION", "21-location-page", ""), ("VIEW REQUESTS", "33-requests-pending", ""), ("CANCEL MEETUP", "24-cancel-meetup-dialog", "")]),
    S("24-cancel-meetup-dialog", "meetup", "Cancel this meetup?", [("BACK", "20-meetup-host", "")]),
    S("21-location-page", "meetup", "Location", [("GET DIRECTIONS", "21-location-page", "opens Google Maps")]),
    S("21b-location-page-galle-face", "meetup", "Location (Galle Face Green)", dump="21-location-page"),
    S("22-whos-coming", "meetup", "Who's coming (host)", [("Test L2 Bravo", "23-public-profile", "")]),
    S("22b-whos-coming-participant", "meetup", "Who's coming (participant)", [("Test L3 Alpha", "23-public-profile", "")]),
    S("23-public-profile", "meetup", "Member profile"),
    S("50-review-page", "meetup", "Share your thoughts", [("Very good", "50b-review-rated", "")]),
    S("50b-review-rated", "meetup", "Review: rating picked", [("SUBMIT", "50c-review-traits", "")]),
    S("50c-review-traits", "meetup", "Review: traits", dump="50b-review-rated"),
    # ---------------------------------------------------------------- host
    S("60-schedule-1-intent", "host", "Schedule 1/5: intent", [("COFFEE", "61-schedule-2-when", "")]),
    S("61-schedule-2-when", "host", "Schedule 2/5: when", [("DATE", "61b-schedule-2-date-picker", ""), ("CONTINUE", "61c-schedule-2-filled", "")]),
    S("61b-schedule-2-date-picker", "host", "Schedule 2/5: date picker", [("OK", "61c-schedule-2-filled", "")]),
    S("61c-schedule-2-filled", "host", "Schedule 2/5: window set", [("CONTINUE", "62-schedule-3-where", "no overlap; overlap → conflict")], dump="61-schedule-2-when"),
    S("65-schedule-time-conflict", "host", "Schedule: one meetup at a time", [("OPEN THAT MEETUP", "20-meetup-host", ""), ("I'LL WAIT", "61c-schedule-2-filled", "")]),
    S("62-schedule-3-where", "host", "Schedule 3/5: where", [("USE MY CURRENT LOCATION", "62b-schedule-3-finding-you", ""), ("CONTINUE", "63-schedule-4-capacity", "")]),
    S("62b-schedule-3-finding-you", "host", "Schedule 3/5: finding you", note="Ring sweeps, label breathes, dots step.", dump="62-schedule-3-where"),
    S("62c-schedule-3-located", "host", "Schedule 3/5: located", [("CONTINUE", "63-schedule-4-capacity", "")]),
    S("62d-schedule-3-search-suggestions", "host", "Schedule 3/5: place search", [("Galle Face Green", "62e-schedule-3-place-picked", "")]),
    S("62e-schedule-3-place-picked", "host", "Schedule 3/5: place picked", [("CONTINUE", "63-schedule-4-capacity", "")]),
    S("63-schedule-4-capacity", "host", "Schedule 4/5: how many", [("CONTINUE", "64-schedule-5-review", "")]),
    S("64-schedule-5-review", "host", "Schedule 5/5: review & confirm", [("CONFIRM", "64b-schedule-confirming", "")]),
    S("64b-schedule-confirming", "host", "Scheduling...", dump="64-schedule-5-review", extra=[("created", "66-after-schedule-meetup-page", (0, 1000, 1080, 1400))]),
    S("66-after-schedule-meetup-page", "host", "Your new meetup", [("LOCATION", "21b-location-page-galle-face", "")], dump="20-meetup-host"),
    S("67-hosting-unlock", "host", "Unlock hosting", [("Unlock joining", "70-verification-checklist", "")]),
    # ---------------------------------------------------------------- tabs
    S("30-events-my-meetings", "tabs", "Events: my meetings", [("Requested Meetings", "32-events-requested", ""), ("History", "31-events-my-history", ""), ("VIEW REQUESTS", "33-requests-pending", ""), ("NETWORKING&#10;L3 Trust", "33-requests-pending", "card")], tabs=True),
    S("31-events-my-history", "tabs", "Events: history", [("Open meetups", "30-events-my-meetings", ""), ("MEAL", "50-review-page", "finished meetup")], tabs=True),
    S("32-events-requested", "tabs", "Events: requested", [("My Meetings", "30-events-my-meetings", ""), ("COFFEE", "25-meetup-not-this-time", "")], tabs=True),
    S("32b-events-requested-empty", "tabs", "Events: no requests", dump="30b-events-empty", tabs=True),
    S("32d-events-requested-youre-in", "tabs", "Events: you're in (L2)", [("NETWORKING&#10;L3 Trust", "28c-meetup-youre-in", "")], tabs=True),
    S("30b-events-empty", "tabs", "Events: nothing yet", [("HOST A MEETUP", "67-hosting-unlock", "below L3")], tabs=True),
    S("30c-events-loading", "tabs", "Events: loading", dump="30-events-my-meetings", tabs=True),
    S("30d-events-offline", "tabs", "Events: offline", [("TRY AGAIN", "30-events-my-meetings", "")], tabs=True),
    S("30e-events-guest", "tabs", "Events as a guest", dump="30b-events-empty", tabs=True),
    S("33-requests-pending", "tabs", "Requests: pending", [("ACCEPTED", "33b-requests-accepted-empty", ""), ("REJECTED", "33c-requests-rejected-empty", ""), ("CANCEL MEETUP", "24-cancel-meetup-dialog", "")],
      extra=[("requester", "23-public-profile", (53, 860, 1028, 1110)), ("ACCEPT", "33b-requests-accepted-empty", (88, 1140, 528, 1240)), ("REJECT", "33c-requests-rejected-empty", (560, 1140, 990, 1240))]),
    S("33b-requests-accepted-empty", "tabs", "Requests: accepted", [("PENDING", "33-requests-pending", ""), ("REJECTED", "33c-requests-rejected-empty", "")], dump="33b-requests-accepted"),
    S("33c-requests-rejected-empty", "tabs", "Requests: rejected", [("PENDING", "33-requests-pending", ""), ("ACCEPTED", "33b-requests-accepted-empty", "")]),
    S("46-safety-center", "tabs", "Safety Center", [("Add a contact", "48-trusted-contacts-empty", ""), ("TRIGGER SOS", "48-trusted-contacts-empty", "no contacts yet")], dump="46b-safety-center-with-contact", tabs=True),
    S("46b-safety-center-with-contact", "tabs", "Safety Center (with a contact)", [("Nadia", "48b-trusted-contacts-one", ""), ("TRIGGER SOS", "47-sos-dialog", "L2 or higher")], tabs=True),
    S("46c-safety-L1-locked", "tabs", "Safety Center (L1)", extra=[("UNLOCK SAFETY FEATURES", "70-verification-checklist", (53, 1940, 1028, 2090))], tabs=True),
    S("46d-safety-guest", "tabs", "Safety Center (guest)", extra=[("UNLOCK SAFETY FEATURES", "70c-verification-checklist-guest", (53, 1940, 1028, 2090))], tabs=True),
    S("47-sos-dialog", "tabs", "Emergency SOS", [("CANCEL", "46b-safety-center-with-contact", ""), ("CONFIRM", "46b-safety-center-with-contact", "shares live location"), ("CALL EMERGENCY SERVICES", "47-sos-dialog", "dialer")]),
    S("48-trusted-contacts-empty", "tabs", "Trusted contacts: empty", [("ADD CONTACT", "49-add-contact-form", "")], dump="48b-trusted-contacts-one"),
    S("48b-trusted-contacts-one", "tabs", "Trusted contacts", [("ADD CONTACT", "49-add-contact-form", "")]),
    S("49-add-contact-form", "tabs", "Add a contact", [("SAVE", "49b-add-contact-filled", ""), ("CANCEL", "48b-trusted-contacts-one", "")]),
    S("49b-add-contact-filled", "tabs", "Add a contact: filled", [("SAVE", "48b-trusted-contacts-one", "")], dump="49-add-contact-form"),
    S("40-profile-top", "tabs", "Profile (L3)", [("Phone", "71-verify-phone", ""), ("Personal Email", "72-verify-personal-email", ""), ("Personal Details", "73-personal-details", ""), ("Work Email", "74-work-email", "")], tabs=True),
    S("41-profile-preferences", "tabs", "Profile: preferences", [("Premium", "43-premium-plans", ""), ("Privacy Controls", "44-privacy-controls", ""), ("Notifications", "45b-notifications-list", ""), ("Safety Center", "46b-safety-center-with-contact", ""), ("SIGN OUT", "42-profile-sign-out-dialog", "")], tabs=True),
    S("42-profile-sign-out-dialog", "tabs", "Sign out?", [("CANCEL", "41-profile-preferences", "")], extra=[("SIGN OUT (confirm)", "01-landing", (614, 1275, 845, 1401))]),
    S("40b-profile-new-account-L1", "tabs", "Profile (new account, L1)", extra=[("CONNECT LINKEDIN", "40b-profile-new-account-L1", (100, 1450, 980, 1560))], dump="40-profile-top", tabs=True),
    S("40c-profile-L2", "tabs", "Profile (L2)", [("Phone", "71-verify-phone", ""), ("Personal Email", "72-verify-personal-email", ""), ("Personal Details", "73-personal-details", ""), ("Work Email", "74-work-email", "")], tabs=True),
    S("40d-profile-guest-L0", "tabs", "Profile (guest)", [("CONNECT LINKEDIN", "40d-profile-guest-L0", "LinkedIn OAuth")], tabs=True),
    S("43-premium-plans", "tabs", "Premium plans", [("START 7 DAYS FREE TRIAL", "43-premium-plans", "coming soon toast")]),
    S("44-privacy-controls", "tabs", "Privacy controls"),
    S("45-notifications-empty", "tabs", "Notifications: all quiet", dump="45b-notifications-list"),
    S("45b-notifications-list", "tabs", "Notifications", [("New join request", "33-requests-pending", ""), ("Not this time", "25-meetup-not-this-time", ""), ("Meetup starting soon", "20-meetup-host", "")]),
    S("45c-notifications-offline", "tabs", "Notifications: offline", [("TRY AGAIN", "45b-notifications-list", "")], dump="30d-events-offline"),
    # -------------------------------------------------------------- verify
    S("70-verification-checklist", "verify", "Unlock joining meetups (L1)", [("CONNECT LINKEDIN", "70-verification-checklist", "LinkedIn OAuth")]),
    S("70b-verification-checklist-steps", "verify", "Checklist: remaining steps", dump="70-verification-checklist"),
    S("70c-verification-checklist-guest", "verify", "Unlock joining meetups (guest)", [("CONNECT LINKEDIN", "70c-verification-checklist-guest", "LinkedIn OAuth")]),
    S("71-verify-phone", "verify", "Verify your phone", [("SEND CODE", "71-verify-phone", ""), ("Skip for now", "40c-profile-L2", "")]),
    S("72-verify-personal-email", "verify", "Verify your email", [("SEND CODE", "72-verify-personal-email", ""), ("Skip for now", "40c-profile-L2", "")]),
    S("73-personal-details", "verify", "Personal details", [("CONTINUE", "40c-profile-L2", ""), ("Skip for now", "40c-profile-L2", "")]),
    S("74-work-email", "verify", "Verify your work email", [("SEND CODE", "74-work-email", ""), ("Skip for now", "40c-profile-L2", "")]),
    # ---------------------------------------------------------------- dark
    S("90-dark-profile", "dark", "Profile (dark)", dump="40d-profile-guest-L0", tabs=True),
    S("91-dark-home", "dark", "Home (dark)", dump="17-home-guest-L0", tabs=True),
    S("92-dark-home-cards", "dark", "Home cards (dark)", dump="17b-home-guest-L0-cards", tabs=True),
    S("93-dark-meetup-page", "dark", "Meetup page (dark)", dump="26-meetup-viewer"),
    S("94-dark-events", "dark", "Events (dark)", dump="30b-events-empty", tabs=True),
    S("95-dark-safety", "dark", "Safety (dark)", dump="46d-safety-guest", tabs=True),
]

BY_ID = {s["id"]: s for s in SCREENS}

_node = re.compile(r'<node [^>]*?content-desc="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')


def dump_nodes(screen_id):
    path = os.path.join(HERE, "dumps", screen_id + ".xml")
    if not os.path.exists(path):
        return []
    out = []
    for m in _node.finditer(open(path).read()):
        desc, x1, y1, x2, y2 = m.group(1), *map(int, m.groups()[1:])
        if desc and x2 > x1 and y2 > y1:
            out.append((desc, (x1, y1, x2, y2)))
    return out


def find_bounds(nodes, label):
    """Smallest node whose label contains `label` (labels are HTML-escaped
    in the dump; links use the same escaping, e.g. &#10; for a newline)."""
    best = None
    for desc, b in nodes:
        if label in desc:
            area = (b[2] - b[0]) * (b[3] - b[1])
            if best is None or area < best[0]:
                best = (area, b)
    return best[1] if best else None


def hotspots(screen):
    nodes = dump_nodes(screen["dump"])
    spots = []
    for label, target, gate in screen["links"]:
        b = find_bounds(nodes, label)
        if b is None:
            spots.append(dict(label=label.replace("&#10;", " / "), target=target, gate=gate, rect=None))
        else:
            spots.append(dict(label=label.replace("&#10;", " / "), target=target, gate=gate, rect=b))
    for label, target, rect in screen["extra"]:
        spots.append(dict(label=label, target=target, gate="", rect=rect))
    if screen["tabs"]:
        for label, target in TABS:
            b = find_bounds(nodes, 'content-desc="' + label) or find_bounds(nodes, label)
            # the tab bar is fixed: fall back to its known geometry
            if b is None or b[3] < 2100:
                i = [t[0] for t in TABS].index(label)
                b = (16 + i * 262, 2216, 278 + i * 262, 2311)
            spots.append(dict(label=label + " tab", target=target, gate="", rect=b))
    return spots


if __name__ == "__main__":
    missing = []
    for s in SCREENS:
        assert os.path.exists(os.path.join(HERE, "shots", s["id"] + ".png")), s["id"]
        for h in hotspots(s):
            assert h["target"] in BY_ID, (s["id"], h["target"])
            if h["rect"] is None:
                missing.append((s["id"], h["label"]))
    print(len(SCREENS), "screens;", sum(len(hotspots(s)) for s in SCREENS), "hotspots; unresolved:", missing)
