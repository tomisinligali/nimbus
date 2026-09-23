#!/usr/bin/env python3
"""
Render the three PostgreSQL constraint-violation rejections as terminal screenshots.

For each invalid state, a real psql session is run against PostgreSQL 14 and its
genuine output (statement echo via -e, then the database's ERROR) is drawn onto
a terminal-window-style PNG.

  IND-1  partial unique index  -> uq_trips_one_active_per_rider
  IND-2  transition-guard      -> TRP-02 illegal trip transition
  IND-3  CHECK constraint      -> trips_cancel_fee_only_when_cancelled

Run:  python3 evidence/make_rejection_screenshots.py
Requires: psql/createdb/dropdb (PostgreSQL 14), Pillow.
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

DB = "nimbus_step5_sc"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "evidence", "screenshots")
FONT_PATH = "/System/Library/Fonts/Menlo.ttc"

# Terminal palette
BG      = (28, 30, 34)
TITLE   = (206, 212, 218)
FG      = (231, 233, 238)
OK      = (152, 195, 121)
ERROR   = (255, 106, 106)
DIM     = (168, 172, 178)
META    = (214, 157, 133)
BORDER  = (68, 72, 80)

FSIZE = 17
CHROME_H = 40
PAD_X = 18
PAD_Y_TOP = 26
PAD_Y_BOT = 22

CASES = [
    {
        "file": "IND-1_second_active_trip_rejected.png",
        "title": "IND-1 · partial unique index · uq_trips_one_active_per_rider",
        "sql": [
            # first writer wins...
            "INSERT INTO trips (id, rider_id, status, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, rate_card_id, currency, base_fare_cents, per_km_cents, per_min_cents, surge_bps, estimated_km, estimated_minutes, quote_total_cents)",
            "VALUES ('f0000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001', 'REQUESTED', 37.775, -122.415, 37.787, -122.401, 'b1000000-0000-4000-8000-000000000001', 'USD', 250, 80, 30, 150, 5, 10, 1500);",
            # ...second active trip for the same rider must fail
            "INSERT INTO trips (id, rider_id, status, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, rate_card_id, currency, base_fare_cents, per_km_cents, per_min_cents, surge_bps, estimated_km, estimated_minutes, quote_total_cents)",
            "VALUES ('f0000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000001', 'REQUESTED', 37.775, -122.415, 37.787, -122.401, 'b1000000-0000-4000-8000-000000000001', 'USD', 250, 80, 30, 150, 5, 10, 1500);",
        ],
        "expect_error": "uq_trips_one_active_per_rider",
        "summary": "TRP-01: one active trip per rider — enforced by the DATABASE, not code.",
    },
    {
        "file": "IND-2_illegal_transition_rejected.png",
        "title": "IND-2 · transition-guard trigger · TRP-02",
        "sql": [
            "UPDATE trips SET status = 'ON_TRIP', accepted_at = now()",
            "WHERE id = 'f0000000-0000-4000-8000-000000000003';",
        ],
        "expect_error": "TRP-02",
        "summary": "REQUESTED -> ON_TRIP is not in trip_transitions — trg_trip_transition_guard raises TRP-02 BEFORE the write.",
    },
    {
        "file": "IND-3_fee_on_non_cancelled_rejected.png",
        "title": "IND-3 · CHECK constraint · trips_cancel_fee_only_when_cancelled",
        "sql": [
            "INSERT INTO trips (id, rider_id, status, cancellation_fee_cents, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, rate_card_id, currency, base_fare_cents, per_km_cents, per_min_cents, surge_bps, estimated_km, estimated_minutes, quote_total_cents)",
            "VALUES ('f0000000-0000-4000-8000-000000000005', '40000000-0000-4000-8000-000000000001', 'REQUESTED', 500, 37.775, -122.415, 37.787, -122.401, 'b1000000-0000-4000-8000-000000000001', 'USD', 250, 80, 30, 150, 5, 10, 1500);",
        ],
        "expect_error": "trips_cancel_fee_only_when_cancelled",
        "summary": "FEE-05/FEE-06: a cancellation fee may exist only on a CANCELLED trip (FEE-04 fare gates it off otherwise).",
    },
]


def setup_db():
    subprocess.run(["dropdb", "--if-exists", DB], capture_output=True, check=True)
    subprocess.run(["createdb", DB], capture_output=True, check=True)
    subprocess.run(
        ["psql", "-v", "ON_ERROR_STOP=1", "-q", "-d", DB,
         "-f", os.path.join(ROOT, "migrations", "0001_init_nimbus.sql")],
        capture_output=True, check=True)
    subprocess.run(
        ["psql", "-v", "ON_ERROR_STOP=1", "-q", "-d", DB,
         "-f", os.path.join(ROOT, "migrations", "0002_seed_nimbus.sql")],
        capture_output=True, check=True)


def run_psql(statements, expect_error):
    # Feed via -f (not -c): each statement is its own implicit transaction and
    # each is committed, so earlier statements persist for later ones — matching
    # queries/invalid_states.sql exactly.
    sql = "\n".join(statements)
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
        f.write(sql)
        tmp = f.name
    try:
        proc = subprocess.run(
            ["psql", "-X", "-d", DB, "-e", "-f", tmp],
            capture_output=True, text=True)
    finally:
        os.unlink(tmp)
    out = proc.stdout + proc.stderr
    assert expect_error in out, (
        f"expected '{expect_error}' in live psql output, got:\n{out}")
    return out.splitlines()


def colorize(line_font, line, colors):
    """Return list of (text, color) runs for one terminal line."""
    if line.startswith("psql:"):
        color = META
    elif line.startswith("ERROR:"):
        color = ERROR
    elif line.startswith("DETAIL:") or line.startswith("CONTEXT:") or line.startswith("HINT:"):
        color = DIM
    elif line.startswith(("INSERT ", "UPDATE ", "DELETE ", "SELECT ")):
        color = OK
    else:
        color = FG
    return [(line, color)]


def render(lines, title):
    font = ImageFont.truetype(FONT_PATH, FSIZE)
    title_font = ImageFont.truetype(FONT_PATH, 14)
    dot_font = ImageFont.truetype(FONT_PATH, 15)

    char_w = font.getbbox("M")[2]
    line_h = int(FSIZE * 1.5)

    text_w = max(len(l) for l in lines)
    width = char_w * text_w + PAD_X * 2
    height = CHROME_H + line_h * len(lines) + PAD_Y_TOP + PAD_Y_BOT

    img = Image.new("RGB", (width, height), BG)
    d = ImageDraw.Draw(img)

    # window chrome
    d.rectangle([0, 0, width, CHROME_H], fill=(18, 19, 21))
    d.line([0, CHROME_H, width, CHROME_H], fill=BORDER, width=1)
    for x, col in ((14, (255, 95, 86)), (34, (255, 189, 46)), (54, (39, 201, 63))):
        d.ellipse([x, 14, x + 12, 26], fill=col)
    d.text((86, 13), title, font=title_font, fill=TITLE)

    y = CHROME_H + PAD_Y_TOP
    for raw in lines:
        text = raw if len(raw) <= text_w else raw[: text_w]
        for seg, color in colorize(font, text, []):
            d.text((PAD_X, y), seg, font=font, fill=color)
        y += line_h

    return img


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    setup_db()
    for case in CASES:
        lines = run_psql(case["sql"], case["expect_error"])
        img = render(lines, case["title"])
        path = os.path.join(OUT_DIR, case["file"])
        img.save(path)
        print(f"✓ {path}")


if __name__ == "__main__":
    sys.exit(main())