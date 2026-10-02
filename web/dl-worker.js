// fizzy's plugin download and image proxy — a Cloudflare Worker (`/dl/*`, `/img/*`).
//
// **Why it exists.** A plugin publishes one set of binaries, wherever its author likes, and the
// registry records the URLs. On the desktop fizzy downloads them directly. A browser cannot: it
// may only read a response whose host sends `access-control-allow-origin`, and GitHub release
// assets — how every plugin ships today — send none. That is a rule about the *client*, not a
// property of the file, so it is answered on the client's side rather than by making every
// author publish a second copy somewhere CORS-friendly. The web app tries the URL directly first
// and only falls back to here, so a host that does send CORS never touches this Worker.
//
// **What it will fetch.** Only a URL the catalog publishes for the asking build. The request
// carries the caller's ABI fingerprint — `/dl/<fingerprint>/<encoded url>` — and the Worker
// checks the URL against that shard, which is the same file the app itself reads to decide what
// it may install. So this cannot be used as a general proxy, and the allowlist needs no
// maintenance: registering a plugin is what adds it.
//
// **What it does not do.** It does not check the sha256. The page does that, against the hash
// the registry published, before the module is compiled — which is the point: the page cannot
// trust this Worker any more than it trusts the origin, so the check belongs at the end of the
// pipe, not in the middle of it.
//
// **Images, on `/img/<encoded url>`.** Markdown in the web app — store READMEs, a user's notes —
// shows remote images, and the app can only draw one whose pixels it can read, which is the same
// CORS rule. Drawn as pixels, an image is an ordinary texture: it sits under menus, is frosted
// behind a flyout, takes the theme's corners. So an image whose host sends no CORS header comes
// through here. This route is not limited to a catalog — a note may embed anything — so it is
// limited by what it returns and to whom: https in, `image/*` out, at most `MAX_IMAGE_BYTES`, and
// only for pages on `IMAGE_ORIGINS`. A non-browser client can claim any Origin; the rest still
// holds, and Cloudflare's cache keeps a repeated URL off the upstream.
//
// Deploy: `npx wrangler deploy --config web/wrangler.toml`.

const CATALOG = "https://plugins.fizzyed.it/catalog";

// A shard changes when a plugin is released, not when someone installs one. Ten minutes of
// staleness costs a user one retry after a brand-new release; re-reading it per download would
// cost every user a round trip.
const SHARD_TTL_SECONDS = 600;

// An ABI fingerprint as the catalog spells it: `0x` and 16 hex digits. Checked before it reaches
// a URL, so a request can never name a path of its own.
const FINGERPRINT = /^0x[0-9a-f]{1,16}$/;

// Pages the image route answers: the deployed app and a local `zig build web` server.
const IMAGE_ORIGINS = [/^https:\/\/fizzyed\.it$/, /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/];

// A README image past this is a mistake, and the app refuses to decode one this large anyway.
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;

export default {
  async fetch(request) {
    if (request.method === "OPTIONS") return preflight();
    if (request.method !== "GET" && request.method !== "HEAD") return problem(405, "only GET");

    const url = new URL(request.url);
    if (url.pathname.startsWith("/img/")) return image(request, url);
    if (!url.pathname.startsWith("/dl/")) return problem(404, "not a download path");

    // `/dl/<fingerprint>/<encoded url>` — everything after the second slash is the target,
    // undecoded as one piece so a query string survives.
    const rest = url.pathname.slice("/dl/".length);
    const slash = rest.indexOf("/");
    if (slash < 0) return problem(400, "expected /dl/<abi_fingerprint>/<url>");
    const fingerprint = rest.slice(0, slash).toLowerCase();
    if (!FINGERPRINT.test(fingerprint)) return problem(400, "not an abi fingerprint");

    const target = decodeURIComponent(rest.slice(slash + 1)) + url.search;
    let parsed;
    try {
      parsed = new URL(target);
    } catch {
      return problem(400, "not a URL");
    }
    if (parsed.protocol !== "https:") return problem(400, "https only");

    const published = await shardUrls(fingerprint);
    if (!published.has(parsed.toString())) {
      // Deliberately not "forbidden host": what is allowed is a download *this build could
      // install*, so a plugin that is not in the registry is simply not here.
      return problem(403, "not a published download for " + fingerprint);
    }

    const upstream = await download(parsed.toString());
    if (!upstream.ok) return problem(upstream.status, "upstream said " + upstream.status);

    const headers = new Headers();
    headers.set("access-control-allow-origin", "*");
    headers.set("cache-control", "public, max-age=86400, immutable");
    headers.set("content-type", upstream.headers.get("content-type") ?? "application/wasm");
    const len = upstream.headers.get("content-length");
    if (len) headers.set("content-length", len);
    return new Response(request.method === "HEAD" ? null : upstream.body, { status: 200, headers });
  },
};

