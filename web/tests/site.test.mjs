import assert from "node:assert/strict";
import { access, readFile, readdir } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { test } from "node:test";

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
  assert.match(index, /<title>VocaMac — native voice typing for macOS, transcribed on your Mac<\/title>/);
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

test("keeps the stable product boundary explicit", () => {
  assert.match(index, /v0\.7\.2/);
  assert.match(index, /macOS 13\+|macOS 13 Ventura/);
  assert.match(index, /Apple Silicon/);
  assert.match(index, /WhisperKit/);
  assert.match(index, /model downloads/i);
  assert.match(index, /Stable release/);
  assert.match(index, /Additional engine work is currently shipped in nightly\/source channels/i);
  assert.doesNotMatch(index, /beta/i);
  assert.doesNotMatch(index, /Zero Network Calls/i);
  assert.doesNotMatch(index, /100% Offline/i);
  assert.doesNotMatch(index, /Works in All Apps/i);
  assert.doesNotMatch(index, /99\+ Languages/i);
  assert.doesNotMatch(index, /remove local models/i);
  assert.match(product, /status = "Stable release"/);
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
  assert.equal(structured.softwareVersion, "0.7.2");
  assert.equal(structured.processorRequirements, "Apple Silicon");
});

test("keeps the visual and privacy boundaries flat", () => {
  const banned = ["linear-gradient", "radial-gradient", "conic-gradient", "backdrop-filter"];
  for (const token of banned) assert.doesNotMatch(css, new RegExp(token, "i"), `unexpected ${token}`);
  assert.match(css, /prefers-reduced-motion:\s*reduce/);
  assert.match(css, /overflow-x:\s*hidden/);
  assert.doesNotMatch(index, /googletagmanager|google-analytics|gtag\(/i);
  assert.doesNotMatch(script, /api\.github\.com|fetch\(/i);
});

test("keeps content available without javascript", () => {
  assert.match(index, /<details[^>]+open/);
  assert.match(index, /<summary>Does my voice leave my Mac\?<\/summary>/);
  assert.match(index, /brew install --cask vocamac/);
  assert.match(index, /Download v0\.7\.2 DMG/);
  assert.match(script, /IntersectionObserver/);
  assert.match(script, /setTimeout\(function \(\) \{ revealItems\.forEach\(reveal\); \}, 800\)/);
  assert.match(script, /event\.key === "Escape"/);
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
