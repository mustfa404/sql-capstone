"""Phase 3 - Data Preparation (CRISP-DM).

Runs, inside ONE transaction (all-or-nothing):

1. sql/data_cleaning.sql  - dedup, imputation, outlier capping, cohort flag
2. sql/feature_store.sql  - feature engineering + MATERIALIZED VIEW + PL/pgSQL refresh
3. Validation queries     - duplicates, NULLs, target balance, volume change
4. Streaming export       - outputs/feature_store_export.csv
"""
import logging
import time

from config import (OUTPUT_DIR, db_connection, export_query_to_csv, load_queries,
                    log_metadata, reset_phase_metadata)

logger = logging.getLogger(__name__)

PHASE = "phase3"


def run_sql_blocks(cur, queries, category, skip_prefixes=()):
    """Execute every named block (in file order) except the skipped ones."""
    for name, query in queries.items():
        if name.startswith(skip_prefixes):
            continue
        started = time.perf_counter()
        cur.execute(query)
        elapsed = time.perf_counter() - started
        log_metadata(cur, PHASE, category, name, f"seconds={elapsed:.2f}")
        logger.info("%-34s %.2fs", name, elapsed)


def validate_feature_store(cur, queries):
    """Run validation queries and log the results against the ROI targets."""
    cur.execute(queries["validate_volume"])
    raw, clean, cohort, store = cur.fetchone()
    log_metadata(cur, PHASE, "volume_check", "orders",
                 f"raw={raw}; clean={clean}; cohort={cohort}; feature_store={store}")

    cur.execute(queries["validate_duplicates"])
    duplicates = cur.fetchone()[0]

    cur.execute(queries["validate_nulls"])
    null_columns = {column: nulls for column, nulls in cur.fetchall() if nulls > 0}
    total_nulls = sum(null_columns.values())

    cur.execute(queries["validate_target"])
    total_rows, late_rows, late_pct = cur.fetchone()

    log_metadata(cur, PHASE, "roi_result", "duplicate_orders_in_feature_store",
                 f"{duplicates} -> {'PASS' if duplicates == 0 else 'FAIL'}")
    log_metadata(cur, PHASE, "roi_result", "null_values_in_feature_store",
                 f"{total_nulls} -> {'PASS' if total_nulls == 0 else 'FAIL'} {null_columns or ''}")
    log_metadata(cur, PHASE, "roi_result", "target_balance",
                 f"rows={total_rows}; late_rows={late_rows}; late_pct={late_pct}")
    logger.info("Validation: rows=%s duplicates=%s nulls=%s late_pct=%s",
                total_rows, duplicates, total_nulls, late_pct)
    return total_rows


def run():
    cleaning = load_queries("data_cleaning.sql")
    features = load_queries("feature_store.sql")

    with db_connection() as conn:
        with conn.cursor() as cur:
            reset_phase_metadata(cur, PHASE)

            logger.info("--- Cleaning (data_cleaning.sql) ---")
            run_sql_blocks(cur, cleaning, "cleaning")

            logger.info("--- Feature engineering (feature_store.sql) ---")
            run_sql_blocks(cur, features, "feature_engineering",
                           skip_prefixes=("validate_", "export_"))

            cur.execute("SELECT feature_store.refresh_feature_store()")
            refreshed_rows = cur.fetchone()[0]
            log_metadata(cur, PHASE, "feature_engineering", "refresh_feature_store()",
                         f"rows={refreshed_rows}")

            validate_feature_store(cur, features)

        started = time.perf_counter()
        exported = export_query_to_csv(conn, features["export_feature_store"],
                                       OUTPUT_DIR / "feature_store_export.csv")
        elapsed = time.perf_counter() - started
        with conn.cursor() as cur:
            log_metadata(cur, PHASE, "export", "feature_store_export.csv",
                         f"rows={exported}; seconds={elapsed:.2f}")
    logger.info("Phase 3 completed - %s rows exported", exported)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    run()
