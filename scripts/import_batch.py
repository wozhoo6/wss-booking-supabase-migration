"""
Load one derm-scraper SQLite file into Supabase as an import batch.

    python scripts/import_batch.py path/to/clinics.db --region TX --dry-run
    python scripts/import_batch.py path/to/clinics.db --region TX

Connection: SUPABASE_DB_URL (Postgres URL, postgres user), from the shell or
from ../.env. Defaults to the local Supabase database started by `supabase start`.
The target host is printed before anything is written.

What it does:
  1. Opens the SQLite file read-only and checks it has the scraper's four tables.
  2. Computes clinic_addresses.name_match (does the Google place name match the
     registered clinic, or a doctor linked to it?).
  3. Registers a batch in public.import_batches and fills the staging tables.
  4. Calls public.import_batch(batch_id, dry_run), which validates, upserts
     (fill blanks only) and returns the counts.

Requires: pip install "psycopg[binary]>=3.1"
"""

import argparse
import difflib
import hashlib
import json
import os
import re
import sqlite3
import sys

import psycopg

DEFAULT_DB_URL = "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env")


def load_env_file(path=ENV_FILE):
    """Minimal .env loader (KEY=value lines). A variable already set in the shell wins."""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))

EXPECTED_COLUMNS = {
    "clinics": {"clinic_id", "npi", "name", "address1", "address2", "city", "state", "zip", "phone"},
    "clinic_addresses": {
        "address_id", "clinic_id", "place_id", "place_name", "address", "lat", "lng", "phone",
        "website", "rating", "review_count", "business_status", "result_rank",
        "matches_registered", "search_query", "searched_at",
    },
    "dermatologists": {
        "npi", "name", "address1", "address2", "city", "state", "zip", "phone",
        "first_seen", "last_seen",
    },
    "assignments": {"npi", "clinic_id", "confidence", "derm_name", "clinic_name"},
}

# ---------------------------------------------------------------------------
# Name matching
# ---------------------------------------------------------------------------
NAME_MATCH_THRESHOLD = 0.8
STOP_WORDS = {"md", "do", "pa", "pllc", "llc", "inc", "pc", "dba", "the", "of", "and", "dr", "phd", "np"}
SUFFIXES = {"md", "do", "pa", "phd", "np", "facs", "faad", "jr", "sr", "ii", "iii"}


def tokens(text):
    cleaned = re.sub(r"[^a-z0-9 ]", " ", (text or "").lower())
    return {t for t in cleaned.split() if t not in STOP_WORDS and len(t) > 1}


def name_score(registered, place):
    a, b = tokens(registered), tokens(place)
    if not a or not b:
        return 0.0
    overlap = len(a & b) / min(len(a), len(b))
    seq = difflib.SequenceMatcher(None, " ".join(sorted(a)), " ".join(sorted(b))).ratio()
    return max(overlap, seq)


def surname(doctor_name):
    """'Thomas J. Lambert, MD' -> 'lambert'."""
    before_comma = (doctor_name or "").split(",")[0]
    words = [w for w in re.sub(r"[^a-z ]", " ", before_comma.lower()).split() if w not in SUFFIXES]
    return words[-1] if words and len(words[-1]) > 2 else None


