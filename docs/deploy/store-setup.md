# Store setup checklist (plan 29B)

Everything in the App Store and Play consoles and Google Cloud that the server
needs before real purchases work. Only the account owner can do these steps
(plan 29 §9). Until each one is done, the matching purchases answer 503 and
nothing is granted: the server never falls back to trusting the app.

Console menus move around; the names below were right when this was written.
Check the current Apple and Google documentation if a step does not match.

Throughout, `<gateway>` is the public gateway host (the Cloud Run gateway
service URL, or the custom domain in front of it).

## The products

Use these product ids on **both** stores. The server's catalog
(`billing.store_products`, migration 0029) uses the same ids, and the app shows
whatever the catalog lists, so a product missing from a store is simply skipped.

| Product id | Type | Grants | Notes |
|---|---|---|---|
| `credits_50` | Consumable | 750 credits | |
| `credits_120` | Consumable | 1800 credits (1500 + 300 bonus) | |
| `credits_300` | Consumable | 4500 credits (3375 + 1125 bonus) | |
| `premium_monthly` | Auto-renewable subscription | Pro, monthly | 10 meetups a month, 30 people, 30 days ahead |
| `premium_yearly` | Auto-renewable subscription | Pro, yearly | Same plan; the 10 meetups reset every month |

Prices are set in the stores only. The server never stores or sends a price.
`premium_weekly` (in the current app) is dropped (D5): do not submit it, and
remove it from sale if it exists.

Purchased credits never expire (App Review Guideline 3.1.1). Keep it that way.

## Apple: App Store Connect

1. **In-app purchases.** In the app's *Monetization > In-App Purchases*,
   create the three consumables above, with a display name, description and
   price for each.
2. **Subscriptions.** In *Monetization > Subscriptions*, create one
   subscription group (for example "TieHere Pro") with `premium_monthly` and
   `premium_yearly` in it. Set the price, the duration, and a grace period
   ("Billing Grace Period", recommended: the server honours it).
3. **Submit them with the first release that contains the credits UI (29C).**
   A first in-app purchase or subscription can only be reviewed together with
   an app version. Submit the subscriptions then too, even though they are
   hidden, so they can be shown later without another app review (plan 29 §6).
4. **App Store Server API key.** In *Users and Access > Integrations >
   In-App Purchase*, generate a key. You need three things from that page:
   - the **Issuer ID** at the top of the page, which goes in `APPLE_APP_STORE_ISSUER_ID`;
   - the **Key ID**, which goes in `APPLE_APP_STORE_KEY_ID`;
   - the **`.p8` file**. It can be downloaded only once. Put its full text in
     the Secret Manager secret `apple-app-store-private-key`, which feeds
     `APPLE_APP_STORE_PRIVATE_KEY`. Keep a copy in the password manager.
5. **Server Notifications.** In the app's *App Information > App Store Server
   Notifications*, set **Version 2** for both URLs:
   - Production: `https://<gateway>/v1/billing/webhooks/apple`
   - Sandbox: the same URL (sandbox notifications are only acted on for
     purchases the server already accepted).

   Use *Request a Test Notification*. The server records it as `test` in
   `billing.processed_store_notifications`.
6. **Sandbox testers.** In *Users and Access > Sandbox > Test Accounts*, add a
   tester for each person who will test purchases. In production, sandbox
   purchases are accepted only from TieHere accounts on the
   `billing.plans.visible` allowlist (the seeded `@meetups.test` users).
   Off Cloud Run they are accepted from anyone.

The bundle id the server checks defaults to
`com.profconn.professionalConnectionsPlatform`. If it ever changes, set
`APPLE_BUNDLE_ID`.

### Review notes for the hidden plans

App Review asks that apps contain no hidden features (Guideline 2.3.1), so say
plainly that the subscriptions are switched on from the server. Check the
current wording of Guidelines 2.3.1 and 3.1.2 at submission time. Suggested
text for *App Review Information > Notes*:

> TieHere sells credit packs (consumables) that hosts spend to create meetups.
> It also has a Pro subscription (premium_monthly, premium_yearly), submitted
> with this version. The subscription screen is turned on from our server and
> is currently shown only to test accounts while we prepare the launch; it
> will be turned on for everyone without an app update. To review it, sign in
> with the demo account below, which has the subscription screen turned on:
> open Profile > Premium. Purchases are verified on our server with the App
> Store Server API; credits bought in the app never expire.
>
> Demo account: <a seeded @meetups.test account on the allowlist, and how to
> sign in with it>

