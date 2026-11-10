# WSS Clinic Referrals

Supabase backend for the WSS clinic referral site: clinic data imported from the
derm-scraper, nearby/search APIs for the frontend, booking requests, and an admin API.

## Layout

- `supabase/migrations/` — Postgres schema, import functions, and public/admin API functions, applied in filename order.
- `supabase/functions/clinic-redirect/` — Edge Function that logs a website/appointment click, then redirects to the clinic.
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
