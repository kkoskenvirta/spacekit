// node --test web/test
import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";

import { compareVersions, createHandler, installerVersion, loadConfig } from "../server.mjs";

const PAID = "cs_test_a1PaidSession0000000000";
const UNPAID = "cs_test_a1OpenSession0000000000";
const PENDING = "cs_test_a1PendingSession000000";
const OTHER_LINK = "cs_test_a1OtherLink00000000000";
const MISSING = "cs_test_a1Missing0000000000000";

const sessions = {
  [PAID]: { status: "complete", payment_status: "paid", payment_link: "plink_spacekit", customer_details: { email: "buyer@example.com" } },
  [UNPAID]: { status: "open", payment_status: "unpaid", payment_link: "plink_spacekit" },
  [PENDING]: { status: "complete", payment_status: "unpaid", payment_link: "plink_spacekit" },
  [OTHER_LINK]: { status: "complete", payment_status: "paid", payment_link: "plink_other" },
};

let base;
let server;
let stripeCalls = 0;

async function fakeStripe(url, init) {
  stripeCalls += 1;
  assert.equal(init.headers.Authorization, "Bearer rk_test_key");
  const id = url.split("/").pop();
  const session = sessions[id];
  if (!session) return new Response(JSON.stringify({ error: { code: "resource_missing" } }), { status: 404 });
  return new Response(JSON.stringify({ id, ...session }), { status: 200 });
}

