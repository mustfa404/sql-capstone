"""Configuration, connection pooling and small shared helpers.

Loads environment variables, exposes a psycopg2 connection pool and a few
helpers (named SQL-file loader, metadata logging, streaming CSV export).

No data manipulation happens in Python: every transformation is executed by
PostgreSQL. Python only orchestrates connections, transactions and I/O.
"""
import csv
import logging
import os
import re
from contextlib import contextmanager
from pathlib import Path

from dotenv import load_dotenv
from psycopg2 import pool

BASE_DIR = Path(__file__).resolve().parent
SQL_DIR = BASE_DIR / "sql"
OUTPUT_DIR = BASE_DIR / "outputs"

load_dotenv(BASE_DIR / ".env")

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "localhost"),
    "port": int(os.getenv("DB_PORT", "5432")),
    "dbname": os.getenv("DB_NAME", "olist_db"),
    "user": os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
}

logger = logging.getLogger(__name__)
_pool = None


# --------------------------------------------------------------------------
# Connection pool
# --------------------------------------------------------------------------
def get_pool():
    """Return the shared connection pool (created lazily)."""
    global _pool
    if _pool is None:
        _pool = pool.SimpleConnectionPool(1, 5, **DB_CONFIG)
    return _pool


@contextmanager
def db_connection():
    """Borrow a pooled connection; commit on success, rollback on error."""
    db_pool = get_pool()
    conn = db_pool.getconn()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        db_pool.putconn(conn)


def close_pool():
    """Close every pooled connection."""
    global _pool
    if _pool is not None:
        _pool.closeall()
        _pool = None


# --------------------------------------------------------------------------
# Named SQL blocks:  "-- name: <block_name>" followed by the SQL text
# --------------------------------------------------------------------------
_NAME_PATTERN = re.compile(r"^--\s*name:\s*(\S+)\s*$", re.MULTILINE)


def load_queries(filename):
    """Parse a .sql file into an ordered {block_name: sql_text} dict."""
    text = (SQL_DIR / filename).read_text(encoding="utf-8")
    matches = list(_NAME_PATTERN.finditer(text))
    queries = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        queries[match.group(1)] = text[match.end():end].strip()
    return queries


# --------------------------------------------------------------------------
# Pipeline metadata log (lives inside PostgreSQL)
# --------------------------------------------------------------------------
_DDL_METADATA = """
CREATE TABLE IF NOT EXISTS pipeline_metadata (
    id        SERIAL PRIMARY KEY,
    phase     TEXT NOT NULL,
    category  TEXT NOT NULL,
    item      TEXT NOT NULL,
    detail    TEXT,
    logged_at TIMESTAMP DEFAULT NOW()
);
"""


def reset_phase_metadata(cur, phase):
    """Create the metadata table if needed and clear the phase's old rows."""
    cur.execute(_DDL_METADATA)
    cur.execute("DELETE FROM pipeline_metadata WHERE phase = %s", (phase,))


def log_metadata(cur, phase, category, item, detail):
    cur.execute(
        "INSERT INTO pipeline_metadata (phase, category, item, detail) "
        "VALUES (%s, %s, %s, %s)",
        (phase, category, item, str(detail)),
    )


# --------------------------------------------------------------------------
# CSV export (native csv module, server-side cursor => constant memory)
# --------------------------------------------------------------------------
def export_query_to_csv(conn, query, path, fetch_size=5000):
    """Stream a query result into a CSV file. Returns the number of rows."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    rows_written = 0
    with conn.cursor(name="csv_export_cursor") as cur, \
            open(path, "w", newline="", encoding="utf-8") as handle:
        cur.itersize = fetch_size
        cur.execute(query)
        writer = csv.writer(handle)
        for row in cur:
            if rows_written == 0:
                writer.writerow([column[0] for column in cur.description])
            writer.writerow(row)
            rows_written += 1
    logger.info("Wrote %s rows to %s", rows_written, path)
    return rows_written
