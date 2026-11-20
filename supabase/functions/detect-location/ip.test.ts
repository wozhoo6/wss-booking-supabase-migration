// Run with:  node --test supabase/functions/detect-location/ip.test.ts
// (Node 22.18+ strips the types itself; `deno test` also works.)
import assert from "node:assert/strict";
import { test } from "node:test";
import { isPublicIp, parseLocation, resolveIp } from "./ip.ts";

test("resolveIp takes the first X-Forwarded-For entry", () => {
  const h = new Headers({ "x-forwarded-for": " 203.0.113.9 , 10.0.0.1" });
  assert.equal(resolveIp(h), "203.0.113.9");
});

test("resolveIp falls back to cf-connecting-ip, then x-real-ip, then null", () => {
  assert.equal(resolveIp(new Headers({ "cf-connecting-ip": "198.51.100.7" })), "198.51.100.7");
  assert.equal(resolveIp(new Headers({ "x-real-ip": "198.51.100.8" })), "198.51.100.8");
  assert.equal(resolveIp(new Headers()), null);
});

test("isPublicIp accepts public addresses", () => {
  for (const ip of ["8.8.8.8", "203.0.113.9", "172.32.0.1", "100.63.0.1", "2001:4860:4860::8888"]) {
    assert.equal(isPublicIp(ip), true, ip);
  }
});

test("isPublicIp rejects private, loopback and malformed addresses", () => {
  const bad = [
    "10.0.0.1", "127.0.0.1", "0.0.0.0", "169.254.1.1", "172.16.0.1", "172.31.255.255",
    "192.168.1.1", "100.64.0.1", "224.0.0.1", "256.1.1.1", "1.2.3", "abc", "",
    "1.2.3.4; drop table", "::1", "::", "fd12:3456::1", "fe80::1", "ff02::1",
    "::ffff:10.0.0.1",
  ];
  for (const ip of bad) assert.equal(isPublicIp(ip), false, ip);
  assert.equal(isPublicIp("::ffff:8.8.8.8"), true);
});

test("parseLocation reads the v3 shape (nested, string coordinates)", () => {
  const place = parseLocation({
    ip: "8.8.8.8",
    location: {
      city: "Houston",
      state_prov: "Texas",
      state_code: "US-TX",
      latitude: "29.76043",
      longitude: "-95.36980",
    },
  });
  assert.deepEqual(place, { city: "Houston", region: "TX", lat: 29.76, lng: -95.37 });
});

test("parseLocation also accepts a flat body and uses the state name outside the US", () => {
  const place = parseLocation({
    city: "Stockholm",
    state_prov: "Stockholms län",
    state_code: "SE-AB",
    latitude: 59.4051,
    longitude: 17.9551,
  });
  assert.deepEqual(place, { city: "Stockholm", region: "Stockholms län", lat: 59.41, lng: 17.96 });
});

test("parseLocation keeps a place that has coordinates but no city", () => {
  const place = parseLocation({ location: { latitude: "31.0", longitude: "-100.0" } });
  assert.deepEqual(place, { city: null, region: null, lat: 31, lng: -100 });
});

test("parseLocation returns null when coordinates are missing or unusable", () => {
  assert.equal(parseLocation(null), null);
  assert.equal(parseLocation("nope"), null);
  assert.equal(parseLocation([]), null);
  assert.equal(parseLocation({ location: { city: "Houston" } }), null);
  assert.equal(parseLocation({ location: { latitude: "", longitude: "" } }), null);
  assert.equal(parseLocation({ location: { latitude: "abc", longitude: "1" } }), null);
  assert.equal(parseLocation({ location: { latitude: "91", longitude: "1" } }), null);
  assert.equal(parseLocation({ location: { latitude: "1", longitude: "181" } }), null);
  assert.equal(parseLocation({ location: { latitude: "0", longitude: "0" } }), null);
});
