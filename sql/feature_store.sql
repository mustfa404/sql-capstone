-- ============================================================================
-- feature_store.sql  |  Phase 3 - Feature engineering & dataset packaging
-- Builds MATERIALIZED VIEW feature_store.olist_features (one row per delivered
-- order) plus a PL/pgSQL function that refreshes it.
--
-- Column groups:
--   target ................ is_late_delivery
--   purchase-time ......... known when the customer places the order
--   shipping-time ......... known once the order is approved / handed to carrier
--   leak_* ................ computed from the delivery date -> LEAKAGE, analysis only
-- Customer / seller history features use window frames that END at
-- "1 PRECEDING", so an order never sees itself or the future (no leakage).
-- ============================================================================

-- name: 10_create_feature_store
DROP MATERIALIZED VIEW IF EXISTS feature_store.olist_features;

CREATE MATERIALIZED VIEW feature_store.olist_features AS
WITH items_agg AS (
    SELECT oi.order_id,
           COUNT(*)                         AS item_count,
           COUNT(DISTINCT oi.seller_id)     AS seller_count,
           COUNT(DISTINCT oi.product_id)    AS product_count,
           SUM(oi.price)                    AS items_value,
           SUM(oi.freight_value)            AS freight_total,
           AVG(oi.price)                    AS avg_item_price,
           MAX(oi.price)                    AS max_item_price,
           SUM(p.weight_g)                  AS total_weight_g,
           SUM(p.length_cm * p.height_cm * p.width_cm) AS total_volume_cm3
    FROM clean.order_items oi
    LEFT JOIN clean.products p ON p.product_id = oi.product_id
    GROUP BY oi.order_id
    HAVING SUM(oi.price) > 0
),
primary_item AS (
    -- the most expensive item defines the order's "primary" seller and product
    SELECT DISTINCT ON (oi.order_id)
           oi.order_id,
           oi.seller_id  AS primary_seller_id,
           oi.product_id AS primary_product_id
    FROM clean.order_items oi
    ORDER BY oi.order_id, oi.price DESC, oi.order_item_id
),
payments_agg AS (
    SELECT op.order_id,
           SUM(op.payment_value)              AS payment_value_total,
           MAX(op.payment_installments)       AS max_installments,
           COUNT(DISTINCT op.payment_type)    AS payment_methods_count
    FROM clean.order_payments op
    GROUP BY op.order_id
),
main_payment AS (
    SELECT DISTINCT ON (op.order_id)
           op.order_id,
           op.payment_type AS main_payment_type
    FROM clean.order_payments op
    ORDER BY op.order_id, op.payment_value DESC, op.payment_sequential
),
base AS (
    SELECT o.order_id,
           o.in_cohort,
           o.order_purchase_timestamp          AS purchase_ts,
           o.order_approved_at                 AS approved_ts,
           o.order_delivered_carrier_date      AS carrier_ts,
           o.order_delivered_customer_date     AS delivered_ts,
           o.order_estimated_delivery_date     AS estimated_ts,
           cu.customer_unique_id,
           cu.customer_state,
           pit.primary_seller_id,
           se.seller_state,
           pr.product_category                 AS primary_category,
           ia.item_count, ia.seller_count, ia.product_count,
           ia.items_value, ia.freight_total, ia.avg_item_price, ia.max_item_price,
           ia.total_weight_g, ia.total_volume_cm3,
           pa.payment_value_total, pa.max_installments, pa.payment_methods_count,
           mp.main_payment_type,
           gc.lat AS cust_lat, gc.lng AS cust_lng,
           gs.lat AS sell_lat, gs.lng AS sell_lng
    FROM clean.orders o
    JOIN clean.customers cu        ON cu.customer_id = o.customer_id
    JOIN items_agg ia              ON ia.order_id = o.order_id
    JOIN primary_item pit          ON pit.order_id = o.order_id
    LEFT JOIN clean.sellers se     ON se.seller_id = pit.primary_seller_id
    LEFT JOIN clean.products pr    ON pr.product_id = pit.primary_product_id
    LEFT JOIN payments_agg pa      ON pa.order_id = o.order_id
    LEFT JOIN main_payment mp      ON mp.order_id = o.order_id
    LEFT JOIN clean.geolocation_zip gc ON gc.zip_code_prefix = cu.customer_zip_code_prefix
    LEFT JOIN clean.geolocation_zip gs ON gs.zip_code_prefix = se.seller_zip_code_prefix
),
windowed AS (
    -- window features are computed over ALL orders, filtered to the cohort later
    SELECT b.*,
           COUNT(*) OVER (PARTITION BY b.customer_unique_id
                          ORDER BY b.purchase_ts, b.order_id
                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS customer_prior_orders,
           COALESCE(SUM(b.items_value) OVER (PARTITION BY b.customer_unique_id
                          ORDER BY b.purchase_ts, b.order_id
                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS customer_prior_spend,
           AVG(b.items_value) OVER (PARTITION BY b.customer_unique_id
                          ORDER BY b.purchase_ts, b.order_id
                          ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING) AS customer_rolling_avg_raw,
           LAG(b.purchase_ts) OVER (PARTITION BY b.customer_unique_id
                          ORDER BY b.purchase_ts, b.order_id) AS prev_order_ts,
           MIN(b.purchase_ts) OVER (PARTITION BY b.customer_unique_id) AS first_order_ts,
           COUNT(*) OVER (PARTITION BY b.primary_seller_id
                          ORDER BY b.purchase_ts, b.order_id
                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS seller_prior_orders,
           COUNT(*) OVER (PARTITION BY b.primary_seller_id
                          ORDER BY b.purchase_ts
                          RANGE BETWEEN INTERVAL '30 days' PRECEDING
                                    AND INTERVAL '1 second' PRECEDING) AS seller_orders_prev_30d
    FROM base b
),
cohort AS (
    SELECT w.order_id,
           w.customer_unique_id,
           CASE WHEN w.delivered_ts > w.estimated_ts THEN 1 ELSE 0 END AS is_late_delivery,
           w.purchase_ts,
           EXTRACT(EPOCH FROM (w.estimated_ts - w.purchase_ts)) / 86400.0 AS estimated_delivery_days,
           w.item_count, w.seller_count, w.product_count,
           w.items_value, w.freight_total, w.avg_item_price, w.max_item_price,
           w.total_weight_g, w.total_volume_cm3,
           w.payment_value_total, w.max_installments, w.payment_methods_count,
           w.main_payment_type,
           w.primary_category,
           w.customer_state, w.seller_state,
           6371.0 * 2 * ASIN(LEAST(1.0, SQRT(
               POWER(SIN(RADIANS(w.sell_lat - w.cust_lat) / 2), 2)
             + COS(RADIANS(w.cust_lat)) * COS(RADIANS(w.sell_lat))
             * POWER(SIN(RADIANS(w.sell_lng - w.cust_lng) / 2), 2)))) AS distance_km_raw,
           w.customer_prior_orders,
           w.customer_prior_spend,
           w.customer_rolling_avg_raw,
           EXTRACT(EPOCH FROM (w.purchase_ts - w.prev_order_ts)) / 86400.0 AS days_since_prev_raw,
           DATE_PART('year', AGE(w.purchase_ts, w.first_order_ts)) * 12
             + DATE_PART('month', AGE(w.purchase_ts, w.first_order_ts)) AS tenure_months_raw,
           w.seller_prior_orders,
           w.seller_orders_prev_30d,
           EXTRACT(EPOCH FROM (w.approved_ts - w.purchase_ts)) / 3600.0 AS approval_hours_raw,
           EXTRACT(EPOCH FROM (w.carrier_ts - w.purchase_ts)) / 86400.0 AS carrier_days_raw,
           EXTRACT(EPOCH FROM (w.delivered_ts - w.purchase_ts)) / 86400.0 AS actual_delivery_days,
           EXTRACT(EPOCH FROM (w.delivered_ts - w.estimated_ts)) / 86400.0 AS delay_days
    FROM windowed w
    WHERE w.in_cohort
)
SELECT
    c.order_id::TEXT                                              AS order_id,
    c.customer_unique_id::TEXT                                    AS customer_unique_id,
    -- ------------------------------------------------------------ target
    c.is_late_delivery::SMALLINT                                  AS is_late_delivery,
    -- ------------------------------------------------------------ purchase-time features
    DATE_PART('year',  c.purchase_ts)::SMALLINT                   AS purchase_year,
    DATE_PART('month', c.purchase_ts)::SMALLINT                   AS purchase_month,
    EXTRACT(ISODOW FROM c.purchase_ts)::SMALLINT                  AS purchase_dow,
    DATE_PART('hour',  c.purchase_ts)::SMALLINT                   AS purchase_hour,
    (CASE WHEN EXTRACT(ISODOW FROM c.purchase_ts) >= 6 THEN 1 ELSE 0 END)::SMALLINT AS is_weekend,
    (CASE WHEN DATE_PART('month', c.purchase_ts) IN (11, 12) THEN 1 ELSE 0 END)::SMALLINT AS is_holiday_season,
    ROUND(c.estimated_delivery_days::NUMERIC, 2)::NUMERIC(8,2)    AS estimated_delivery_days,
    c.item_count::INT                                             AS item_count,
    c.seller_count::INT                                           AS seller_count,
    c.product_count::INT                                          AS product_count,
    c.items_value::NUMERIC(12,2)                                  AS items_value,
    c.freight_total::NUMERIC(12,2)                                AS freight_total,
    ROUND((c.freight_total / NULLIF(c.items_value, 0))::NUMERIC, 4)::NUMERIC(8,4) AS freight_ratio,
    ROUND(c.avg_item_price::NUMERIC, 2)::NUMERIC(12,2)            AS avg_item_price,
    c.max_item_price::NUMERIC(12,2)                               AS max_item_price,
    ROUND(COALESCE(c.total_weight_g, AVG(c.total_weight_g) OVER ())::NUMERIC, 2)::NUMERIC(12,2) AS total_weight_g,
    ROUND(COALESCE(c.total_volume_cm3, AVG(c.total_volume_cm3) OVER ())::NUMERIC, 2)::NUMERIC(14,2) AS total_volume_cm3,
    ROUND(COALESCE(c.payment_value_total, c.items_value + c.freight_total)::NUMERIC, 2)::NUMERIC(12,2) AS payment_value_total,
    COALESCE(c.max_installments, 1)::INT                          AS max_installments,
    COALESCE(c.payment_methods_count, 0)::INT                     AS payment_methods_count,
    COALESCE(c.main_payment_type, 'unknown')::TEXT                AS main_payment_type,
    (CASE
        WHEN c.primary_category ~ '^(bed_bath|furniture|home|housewares|la_cuisine|kitchen|office_furniture|garden|small_appliances|air_conditioning)' THEN 'home_and_furniture'
        WHEN c.primary_category ~ '^(computers|telephony|electronics|tablets|consoles|audio|pc_gamer|fixed_telephony|cine_photo)' THEN 'electronics_and_tech'
        WHEN c.primary_category ~ '^(fashi|watches|luggage)' THEN 'fashion_and_accessories'
        WHEN c.primary_category ~ '^(health|perfumery|diapers|baby)' THEN 'health_beauty_baby'
        WHEN c.primary_category ~ '^(sports|cool_stuff|toys|music|party|christmas|art|books|cds|dvds|flowers|stationery)' THEN 'leisure_hobbies_media'
        WHEN c.primary_category ~ '^(auto|construction|costruction|industry|agro|security|signaling)' THEN 'tools_auto_industry'
        WHEN c.primary_category ~ '^(food|drinks|pet_shop|market_place)' THEN 'food_pets_marketplace'
        ELSE 'other'
     END)::TEXT                                                   AS product_category_group,
    (CASE
        WHEN c.customer_state IN ('SP', 'RJ', 'MG', 'ES') THEN 'southeast'
        WHEN c.customer_state IN ('PR', 'RS', 'SC') THEN 'south'
        WHEN c.customer_state IN ('DF', 'GO', 'MT', 'MS') THEN 'central_west'
        WHEN c.customer_state IN ('AL', 'BA', 'CE', 'MA', 'PB', 'PE', 'PI', 'RN', 'SE') THEN 'northeast'
        WHEN c.customer_state IN ('AC', 'AP', 'AM', 'PA', 'RO', 'RR', 'TO') THEN 'north'
        ELSE 'unknown'
     END)::TEXT                                                   AS customer_region,
    (CASE
        WHEN c.seller_state IN ('SP', 'RJ', 'MG', 'ES') THEN 'southeast'
        WHEN c.seller_state IN ('PR', 'RS', 'SC') THEN 'south'
        WHEN c.seller_state IN ('DF', 'GO', 'MT', 'MS') THEN 'central_west'
        WHEN c.seller_state IN ('AL', 'BA', 'CE', 'MA', 'PB', 'PE', 'PI', 'RN', 'SE') THEN 'northeast'
        WHEN c.seller_state IN ('AC', 'AP', 'AM', 'PA', 'RO', 'RR', 'TO') THEN 'north'
        ELSE 'unknown'
     END)::TEXT                                                   AS seller_region,
    (CASE WHEN c.customer_state IS NOT NULL AND c.customer_state = c.seller_state THEN 1 ELSE 0 END)::SMALLINT AS is_same_state,
    ROUND(COALESCE(c.distance_km_raw, AVG(c.distance_km_raw) OVER ())::NUMERIC, 2)::NUMERIC(8,2) AS seller_customer_distance_km,
    c.customer_prior_orders::INT                                  AS customer_prior_orders,
    (CASE WHEN c.customer_prior_orders = 0 THEN 1 ELSE 0 END)::SMALLINT AS is_first_order,
    c.customer_prior_spend::NUMERIC(14,2)                         AS customer_prior_spend,
    ROUND(COALESCE(c.days_since_prev_raw, 0)::NUMERIC, 2)::NUMERIC(10,2) AS days_since_prev_order,
    c.tenure_months_raw::INT                                      AS customer_tenure_months,
    ROUND(COALESCE(c.customer_rolling_avg_raw, c.items_value)::NUMERIC, 2)::NUMERIC(12,2) AS customer_rolling_avg_value_3,
    c.seller_prior_orders::INT                                    AS seller_prior_orders,
    c.seller_orders_prev_30d::INT                                 AS seller_orders_prev_30d,
    -- ------------------------------------------------------------ shipping-time features
    ROUND(COALESCE(c.approval_hours_raw, AVG(c.approval_hours_raw) OVER ())::NUMERIC, 2)::NUMERIC(10,2) AS approval_hours,
    ROUND(COALESCE(c.carrier_days_raw, AVG(c.carrier_days_raw) OVER ())::NUMERIC, 2)::NUMERIC(8,2) AS carrier_handover_days,
    -- ------------------------------------------------------------ LEAKAGE columns (analysis only)
    ROUND(c.actual_delivery_days::NUMERIC, 2)::NUMERIC(8,2)       AS leak_actual_delivery_days,
    ROUND(c.delay_days::NUMERIC, 2)::NUMERIC(8,2)                 AS leak_delay_days
FROM cohort c
WITH NO DATA;

-- name: 11_create_feature_store_indexes
CREATE UNIQUE INDEX IF NOT EXISTS ux_olist_features_order_id
    ON feature_store.olist_features (order_id);
CREATE INDEX IF NOT EXISTS ix_olist_features_target
    ON feature_store.olist_features (is_late_delivery);
CREATE INDEX IF NOT EXISTS ix_olist_features_customer
    ON feature_store.olist_features (customer_unique_id);

-- name: 12_create_refresh_function
CREATE OR REPLACE FUNCTION feature_store.refresh_feature_store()
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    row_total BIGINT;
BEGIN
    REFRESH MATERIALIZED VIEW feature_store.olist_features;
    SELECT COUNT(*) INTO row_total FROM feature_store.olist_features;
    RETURN row_total;
END;
$$;

-- name: validate_duplicates
SELECT COUNT(*) - COUNT(DISTINCT order_id) AS duplicate_orders
FROM feature_store.olist_features;

-- name: validate_nulls
-- NULL count for every column of the Feature Store (generic, via JSONB).
SELECT e.key AS column_name,
       COUNT(*) FILTER (WHERE e.value = 'null'::JSONB) AS null_count
FROM feature_store.olist_features f
CROSS JOIN LATERAL jsonb_each(to_jsonb(f)) AS e(key, value)
GROUP BY e.key
ORDER BY e.key;

-- name: validate_target
SELECT COUNT(*) AS total_rows,
       SUM(is_late_delivery) AS late_rows,
       ROUND(100.0 * AVG(is_late_delivery), 2) AS late_pct
FROM feature_store.olist_features;

-- name: validate_volume
-- Row counts before / after cleaning, cohort filtering and joins.
SELECT (SELECT COUNT(*) FROM orders)                              AS raw_orders,
       (SELECT COUNT(*) FROM clean.orders)                        AS clean_orders,
       (SELECT COUNT(*) FROM clean.orders WHERE in_cohort)        AS cohort_orders,
       (SELECT COUNT(*) FROM feature_store.olist_features)        AS feature_store_rows;

-- name: export_feature_store
SELECT * FROM feature_store.olist_features ORDER BY order_id;
