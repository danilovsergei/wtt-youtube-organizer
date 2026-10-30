#!/usr/bin/env python3
"""
WTT Cloud Sync Keep-Alive Worker
Pings registered user Supabase projects daily to prevent the 7-day inactivity pause.
"""
import os
import sys
import json
import urllib.request
import psycopg2

DATABASE_URL = os.environ.get("DATABASE_URL")
if not DATABASE_URL:
    print("❌ ERROR: DATABASE_URL environment variable is required.")
    sys.exit(1)

def ping_project(url: str, anon_key: str) -> tuple[bool, str]:
    base = url.rstrip("/")
    headers = {
        "apikey": anon_key,
        "Authorization": f"Bearer {anon_key}",
        "User-Agent": "WTT-KeepAlive-Worker/1.0"
    }
    
    # 1. Primary ping: query playback_progress (guaranteed to exist on 100% of user projects)
    target_url = f"{base}/rest/v1/playback_progress?select=match_id&limit=1"
    req = urllib.request.Request(target_url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return True, f"HTTP {resp.status} OK (playback_progress)"
    except urllib.error.HTTPError as e:
        # 2. Fallback ping: PostgREST root schema inspection
        try:
            req_root = urllib.request.Request(f"{base}/rest/v1/", headers=headers)
            with urllib.request.urlopen(req_root, timeout=10) as r2:
                return True, f"HTTP {r2.status} OK (rest_root)"
        except Exception:
            return False, f"HTTP {e.code}: {e.reason}"
    except Exception as e:
        return False, str(e)

def main():
    print("🚀 Starting WTT Cloud Sync Keep-Alive Worker...")
    try:
        conn = psycopg2.connect(DATABASE_URL)
    except Exception as e:
        print(f"❌ Database connection failed: {e}")
        sys.exit(1)

    cur = conn.cursor()
    cur.execute("SELECT supabase_url, anon_key FROM public.sync_keepalive_endpoints;")
    rows = cur.fetchall()
    print(f"📋 Found {len(rows)} registered project(s) to keep alive.")

    success_count = 0
    fail_count = 0

    for url, key in rows:
        print(f"⏳ Pinging {url}...")
        ok, status = ping_project(url, key)
        if ok:
            print(f"  ✅ Success: {status}")
            success_count += 1
        else:
            print(f"  ⚠️ Failed: {status}")
            fail_count += 1

        cur.execute("""
            UPDATE public.sync_keepalive_endpoints
            SET last_ping_at = now(),
                last_ping_status = %s
            WHERE supabase_url = %s;
        """, (status, url))
        conn.commit()

    conn.close()
    print(f"🎉 Done! Success: {success_count}, Failed: {fail_count}")

if __name__ == "__main__":
    main()
