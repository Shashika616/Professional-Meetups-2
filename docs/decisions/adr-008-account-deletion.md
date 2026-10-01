# ADR-008 - Account Deletion

## Status

Accepted (2026-09-28). Code complete; migrations 0014-0016 not yet applied
to production.

## Context

The App Store (guideline 5.1.1(v)) and Google Play both require an app that
creates accounts to let people delete them from inside the app. The
deletion has to remove the account's data, not just hide it, and anything
kept afterwards has to be for a reason the store accepts (a legal, safety or
fraud reason) and disclosed in the privacy policy.

Three things make this less than a `DELETE FROM users`:

1. **Other people depend on some of the rows.** A meetup someone is hosting
   tomorrow has attendees. A rating someone wrote about another member is
   part of that other member's record.
2. **The data is split across two modules** (auth and meetup) that must not
   reach into each other's tables (ADR-001 §3), and that may one day be
   separate services with separate databases.
3. **SOS alerts are a safety record.** If someone sends an SOS and then
   deletes their account, the record of that alert may matter to the people
   who were alerted, or to an investigation, for a while afterwards.

## Decision

### Who can delete, and when

`DELETE /v1/users/me` deletes the caller's own account. The user id comes
from the verified token only; there is no way to name another account.

Deletion is **refused (409)** while the account has anything that has not
happened yet:

- a meetup they are hosting that is open or full and whose window has not
  ended;
- an accepted place in someone else's meetup like that;
- a pending request to join one.

The 409 carries a sentence for the person saying which of these applies and
what to do (attend it, cancel it, or withdraw), and the app shows it as it
is. The check lives in the meetup service (`CheckAccountDeletable`), the
delete in the auth service (`DeleteAccount`); the gateway calls one and
then the other. Neither service calls the other.

### What is deleted, what is kept

| Data | What happens |
|---|---|
| Profile, verifications, identities, refresh tokens, verification codes, company claims | Deleted with the account row (auth module, one transaction) |
| Trusted contacts | Deleted. They are the account's own list; the contacts themselves are often not users and have nothing else in the system |
| Join requests, safety check-ins, safety shares, feedback, device tokens, notifications, the display/location/subscription caches | Deleted (meetup module) |
| Ratings they gave, ratings about them | **Kept, anonymised.** The account's id in each row is replaced with a fresh random id per row, so the rows cannot be joined back to the account or to each other. Other members' averages stay correct |
| Meetups they hosted in the past | **Kept, anonymised** the same way, so attendees' history still shows the meetup happened |
| SOS alerts | **Held for 90 days** in `auth.safety_holds` (name, legal name, phone, personal email, and the alerts), then deleted by the hourly sweeper. Only created if the account ever sent an SOS |

Anonymised rows use a new id per row, not one replacement id per account:
one id per account would still link every rating that account wrote, which
is pseudonymisation, not anonymisation. Database backups still contain the
original rows until they age out; the privacy policy states an upper bound
of 30 days, so check the Supabase plan's backup retention stays within it.

### How the two modules stay independent

The auth module deletes the account and, **in the same transaction**,
writes a row to `auth.user_deleted_outbox`. A poller (the generic
`internal/platform/outbox`) delivers it to the meetup module's
`HandleUserDeleted`, which cancels any live meetup the account still hosts
(the gateway check makes that rare; it covers a meetup created in the
moment between check and delete) and then purges and anonymises in one
transaction under the account's schedule lock.

- **Atomic:** the account and its outbox row commit together, so a crash
  can never delete an account without its cleanup being scheduled.
- **Idempotent:** every step is a delete or an update keyed by user id, so
  running the cleanup twice finds nothing the second time. Deleting an
  account that is already gone returns success.
- **No table locks:** every statement is a row-level delete or update on an
  indexed column (0014 adds the indexes that were missing). Nothing locks a
  table, and nothing takes more than the one user's rows.
- **Retried, then dead-lettered:** a failed cleanup is retried with backoff
  and, after repeated failures, kept with its error for someone to look at
  rather than dropped.

Guest accounts removed by the abandoned-guest sweeper go through the same
outbox, so their meetup-side rows are cleaned up the same way.

There are no foreign keys between modules. If the modules become services,
the outbox row becomes a message on a queue and nothing else changes.

### Migrations

| Migration | Adds |
|---|---|
| `0014_account_deletion_indexes` | Indexes on the six user-id columns the purge touches that had none (including `meetup_user_ratings.rater_user_id`, which only existed as the second column of a composite unique and so could not be seeked on) |
| `0015_user_deleted_outbox` | `auth.user_deleted_outbox` and its claim, retention and dead-letter indexes |
| `0016_safety_holds` | `auth.safety_holds` and its purge index |

All three are additive. 0014 uses plain `CREATE INDEX` (golang-migrate runs
each file in a transaction, which `CONCURRENTLY` cannot run in); the tables
are small enough today that the brief lock is not noticeable.

## Why not the alternatives

- **Soft delete (a `deleted_at` flag).** Keeps everything, which is exactly
  what the stores and data-protection law ask us not to do, and every query
  in both modules would need to remember the flag.
- **Delete ratings too.** Would silently change other members' averages and
  erase their record of how a meetup went.
- **Cascade across modules with foreign keys.** Ties the two modules to one
  database for good (ADR-001 §3), and a cascade of that size is exactly the
  long, lock-heavy transaction we want to avoid.
- **Keep everything for a fixed period "just in case".** Neither store
  accepts that without a specific reason; SOS is the one place a specific
  safety reason exists, so it is the one place anything is held.

## Legal basis

Sri Lanka's Personal Data Protection Act No. 9 of 2022, Parts I to III, is
not yet in force (the 2025 operative date was repealed and no new date has
been appointed), so today the binding requirements are the stores' rules.
The design follows the GDPR standard anyway, since that is what the stores
and most users expect: erasure on request (Art. 17), with the SOS hold
justified as protecting someone's vital interests and establishing or
defending legal claims (Art. 17(3)(e)), limited to 90 days, and disclosed.

## Privacy policy wording (draft for review)

> **Deleting your account.** You can delete your TieHere account at any
> time from Profile, then Delete account. If you are hosting or joining a
> meetup that has not happened yet, or have a request to join one waiting,
> the app will ask you to attend, cancel or withdraw first.
>
> When you delete your account we delete your profile, your verification
> details, your trusted contacts, your meetup requests and history, your
> notifications and your device registrations, straight away.
>
> **What we keep.** Ratings you gave or received, and past meetups you
> hosted, stay so that other members' records remain accurate, but we
> remove everything that links them to you: they cannot be traced back to
> you or to each other.
>
> If you ever sent an SOS alert, we keep a private record of those alerts
> and the contact details on your account for 90 days after deletion, in
> case it is needed to help the people you alerted or for a safety
> investigation. It is then deleted automatically.
>
> Copies of deleted data can remain in our encrypted database backups for
> up to 30 days before they are overwritten.
>
> **Subscriptions.** Premium is billed by the App Store or Google Play.
> Deleting your account does not cancel it; cancel it in your store
> account to stop future charges.
