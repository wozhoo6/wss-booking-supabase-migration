# WSS Clinic Referrals

Supabase backend for the WSS clinic referral site: clinic data imported from the
derm-scraper, nearby/search APIs for the frontend, booking requests, and an admin API.

## Layout

- `supabase/migrations/` — Postgres schema, import functions, and public/admin API functions, applied in filename order.
- `supabase/functions/clinic-redirect/` — Edge Function that logs a website/appointment click, then redirects to the clinic.
- `supabase/functions/detect-location/` — Edge Function that guesses the visitor's city from their IP (via ipgeolocation.io) so the clinic page can show nearby clinics without the browser location prompt. Nothing is logged or stored.
- `supabase/config.toml` — local Supabase config. Secrets are read from `env(...)` placeholders, never committed values.
- `scripts/import_batch.py` — loads one derm-scraper SQLite file into staging and calls `public.import_batch()`.

## Local setup

1. Install the Supabase CLI and Docker, then start the local stack:
   ```
   supabase start
   supabase db reset   # applies migrations and seed
   ```
2. For the import script, install its dependency:
   ```
   pip install "psycopg[binary]>=3.1"
   ```
3. Copy any needed secrets into a `.env` at the repo root (git-ignored). Variables used:
   - `SUPABASE_DB_URL` — Postgres connection string (defaults to the local database).
   - `OPENAI_API_KEY`, `SUPABASE_AUTH_*`, `S3_SECRET_KEY` — referenced by `config.toml`.

   The `detect-location` function reads its own secrets, not from `config.toml`:
   - `IPGEOLOCATION_API_KEY` — free key from ipgeolocation.io. Hosted: `supabase secrets set IPGEOLOCATION_API_KEY=...`. Local: put it in a git-ignored env file and run `supabase functions serve detect-location --env-file <file>`.
   - `ALLOW_IP_OVERRIDE=true` — **local only**. Lets `?ip=<address>` replace the caller's IP so you can test from outside the clinics' region. Never set it on the hosted project.

   Free plan: 1,000 lookups per day. Past that the function answers `{ "located": false }` and the page falls back to the ZIP/city search.
   Helper tests: `node --test supabase/functions/detect-location/ip.test.ts`.

## Importing clinic data

```
python scripts/import_batch.py path/to/clinics.db --region TX --dry-run
python scripts/import_batch.py path/to/clinics.db --region TX
```

The script prints the target database host before writing anything. Run `--dry-run` first.

## Notes

- Batch imports never write to the WSS-owned tables (`wss_*`); those are only touched by the API functions.
- The admin API functions require an admin key, checked by `private.require_admin`.
- The Teams booking notification is posted from the database (`booking_teams_notify` migrations). No webhook URL is stored in this repo.
