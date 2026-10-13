// SpaceKit marketing page: hero animation, charts, job builder. No dependencies.

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const SVG_NS = "http://www.w3.org/2000/svg";
const CAPACITY = 494;

function svg(tag, attrs = {}, parent) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  if (parent) parent.appendChild(node);
  return node;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ───────────── Hero: the disk creeps full, then a job runs ─────────────

function hero() {
  const segments = Object.fromEntries([...document.querySelectorAll("#capacity span")].map((el) => [el.dataset.key, el]));
  const usedEl = document.getElementById("disk-used");
  const freeEl = document.getElementById("disk-free");
  const statusEl = document.getElementById("disk-status");
  const log = document.getElementById("joblog");
  if (!log) return;

  const start = { dev: 118, ai: 38, apps: 62, docs: 88, other: 96 };
  const creep = [
    ["dev", 9.4, "DerivedData", "xcodebuild MyApp"],
    ["dev", 3.1, "node_modules", "npm install · web-dashboard"],
    ["ai", 4.9, "Ollama", "ollama pull llama3.1:8b"],
    ["dev", 7.8, "Docker", "docker build ."],
    ["dev", 6.2, "Simulator", "iOS Simulator runtime download"],
    ["ai", 13.6, "Hugging Face", "model snapshot download"],
    ["dev", 11.7, "Cargo target/", "cargo build --release"],
    ["ai", 9.5, "Ollama", "ollama pull qwen2.5-coder:14b"],
    ["dev", 14.6, "DerivedData", "xcodebuild ClientApp"],
  ];
  const cleanup = [
    ["ok", "dev", -41.8, "DerivedData · 23 projects idle 14+ days"],
    ["ok", "dev", -18.6, "node_modules · 31 projects idle 60+ days"],
    ["ok", "dev", -9.4, "Cargo target/ · 4 projects idle 30+ days"],
    ["ask", "ai", 0, "12.4 GB Ollama · 2 models idle 90+ days → asks you first"],
  ];

  let state = {};
  let shownUsed = 0;
  const total = () => Object.values(state).reduce((a, b) => a + b, 0);

  function paint(animateNumber = true) {
    const used = total();
    for (const [key, el] of Object.entries(segments)) {
      el.style.flexGrow = key === "free" ? Math.max(CAPACITY - used, 0) : state[key];
    }
    const from = shownUsed;
    const t0 = performance.now();
    const step = (t) => {
      const k = animateNumber && !reduceMotion ? Math.min((t - t0) / 700, 1) : 1;
      shownUsed = from + (used - from) * (1 - Math.pow(1 - k, 3));
      usedEl.textContent = `${Math.round(shownUsed)} GB`;
      freeEl.textContent = `${Math.round(CAPACITY - shownUsed)} GB`;
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
    const [cls, text] = used >= 470 ? ["chip-crit", "● Almost full"] : used >= 440 ? ["chip-warn", "● Filling up"] : ["chip-good", "● Healthy"];
    statusEl.className = `chip ${cls}`;
    statusEl.textContent = text;
  }

  function line(cls, html) {
    const div = document.createElement("div");
    div.className = cls;
    div.innerHTML = html;
    log.appendChild(div);
    while (log.children.length > 14) log.firstElementChild.remove();
  }

  const gb = (n) => `${Math.abs(n).toFixed(1)} GB`;

  function reset() {
    state = { ...start };
    log.innerHTML = "";
    paint(false);
  }

  if (reduceMotion) {
    reset();
    for (const [key, delta] of creep) state[key] += delta;
    line("add", "<b>+80.8 GB</b> added by builds, installs and model pulls");
    line("run", "▸ Sun 03:00 · job “Dev caches” · automatic");
    for (const [kind, key, delta, text] of cleanup) {
      state[key] += delta;
      line(kind, kind === "ok" ? `✓ <b>−${gb(delta)}</b>  ${text}` : `? <b>${text.split(" · ")[0]}</b> · ${text.split(" · ").slice(1).join(" · ")}`);
    }
    line("sum", "Freed <b>69.8 GB</b> · moved to Trash · journaled");
    paint(false);
    return;
  }

  let visible = true;
  new IntersectionObserver(([entry]) => (visible = entry.isIntersecting)).observe(log);
  const waitVisible = async () => {
    while (!visible || document.hidden) await sleep(400);
  };

  (async function loop() {
    for (;;) {
      reset();
      await sleep(900);
      for (const [key, delta, what, cmd] of creep) {
        await waitVisible();
        state[key] += delta;
        line("add", `<b>+${gb(delta)}</b>  ${what.padEnd(13, " ").replace(/ /g, "&nbsp;")}<span>${cmd}</span>`);
        paint();
        await sleep(620);
      }
      await sleep(1100);
      line("run", "▸ Sun 03:00 · job “Dev caches” · automatic");
      await sleep(900);
      for (const [kind, key, delta, text] of cleanup) {
        await waitVisible();
        state[key] += delta;
        if (kind === "ok") line("ok", `✓ <b>−${gb(delta)}</b>  ${text}`);
        else {
          const [size, ...rest] = text.split(" · ");
          line("ask", `? <b>${size}</b> · ${rest.join(" · ")}`);
        }
        paint();
        await sleep(800);
      }
      line("sum", "Freed <b>69.8 GB</b> · moved to Trash · journaled");
      await sleep(5200);
    }
  })();
}

// ───────────── Tools marquee ─────────────

function marquee() {
  const track = document.getElementById("marquee");
  if (!track) return;
  const tools = [
    "Xcode", "SwiftPM", "CocoaPods", "Carthage", "node_modules", "npm", "pnpm", "Yarn", "Bun", "Deno", "Next.js",
    "Turborepo", "Python", "uv", "Poetry", "Conda", "Rust", "Cargo", "Go", "Gradle", "Maven", "Android Studio",
    "Flutter", "Dart", ".NET", "Ruby", "Docker", "OrbStack", "Colima", "Podman", "Homebrew", "VS Code", "Cursor",
    "Windsurf", "Zed", "JetBrains", "Postgres", "Ollama", "Hugging Face", "LM Studio", "PyTorch", "Whisper",
    "Claude Code", "Codex", "Playwright", "Cypress", "git worktrees",
  ];
  const html = tools.map((t) => `<span>${t}</span>`).join("");
  track.innerHTML = html + html.replace(/<span>/g, '<span aria-hidden="true">');
}

// ───────────── Line chart with crosshair tooltip ─────────────

function lineChart(host, { labels, series, yMax, yStep, capacity, xTicks, tooltipTitle, endLabels = true, area = false }) {
  // Draw at the container's own width (within limits) so labels stay readable on phones.
  const W = Math.round(Math.max(320, Math.min(640, host.clientWidth || 640)));
  const H = W < 480 ? 240 : 300;
  const m = { top: 16, right: endLabels ? (W < 480 ? 74 : 118) : 16, bottom: 30, left: 40 };
  const iw = W - m.left - m.right;
  const ih = H - m.top - m.bottom;
  const n = labels.length;
  const x = (i) => m.left + (i / (n - 1)) * iw;
  const y = (v) => m.top + ih - (v / yMax) * ih;

  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": host.dataset.label || "" });
  const grid = svg("g", { class: "grid" }, root);
  const axis = svg("g", { class: "axis" }, root);
  for (let v = 0; v <= yMax; v += yStep) {
    svg("line", { x1: m.left, x2: m.left + iw, y1: y(v), y2: y(v) }, grid);
    svg("text", { x: m.left - 8, y: y(v) + 4, "text-anchor": "end" }, axis).textContent = `${v}`;
  }
  for (const [i, text] of xTicks) {
    svg("text", { x: x(i), y: H - 8, "text-anchor": "middle" }, axis).textContent = text;
  }

  if (capacity) {
    svg("line", {
      x1: m.left, x2: m.left + iw, y1: y(capacity), y2: y(capacity),
      stroke: "var(--critical)", "stroke-width": 1.5, "stroke-dasharray": "5 5",
    }, root);
    svg("text", { x: m.left + 6, y: y(capacity) - 7, class: "label-muted" }, root).textContent = `Disk full · ${capacity} GB`;
  }

  const paths = [];
  for (const s of series) {
    const d = s.values.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)} ${y(v).toFixed(1)}`).join(" ");
    if (area && s.area) {
      const gradId = `g${Math.random().toString(36).slice(2, 8)}`;
      const defs = svg("defs", {}, root);
      const grad = svg("linearGradient", { id: gradId, x1: 0, x2: 0, y1: 0, y2: 1 }, defs);
      svg("stop", { offset: "0%", "stop-color": s.color, "stop-opacity": 0.28 }, grad);
      svg("stop", { offset: "100%", "stop-color": s.color, "stop-opacity": 0 }, grad);
      const areaPath = svg("path", { d: `${d} L${x(n - 1)} ${y(0)} L${x(0)} ${y(0)} Z`, fill: `url(#${gradId})`, opacity: 0 }, root);
      areaPath.style.transition = "opacity 1.2s ease 0.8s";
      paths.push({ el: areaPath, kind: "area" });
    }
    const path = svg("path", {
      d, fill: "none", stroke: s.color, "stroke-width": s.width ?? 2, "stroke-linejoin": "round", "stroke-linecap": "round",
    }, root);
    paths.push({ el: path, kind: "line" });
    if (endLabels) {
      const last = s.values[n - 1];
      svg("circle", { cx: x(n - 1), cy: y(last), r: 4, fill: s.color, stroke: "var(--surface)", "stroke-width": 2 }, root);
      const t = svg("text", { x: x(n - 1) + 10, y: y(last) + (s.labelDy ?? 0) + 4, class: "label" }, root);
      t.textContent = s.endLabel ?? `${Math.round(last)} GB`;
      if (s.endSub) {
        const sub = svg("text", { x: x(n - 1) + 10, y: y(last) + (s.labelDy ?? 0) + 19, class: "label-muted" }, root);
        sub.textContent = s.endSub;
      }
    }
  }

  // Hover layer: crosshair, a dot per series and one tooltip listing every series at that point.
  const cross = svg("line", { class: "crosshair", y1: m.top, y2: m.top + ih, opacity: 0 }, root);
  const dots = series.map((s) => svg("circle", { r: 4.5, fill: s.color, stroke: "var(--surface)", "stroke-width": 2, opacity: 0 }, root));
  const hit = svg("rect", { class: "hit", x: m.left, y: m.top, width: iw, height: ih }, root);
  const tip = document.createElement("div");
  tip.className = "tooltip";
  host.appendChild(root);
  host.appendChild(tip);

  function show(evt) {
    const box = root.getBoundingClientRect();
    const px = ((evt.clientX - box.left) / box.width) * W;
    const i = Math.max(0, Math.min(n - 1, Math.round(((px - m.left) / iw) * (n - 1))));
    cross.setAttribute("x1", x(i));
    cross.setAttribute("x2", x(i));
    cross.setAttribute("opacity", 1);
    series.forEach((s, k) => {
      dots[k].setAttribute("cx", x(i));
      dots[k].setAttribute("cy", y(s.values[i]));
      dots[k].setAttribute("opacity", 1);
    });
    tip.innerHTML =
      `<strong>${tooltipTitle(i)}</strong>` +
      series
        .map((s) => `<div class="row"><span class="swatch swatch-line" style="background:${s.color}"></span>${s.name}<b>${Math.round(s.values[i])} GB</b></div>`)
        .join("");
    const top = Math.min(...series.map((s) => y(s.values[i])));
    tip.style.left = `${(x(i) / W) * box.width}px`;
    tip.style.top = `${(top / H) * box.height}px`;
    tip.classList.add("show");
  }
  function hide() {
    cross.setAttribute("opacity", 0);
    dots.forEach((d) => d.setAttribute("opacity", 0));
    tip.classList.remove("show");
  }
  hit.addEventListener("pointermove", show);
  hit.addEventListener("pointerdown", show);
  hit.addEventListener("pointerleave", hide);

  // Draw the lines in when the chart scrolls into view.
  const play = () => {
    for (const { el, kind } of paths) {
      if (kind === "area") {
        el.setAttribute("opacity", 1);
        continue;
      }
      const len = el.getTotalLength();
      el.style.strokeDasharray = `${len}`;
      el.style.strokeDashoffset = `${len}`;
      el.getBoundingClientRect();
      el.style.transition = "stroke-dashoffset 1.8s cubic-bezier(0.45, 0, 0.2, 1)";
      el.style.strokeDashoffset = "0";
    }
  };
  if (reduceMotion) {
    paths.forEach(({ el, kind }) => kind === "area" && el.setAttribute("opacity", 1));
  } else {
    paths.forEach(({ el, kind }) => {
      if (kind === "line") el.style.strokeDasharray = el.style.strokeDashoffset = `${el.getTotalLength()}`;
    });
  }
  return { play };
}

