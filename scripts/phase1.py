"""Phase 1 - Business Understanding (CRISP-DM).

Automates the four Phase 1 checklist items and logs everything to the
``pipeline_metadata`` table inside PostgreSQL:

1. Define objectives
2. Resource audit (tables, row counts, declared constraints, execution schedule)
3. Target definition (is_late_delivery) with a baseline measured in SQL
4. ROI framework (quantifiable technical success metrics)
"""
import logging

from config import db_connection, load_queries, log_metadata, reset_phase_metadata

logger = logging.getLogger(__name__)

PHASE = "phase1"

OBJECTIVES = [
    ("business_goal",
     "Reduce late deliveries on the Olist marketplace by predicting which orders "
     "will arrive after the estimated delivery date."),
    ("ml_goal",
     "Produce a clean, leakage-free Feature Store for a binary classifier "
     "(target: is_late_delivery)."),
    ("database_goal",
     "Run every audit, cleaning step and feature calculation inside PostgreSQL "
     "(no Pandas / Polars)."),
    ("pipeline_goal",
     "Make the pipeline repeatable end to end (etl.py) with a CLI (main.py) and "
     "transactional safety (commit / rollback)."),
]

EXECUTION_SCHEDULE = [
    ("step_1", "phase1.py  - log objectives, resource audit, target and ROI metrics"),
    ("step_2", "phase2.py  - structural audit, SQL EDA and data-quality audit (CSV exports)"),
    ("step_3", "phase3.py  - cleaning, cohort filtering, feature engineering, Feature Store export"),
]

TARGET_DEFINITION = (
    "is_late_delivery = 1 if order_delivered_customer_date > "
    "order_estimated_delivery_date, else 0. Cohort: delivered orders with a "
    "real delivery date (the target is undefined otherwise)."
)

ROI_METRICS = [
    ("duplicate_orders_in_feature_store", "target = 0"),
    ("null_values_in_feature_store", "target = 0"),
    ("pandas_or_polars_imports", "target = 0"),
    ("pipeline_rerun_without_errors", "target = 100% (idempotent DDL)"),
    ("feature_store_export_rows", "= number of delivered orders with items (logged by phase3)"),
]


def log_objectives(cur):
    for item, detail in OBJECTIVES:
        log_metadata(cur, PHASE, "objective", item, detail)


def resource_audit(cur, queries):
    cur.execute(queries["baseline_row_counts"])
    row_counts = cur.fetchall()
    cur.execute(queries["table_constraints_summary"])
    constraints = {table: (pks, fks) for table, pks, fks in cur.fetchall()}

    for table, rows in row_counts:
        pks, fks = constraints.get(table, (0, 0))
        log_metadata(cur, PHASE, "resource_audit", table,
                     f"rows={rows}; primary_keys={pks}; foreign_keys={fks}")
    for item, detail in EXECUTION_SCHEDULE:
        log_metadata(cur, PHASE, "execution_schedule", item, detail)
    logger.info("Resource audit logged for %s tables", len(row_counts))


def define_target(cur, queries):
    log_metadata(cur, PHASE, "target", "definition", TARGET_DEFINITION)
    cur.execute(queries["target_baseline"])
    total, delivered, late, late_pct = cur.fetchone()
    log_metadata(cur, PHASE, "target", "baseline",
                 f"total_orders={total}; delivered_with_date={delivered}; "
                 f"late_orders={late}; late_pct={late_pct}")
    logger.info("Target baseline: %s late of %s delivered (%s%%)", late, delivered, late_pct)


def log_roi_framework(cur):
    for item, detail in ROI_METRICS:
        log_metadata(cur, PHASE, "roi", item, detail)


def run():
    queries = load_queries("audit_queries.sql")
    with db_connection() as conn:
        with conn.cursor() as cur:
            reset_phase_metadata(cur, PHASE)
            log_objectives(cur)
            resource_audit(cur, queries)
            define_target(cur, queries)
            log_roi_framework(cur)
    logger.info("Phase 1 completed - metadata stored in pipeline_metadata")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    run()
