// The SpaceKit website: the marketing pages, the checkout redirect and the paid download.
//
// Purchases go through a Stripe Payment Link. After paying, Stripe sends the buyer to
// /thanks?session_id=…; that page asks /api/claim, which looks the Checkout Session up in Stripe's API
// and, once it is paid, hands out a signed, short-lived link to the installer. No database: the session
// id is the proof of purchase.
//
// No dependencies, Node 22+. Configuration comes from the environment; see .env.example.

import { createHmac, timingSafeEqual } from "node:crypto";
import { createReadStream } from "node:fs";
import { readFile, readdir, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";

const PUBLIC_DIR = fileURLToPath(new URL("./public/", import.meta.url));

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
  ".webmanifest": "application/manifest+json",
};

const SECURITY_HEADERS = {
  "Content-Security-Policy":
    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; " +
    "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
};

// Stripe Checkout Session ids; anything else never reaches the API.
const SESSION_ID = /^cs_(live|test)_[A-Za-z0-9]{10,250}$/;

export function loadConfig(env = process.env) {
  const config = {
    port: Number(env.PORT) || 3000,
    stripeApi: (env.STRIPE_API_URL || "https://api.stripe.com").replace(/\/$/, ""),
    stripeKey: env.STRIPE_SECRET_KEY || "",
    checkoutUrl: env.STRIPE_PAYMENT_LINK_URL || "",
    paymentLinkId: env.STRIPE_PAYMENT_LINK_ID || "",
    downloadSecret: env.DOWNLOAD_SECRET || "",
    downloadsDir: env.DOWNLOADS_DIR || "/data/downloads",
    installerFile: env.INSTALLER_FILE || "",
    downloadTtlSeconds: Number(env.DOWNLOAD_TTL_SECONDS) || 3600,
    // Seller details shown in the footer and the legal pages, where pages say {{NAME}}.
    site: {
      BUSINESS_NAME: env.BUSINESS_NAME || "AppRise Ventures Oy",
      BUSINESS_ID: env.BUSINESS_ID || "",
      BUSINESS_ADDRESS: env.BUSINESS_ADDRESS || "",
      SUPPORT_EMAIL: env.SUPPORT_EMAIL || "",
    },
  };
  const problems = [];
  if (!config.stripeKey) problems.push("STRIPE_SECRET_KEY is not set: purchases can't be verified");
  if (!config.checkoutUrl) problems.push("STRIPE_PAYMENT_LINK_URL is not set: /buy has nowhere to go");
  if (!config.paymentLinkId) problems.push("STRIPE_PAYMENT_LINK_ID is not set: any paid checkout on the account unlocks the download");
  if (config.downloadSecret.length < 32) problems.push("DOWNLOAD_SECRET must be at least 32 characters: downloads are disabled");
  for (const key of ["SUPPORT_EMAIL", "BUSINESS_ID", "BUSINESS_ADDRESS"]) {
    if (!config.site[key]) problems.push(`${key} is not set: the footer and legal pages leave it blank`);
  }
  return { config, problems };
}

