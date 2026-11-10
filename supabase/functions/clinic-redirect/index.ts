// GET /functions/v1/clinic-redirect?place_id=...&type=website|appointment
//     &referral_id=&session_id=&screening_id=&search_location=
//
// Logs a WEBSITE_CLICKED / APPOINTMENT_CLICKED event through public.log_redirect
// (service_role only), then 302s to the clinic's website. Logging happens
// before the redirect so a click is never lost.
//   302 -> clinic website
//   400 -> missing place_id or bad type
//   404 -> unknown or closed place, or no website
//   500 -> anything else (details only in the function logs)

import { createClient } from "npm:@supabase/supabase-js@2.49.4";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

function text(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "GET") {
    return text(405, "Method not allowed");
  }

  const params = new URL(req.url).searchParams;
  const placeId = params.get("place_id")?.trim();
  const type = params.get("type")?.trim();

  if (!placeId) return text(400, "place_id is required");
  if (type !== "website" && type !== "appointment") {
    return text(400, "type must be website or appointment");
  }

  const { data, error } = await supabase.rpc("log_redirect", {
    p_place_id: placeId,
    p_type: type,
    p_referral_id: params.get("referral_id"),
    p_session_id: params.get("session_id"),
    p_screening_id: params.get("screening_id"),
    p_search_location: params.get("search_location"),
  });

  if (error) {
    if (error.code === "22023") return text(400, error.message);
    if (error.code === "P0002") return text(404, "Clinic not found or has no website");
    console.error("log_redirect failed", error);
    return text(500, "Could not open the clinic link");
  }

  return new Response(null, {
    status: 302,
    headers: { Location: data.url, "Cache-Control": "no-store" },
  });
});