// ───────────── Problem: creep chart + what grew ─────────────

const MONTHS = ["Nov", "Dec", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct"];
const CREEP = [236, 251, 262, 284, 297, 318, 341, 356, 389, 412, 447, 481];

function problem(onVisible) {
  const host = document.getElementById("creep-chart");
  if (!host) return;
  host.dataset.label = "Line chart: used space grows every month, from 236 GB in November to 481 GB in October, on a 494 GB disk.";
  const chart = lineChart(host, {
    labels: MONTHS,
    series: [{ name: "Used", color: "var(--c-dev)", values: CREEP, area: true, endLabel: "481 GB", endSub: "97% full", labelDy: 6 }],
    yMax: 500,
    yStep: 100,
    capacity: CAPACITY,
    area: true,
    xTicks: MONTHS.map((mo, i) => [i, mo]),
    tooltipTitle: (i) => `${MONTHS[i]} · ${Math.round((CREEP[i] / CAPACITY) * 100)}% full`,
  });

  const grew = [
    ["Xcode DerivedData", 62],
    ["Docker images & build cache", 48],
    ["AI models (Ollama, Hugging Face)", 41],
    ["node_modules", 37],
    ["iOS Simulators & DeviceSupport", 29],
    ["Package caches (npm, pip, Homebrew)", 28],
  ];
  const list = document.getElementById("grew-list");
  const max = Math.max(...grew.map(([, v]) => v));
  list.innerHTML = grew
    .map(([name, v]) => `<li title="${name}: +${v} GB"><span>${name}</span><span class="val">+${v} GB</span><span class="bar"><i data-w="${(v / max) * 100}"></i></span></li>`)
    .join("");

  onVisible(host.closest(".panel"), () => {
    chart.play();
    setTimeout(() => document.getElementById("creep-notif").classList.add("show"), reduceMotion ? 0 : 1700);
  });
  onVisible(list, () => list.querySelectorAll("i").forEach((el, k) => setTimeout(() => (el.style.width = `${el.dataset.w}%`), k * 90)));
}

// ───────────── Automation: with vs without ─────────────

function compare(onVisible) {
  const host = document.getElementById("compare-chart");
  if (!host) return;
  const weeks = 52;
  // Deterministic, slightly bumpy weekly growth that adds up to the same 245 GB as the creep chart.
  const raw = Array.from({ length: weeks }, (_, i) => 4.7 + 1.9 * Math.sin(i * 0.9) + (((i * 7) % 5) - 2) * 0.55);
  const scale = 245 / raw.reduce((a, b) => a + b, 0);
  const growth = raw.map((g) => g * scale);

  const without = [];
  const withJobs = [];
  let w = 236;
  let kept = 236; // your own files: about a fifth of the growth
  let leftovers = 0; // regenerable data, cleared by the jobs
  for (let i = 0; i < weeks; i++) {
    w += growth[i];
    kept += growth[i] * 0.2;
    leftovers += growth[i] * 0.8;
    without.push(w);
    withJobs.push(kept + leftovers);
    if (i % 2 === 1) leftovers *= 0.12; // a job runs every other Sunday once its size threshold is reached
  }
  const labels = Array.from({ length: weeks }, (_, i) => i);
  const monthAt = (i) => MONTHS[Math.min(11, Math.floor((i / weeks) * 12))];
  host.dataset.label = "Line chart: without SpaceKit used space climbs to 481 GB; with cleanup jobs it stays in a sawtooth under 300 GB.";

  const chart = lineChart(host, {
    labels,
    series: [
      { name: "Without SpaceKit", color: "#8a919c", values: without, endLabel: `${Math.round(without[weeks - 1])} GB`, endSub: "Without", labelDy: 8 },
      { name: "With jobs", color: "var(--c-dev)", values: withJobs, width: 2.5, endLabel: `${Math.round(withJobs[weeks - 1])} GB`, endSub: "With jobs" },
    ],
    yMax: 500,
    yStep: 100,
    capacity: CAPACITY,
    xTicks: [0, 2, 4, 6, 8, 10].map((k) => Math.ceil((k * weeks) / 12)).map((i) => [i, monthAt(i)]),
    tooltipTitle: (i) => `Week ${i + 1} · ${monthAt(i)}`,
  });

  const freeWith = Math.round(CAPACITY - withJobs[weeks - 1]);
  const freeWithout = Math.round(CAPACITY - without[weeks - 1]);
  document.getElementById("stat-with").textContent = `${freeWith} GB`;
  document.getElementById("stat-without").textContent = `Without SpaceKit: ${freeWithout} GB, and shrinking every week.`;
  onVisible(host.closest(".panel"), chart.play);
}

// ───────────── Job builder ─────────────

function builder() {
  const root = document.getElementById("builder");
  if (!root) return;

  const TARGETS = {
    derived: {
      label: "Xcode DerivedData", rules: ["xcode.derived-data"], size: 30, what: "old DerivedData",
      age: { key: "keepRecent", days: 14, label: "Keep projects used within", phrase: (d) => `except projects opened in the last ${d}` },
    },
    node: {
      label: "node_modules", rules: ["node.node-modules"], size: 10, what: "node_modules folders",
      age: { key: "olderThan", days: 60, label: "Only projects untouched for", phrase: (d) => `in projects untouched for ${d}` },
    },
    cargo: {
      label: "Rust target/", name: "Rust target folders", rules: ["cargo.target"], size: 20, what: "Cargo target folders",
      age: { key: "olderThan", days: 30, label: "Only projects untouched for", phrase: (d) => `in projects untouched for ${d}` },
    },
    device: {
      label: "iOS DeviceSupport", rules: ["xcode.ios-device-support"], size: 10, what: "iOS DeviceSupport files",
      age: { key: "olderThan", days: 90, label: "Only versions unused for", phrase: (d) => `unused for ${d}` },
    },
    caches: {
      label: "pip & Yarn caches", name: "Package caches", rules: ["python.pip-cache", "node.yarn-cache"], size: 5,
      what: "the pip and Yarn caches", age: null,
    },
    ollama: {
      label: "Ollama models", rules: ["ai.ollama.models"], size: 20, what: "Ollama models", review: true,
      age: { key: "olderThan", days: 90, label: "Only models unused for", phrase: (d) => `unused for ${d}` },
    },
  };
  const MODES = { observe: "Observe", suggest: "Suggest", automatic: "Automatic" };
  const SCHEDULES = {
    daily: { label: "Nightly", yaml: "daily at 03:00", phrase: "Every night at 03:00" },
    weekly: { label: "Weekly", yaml: "sunday 03:00", phrase: "Every Sunday at 03:00" },
    monthly: { label: "Monthly", yaml: "monthly", phrase: "On the 1st of every month" },
  };

  const state = { target: "derived", mode: "automatic", schedule: "weekly", size: 30, age: 14 };
  const size = document.getElementById("size");
  const age = document.getElementById("age");
  const ageField = document.getElementById("age-field");
  let previous = [];

  function segmented(field, options) {
    const group = root.querySelector(`[data-field="${field}"]`);
    group.innerHTML = Object.entries(options)
      .map(([key, o]) => `<button type="button" data-value="${key}" aria-pressed="${state[field] === key}">${typeof o === "string" ? o : o.label}</button>`)
      .join("");
    group.addEventListener("click", (e) => {
      const button = e.target.closest("button");
      if (!button) return;
      state[field] = button.dataset.value;
      if (field === "target") {
        const t = TARGETS[state.target];
        state.size = t.size;
        if (t.age) state.age = t.age.days;
      }
      group.querySelectorAll("button").forEach((b) => b.setAttribute("aria-pressed", b === button));
      render();
    });
  }

  const days = (d) => `${d} day${d === 1 ? "" : "s"}`;

  function yamlLines() {
    const t = TARGETS[state.target];
    const lines = [
      ["jobs:"],
      [`  - name: ${t.name ?? t.label}`],
      [`    rules: [${t.rules.join(", ")}]`],
      [`    mode: ${state.mode}`],
      [`    schedule: ${SCHEDULES[state.schedule].yaml}`],
      ["    when:"],
      [`      sizeAbove: ${state.size}GB`],
    ];
    if (t.age && state.mode !== "observe") lines.push([`      ${t.age.key}: ${state.age}d`]);
    if (t.review && state.mode === "automatic") lines.push(["    includeReview: true", "models are 🟡 review items"]);
    return lines;
  }

  function highlight([text, comment]) {
    const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
    const m = text.match(/^(\s*-?\s*)([A-Za-z]+):(\s*)(.*)$/);
    let html = esc(text);
    if (m) {
      const [, indent, key, gap, value] = m;
      let v = esc(value);
      if (/^\[.*\]$/.test(value)) v = `[<span class="s">${esc(value.slice(1, -1))}</span>]`;
      else if (/^\d/.test(value) || value === "true") v = `<span class="n">${v}</span>`;
      else if (value) v = `<span class="s">${v}</span>`;
      html = `${esc(indent)}<span class="k">${key}</span>:${gap}${v}`;
    }
    if (comment) html += `   <span class="c"># ${esc(comment)}</span>`;
    return html;
  }

  function render() {
    const t = TARGETS[state.target];
    size.value = state.size;
    document.getElementById("size-out").textContent = `${state.size} GB`;
    const showAge = Boolean(t.age) && state.mode !== "observe";
    ageField.style.display = showAge ? "" : "none";
    if (t.age) {
      age.value = state.age;
      document.getElementById("age-label").textContent = t.age.label;
      document.getElementById("age-out").textContent = days(state.age);
    }

    const lines = yamlLines();
    const yaml = document.getElementById("yaml");
    yaml.innerHTML = lines
      .map((line, i) => {
        const html = highlight(line);
        const changed = previous.length && previous[i] !== line[0];
        return changed ? `<span class="flash">${html}</span>` : html;
      })
      .join("\n");
    previous = lines.map((l) => l[0]);
    yaml.dataset.plain = lines.map(([text, comment]) => (comment ? `${text}   # ${comment}` : text)).join("\n");

    const when = SCHEDULES[state.schedule].phrase;
    const name = t.name ?? t.label;
    const scope = t.age ? ` ${t.age.phrase(days(state.age))}` : "";
    const cond = `if ${name} is bigger than <b>${state.size} GB</b>`;
    let sentence;
    if (state.mode === "observe") sentence = `${when}, ${cond}, <b>notify me</b>. Nothing is removed.`;
    else if (state.mode === "suggest") sentence = `${when}, ${cond}, <b>prepare a cleanup</b> of ${t.what}${scope} and wait for my approval.`;
    else sentence = `${when}, ${cond}, <b>move ${t.what}${scope} to the Trash</b> and notify me.`;
    if (t.review && state.mode === "automatic") sentence += " Models take a while to download again, so this job opts in with <code>includeReview</code>.";
    document.getElementById("plain").innerHTML = sentence;
  }

  segmented("target", Object.fromEntries(Object.entries(TARGETS).map(([k, t]) => [k, t.label])));
  segmented("mode", MODES);
  segmented("schedule", SCHEDULES);
  size.addEventListener("input", () => {
    state.size = Number(size.value);
    render();
  });
  age.addEventListener("input", () => {
    state.age = Number(age.value);
    render();
  });

  const copy = document.getElementById("copy-yaml");
  copy.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(document.getElementById("yaml").dataset.plain);
      copy.textContent = "Copied ✓";
    } catch {
      copy.textContent = "Select & copy";
    }
    setTimeout(() => (copy.textContent = "Copy"), 1800);
  });

  render();
}

