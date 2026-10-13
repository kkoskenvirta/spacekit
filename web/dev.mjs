// Local preview with a pretend Stripe: `npm run dev`, then open http://localhost:3000.
// /buy skips the payment and lands on /thanks as a paid purchase, serving the newest installer from
// ../build. Never deployed: the Dockerfile runs server.mjs.

import { createServer } from "node:http";
import { fileURLToPath } from "node:url";

import { createHandler, loadConfig } from "./server.mjs";

const PAID = "cs_test_localPreviewPaidSession000";
const port = Number(process.env.PORT) || 3000;
const { config } = loadConfig({
  BUSINESS_ID: "1234567-8 (example)",
  BUSINESS_ADDRESS: "Example Street 1, 00100 Helsinki, Finland",
  SUPPORT_EMAIL: "support@example.com",
  ...process.env,
  STRIPE_SECRET_KEY: "rk_test_local",
  STRIPE_PAYMENT_LINK_URL: `http://localhost:${port}/thanks?session_id=${PAID}`,
  STRIPE_PAYMENT_LINK_ID: "plink_local",
  DOWNLOAD_SECRET: "local-preview-secret-local-preview-secret",
  DOWNLOADS_DIR: process.env.DOWNLOADS_DIR || fileURLToPath(new URL("../build/", import.meta.url)),
});

async function fakeStripe(url) {
  const id = url.split("/").pop();
  if (id !== PAID) return new Response("{}", { status: 404 });
  const session = { id, status: "complete", payment_status: "paid", payment_link: "plink_local", customer_details: { email: "you@example.com" } };
  return new Response(JSON.stringify(session), { status: 200 });
}

createServer(createHandler(config, { fetch: fakeStripe })).listen(port, () => {
  console.log(`SpaceKit site (local preview, fake payments) on http://localhost:${port}`);
});