export function createHandler(config, { fetch = globalThis.fetch, now = () => Date.now(), log = console.log } = {}) {
  const startedAt = Math.floor(Date.now() / 1000) * 1000;
  const claims = new Map(); // session id → { until, body } for sessions already confirmed as paid
  const limiter = rateLimiter({ limit: 30, windowMs: 10 * 60 * 1000, now });

  function sign(payload) {
    return createHmac("sha256", config.downloadSecret).update(payload).digest("base64url");
  }

  // A signed download link for a purchase. With `file`, it serves exactly that installer (the one an
  // appcast's signature covers); without, whatever is newest when it's used.
  function issueToken(sessionId, { file, ttlSeconds = config.downloadTtlSeconds } = {}) {
    const payload = Buffer.from(
      JSON.stringify({ s: sessionId, ...(file ? { f: file } : {}), exp: Math.floor(now() / 1000) + ttlSeconds }),
    ).toString("base64url");
    return `${payload}.${sign(payload)}`;
  }

  function readToken(token) {
    const [payload, signature, extra] = String(token).split(".");
    if (!payload || !signature || extra !== undefined) return null;
    const expected = Buffer.from(sign(payload));
    const given = Buffer.from(signature);
    if (expected.length !== given.length || !timingSafeEqual(expected, given)) return null;
    try {
      const data = JSON.parse(Buffer.from(payload, "base64url").toString());
      return typeof data.exp === "number" && data.exp * 1000 > now() ? data : null;
    } catch {
      return null;
    }
  }

  // The installer customers get: INSTALLER_FILE if set, otherwise the highest version uploaded
  // (SpaceKit-<version>.pkg or .dmg; the .pkg when both exist), with the newest upload breaking ties.
  async function findInstaller() {
    let names;
    try {
      names = config.installerFile ? [config.installerFile] : await readdir(config.downloadsDir);
    } catch {
      return null;
    }
    const candidates = [];
    for (const name of names) {
      if (name.includes("/") || name.startsWith(".") || ![".pkg", ".dmg"].includes(extname(name))) continue;
      try {
        const info = await stat(join(config.downloadsDir, name));
        if (info.isFile()) {
          candidates.push({ name, path: join(config.downloadsDir, name), size: info.size, mtime: info.mtimeMs, version: installerVersion(name) });
        }
      } catch {}
    }
    const rank = (file) => (extname(file.name) === ".pkg" ? 1 : 0);
    candidates.sort((a, b) => compareVersions(b.version, a.version) || rank(b) - rank(a) || b.mtime - a.mtime);
    return candidates[0] ?? null;
  }

  async function namedInstaller(name) {
    if (!installerVersion(name)) return null;
    try {
      const path = join(config.downloadsDir, name);
      const info = await stat(path);
      return info.isFile() ? { name, path, size: info.size, mtime: info.mtimeMs, version: installerVersion(name) } : null;
    } catch {
      return null;
    }
  }

  // Release notes uploaded next to an installer, as SpaceKit-<version>.notes.md.
  async function releaseNotes(version) {
    if (!version) return null;
    try {
      const notes = await readFile(join(config.downloadsDir, `SpaceKit-${version}.notes.md`), "utf8");
      return notes.trim().slice(0, 8000) || null;
    } catch {
      return null;
    }
  }

  // What the app's update check reads. Public: it says which version exists, not how to download it.
  async function latestRelease() {
    const installer = await findInstaller();
    if (!installer?.version) return [503, { status: "unavailable", message: "No release is available right now." }];
    return [
      200,
      {
        version: installer.version,
        size: installer.size,
        published_at: new Date(installer.mtime).toISOString(),
        minimum_system_version: "15.0",
        notes: await releaseNotes(installer.version),
        download_page: "/update",
      },
    ];
  }

  async function claim(sessionId) {
    const purchase = await verifyPurchase(sessionId);
    return purchase.paid ? ready(sessionId, purchase.email) : purchase.answer;
  }

  // Whether a purchase key is a paid SpaceKit purchase: { paid: true, email } or { paid: false, answer }
  // with the HTTP status and body that explain why not. Paid purchases are remembered for an hour.
  async function verifyPurchase(sessionId) {
    const no = (status, body) => ({ paid: false, answer: [status, body] });
    if (!SESSION_ID.test(sessionId)) return no(400, { status: "invalid", message: "That isn't a valid purchase link." });
    const cached = claims.get(sessionId);
    if (cached && cached.until > now()) return { paid: true, email: cached.email };
    if (!config.stripeKey || config.downloadSecret.length < 32) {
      return no(503, { status: "unavailable", message: "Downloads are temporarily unavailable." });
    }

    let response;
    try {
      response = await fetch(`${config.stripeApi}/v1/checkout/sessions/${sessionId}`, {
        headers: { Authorization: `Bearer ${config.stripeKey}` },
        signal: AbortSignal.timeout(10_000),
      });
    } catch (error) {
      log(`claim ${sessionId}: Stripe unreachable (${error.message})`);
      return no(502, { status: "unavailable", message: "We couldn't reach the payment provider. Try again in a moment." });
    }
    if (response.status === 404) {
      return no(404, { status: "not_found", message: "We couldn't find that purchase." });
    }
    if (!response.ok) {
      log(`claim ${sessionId}: Stripe answered ${response.status}`);
      return no(502, { status: "unavailable", message: "The payment provider didn't answer. Try again in a moment." });
    }

    const session = await response.json();
    if (config.paymentLinkId && session.payment_link !== config.paymentLinkId) {
      log(`claim ${sessionId}: session is from another payment link`);
      return no(404, { status: "not_found", message: "That purchase isn't for SpaceKit." });
    }
    if (session.status === "expired") {
      return no(410, { status: "expired", message: "This checkout expired before it was paid." });
    }
    if (session.status !== "complete") {
      return no(402, { status: "unpaid", message: "This checkout hasn't been paid yet." });
    }
    // Card payments are paid on completion; bank debits and the like settle later.
    if (session.payment_status !== "paid" && session.payment_status !== "no_payment_required") {
      return no(202, { status: "processing", message: "Your payment is being processed. You'll get an email receipt from Stripe once it clears; come back to this page then." });
    }

    const email = session.customer_details?.email ?? null;
    claims.set(sessionId, { until: now() + 60 * 60 * 1000, email });
    log(`claim ${sessionId}: paid`);
    return { paid: true, email };
  }

  // A paid purchase's answer: the current installer and a fresh link to it.
  async function ready(sessionId, email) {
    const installer = await findInstaller();
    if (!installer) {
      log(`claim ${sessionId}: paid, but no installer in ${config.downloadsDir}`);
      return [503, { status: "unavailable", message: "Your payment went through, but the download isn't ready yet. Keep this page's address and try again shortly." }];
    }
    const body = { status: "ready", email, file: installer.name, version: installer.version, size: installer.size };
    return [200, { ...body, download_url: `/download/${issueToken(sessionId)}` }];
  }

  // The Sparkle appcast the app checks for updates (/appcast.xml?key=<purchase key>). It always names the
  // newest version; only for a paid purchase key does it include the signed download Sparkle installs.
  // Anyone else gets it as an informational update that links to the update page.
  async function appcast(req, key) {
    const installer = await findInstaller();
    const origin = publicOrigin(req);
    const items = [];
    if (installer?.version) {
      const version = installer.version;
      const dmg = `SpaceKit-${version}.dmg`;
      const signature = await updateSignature(dmg);
      const purchase = key ? await verifyPurchase(key) : null;
      const installable = Boolean(purchase?.paid && signature);
      const notes = await releaseNotes(version);
      const page = `${origin}/update${key && SESSION_ID.test(key) ? `?session_id=${key}` : ""}`;
      const lines = [
        "    <item>",
        `      <title>SpaceKit ${version}</title>`,
        `      <pubDate>${new Date(installer.mtime).toUTCString()}</pubDate>`,
        `      <sparkle:version>${version}</sparkle:version>`,
        `      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>`,
        "      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>",
      ];
      if (notes) lines.push(`      <description><![CDATA[${markdownToHtml(notes)}]]></description>`);
      if (installable) {
        // A week, so an update the buyer postpones still downloads.
        const token = issueToken(key, { file: dmg, ttlSeconds: 7 * 24 * 60 * 60 });
        lines.push(
          `      <enclosure url="${xml(`${origin}/download/${token}`)}" length="${signature.length}" type="application/octet-stream" sparkle:edSignature="${xml(signature.edSignature)}"/>`,
        );
      } else {
        lines.push(`      <link>${xml(page)}</link>`, "      <sparkle:informationalUpdate></sparkle:informationalUpdate>");
      }
      lines.push("    </item>");
      items.push(lines.join("\n"));
      if (key) log(`appcast ${key.slice(0, 16)}…: ${installable ? "installable" : purchase?.paid ? "paid, no signature" : "not paid"} ${version}`);
    }
    return [
      '<?xml version="1.0" encoding="utf-8"?>',
      '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">',
      "  <channel>",
      "    <title>SpaceKit</title>",
      `    <link>${xml(origin)}</link>`,
      ...items,
      "  </channel>",
      "</rss>",
      "",
    ].join("\n");
  }

  // The Sparkle signature uploaded next to a DMG, as sign_update prints it: sparkle:edSignature="…" length="…".
  async function updateSignature(dmg) {
    try {
      const text = await readFile(join(config.downloadsDir, `${dmg}.sig`), "utf8");
      const edSignature = /edSignature="([A-Za-z0-9+/=]+)"/.exec(text)?.[1];
      const length = /length="(\d+)"/.exec(text)?.[1];
      const info = await stat(join(config.downloadsDir, dmg));
      // A signature for some other upload of the file would fail in the app anyway; don't offer it.
      if (!edSignature || !length || Number(length) !== info.size) return null;
      return { edSignature, length };
    } catch {
      return null;
    }
  }

  async function serveDownload(req, res, token) {
    const data = readToken(token);
    if (!data) return sendHtmlError(res, 410, "This download link has expired", "Open the link from your purchase page or receipt again to get a fresh one.");
    const installer = data.f ? await namedInstaller(data.f) : await findInstaller();
    if (!installer) return sendHtmlError(res, 503, "The download isn't available right now", "Please try again in a few minutes.");
    res.writeHead(200, {
      ...SECURITY_HEADERS,
      "Content-Type": "application/octet-stream",
      "Content-Length": installer.size,
      "Content-Disposition": `attachment; filename="${installer.name}"`,
      "Cache-Control": "private, no-store",
    });
    if (req.method === "HEAD") return res.end();
    log(`download ${data.s}: ${installer.name}`);
    createReadStream(installer.path).pipe(res);
  }

  async function serveStatic(req, res, pathname) {
    const routes = {
      "/": "index.html",
      "/thanks": "thanks.html",
      "/terms": "terms.html",
      "/privacy": "privacy.html",
      "/refunds": "refunds.html",
      "/update": "update.html",
    };
    const file = routes[pathname] ?? pathname.slice(1);
    const resolved = normalize(join(PUBLIC_DIR, file));
    const inside = resolved.slice(PUBLIC_DIR.length);
    if (!resolved.startsWith(PUBLIC_DIR) || inside.split(sep).some((part) => part.startsWith("."))) {
      return sendNotFound(res);
    }
    let info;
    try {
      info = await stat(resolved);
    } catch {
      return sendNotFound(res);
    }
    if (!info.isFile()) return sendNotFound(res);
    const type = CONTENT_TYPES[extname(resolved)] ?? "application/octet-stream";
    const isHtml = type.startsWith("text/html");
    // Browsers revalidate every asset (a cheap 304), so a deploy shows up immediately. HTML also changes
    // when the seller details in the environment do, which takes a restart.
    const modified = Math.max(Math.floor(info.mtimeMs / 1000) * 1000, isHtml ? startedAt : 0);
    const lastModified = new Date(modified).toUTCString();
    const headers = {
      ...SECURITY_HEADERS,
      "Content-Type": type,
      "Cache-Control": "no-cache",
      "Last-Modified": lastModified,
    };
    // The purchase page's URL carries the session id: don't leak it to other sites.
    if (pathname === "/thanks") headers["Referrer-Policy"] = "no-referrer";
    if (req.headers["if-modified-since"] === lastModified) {
      res.writeHead(304, headers);
      return res.end();
    }
    if (isHtml) {
      const body = Buffer.from(fillPlaceholders(await readFile(resolved, "utf8"), config.site));
      res.writeHead(200, { ...headers, "Content-Length": body.length });
      return res.end(req.method === "HEAD" ? undefined : body);
    }
    res.writeHead(200, { ...headers, "Content-Length": info.size });
    if (req.method === "HEAD") return res.end();
    createReadStream(resolved).pipe(res);
  }

  function sendNotFound(res) {
    sendHtmlError(res, 404, "Page not found", "There's nothing at this address.");
  }

  return async function handle(req, res) {
    try {
      const url = new URL(req.url, "http://localhost");
      const { pathname } = url;
      if (req.method !== "GET" && req.method !== "HEAD") {
        res.writeHead(405, { ...SECURITY_HEADERS, Allow: "GET, HEAD" });
        return res.end();
      }
      if (pathname === "/healthz") {
        return sendJson(res, 200, { ok: true, installer: (await findInstaller())?.name ?? null });
      }
      if (pathname === "/api/updates/latest") {
        const [status, body] = await latestRelease();
        res.writeHead(status, {
          ...SECURITY_HEADERS,
          "Content-Type": "application/json; charset=utf-8",
          "Cache-Control": status === 200 ? "public, max-age=300" : "no-store",
        });
        return res.end(req.method === "HEAD" ? undefined : JSON.stringify(body));
      }
      if (pathname === "/appcast.xml") {
        if (!limiter(clientAddress(req))) {
          res.writeHead(429, { ...SECURITY_HEADERS, "Retry-After": "600" });
          return res.end();
        }
        const body = await appcast(req, url.searchParams.get("key") ?? "");
        res.writeHead(200, { ...SECURITY_HEADERS, "Content-Type": "application/rss+xml; charset=utf-8", "Cache-Control": "no-store" });
        return res.end(req.method === "HEAD" ? undefined : body);
      }
      if (pathname === "/buy") {
        if (!config.checkoutUrl) return sendHtmlError(res, 503, "Checkout is temporarily unavailable", "Please try again in a few minutes.");
        res.writeHead(302, { ...SECURITY_HEADERS, Location: config.checkoutUrl, "Cache-Control": "no-store" });
        return res.end();
      }
      if (pathname === "/api/claim") {
        if (!limiter(clientAddress(req))) {
          return sendJson(res, 429, { status: "rate_limited", message: "Too many attempts. Wait a few minutes and try again." });
        }
        const [status, body] = await claim(url.searchParams.get("session_id") ?? "");
        return sendJson(res, status, body);
      }
      if (pathname.startsWith("/download/")) {
        return await serveDownload(req, res, pathname.slice("/download/".length));
      }
      return await serveStatic(req, res, decodeURIComponent(pathname));
    } catch (error) {
      log(`error ${req.method} ${req.url}: ${error.stack ?? error}`);
      if (!res.headersSent) sendHtmlError(res, 500, "Something went wrong", "Please try again.");
      else res.destroy();
    }
  };
}

