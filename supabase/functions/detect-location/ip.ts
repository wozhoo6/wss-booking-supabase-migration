// Pure helpers for the detect-location Edge Function. No Deno APIs in here, so
// they can be unit-tested with plain Node (see ip.test.ts).

export type Place = {
  city: string | null;
  region: string | null;
  lat: number;
  lng: number;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * The visitor's IP as the Supabase gateway saw it: first entry of
 * X-Forwarded-For, then the usual single-value headers. A client can put its own
 * value in X-Forwarded-For, but that only changes the answer for that client.
 */
export function resolveIp(headers: Headers): string | null {
  const forwarded = headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  const candidate = forwarded || headers.get("cf-connecting-ip")?.trim() ||
    headers.get("x-real-ip")?.trim();
  return candidate || null;
}

function isPublicIpv4(ip: string): boolean {
  const match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip);
  if (!match) return false;
  const [a, b] = [Number(match[1]), Number(match[2])];
  if ([a, b, Number(match[3]), Number(match[4])].some((n) => n > 255)) return false;
  if (a === 0 || a === 10 || a === 127) return false; // "this" network, private, loopback
  if (a === 169 && b === 254) return false; // link-local
  if (a === 172 && b >= 16 && b <= 31) return false; // private
  if (a === 192 && b === 168) return false; // private
  if (a === 100 && b >= 64 && b <= 127) return false; // carrier-grade NAT
  if (a >= 224) return false; // multicast and reserved
  return true;
}

function isPublicIpv6(ip: string): boolean {
  if (ip.length > 45 || !/^[0-9a-fA-F:.]+$/.test(ip) || !ip.includes(":")) return false;
  const lower = ip.toLowerCase();
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(lower); // IPv4-mapped
  if (mapped) return isPublicIpv4(mapped[1]);
  if (lower === "::" || lower === "::1") return false; // unspecified, loopback
  if (/^f[cd]/.test(lower)) return false; // unique local fc00::/7
  if (/^fe[89ab]/.test(lower)) return false; // link-local fe80::/10
  if (lower.startsWith("ff")) return false; // multicast
  return true;
}

/** True only for a well-formed IPv4/IPv6 address on the public internet. */
export function isPublicIp(ip: string): boolean {
  return ip.includes(":") ? isPublicIpv6(ip) : isPublicIpv4(ip);
}

function toCoordinate(value: unknown, limit: number): number | null {
  if (typeof value === "string" && value.trim() === "") return null;
  if (typeof value !== "string" && typeof value !== "number") return null;
  const n = Number(value);
  return Number.isFinite(n) && Math.abs(n) <= limit ? n : null;
}

function cleanText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim().slice(0, 80);
  return text || null;
}

// "US-TX" -> "TX" for the US; elsewhere the full name reads better than a code.
function regionLabel(stateCode: unknown, stateName: unknown): string | null {
  if (typeof stateCode === "string") {
    const us = /^US-([A-Z]{2})$/.exec(stateCode.trim().toUpperCase());
    if (us) return us[1];
  }
  return cleanText(stateName);
}

const round2 = (n: number) => Math.round(n * 100) / 100;

/**
 * Turns an ipgeolocation.io v3 response into a Place, or null when it has no
 * usable coordinates. v3 nests everything under `location` and sends latitude
 * and longitude as strings; a flat body is accepted too. Coordinates are
 * rounded to 2 decimals (about 1 km), which is all an IP address can tell us.
 */
export function parseLocation(data: unknown): Place | null {
  if (!isRecord(data)) return null;
  const loc = isRecord(data.location) ? data.location : data;

  const lat = toCoordinate(loc.latitude, 90);
  const lng = toCoordinate(loc.longitude, 180);
  if (lat === null || lng === null) return null;
  if (lat === 0 && lng === 0) return null; // "null island": a missing value, not a place

  return {
    city: cleanText(loc.city),
    region: regionLabel(loc.state_code, loc.state_prov),
    lat: round2(lat),
    lng: round2(lng),
  };
}
