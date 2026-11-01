import { createHash } from "node:crypto";
import assert from "node:assert/strict";
import { access, readFile, readdir } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const siteRoot = resolve(new URL("..", import.meta.url).pathname);
const outputRoot = join(siteRoot, "public");
const index = await readFile(join(outputRoot, "index.html"), "utf8");
const css = await readFile(join(outputRoot, "style.css"), "utf8");
const script = await readFile(join(outputRoot, "script.js"), "utf8");
const product = await readFile(join(siteRoot, "data/product.toml"), "utf8");

async function htmlFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await htmlFiles(path));
    else if (entry.name.endsWith(".html")) files.push(path);
  }
  return files;
}

const pages = await htmlFiles(outputRoot);

function attrValues(html, attribute) {
  return [...html.matchAll(new RegExp(`${attribute}="([^"]+)"`, "g"))].map((match) => match[1]);
}

function pngDimensions(buffer) {
  assert.equal(buffer.toString("ascii", 1, 4), "PNG", "asset must be a PNG");
  return {
    width: buffer.readUInt32BE(16),
    height: buffer.readUInt32BE(20),
  };
}

test("renders a complete VocaMac homepage", () => {
  assert.match(index, /<title>VocaMac: Free On-Device Voice to Text and Dictation for Mac<\/title>/);
  assert.equal((index.match(/<h1\b/g) ?? []).length, 1);
  assert.match(index, /<main id="main">/);
  assert.match(index, /class="skip-link" href="#main"/);
  assert.match(index, /<header[^>]+data-header/);
  assert.match(index, /<footer class="site-footer">/);
});

test("keeps navigation and anchors accessible", () => {
  assert.match(index, /data-nav-toggle[^>]+aria-expanded="false"[^>]+aria-controls="mobile-nav"/);
  assert.match(index, /<nav[^>]+id="mobile-nav"[^>]+aria-label="Site"/);

  const ids = [...index.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
  assert.equal(new Set(ids).size, ids.length, "homepage IDs must be unique");
  for (const target of attrValues(index, "href").filter((href) => href.startsWith("#"))) {
    assert.ok(ids.includes(target.slice(1)), `missing in-page target ${target}`);
  }
});

test("keeps the PRODUCT.md product boundary explicit", () => {
  assert.match(index, /v1\.2\.0/);
  assert.match(index, /macOS 14\+|macOS 14 Sonoma/);
  assert.match(index, /Apple Silicon/);
  assert.match(index, /WhisperKit/);
  assert.match(index, /model downloads/i);
  assert.match(index, /Available now/);
  assert.match(index, /includes Parakeet/i);
  assert.match(index, /Additional engines and models available in v1\.2\.0/i);
  assert.match(index, /Parakeet/);
  assert.match(index, /sherpa-onnx/);
  assert.doesNotMatch(index, /macOS 13/);
  assert.doesNotMatch(index, /Zero Network Calls/i);
  assert.doesNotMatch(index, /100% Offline/i);
  assert.doesNotMatch(index, /Works in All Apps/i);
  assert.doesNotMatch(index, /99\+ Languages/i);
  assert.doesNotMatch(index, /remove local models/i);
  assert.match(product, /status = "Available now"/);
  assert.match(product, /osShort = "macOS 14\+"/);
  assert.match(product, /count = 43/);
  assert.doesNotMatch(product, /count = 37/);
});

test("uses local assets and accurate social metadata", async () => {
  for (const asset of ["/style.css", "/script.js", "/brand/voca-logo.svg", "/brand/paper-dots.svg", "/og-image.png", "/CNAME"]) {
    await access(join(outputRoot, asset));
  }
  assert.equal((await readFile(join(outputRoot, "CNAME"), "utf8")).trim(), "vocamac.com");

  assert.match(index, /rel="canonical" href="https:\/\/vocamac\.com\/"/);
  assert.match(index, /property="og:image:secure_url"/);
  assert.match(index, /property="og:image:type" content="image\/png"/);
  assert.match(index, /property="og:image:width" content="1200"/);
  assert.match(index, /property="og:image:height" content="630"/);
  assert.deepEqual(pngDimensions(await readFile(join(outputRoot, "og-image.png"))), { width: 1200, height: 630 });
});

test("emits valid structured metadata", () => {
  const jsonLd = index.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)?.[1];
  assert.ok(jsonLd, "homepage JSON-LD is present");
  const structured = JSON.parse(jsonLd);
  assert.equal(structured["@type"], "SoftwareApplication");
  assert.equal(structured.softwareVersion, "1.2.0");
  assert.equal(structured.processorRequirements, "Apple Silicon");
});