// The site's own address as the client reached it (Coolify's proxy forwards the original scheme and host).
function publicOrigin(req) {
  const forwarded = (name) => String(req.headers[name] ?? "").split(",")[0].trim();
  const proto = forwarded("x-forwarded-proto") || (req.socket.encrypted ? "https" : "http");
  const host = forwarded("x-forwarded-host") || req.headers.host || "localhost";
  return `${proto === "https" ? "https" : "http"}://${/^[A-Za-z0-9.:-]+$/.test(host) ? host : "localhost"}`;
}

function xml(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" })[c]);
}

// Just enough Markdown for release notes: paragraphs, "- " lists, **bold**, *italic* and `code`.
export function markdownToHtml(markdown) {
  const inline = (text) =>
    xml(text)
      .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
      .replace(/\*(.+?)\*/g, "<i>$1</i>")
      .replace(/`(.+?)`/g, "<code>$1</code>");
  const html = [];
  let list = false;
  for (const line of markdown.split("\n")) {
    const item = /^\s*[-*]\s+(.*)$/.exec(line);
    if (item) {
      if (!list) html.push("<ul>");
      list = true;
      html.push(`<li>${inline(item[1])}</li>`);
      continue;
    }
    if (list) html.push("</ul>");
    list = false;
    if (line.trim()) html.push(`<p>${inline(line.trim())}</p>`);
  }
  if (list) html.push("</ul>");
  return html.join("\n").replaceAll("]]>", "]]&gt;");
}