Give App Review an account on the allowlist (one of the seeded test accounts,
`TESTING-NOTES.md`). The test accounts and the OTP bypass stay exactly as they
are.

## Google: Play Console and Google Cloud

1. **One-time products.** In *Monetize > Products > In-app products*, create
   `credits_50`, `credits_120` and `credits_300` as consumable one-time
   products, with prices, and activate them.
2. **Subscriptions.** In *Monetize > Products > Subscriptions*, create
   `premium_monthly` and `premium_yearly`, each with an auto-renewing base plan
   (monthly and yearly) and its price. Turn on a grace period. The server reads
   the extended expiry Google reports during grace.
3. **Android Publisher API service account.**
   - In the Google Cloud project, enable the **Google Play Android Developer
     API**.
   - Create a service account (for example `play-verifier`) and a JSON key for
     it.
   - Put the key file's full contents in the Secret Manager secret
     `google-play-service-account`, which feeds
     `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`.
   - In Play Console *Users and permissions*, invite the service account's
     email with app access to TieHere and these permissions: *View financial
     data, orders and cancellation survey responses* and *Manage orders and
     subscriptions*. Access can take up to a day to take effect.
4. **Real-time developer notifications (RTDN).**
   - In Google Cloud Pub/Sub, create a topic (for example `play-rtdn`).
   - Grant `google-play-developer-notifications@system.gserviceaccount.com`
     the **Pub/Sub Publisher** role on the topic.
   - Create a **push** subscription on the topic:
     - endpoint `https://<gateway>/v1/billing/webhooks/google`;
     - authentication enabled, with a service account you create for it
       (for example `rtdn-push`);
     - audience set to the endpoint URL.
   - Set two plain env values on the monolith:
     - `GOOGLE_PUBSUB_PUSH_AUDIENCE` to exactly the audience;
     - `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT` to the push service account's email.
   - Without the audience, the webhook answers 503 and Pub/Sub keeps retrying.
   - In Play Console *Monetize > Monetization setup*, enter the topic name
     (`projects/<project>/topics/play-rtdn`) under *Real-time developer
     notifications*. Press *Send test notification*; the server records it as
     `test`.
5. **License testers.** In Play Console *Settings > License testing*, add the
   testers' Google accounts. Their purchases are test purchases, and the same
   sandbox rule as Apple's applies.

The server consumes credit packs and acknowledges subscriptions itself. Google
refunds a purchase that is not acknowledged within three days, so watch for
dead-lettered `store.finish` rows (runbook §13).

The package name the server checks defaults to
`com.profconn.professional_connections_platform`. If it ever changes, set
`GOOGLE_PLAY_PACKAGE_NAME`.

## Legal links

Subscription screens must show the terms and the privacy policy (Guideline
3.1.2). Publish both pages, then set `BILLING_TERMS_URL` and
`BILLING_PRIVACY_URL`; both must be https. The catalog carries them to the
app. Get both reviewed (plan 29 §6).

## Checking it works

Do these once each, with a tester account that is on the allowlist:

- [ ] iOS: buy `credits_50` in the sandbox. Verify answers 200, the wallet
      shows +50, and `billing.store_purchases` has one row with
      `environment = 'sandbox'`.
- [ ] iOS: subscribe to `premium_monthly`. `GET /v1/billing/subscription`
      shows `entitled: true`. The sandbox renews within minutes, and each
      renewal arrives as a `DID_RENEW` row in
      `billing.processed_store_notifications`.
- [ ] Android: buy `credits_50` as a license tester. Within seconds the row
      has `finished_at` set and no `pending_finish_token`, and the Play
      Console order shows as consumed.
- [ ] Android: subscribe, then cancel in the Play Store. An RTDN arrives and
      `auto_renew` turns false.
- [ ] Refund a sandbox credit pack (Apple: the sandbox refund tool; Google:
      refund the order in the Play Console). The pack's unspent credits are
      removed, and any part already spent shows as `debt`.
- [ ] Sign in as an ordinary (not allowlisted) account. The catalog has
      `plans_visible: false`, and a sandbox purchase from it is refused.