before(async () => {
  const downloads = await mkdtemp(join(tmpdir(), "spacekit-web-"));
  await writeFile(join(downloads, "SpaceKit-0.1.0.dmg"), "dmg");
  await writeFile(join(downloads, "SpaceKit-0.1.0.pkg"), "installer-bytes");
  const { config } = loadConfig({
    STRIPE_SECRET_KEY: "rk_test_key",
    STRIPE_PAYMENT_LINK_URL: "https://buy.stripe.com/test_123",
    STRIPE_PAYMENT_LINK_ID: "plink_spacekit",
    DOWNLOAD_SECRET: "x".repeat(40),
    DOWNLOADS_DIR: downloads,
    BUSINESS_ID: "1234567-8",
    BUSINESS_ADDRESS: "Testikatu 1 <b>, Helsinki",
    SUPPORT_EMAIL: "help@example.com",
  });
  server = createServer(createHandler(config, { fetch: fakeStripe, log: () => {} }));
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

const claim = (id) => fetch(`${base}/api/claim?session_id=${id}`);

test("serves the home and thanks pages with security headers", async () => {
  for (const path of ["/", "/thanks", "/styles.css", "/main.js"]) {
    const res = await fetch(base + path);
    assert.equal(res.status, 200, path);
    assert.match(res.headers.get("content-security-policy"), /default-src 'self'/);
  }
  assert.equal((await fetch(`${base}/thanks`)).headers.get("referrer-policy"), "no-referrer");
});

test("legal pages show the seller details from the environment, escaped", async () => {
  for (const path of ["/terms", "/privacy", "/refunds", "/"]) {
    const res = await fetch(base + path);
    assert.equal(res.status, 200, path);
    const html = await res.text();
    assert.doesNotMatch(html, /\{\{[A-Z_]+\}\}/, `${path} has an unfilled placeholder`);
    assert.match(html, /AppRise Ventures Oy/, path);
    assert.match(html, /1234567-8/, path);
    assert.match(html, /mailto:help@example\.com/, path);
    assert.match(html, /Testikatu 1 &lt;b&gt;, Helsinki/, path);
    assert.equal(Number(res.headers.get("content-length")), Buffer.byteLength(html), path);
  }
});

test("refuses path traversal and dotfiles", async () => {
  assert.equal((await fetch(`${base}/..%2fserver.mjs`)).status, 404);
  assert.equal((await fetch(`${base}/%2e%2e/server.mjs`)).status, 404);
  assert.equal((await fetch(`${base}/.env`)).status, 404);
});

test("/buy redirects to the Stripe payment link", async () => {
  const res = await fetch(`${base}/buy`, { redirect: "manual" });
  assert.equal(res.status, 302);
  assert.equal(res.headers.get("location"), "https://buy.stripe.com/test_123");
});

test("a paid session gets a working download link for the .pkg", async () => {
  const res = await claim(PAID);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.status, "ready");
  assert.equal(body.file, "SpaceKit-0.1.0.pkg");
  assert.equal(body.email, "buyer@example.com");

  const download = await fetch(base + body.download_url);
  assert.equal(download.status, 200);
  assert.match(download.headers.get("content-disposition"), /SpaceKit-0\.1\.0\.pkg/);
  assert.equal(await download.text(), "installer-bytes");
});

test("a paid session is cached instead of asking Stripe again", async () => {
  await claim(PAID);
  const calls = stripeCalls;
  assert.equal((await claim(PAID)).status, 200);
  assert.equal(stripeCalls, calls);
});

test("unpaid, pending, foreign and unknown sessions get no download", async () => {
  const cases = [
    [UNPAID, 402, "unpaid"],
    [PENDING, 202, "processing"],
    [OTHER_LINK, 404, "not_found"],
    [MISSING, 404, "not_found"],
    ["not-a-session", 400, "invalid"],
  ];
  for (const [id, status, kind] of cases) {
    const res = await claim(id);
    const body = await res.json();
    assert.equal(res.status, status, id);
    assert.equal(body.status, kind, id);
    assert.equal(body.download_url, undefined, id);
  }
});

test("tampered or garbage download tokens are refused", async () => {
  const { download_url } = await (await claim(PAID)).json();
  const [payload, signature] = download_url.slice("/download/".length).split(".");
  const forged = Buffer.from(JSON.stringify({ s: PAID, exp: 9999999999 })).toString("base64url");
  assert.equal((await fetch(`${base}/download/${forged}.${signature}`)).status, 410);
  assert.equal((await fetch(`${base}/download/${payload}.AAAA`)).status, 410);
  assert.equal((await fetch(`${base}/download/nonsense`)).status, 410);
});

test("download links stop working after their TTL", async () => {
  let clock = Date.now();
  const downloads = await mkdtemp(join(tmpdir(), "spacekit-web-"));
  await writeFile(join(downloads, "SpaceKit-0.1.0.pkg"), "installer-bytes");
  const { config } = loadConfig({
    STRIPE_SECRET_KEY: "rk_test_key",
    STRIPE_PAYMENT_LINK_ID: "plink_spacekit",
    DOWNLOAD_SECRET: "y".repeat(40),
    DOWNLOADS_DIR: downloads,
    DOWNLOAD_TTL_SECONDS: "60",
  });
  const local = createServer(createHandler(config, { fetch: fakeStripe, now: () => clock, log: () => {} }));
  await new Promise((resolve) => local.listen(0, resolve));
  const url = `http://127.0.0.1:${local.address().port}`;
  try {
    const { download_url } = await (await fetch(`${url}/api/claim?session_id=${PAID}`)).json();
    assert.equal((await fetch(url + download_url)).status, 200);
    clock += 61_000;
    assert.equal((await fetch(url + download_url)).status, 410);
    // Claiming again issues a fresh link.
    const again = await (await fetch(`${url}/api/claim?session_id=${PAID}`)).json();
    assert.equal((await fetch(url + again.download_url)).status, 200);
  } finally {
    local.close();
  }
});

test("healthz reports the installer it would serve", async () => {
  const body = await (await fetch(`${base}/healthz`)).json();
  assert.deepEqual(body, { ok: true, installer: "SpaceKit-0.1.0.pkg" });
});

test("installer names give versions that order number by number", () => {
  assert.equal(installerVersion("SpaceKit-0.2.0.dmg"), "0.2.0");
  assert.equal(installerVersion("SpaceKit-1.10.pkg"), "1.10");
  assert.equal(installerVersion("SpaceKit.dmg"), null);
  assert.equal(installerVersion("SpaceKit-0.2.0.notes.md"), null);
  assert.ok(compareVersions("0.10.0", "0.9.1") > 0);
  assert.equal(compareVersions("1.0", "1.0.0"), 0);
  assert.ok(compareVersions("0.1.0", null) > 0);
});

test("the newest version is served, with its notes, to the update check and to buyers", async () => {
  const downloads = await mkdtemp(join(tmpdir(), "spacekit-web-"));
  await writeFile(join(downloads, "SpaceKit-0.10.0.dmg"), "new");
  await writeFile(join(downloads, "SpaceKit-0.9.0.pkg"), "old but uploaded later");
  await writeFile(join(downloads, "SpaceKit-0.10.0.notes.md"), "- Updates inside the app\n");
  const { config } = loadConfig({
    STRIPE_SECRET_KEY: "rk_test_key",
    STRIPE_PAYMENT_LINK_ID: "plink_spacekit",
    DOWNLOAD_SECRET: "z".repeat(40),
    DOWNLOADS_DIR: downloads,
  });
  const local = createServer(createHandler(config, { fetch: fakeStripe, log: () => {} }));
  await new Promise((resolve) => local.listen(0, resolve));
  const url = `http://127.0.0.1:${local.address().port}`;
  try {
    const res = await fetch(`${url}/api/updates/latest`);
    assert.equal(res.status, 200);
    assert.match(res.headers.get("cache-control"), /max-age=300/);
    const latest = await res.json();
    assert.equal(latest.version, "0.10.0");
    assert.equal(latest.notes, "- Updates inside the app");
    assert.equal(latest.download_page, "/update");
    assert.equal(latest.minimum_system_version, "15.0");

    const claimed = await (await fetch(`${url}/api/claim?session_id=${PAID}`)).json();
    assert.equal(claimed.version, "0.10.0");
    assert.equal(claimed.file, "SpaceKit-0.10.0.dmg");
    assert.equal(await (await fetch(url + claimed.download_url)).text(), "new");

    // A newer upload is picked up even while the purchase is cached.
    await writeFile(join(downloads, "SpaceKit-0.11.0.dmg"), "newer");
    const again = await (await fetch(`${url}/api/claim?session_id=${PAID}`)).json();
    assert.equal(again.version, "0.11.0");
    assert.equal(await (await fetch(url + again.download_url)).text(), "newer");
  } finally {
    local.close();
  }
});

test("the update check says so when there is no release", async () => {
  const downloads = await mkdtemp(join(tmpdir(), "spacekit-web-"));
  const { config } = loadConfig({ DOWNLOAD_SECRET: "z".repeat(40), DOWNLOADS_DIR: downloads });
  const local = createServer(createHandler(config, { fetch: fakeStripe, log: () => {} }));
  await new Promise((resolve) => local.listen(0, resolve));
  try {
    const res = await fetch(`http://127.0.0.1:${local.address().port}/api/updates/latest`);
    assert.equal(res.status, 503);
  } finally {
    local.close();
  }
});

test("the update page is served", async () => {
  const res = await fetch(`${base}/update`);
  assert.equal(res.status, 200);
  assert.match(await res.text(), /Update SpaceKit/);
});