// ───────────── Decorative sunburst ─────────────

function sunburst() {
  const root = document.getElementById("sunburst");
  if (!root) return;
  const data = [
    ["var(--c-dev)", 170, [0.34, 0.22, 0.16, 0.12, 0.16]],
    ["var(--c-apps)", 62, [0.4, 0.25, 0.35]],
    ["var(--c-ai)", 66, [0.55, 0.3, 0.15]],
    ["var(--c-docs)", 88, [0.3, 0.3, 0.2, 0.2]],
    ["var(--c-other)", 96, [0.5, 0.5]],
  ];
  const total = data.reduce((a, [, v]) => a + v, 0);
  const arc = (r0, r1, a0, a1) => {
    const p = (r, a) => `${(r * Math.sin(a)).toFixed(2)} ${(-r * Math.cos(a)).toFixed(2)}`;
    const large = a1 - a0 > Math.PI ? 1 : 0;
    return `M${p(r1, a0)} A${r1} ${r1} 0 ${large} 1 ${p(r1, a1)} L${p(r0, a1)} A${r0} ${r0} 0 ${large} 0 ${p(r0, a0)} Z`;
  };
  let a = 0;
  for (const [color, value, children] of data) {
    const span = (value / total) * Math.PI * 2;
    svg("path", { d: arc(34, 70, a, a + span), fill: color }, root);
    let b = a;
    children.forEach((share, k) => {
      const s = span * share;
      svg("path", { d: arc(72, 72 + 18 + ((k * 13) % 26), b, b + s), fill: color, "fill-opacity": 0.72 - (k % 3) * 0.14 }, root);
      b += s;
    });
    a += span;
  }
  const t = svg("text", { x: 0, y: -2, "text-anchor": "middle", fill: "var(--text)", "font-size": 15, "font-weight": 650 }, root);
  t.textContent = "482 GB";
  const u = svg("text", { x: 0, y: 14, "text-anchor": "middle", fill: "var(--text-3)", "font-size": 10 }, root);
  u.textContent = "used";
}

// ───────────── Reveal on scroll ─────────────

function onVisibleFactory() {
  const callbacks = new Map();
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("visible");
        const cbs = callbacks.get(entry.target);
        if (cbs) cbs.forEach((cb) => cb());
        callbacks.delete(entry.target);
        observer.unobserve(entry.target);
      }
    },
    { threshold: 0.25 },
  );
  document.querySelectorAll(".reveal").forEach((el) => observer.observe(el));
  return (el, cb) => {
    if (!el) return;
    if (!callbacks.has(el)) callbacks.set(el, []);
    callbacks.get(el).push(cb);
    observer.observe(el);
  };
}

const onVisible = onVisibleFactory();
hero();
marquee();
problem(onVisible);
builder();
compare(onVisible);
sunburst();