/**
 * A published download, from Cloudflare's cache when it holds the file.
 *
 * Only a success is kept. `cacheTtl` alone kept *whatever* came back for a day, so one bad answer
 * pinned a release as undownloadable — zig 0.2.28's wasm was served a cached non-ok response in
 * 13ms while every other build went through. A redirect is not kept either: GitHub's points at a
 * signed URL that expires within the hour. A failure is asked of the origin again, past the
 * cache, before it is reported.
 */
async function download(target) {
  const cached = await fetch(target, {
    redirect: "follow",
    // Immutable and often a few MB; let Cloudflare keep it.
    cf: { cacheEverything: true, cacheTtlByStatus: { "200-299": 86400, "300-599": -1 } },
  });
  if (cached.ok) return cached;
  return fetch(target, { redirect: "follow", cache: "no-store" });
}

/** `/img/<encoded url>`: an image, with the CORS header its host did not send. */
async function image(request, url) {
  const origin = request.headers.get("origin") ?? "";
  if (!IMAGE_ORIGINS.some((re) => re.test(origin))) return problem(403, "not for this origin");

  let target;
  try {
    target = new URL(decodeURIComponent(url.pathname.slice("/img/".length)) + url.search);
  } catch {
    return problem(400, "not a URL");
  }
  if (target.protocol !== "https:") return problem(400, "https only");

  const upstream = await fetch(target.toString(), {
    redirect: "follow",
    cf: { cacheEverything: true, cacheTtl: 86400 },
  });
  if (!upstream.ok) return problem(upstream.status, "upstream said " + upstream.status);
  const type = upstream.headers.get("content-type") ?? "";
  if (!type.startsWith("image/")) return problem(415, "not an image");
  const len = Number(upstream.headers.get("content-length") ?? "0");
  if (len > MAX_IMAGE_BYTES) return problem(413, "image too large");

  const headers = new Headers();
  headers.set("access-control-allow-origin", "*");
  headers.set("cache-control", "public, max-age=86400");
  headers.set("content-type", type);
  if (request.method === "HEAD") return new Response(null, { status: 200, headers });
  // A host that sends no length is held to the cap as the bytes arrive.
  return new Response(upstream.body.pipeThrough(capBytes(MAX_IMAGE_BYTES)), { status: 200, headers });
}

/** A stream that errors once more than `max` bytes have passed through it. */
function capBytes(max) {
  let seen = 0;
  return new TransformStream({
    transform(chunk, controller) {
      seen += chunk.byteLength;
      if (seen > max) controller.error(new Error("image too large"));
      else controller.enqueue(chunk);
    },
  });
}

/** Every download URL one shard publishes, cached per isolate. */
const shards = new Map();

async function shardUrls(fingerprint) {
  const now = Date.now() / 1000;
  const hit = shards.get(fingerprint);
  if (hit && now - hit.at < SHARD_TTL_SECONDS) return hit.urls;

  try {
    const res = await fetch(`${CATALOG}/${fingerprint}/releases.json`, { cf: { cacheTtl: 300 } });
    if (!res.ok) {
      // No shard for that fingerprint is a real answer — that build has nothing to install —
      // and an empty set says so without pretending the catalog is down.
      shards.set(fingerprint, { at: now, urls: new Set() });
      return shards.get(fingerprint).urls;
    }
    const shard = await res.json();
    const urls = new Set();
    for (const rel of Object.values(shard.releases ?? {})) {
      for (const d of Object.values(rel.downloads ?? {})) if (d.url) urls.add(d.url);
    }
    shards.set(fingerprint, { at: now, urls });
    return urls;
  } catch {
    // Keep serving the last good list rather than refusing every download because the catalog
    // blinked. With no list ever fetched this is empty, which fails closed.
    return hit?.urls ?? new Set();
  }
}

function preflight() {
  return new Response(null, {
    status: 204,
    headers: {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET, HEAD, OPTIONS",
      "access-control-max-age": "86400",
    },
  });
}

function problem(status, message) {
  // An upstream status is passed straight through, and `new Response` throws outside 200–599 —
  // which surfaced as Cloudflare's bare "error code: 1101" in place of this message.
  if (!(status >= 200 && status <= 599)) status = 502;
  return new Response(message + "\n", {
    status,
    headers: { "access-control-allow-origin": "*", "content-type": "text/plain; charset=utf-8" },
  });
}
