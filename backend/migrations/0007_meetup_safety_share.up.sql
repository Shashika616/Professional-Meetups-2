-- "Let a trusted contact know where I am" — the real feature behind what was
-- previously a switch that did nothing.
--
-- WHAT WAS THERE BEFORE. meetup.safety_state.live_location_opt_in was a
-- boolean the UI toggled and NOTHING read. No recipient, no message, no
-- link: the app told the user it was sharing their location and then shared
-- it with nobody. That is worse than not offering it, because a user may
-- rely on it.
--
-- WHAT THIS RECORDS. Which of the caller's own trusted contacts were told
-- about which meetup, and when. One row per (meetup, sharer, contact).
--
-- WHY IT IS PERSISTED AT ALL, rather than fire-and-forget like an SMS OTP:
--   * the user must be able to reopen the meetup and SEE who already knows,
--     which is the whole point of a safety affordance — an action you cannot
--     confirm afterwards is one you cannot trust;
--   * re-sharing with the same contact should not silently re-text them, and
--     the primary key is what makes that a no-op rather than a duplicate.
--
-- Deliberately NOT storing the message body or the contact's phone/email:
-- those live in auth's trusted_contacts, this module does not own them, and
-- copying them here would duplicate PII across a schema boundary for no
-- reason (ADR-001 §3). A contact_id is enough to render "shared with Amma".
CREATE TABLE meetup.safety_share (
    meetup_id   UUID NOT NULL REFERENCES meetup.meetups(id) ON DELETE CASCADE,
    -- deliberately no FK, same as safety_state above: auth.users belongs to
    -- another module's schema (see this file's header).
    user_id     UUID NOT NULL,
    -- Likewise a bare id: auth.trusted_contacts is not this module's table.
    -- A contact deleted after the fact leaves this row pointing at nothing,
    -- which is correct — it is a record that a notification WAS sent, not a
    -- live reference.
    contact_id  UUID NOT NULL,
    notified_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (meetup_id, user_id, contact_id)
);

-- The read is always "everyone this user told about this meetup", which the
-- primary key's leading columns already serve. No extra index.