function jsonLdBlocks(html) {
  return [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((match) => JSON.parse(match[1]));
}

test("names the site and gives every subpage a breadcrumb trail", async () => {
  const website = jsonLdBlocks(index).find((block) => block["@type"] === "WebSite");
  assert.equal(website?.name, "VocaMac");
  assert.equal(website?.url, "https://vocamac.com/");
  assert.ok(!jsonLdBlocks(index).some((block) => block["@type"] === "BreadcrumbList"), "home has no breadcrumb");

  for (const page of pages) {
    const rel = relative(outputRoot, page);
    if (rel === "index.html" || rel === "404.html") continue;
    const html = await readFile(page, "utf8");
    const canonical = html.match(/rel="canonical" href="([^"]+)"/)[1];
    const trail = jsonLdBlocks(html).find((block) => block["@type"] === "BreadcrumbList");
    assert.ok(trail, `${rel} has a BreadcrumbList`);
    const items = trail.itemListElement;
    assert.equal(items[0].item, "https://vocamac.com/", `${rel} starts at the home page`);
    assert.equal(items.at(-1).item, canonical, `${rel} ends at its own canonical URL`);
    assert.deepEqual(items.map((item) => item.position), items.map((_, i) => i + 1));
    if (rel.startsWith("features/") && rel !== "features/index.html") {
      assert.equal(items.length, 3, `${rel} sits under Features`);
      assert.equal(items[1].item, "https://vocamac.com/features/");
    }
  }
});

test("does not add review, rating, FAQ or HowTo markup", async () => {
  for (const page of pages) {
    const html = await readFile(page, "utf8");
    assert.doesNotMatch(html, /aggregateRating|"Review"|"FAQPage"|"HowTo"/, relative(outputRoot, page));
  }
});

