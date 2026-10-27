"""Phase 2 - Data Understanding (CRISP-DM).

* Structural audit: tables, columns, datatypes, declared constraints and
  exact baseline row counts (logged to ``pipeline_metadata``).
* EDA via SQL aggregates  -> outputs/phase2_eda_summary.csv
* Data-quality audit      -> outputs/phase2_quality_audit.csv

All statistics are computed by PostgreSQL; Python only streams the result
sets into CSV files with the built-in ``csv`` module.
"""
import logging

from config import (OUTPUT_DIR, db_connection, export_query_to_csv, load_queries,
                    log_metadata, reset_phase_metadata)

logger = logging.getLogger(__name__)

PHASE = "phase2"


def structural_audit(cur, queries):
    cur.execute(queries["table_columns"])
    for table, column_count, columns in cur.fetchall():
        log_metadata(cur, PHASE, "structural_audit", table,
                     f"columns={column_count}: {columns}")

    cur.execute(queries["foreign_keys"])
    foreign_keys = cur.fetchall()
    if foreign_keys:
        for table, column, ref_table, ref_column in foreign_keys:
            log_metadata(cur, PHASE, "foreign_key", f"{table}.{column}",
                         f"references {ref_table}.{ref_column}")
    else:
        log_metadata(cur, PHASE, "foreign_key", "declared_foreign_keys",
                     "none declared in the raw load; relationships are logical "
                     "(see README) and verified by orphan-key checks")

    cur.execute(queries["baseline_row_counts"])
    for table, rows in cur.fetchall():
        log_metadata(cur, PHASE, "baseline_row_count", table, rows)
    logger.info("Structural audit logged")


def run():
    queries = load_queries("audit_queries.sql")
    with db_connection() as conn:
        with conn.cursor() as cur:
            reset_phase_metadata(cur, PHASE)
            structural_audit(cur, queries)

        eda_rows = export_query_to_csv(conn, queries["eda_summary"],
                                       OUTPUT_DIR / "phase2_eda_summary.csv")
        audit_rows = export_query_to_csv(conn, queries["quality_audit"],
                                         OUTPUT_DIR / "phase2_quality_audit.csv")
        with conn.cursor() as cur:
            log_metadata(cur, PHASE, "export", "phase2_eda_summary.csv", f"rows={eda_rows}")
            log_metadata(cur, PHASE, "export", "phase2_quality_audit.csv", f"rows={audit_rows}")
    logger.info("Phase 2 completed - %s EDA rows, %s audit checks", eda_rows, audit_rows)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    run()