def name_match(registered_name, place_name, doctor_surnames):
    if name_score(registered_name, place_name) >= NAME_MATCH_THRESHOLD:
        return True
    place_tokens = tokens(place_name)
    return any(s in place_tokens for s in doctor_surnames)


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------
def check_schema(src):
    for table, needed in EXPECTED_COLUMNS.items():
        cols = {row[1] for row in src.execute(f"pragma table_info({table})")}
        if not cols:
            sys.exit(f"Source file has no '{table}' table.")
        missing = needed - cols
        if missing:
            sys.exit(f"Source table '{table}' is missing columns: {sorted(missing)}")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_source(src):
    clinics = src.execute(
        "select clinic_id, npi, name, address1, address2, city, state, zip, phone from clinics"
    ).fetchall()
    registered_names = {row[0]: row[2] for row in clinics}

    surnames = {}
    for clinic_id, derm_name in src.execute(
        "select a.clinic_id, d.name from assignments a join dermatologists d using (npi)"
    ):
        s = surname(derm_name)
        if s:
            surnames.setdefault(clinic_id, set()).add(s)

    addresses = []
    for row in src.execute(
        """select address_id, clinic_id, place_id, place_name, address, lat, lng, phone, website,
                  rating, review_count, business_status, result_rank, matches_registered,
                  search_query, searched_at
           from clinic_addresses"""
    ):
        clinic_id, place_name = row[1], row[3]
        match = name_match(registered_names.get(clinic_id, ""), place_name, surnames.get(clinic_id, set()))
        addresses.append(row + (match,))

    dermatologists = src.execute(
        "select npi, name, address1, address2, city, state, zip, phone, first_seen, last_seen from dermatologists"
    ).fetchall()
    assignments = src.execute(
        "select npi, clinic_id, confidence, derm_name, clinic_name from assignments"
    ).fetchall()
    return clinics, addresses, dermatologists, assignments


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", help="path to a derm-scraper clinics.db")
    parser.add_argument("--region", required=True, help="2-letter state the registered clinics must be in, e.g. TX")
    parser.add_argument("--dry-run", action="store_true", help="validate and count, then roll back")
    parser.add_argument("--notes", default=None)
    args = parser.parse_args()

    region = args.region.upper()
    path = os.path.abspath(args.source)
    src = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    check_schema(src)
    clinics, addresses, dermatologists, assignments = read_source(src)
    src.close()

    matched = sum(1 for a in addresses if a[-1])
    print(f"Read {len(clinics)} clinics, {len(addresses)} Google rows ({matched} name matches), "
          f"{len(dermatologists)} doctors, {len(assignments)} assignments.")

    load_env_file()
    db_url = os.environ.get("SUPABASE_DB_URL", DEFAULT_DB_URL)
    host = db_url.split("@")[-1].split("/")[0]
    print(f"Importing into {host}")
    with psycopg.connect(db_url) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """insert into public.import_batches (region, source_file, source_sha256, notes)
                   values (%s, %s, %s, %s) returning batch_id""",
                (region, path, sha256(path), args.notes),
            )
            batch_id = cur.fetchone()[0]

            cur.executemany(
                """insert into staging.stg_clinics
                   (batch_id, src_clinic_id, npi, name, address1, address2, city, state, zip, phone)
                   values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                [(batch_id, *r) for r in clinics],
            )
            cur.executemany(
                """insert into staging.stg_clinic_addresses
                   (batch_id, src_address_id, src_clinic_id, place_id, place_name, address, lat, lng,
                    phone, website, rating, review_count, business_status, result_rank,
                    matches_registered, search_query, searched_at, name_match)
                   values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                [(batch_id, *r) for r in addresses],
            )
            cur.executemany(
                """insert into staging.stg_dermatologists
                   (batch_id, npi, name, address1, address2, city, state, zip, phone, first_seen, last_seen)
                   values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                [(batch_id, *r) for r in dermatologists],
            )
            cur.executemany(
                """insert into staging.stg_assignments
                   (batch_id, npi, src_clinic_id, confidence, derm_name, clinic_name)
                   values (%s, %s, %s, %s, %s, %s)""",
                [(batch_id, *r) for r in assignments],
            )
        conn.commit()  # staging + pending batch row are saved before the import runs

        try:
            with conn.cursor() as cur:
                cur.execute("select public.import_batch(%s, %s)", (batch_id, args.dry_run))
                result = cur.fetchone()[0]
            conn.commit()
        except psycopg.Error as exc:
            conn.rollback()
            with conn.cursor() as cur:
                cur.execute(
                    "update public.import_batches set status = 'failed', notes = %s where batch_id = %s",
                    (str(exc).strip()[:2000], batch_id),
                )
                for table in ("stg_assignments", "stg_clinic_addresses", "stg_dermatologists", "stg_clinics"):
                    cur.execute(f"delete from staging.{table} where batch_id = %s", (batch_id,))
            conn.commit()
            sys.exit(f"Batch {batch_id} failed: {exc}")

    print(json.dumps(result, indent=2))
    if args.dry_run:
        print("Dry run: nothing was imported. Re-run without --dry-run to commit.")


if __name__ == "__main__":
    main()
