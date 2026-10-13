// The download page (/thanks, where Stripe sends buyers) and the update page (/update, where the app sends
// them). Both carry the purchase key as ?session_id=…; the server checks it with Stripe and hands back a
// short-lived link to the newest installer.

const page = document.body.dataset.page;
const params = new URLSearchParams(location.search);
const sessionId = (params.get("session_id") || "").trim();
const STATES = ["ask", "loading", "ready", "error"];
const show = (id) => {
  for (const state of STATES) {
    const el = document.getElementById(`state-${state}`);
    if (el) el.hidden = state !== id;
  }
};

function fail(title, text, { retry = false } = {}) {
  document.getElementById("error-title").textContent = title;
  document.getElementById("error-text").textContent = text;
  const action = document.getElementById("error-action");
  if (retry) {
    action.textContent = "Try again";
    action.href = location.href;
  }
  show("error");
}

function formatSize(bytes) {
  return bytes > 1e6 ? `${(bytes / 1e6).toFixed(1)} MB` : `${Math.round(bytes / 1e3)} KB`;
}

function showReady(body) {
  document.getElementById("download").href = body.download_url;
  const version = body.version ? `SpaceKit ${body.version}` : body.file;
  document.getElementById("file-meta").textContent = `${version} · ${body.file.endsWith(".dmg") ? "disk image" : "installer"} · ${formatSize(body.size)} · macOS 15+`;
  if (body.file.endsWith(".dmg")) {
    document.getElementById("step-install").innerHTML =
      page === "update"
        ? "Open the downloaded <b>disk image</b>, drag <b>SpaceKit</b> into <b>Applications</b> and choose <b>Replace</b>."
        : "Open the downloaded <b>disk image</b> and drag <b>SpaceKit</b> into the <b>Applications</b> folder.";
  }
  if (page === "update" && body.version) {
    document.getElementById("ready-title").textContent = `SpaceKit ${body.version} is ready`;
  }
  if (body.email) document.getElementById("ready-email").textContent = `, ${body.email}`;

  // The license key (the Stripe Checkout Session id), and the link that stores it in the app.
  document.getElementById("purchase-key").textContent = sessionId;
  document.getElementById("link-app").href = `spacekit://activate?key=${encodeURIComponent(sessionId)}`;
  const downloadLink = `${location.origin}/thanks?session_id=${encodeURIComponent(sessionId)}`;
  copyButton("copy-key", () => sessionId, "Key copied");
  copyButton("copy-link", () => downloadLink, "Link copied");
  document.getElementById("save-key").addEventListener("click", (event) => {
    const file = new Blob([licenseFile(sessionId, downloadLink, body)], { type: "text/plain;charset=utf-8" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(file);
    link.download = "SpaceKit license key.txt";
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    flash(event.currentTarget, "Saved");
  });
  show("ready");
}

// A button that copies text, confirming in its own label.
function copyButton(id, text, done) {
  const button = document.getElementById(id);
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(text());
      flash(button, done);
    } catch {
      flash(button, "Select it and copy", false);
    }
  });
}

function flash(button, text, ok = true) {
  const label = button.querySelector("span");
  const original = label.dataset.original ?? label.textContent;
  label.dataset.original = original;
  label.textContent = ok ? `${text} ✓` : text;
  button.classList.toggle("done", ok);
  clearTimeout(button.resetTimer);
  button.resetTimer = setTimeout(() => {
    label.textContent = original;
    button.classList.remove("done");
  }, 2000);
}

// The text file "Download as .txt" saves.
function licenseFile(key, downloadLink, body) {
  const support = document.body.dataset.support;
  return [
    "SpaceKit license key",
    "====================",
    "",
    `License key:   ${key}`,
    `Download link: ${downloadLink}`,
    body.email ? `Bought with:   ${body.email}` : null,
    `Saved:         ${new Date().toISOString().slice(0, 10)}`,
    "",
    "Keep this file somewhere safe and private. Your license key gives you:",
    "",
    "- Free updates. In SpaceKit, open Settings → Updates and paste the key, or open",
    "  the download link above and click \"Link to SpaceKit\". SpaceKit then installs",
    "  new versions itself.",
    "- Downloads of SpaceKit any time, for example on a new Mac: open the download",
    "  link above, or paste the key at https://spacekit.studio/update.",
    "",
    "Anyone with this key can download your copy of SpaceKit, so don't share it.",
    support ? `Questions: ${support}` : null,
    "",
  ]
    .filter((line) => line !== null)
    .join("\n");
}

async function claim(attempt = 0) {
  show("loading");
  let response;
  let body;
  try {
    response = await fetch(`/api/claim?session_id=${encodeURIComponent(sessionId)}`, { cache: "no-store" });
    body = await response.json();
  } catch {
    return fail("Connection problem", "We couldn't reach the server. Check your connection and try again.", { retry: true });
  }

  if (body.status === "ready") return showReady(body);
  // A payment that hasn't settled yet: keep checking for a while.
  if (body.status === "processing" && attempt < 20) {
    document.getElementById("loading-text").textContent = "Your payment is still processing…";
    setTimeout(() => claim(attempt + 1), Math.min(2000 + attempt * 1000, 8000));
    return;
  }
  const retry = ["unavailable", "processing", "rate_limited"].includes(body.status);
  const titles = {
    unpaid: "This checkout isn't paid yet",
    expired: "This checkout expired",
    processing: "Your payment is still processing",
  };
  fail(titles[body.status] ?? "We couldn't confirm your purchase", body.message ?? "Something went wrong.", { retry });
}

// The purchase key in a pasted key or download page address.
function keyIn(text) {
  text = text.trim();
  try {
    const url = new URL(text);
    text = url.searchParams.get("session_id") || url.searchParams.get("key") || "";
  } catch {}
  return /^cs_(live|test)_[A-Za-z0-9]{10,250}$/.test(text) ? text : null;
}

if (sessionId) {
  claim();
} else if (page === "update") {
  show("ask");
  document.getElementById("key-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const key = keyIn(document.getElementById("key-input").value);
    document.getElementById("key-error").hidden = Boolean(key);
    if (key) location.search = `?session_id=${encodeURIComponent(key)}`;
  });
} else {
  fail("No purchase found", "This page is where you land after buying SpaceKit. If you've paid, open the link from your browser history.");
}
