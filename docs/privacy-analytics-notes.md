# Privacy notes: usage analytics (plan 29D)

Input for the privacy policy update that has to ship with analytics (decision D8;
Sri Lanka Personal Data Protection Act No. 9 of 2022). These are facts about what the
system does, for whoever writes the policy text. They are not policy wording.

## What is collected

- **How the app is used:** which screens are opened and for how long; which listed
  buttons are tapped; when a multi-step task (for example scheduling a meetup or buying
  credits) is started, completed or abandoned, and at which step; errors and
  slow-downs shown in the app; app opens and sessions.
- **Coarse device context:** app version, operating system name and version, phone or
  tablet, language setting.
- **Server-side facts about the account's activity:** a meetup was created, a join
  request was made or accepted, a meetup was completed, credits were granted, spent,
  refunded, expired or taken back, a purchase was verified (store, type, product), and
  a subscription changed status.

## What is never collected

Names, email addresses, phone numbers, free text of any kind (messages, meetup titles
or descriptions, search terms), exact locations or coordinates, IP addresses (used
only for rate limiting and never stored), store receipts or purchase tokens, device
advertising or hardware identifiers (IDFA, Android ID), and contacts.

This is enforced by the server, not only by the app. Every event must match a fixed
list. Anything not on it is dropped. Text fields accept only short lowercase codes,
so a sentence or a name cannot be stored.

## Identifiers

- **Install id:** a random value created by the app on first launch. It identifies
  the installation, not the person or the phone, and is reset by reinstalling.
- **Session id:** random, renewed after 30 minutes in the background.
- **Account key:** for signed-in use, a keyed hash (HMAC-SHA256) of the account id
  under a secret held in Google Secret Manager. The raw account id is never stored
  with analytics. The key is pseudonymous rather than anonymous: someone holding the
  secret could link it back to the account. Only the operator holds it.

## Retention

- Raw events: 14 days in the database, then archived to the project's Cloud Storage
  bucket and removed from the database.
- Daily totals (counts per screen, button, step, error and credit event): kept. They
  hold no account key.
- Per account key, for active-user counts and cohorts: the day it was first seen
  (kept) and the days it was active (kept 120 days). Both are deleted with the
  account and when the user opts out.
- The daily report (emailed to the team, stored in the project's bucket) holds
  aggregates only. A group of fewer than 5 accounts is shown as "fewer than 5", never
  as a number.
- Set an archive lifetime on the bucket (a lifecycle rule) and state it in the policy.
  None is set by this plan.

## Choices and rights

- **Opt-out:** a switch in Privacy Controls ("Share usage analytics"), on by default
  (D8; in the app since 29E). When switched off, the app sends nothing. The server
  also refuses anything still carrying the account's key, and deletes what it already
  holds for the account.
- **Account deletion:** deleting the account deletes its analytics events, its
  cohort row and its active-day rows. Events archived to Cloud Storage before the deletion are keyed only by
  the pseudonymous account key. Say how archives are handled, or shorten the archive
  lifetime so it bounds them.
- **Kill switch:** the `analytics.enabled` flag stops all collection at once, without
  a release.

## Processors

Data stays in the existing processors: Supabase (database) and Google Cloud (Cloud
Run, Cloud Storage, Secret Manager). No analytics SDK or third-party analytics
service is used. A future OpenTelemetry Collector pointed at Elasticsearch or Grafana
would be a new processor, and the policy must be updated before one is connected.
