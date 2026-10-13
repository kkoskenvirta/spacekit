// After checkout, Stripe sends the buyer here with ?session_id=…; ask the server for the download.

const params = new URLSearchParams(location.search);
const sessionId = params.get("session_id") || "";
const show = (id) => {
  for (const state of ["loading", "ready", "error"]) document.getElementById(`state-${state}`).hidden = state !== id;
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

async function claim(attempt = 0) {
  let response;
  let body;
  try {
    response = await fetch(`/api/claim?session_id=${encodeURIComponent(sessionId)}`, { cache: "no-store" });
    body = await response.json();
  } catch {
    return fail("Connection problem", "We couldn't reach the server. Check your connection and try again.", { retry: true });
  }

  if (body.status === "ready") {
    document.getElementById("download").href = body.download_url;
    document.getElementById("file-meta").textContent = `${body.file} · ${formatSize(body.size)} · macOS 15+`;
    if (body.file.endsWith(".dmg")) {
      document.getElementById("step-install").innerHTML =
        "Open the downloaded <b>disk image</b> and drag <b>SpaceKit</b> into the <b>Applications</b> folder.";
    }
    if (body.email) document.getElementById("ready-email").textContent = `, ${body.email}`;
    show("ready");
    return;
  }
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

if (!sessionId) {
  fail("No purchase found", "This page is where you land after buying SpaceKit. If you've paid, open the link from your browser history.");
} else {
  claim();
}