test("keeps the visual and privacy boundaries flat", () => {
  const banned = ["linear-gradient", "radial-gradient", "conic-gradient", "backdrop-filter"];
  for (const token of banned) assert.doesNotMatch(css, new RegExp(token, "i"), `unexpected ${token}`);
  assert.match(css, /prefers-reduced-motion:\s*reduce/);
  assert.match(css, /overflow-x:\s*hidden/);
  assert.doesNotMatch(index, /googletagmanager|google-analytics|gtag\(/i);
  assert.doesNotMatch(script, /api\.github\.com|fetch\(/i);
});

test("keeps Windows Chrome headlines on a real sans stack", () => {
  assert.match(
    css,
    /--display:\s*"Avenir Next",\s*"Helvetica Neue",\s*ui-sans-serif,\s*system-ui,\s*"Segoe UI",\s*Arial,\s*sans-serif/,
  );
  assert.doesNotMatch(css, /SF Pro Display/);
  assert.doesNotMatch(css, /@font-face/);
  assert.doesNotMatch(css, /fonts\.google/);
  assert.doesNotMatch(index, /fonts\.google|fonts\.gstatic|typekit|use\.typekit/i);

  assert.match(css, /h1,\s*h2,\s*h3,\s*h4\s*\{[^}]*font-family:\s*var\(--display\)/);
  assert.match(css, /h1,\s*h2,\s*h3,\s*h4\s*\{[^}]*font-weight:\s*760/);
  assert.match(css, /h1,\s*h2,\s*h3,\s*h4\s*\{[^}]*letter-spacing:\s*-0?\.065em/);
  assert.match(css, /h1 em,\s*h2 em,\s*h3 em,\s*h4 em\s*\{[^}]*font-family:\s*var\(--display\)/);
  assert.match(css, /\.hero h1 em\s*\{[^}]*color:\s*var\(--teal\)/);
  assert.match(css, /\.hero h1 em\s*\{[^}]*font-family:\s*var\(--display\)/);
  assert.match(css, /\.hero h1 em\s*\{[^}]*font-style:\s*normal/);
  assert.match(css, /\.hero h1\s*\{[^}]*font-size:\s*clamp\(3\.7rem,\s*10vw,\s*7\.4rem\)/);
  assert.match(css, /\.hero h1\s*\{[^}]*font-weight:\s*780/);
  assert.match(css, /\.hero h1\s*\{[^}]*letter-spacing:\s*-0?\.075em/);
  assert.match(css, /\.hero h1\s*\{[^}]*line-height:\s*0?\.92/);
  assert.match(css, /\.section-title\s*\{[^}]*font-size:\s*clamp\(2\.2rem,\s*6vw,\s*4\.7rem\)/);
  assert.match(css, /\.section-title\s*\{[^}]*font-weight:\s*760/);
  assert.match(css, /\.section-title\s*\{[^}]*letter-spacing:\s*-0?\.065em/);
  assert.match(css, /\.section-title\s*\{[^}]*line-height:\s*1\.06/);
  assert.match(index, /<h1 id="hero-title">Say it once\.<br><em>Your Mac types\.<\/em><\/h1>/);
});

test("keeps content available without javascript", () => {
  assert.match(index, /<details[^>]+open/);
  assert.match(index, /<summary>Does my voice leave my Mac\?<\/summary>/);
  assert.match(index, /brew install --cask vocamac/);
  assert.match(index, /Download v1\.2\.0 DMG/);
  assert.match(script, /IntersectionObserver/);
  assert.match(script, /setTimeout\(function \(\) \{ revealItems\.forEach\(reveal\); \}, 800\)/);
  assert.match(script, /event\.key === "Escape"/);
  assert.match(script, /showModal\(\)/);
  assert.match(script, /shot-lightbox/);
});

test("keeps the screenshot tour readable before its controls initialize", () => {
  const controls = [...index.matchAll(/data-tour-button[^>]+aria-controls="([^"]+)"/g)].map((match) => match[1]);
  const panels = [...index.matchAll(/<figure class="tour-panel" id="([^"]+)" data-tour-panel>/g)].map((match) => match[1]);
  assert.deepEqual(controls, ["tour-ready", "tour-models", "tour-feedback"]);
  assert.deepEqual(panels, controls);
  assert.doesNotMatch(index, /<figure class="tour-panel"[^>]+hidden/);
  assert.match(css, /\.tour-panel\[hidden\]\s*\{\s*display:\s*none/);
});

test("screenshot choices show only their matching panel", () => {
  const ids = ["tour-ready", "tour-models", "tour-feedback"];
  const panels = ids.map((id) => ({ id, hidden: false }));
  const choices = ids.map((id) => {
    const attributes = { "aria-controls": id, "aria-pressed": "false" };
    const listeners = {};
    return {
      attributes,
      listeners,
      getAttribute: (name) => attributes[name],
      setAttribute: (name, value) => { attributes[name] = value; },
      addEventListener: (name, callback) => { listeners[name] = callback; },
    };
  });
  const classes = new Set();
  const tour = {
    classList: { add: (name) => classes.add(name) },
    querySelectorAll: (selector) => selector === "[data-tour-button]" ? choices : panels,
  };
  const document = {
    querySelector: (selector) => selector === "[data-product-tour]" ? tour : null,
    querySelectorAll: () => [],
  };

  runInNewContext(script, {
    document,
    window: { matchMedia: () => ({ matches: false }) },
    navigator: {},
  });

  assert.ok(classes.has("js-tour"));
  for (const [selected, choice] of choices.entries()) {
    choice.listeners.click();
    for (const [index, panel] of panels.entries()) {
      assert.equal(panel.hidden, index !== selected);
      assert.equal(choices[index].attributes["aria-pressed"], index === selected ? "true" : "false");
    }
  }
});

test("every rendered page has one heading and image alternatives", async () => {
  for (const page of pages) {
    const html = page === join(outputRoot, "index.html") ? index : await readFile(page, "utf8");
    assert.equal((html.match(/<h1\b/g) ?? []).length, 1, `${relative(outputRoot, page)} must have one h1`);
    for (const image of html.matchAll(/<img\b[^>]*>/g)) {
      // Hugo's minifier may serialize an empty decorative alt as a boolean
      // attribute (`alt`); informative images retain their text value.
      assert.match(image[0], /\balt(?:="[^"]*"|\b)/);
      if (!image[0].includes('/brand/')) {
        assert.match(image[0], /\bwidth="\d+"/);
        assert.match(image[0], /\bheight="\d+"/);
        assert.match(image[0], /\bloading="lazy"/);
      }
    }
  }
});

test("keeps the site-audit copy and a11y fixes", async () => {
  assert.match(index, /Selected on-device engine/);
  assert.match(index, /WhisperKit\/CoreML, Parakeet, Apple Speech, ONNX/);
  assert.doesNotMatch(
    index,
    /<span class="route-name">WhisperKit \/ CoreML<\/span>/,
  );
  assert.match(
    index,
    /<span class="status-badge"><i aria-hidden="true"><\/i> on-device<\/span>/,
  );
  assert.doesNotMatch(
    index,
    /<span class="status-badge"><i aria-hidden="true"><\/i> local<\/span>/,
  );

  const clipboard = await readFile(
    join(outputRoot, "features/clipboard-preservation/index.html"),
    "utf8",
  );
  assert.match(clipboard, /On-device transcription after model download/);
  assert.doesNotMatch(clipboard, /Works offline/);

  const enterprise = await readFile(join(outputRoot, "enterprise/index.html"), "utf8");
  assert.doesNotMatch(enterprise, /aria-labelledby="content-title"/);
  assert.doesNotMatch(enterprise, /id="content-title"/);

  for (const page of pages) {
    const rel = relative(outputRoot, page);
    if (!rel.startsWith("features/") || rel === "features/index.html") continue;
    const html = await readFile(page, "utf8");
    assert.doesNotMatch(html, /aria-labelledby="feature-content-title"/);
    assert.doesNotMatch(html, /id="feature-content-title"/);
  }

  assert.match(script, /aria-live", "polite"/);
  assert.match(script, /announceCopy\(label\)/);
  assert.match(script, /copyFeedbackToken/);
  assert.match(script, /clearTimeout\(copyFeedbackTimer\)/);
  assert.match(script, /requestToken = \+\+copyFeedbackToken/);
  assert.match(script, /showCopyFeedback\(button, "Copied", requestToken\)/);
  assert.match(script, /showCopyFeedback\(button, "Press ⌘C", requestToken\)/);
  assert.match(script, /if \(token !== copyFeedbackToken\)/);

  const ogSvg = await readFile(join(siteRoot, "static/og-image.svg"), "utf8");
  assert.match(ogSvg, /v1\.2\.0/);
  assert.doesNotMatch(ogSvg, /beta/i);
  assert.match(ogSvg, /ON-DEVICE/);
  assert.doesNotMatch(ogSvg, />LOCAL</);

  // Regenerating web/static/og-image.png requires updating this digest.
  const ogPng = await readFile(join(outputRoot, "og-image.png"));
  assert.equal(
    createHash("sha256").update(ogPng).digest("hex"),
    "9c8ce22ac54d717fd5f4583b965cb48ef6c921d713b52c2e43ef1ccdefddeca4",
  );

  const languages = await readFile(join(outputRoot, "features/languages/index.html"), "utf8");
  assert.match(languages, /43 language hints/);
  assert.doesNotMatch(languages, /37 language hints/);
});

test("all rendered local references resolve", async () => {
  const references = new Set();
  for (const page of pages) {
    const html = await readFile(page, "utf8");
    for (const value of [...attrValues(html, "src"), ...attrValues(html, "href")]) {
      if (!value.startsWith("/") || value.startsWith("/#") || value === "/") continue;
      references.add(value.split("#")[0].split("?")[0]);
    }
  }

  for (const reference of references) {
    const file = join(outputRoot, reference);
    try {
      await access(file);
    } catch {
      await access(join(file, "index.html"));
    }
  }
});

test("every feature page links onward and is linked from other feature pages", async () => {
  const featurePages = pages
    .map((page) => relative(outputRoot, page))
    .filter((rel) => rel.startsWith("features/") && rel !== "features/index.html");
  const inbound = new Map(featurePages.map((rel) => [`/${rel.replace(/index\.html$/, "")}`, 0]));

  for (const rel of featurePages) {
    const html = await readFile(join(outputRoot, rel), "utf8");
    const related = html.match(/<section class="related-features"[\s\S]*?<\/section>/)?.[0];
    assert.ok(related, `${rel} has a related-features block`);
    const links = attrValues(related, "href").filter((href) => href.startsWith("/features/") && href !== "/features/");
    assert.ok(links.length >= 3, `${rel} links to at least three related features`);
    assert.ok(!links.includes(`/${rel.replace(/index\.html$/, "")}`), `${rel} does not link to itself`);
    for (const href of links) inbound.set(href, (inbound.get(href) ?? 0) + 1);
  }
  for (const [href, count] of inbound) assert.ok(count >= 1, `${href} is linked from another feature page`);
});

test("ships a playable 404 page whose assets stay on that page", async () => {
  const notFound = await readFile(join(outputRoot, "404.html"), "utf8");
  assert.equal((notFound.match(/<h1\b/g) ?? []).length, 1);
  assert.match(notFound, /<a class="btn btn-primary" href="\/"/);
  assert.match(notFound, /href="\/features\/"/);
  assert.match(notFound, /href="\/#install"/);
  assert.match(notFound, /<link rel="stylesheet" href="\/404\.css">/);
  assert.match(notFound, /<script src="\/404\.js" defer><\/script>/);
  assert.match(notFound, /href="https:\/\/xkcd\.com\/1172\/"/);
  assert.doesNotMatch(notFound, /<img\b[^>]+xkcd/i);

  const pageScript = await readFile(join(outputRoot, "404.js"), "utf8");
  const pageStyle = await readFile(join(outputRoot, "404.css"), "utf8");
  assert.ok(pageScript.length < 10_000, "404.js stays under 10 KB");
  assert.ok(pageStyle.length < 10_000, "404.css stays under 10 KB");
  assert.doesNotMatch(pageScript, /fetch\(|XMLHttpRequest|https?:\/\//);
  for (const token of ["linear-gradient", "radial-gradient", "conic-gradient", "backdrop-filter"]) {
    assert.doesNotMatch(pageStyle, new RegExp(token, "i"), `unexpected ${token} in 404.css`);
  }
  assert.match(pageStyle, /prefers-reduced-motion:\s*reduce/);

  for (const page of pages) {
    if (page === join(outputRoot, "404.html")) continue;
    const html = page === join(outputRoot, "index.html") ? index : await readFile(page, "utf8");
    assert.doesNotMatch(html, /\/404\.(?:js|css)/, `${relative(outputRoot, page)} must not load 404 assets`);
  }

  const sitemap = await readFile(join(outputRoot, "sitemap.xml"), "utf8");
  assert.doesNotMatch(sitemap, /404/);
});

test("keeps site claims aligned with the v1.2.0 release", async () => {
  assert.doesNotMatch(index, /Custom vocabulary is processed with the Whisper path/);
  assert.doesNotMatch(index, /In-memory audio|captured in memory/);
  assert.match(index, /Does my voice leave my Mac\?<\/summary><p>[^<]*<a href="\/features\/custom-endpoint\/">Custom Endpoint<\/a>/);
  assert.doesNotMatch(product, /\+ Japanese/);

  const feature = (slug) => readFile(join(outputRoot, `features/${slug}/index.html`), "utf8");
  const cleanup = await feature("transcript-cleanup");
  assert.doesNotMatch(cleanup, /never sent anywhere|without anything leaving your Mac/);
  assert.match(cleanup, /Settings → Smart Cleanup/);
  assert.match(cleanup, /Ministral 3 3B Instruct/);
  assert.doesNotMatch(await feature("silence-detection"), /0\.3 seconds|0-100%/);
  assert.doesNotMatch(await feature("clipboard-preservation"), /200 milliseconds|recording \*?<em>started/);
  assert.doesNotMatch(await feature("github-release-updates"), /Debug tab/);
  assert.match(await feature("translation"), /Translate what you say/);
});
