# SpaceKit website

The marketing page, the $5 checkout (Stripe) and the paid download, served by one small Node server with
no dependencies.

```
public/          index.html (marketing page), thanks.html (download page), styles.css, main.js
server.mjs       static files, /buy → Stripe, /api/claim (checks the payment), /download/<token>
dev.mjs          local preview with pretend payments
test/            npm test
Dockerfile       what Coolify runs
```

## How a purchase works

1. **Buy** links go to `/buy`, which redirects to your Stripe Payment Link.
2. The customer pays on Stripe's checkout page. Stripe emails the receipt.
3. Stripe redirects to `/thanks?session_id=cs_…`. That page calls `/api/claim`, which looks the
   Checkout Session up in Stripe's API. Only a **complete, paid** session from **your SpaceKit Payment
   Link** gets through.
4. The page shows a **Download** button with a signed link that works for an hour. Revisiting the page
   (it's bookmarkable) issues a fresh link. The link serves the newest `.pkg` in the downloads volume.

Nothing is stored: the Stripe session id is the proof of purchase.

## Try it locally

```sh
cd web
npm run dev        # http://localhost:3000. "Buy" skips payment and serves ../build/SpaceKit-*.pkg
npm test
```

Build an installer first (`make installer` in the repo root) so there's something to download.

## Stripe setup (once)

1. **Public details** (Settings → Business → Public details). Stripe shows these on checkout pages,
   receipts and card statements:
   - Business name: *AppRise Ventures Oy*. Website: your domain (Coolify's generated URL until you have it).
   - Support email: the same address as `SUPPORT_EMAIL`.
   - Terms of service: `https://<your-domain>/terms`. Privacy policy: `https://<your-domain>/privacy`.
   - Statement descriptor: `SPACEKIT`, so buyers recognise the charge.
2. **Product** (Product catalog → Add product): *SpaceKit for Mac*, one-time price **$5.00 USD**, under *More pricing options* set *Include tax in price* to **Yes** (the
   site advertises $5 with taxes included, as EU consumer law expects). Tax
   code: *Downloadable software, personal use*.
3. **Tax.** Stripe isn't a merchant of record, so VAT on sales to consumers is yours to collect and report.
   In Settings → Tax, set your origin address and add your registrations; for EU consumers that's
   usually the VAT OSS scheme. Ask your accountant if unsure.
4. **Payment Link** (Payment Links → New), with the product:
   - Turn off *Let customers adjust quantity*.
   - Turn on *Collect tax automatically*.
   - Turn on *Require customers to accept your terms of service* (it links the Terms URL from step 1).
   - **After payment:** *Don't show confirmation page*, redirect to
     `https://<your-domain>/thanks?session_id={CHECKOUT_SESSION_ID}`. Type `{CHECKOUT_SESSION_ID}`
     exactly like that: Stripe fills it in.
   - Copy the link's URL (`https://buy.stripe.com/…`) and its id (`plink_…`, in the dashboard address
     when the link is open).
5. **Receipts** (Settings → Customer emails): turn on *Successful payments* and *Refunds*.
6. **API key** (Developers → API keys → Create restricted key): name it *spacekit-website* and give it
   only **Checkout Sessions: Read**. Paste it straight into Coolify; it doesn't belong anywhere else.

To test without real money, do steps 2, 4 and 6 again in test mode, put the test values in Coolify, and
pay with card `4242 4242 4242 4242`, any future date and any CVC.

## Deploy on Coolify

1. **New resource → Application**, from the GitHub repository `kkoskenvirta/spacekit`, branch `main`.
   - Build pack: **Dockerfile**. Base directory: **`/web`**. Port: **3000**.
2. **Environment variables:** everything in [`.env.example`](.env.example). Generate `DOWNLOAD_SECRET`
   with `openssl rand -hex 32`.
3. **Persistent storage:** add a volume mounted at **`/data`**. Note its name: on the server, its files
   are in `/var/lib/docker/volumes/<name>/_data`.
4. **Domain:** until you have one, Coolify's generated URL works for testing. Once you buy it, point its
   DNS (an `A` record) at the server, put `https://<your-domain>` under the app's *Domains* in Coolify
   (it gets the TLS certificate), and update the Payment Link's redirect URL to match.
5. Deploy, then upload the installer from your Mac:

   ```sh
   DEPLOY_TARGET=root@<server>:/var/lib/docker/volumes/<name>/_data/downloads scripts/publish-installer.sh
   ```

6. Check `https://<your-domain>/healthz`. It should say `{"ok":true,"installer":"SpaceKit-<version>.pkg"}`.
   The deploy logs warn about any missing environment variables.

Pushing to `main` redeploys the site if you enable Coolify's auto-deploy. The installer lives on the
volume, so it survives redeploys.
