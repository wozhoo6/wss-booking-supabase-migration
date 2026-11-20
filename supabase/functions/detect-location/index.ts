// GET /functions/v1/detect-location
//
// Guesses where a visitor is from their IP address, so the clinic page can show
// nearby clinics without the browser's location permission prompt.
//   200 { located: true, city, region, lat, lng }   approximate, city level
//   200 { located: false }                           no usable answer (always 200,
//                                                    so the page falls back quietly)
//   405                                              anything but GET / OPTIONS
//
// The lookup goes to ipgeolocation.io (free plan: city + coordinates, 1,000
// lookups/day, key must stay server-side). To change provider, replace lookup().
//
// Secrets (supabase secrets set ...; locally via --env-file):
//   IPGEOLOCATION_API_KEY   required
//   ALLOW_IP_OVERRIDE=true  LOCAL ONLY: lets ?ip=<address> stand in for the caller's
//                           IP, so it can be tested from outside the clinics' region.
//
// The visitor's IP is never logged or stored, and nothing is written to the database.

import { isPublicIp, parseLocation, type Place, resolveIp } from "./ip.ts";

const LOOKUP_TIMEOUT_MS = 3000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
};

function reply(body: Record<string, unknown>, cacheable = false, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS,
      "Content-Type": "application/json; charset=utf-8",
      // A good answer can sit in the visitor's browser for an hour; a miss must not be
      // remembered, or one provider hiccup would stick.
      "Cache-Control": cacheable ? "private, max-age=3600" : "no-store",
    },
  });
}

async function lookup(ip: string): Promise<Place | null> {
  const apiKey = Deno.env.get("IPGEOLOCATION_API_KEY");
  if (!apiKey) {
    console.error("detect-location: IPGEOLOCATION_API_KEY is not set");
    return null;
  }

  const url = new URL("https://api.ipgeolocation.io/v3/ipgeo");
  url.searchParams.set("apiKey", apiKey);
  url.searchParams.set("ip", ip);

  const res = await fetch(url, {
    headers: { Accept: "application/json" },
    signal: AbortSignal.timeout(LOOKUP_TIMEOUT_MS),
  });
  if (!res.ok) {
    // 401 bad key, 423 private IP, 429 daily limit reached, ... Status only: the body and
    // URL are left out of the logs on purpose (the URL carries the key and the IP).
    console.error(`detect-location: ipgeolocation.io answered ${res.status}`);
    return null;
  }
  return parseLocation(await res.json());
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "GET") return reply({ error: "Method not allowed" }, false, 405);

  const override = Deno.env.get("ALLOW_IP_OVERRIDE") === "true"
    ? new URL(req.url).searchParams.get("ip")?.trim()
    : null;
  const ip = override || resolveIp(req.headers);
  if (!ip || !isPublicIp(ip)) return reply({ located: false });

  try {
    const place = await lookup(ip);
    return place ? reply({ located: true, ...place }, true) : reply({ located: false });
  } catch (error) {
    // Timeout, network failure or a non-JSON body. Name only, never the message or the IP.
    console.error("detect-location: lookup failed", error instanceof Error ? error.name : "unknown");
    return reply({ located: false });
  }
});