// SpaceKit-0.2.0.dmg → "0.2.0"; null for names without a version.
export function installerVersion(name) {
  return /^SpaceKit-(\d+(?:\.\d+){0,3})\.(?:pkg|dmg)$/.exec(name)?.[1] ?? null;
}

// Orders dotted versions number by number (0.10.0 after 0.9.1); a missing version sorts first.
export function compareVersions(a, b) {
  if (!a || !b) return (a ? 1 : 0) - (b ? 1 : 0);
  const x = a.split(".").map(Number);
  const y = b.split(".").map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d) return d;
  }
  return 0;
}

// Replaces {{NAME}} with the (HTML-escaped) seller detail of that name.
function fillPlaceholders(html, values) {
  const escape = (text) =>
    String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  return html.replace(/\{\{([A-Z_]+)\}\}/g, (match, key) => (key in values ? escape(values[key]) : match));
}

function sendJson(res, status, body) {
  res.writeHead(status, { ...SECURITY_HEADERS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(JSON.stringify(body));
}

function sendHtmlError(res, status, title, message) {
  res.writeHead(status, { ...SECURITY_HEADERS, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
  res.end(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} · SpaceKit</title><link rel="stylesheet" href="/styles.css"></head>
<body class="page-message"><main class="message-card"><a class="brand" href="/"><img src="/favicon.svg" alt="" width="28" height="28">SpaceKit</a>
<h1>${title}</h1><p>${message}</p><a class="button button-ghost" href="/">Back to the home page</a></main></body></html>`);
}

// Behind Coolify's proxy (Traefik or Caddy) the client's address is the first X-Forwarded-For entry.
function clientAddress(req) {
  const forwarded = req.headers["x-forwarded-for"];
  return (typeof forwarded === "string" && forwarded.split(",")[0].trim()) || req.socket.remoteAddress || "unknown";
}

function rateLimiter({ limit, windowMs, now }) {
  const hits = new Map();
  return (key) => {
    const time = now();
    if (hits.size > 10_000) {
      for (const [k, v] of hits) if (v.reset <= time) hits.delete(k);
    }
    const entry = hits.get(key);
    if (!entry || entry.reset <= time) {
      hits.set(key, { count: 1, reset: time + windowMs });
      return true;
    }
    entry.count += 1;
    return entry.count <= limit;
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { config, problems } = loadConfig();
  for (const problem of problems) console.warn(`warning: ${problem}`);
  const server = createServer(createHandler(config));
  server.listen(config.port, () => console.log(`SpaceKit site on http://localhost:${config.port}`));
  const stop = () => server.close(() => process.exit(0));
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}
