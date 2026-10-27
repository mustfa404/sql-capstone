-- ============================================================================
-- data_cleaning.sql  |  Phase 3 - Data Preparation (cleaning in SQL)
-- Raw tables (public.*) are never modified. Cleaned copies are written to the
-- "clean" schema, so the whole script is idempotent and can be re-run safely.
--   * Deduplication ........ ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)
--   * Imputation ........... COALESCE / CASE WHEN / windowed AVG() OVER (...)
--   * Outlier capping ...... PERCENTILE_CONT winsorisation (1st / 99th pct)
--   * Cohort filtering ..... in_cohort flag on clean.orders
-- ============================================================================

-- name: 00_create_schemas
CREATE SCHEMA IF NOT EXISTS clean;
CREATE SCHEMA IF NOT EXISTS feature_store;
DROP MATERIALIZED VIEW IF EXISTS feature_store.olist_features;

-- name: 01_clean_customers
DROP TABLE IF EXISTS clean.customers CASCADE;
CREATE TABLE clean.customers AS
SELECT d.customer_id,
       d.customer_unique_id,
       CASE WHEN TRIM(d.customer_zip_code_prefix) ~ '^[0-9]{1,5}$'
            THEN LPAD(TRIM(d.customer_zip_code_prefix), 5, '0') END AS customer_zip_code_prefix,
       NULLIF(LOWER(TRIM(d.customer_city)), '') AS customer_city,
       CASE WHEN UPPER(TRIM(d.customer_state)) ~ '^[A-Z]{2}$'
            THEN UPPER(TRIM(d.customer_state)) END AS customer_state
FROM (
    SELECT c.*,
           ROW_NUMBER() OVER (PARTITION BY c.customer_id
                              ORDER BY c.customer_unique_id) AS rn
    FROM customers c
    WHERE c.customer_id IS NOT NULL AND TRIM(c.customer_id) <> ''
) d
WHERE d.rn = 1;
ALTER TABLE clean.customers ADD PRIMARY KEY (customer_id);

-- name: 02_clean_sellers
DROP TABLE IF EXISTS clean.sellers CASCADE;
CREATE TABLE clean.sellers AS
SELECT d.seller_id,
       CASE WHEN TRIM(d.seller_zip_code_prefix) ~ '^[0-9]{1,5}$'
            THEN LPAD(TRIM(d.seller_zip_code_prefix), 5, '0') END AS seller_zip_code_prefix,
       NULLIF(LOWER(TRIM(d.seller_city)), '') AS seller_city,
       CASE WHEN UPPER(TRIM(d.seller_state)) ~ '^[A-Z]{2}$'
            THEN UPPER(TRIM(d.seller_state)) END AS seller_state
FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY s.seller_id
                              ORDER BY s.seller_zip_code_prefix) AS rn
    FROM sellers s
    WHERE s.seller_id IS NOT NULL AND TRIM(s.seller_id) <> ''
) d
WHERE d.rn = 1;
ALTER TABLE clean.sellers ADD PRIMARY KEY (seller_id);

-- name: 03_clean_geolocation_zip
-- ~1M raw rows -> one row per zip prefix (average of valid Brazilian coordinates).
DROP TABLE IF EXISTS clean.geolocation_zip CASCADE;
CREATE TABLE clean.geolocation_zip AS
SELECT LPAD(TRIM(g.geolocation_zip_code_prefix), 5, '0') AS zip_code_prefix,
       AVG(g.geolocation_lat) AS lat,
       AVG(g.geolocation_lng) AS lng,
       COUNT(*) AS source_rows
FROM geolocation g
WHERE TRIM(g.geolocation_zip_code_prefix) ~ '^[0-9]{1,5}$'
  AND g.geolocation_lat BETWEEN -34 AND 6
  AND g.geolocation_lng BETWEEN -74 AND -34
GROUP BY LPAD(TRIM(g.geolocation_zip_code_prefix), 5, '0');
ALTER TABLE clean.geolocation_zip ADD PRIMARY KEY (zip_code_prefix);

-- name: 04_clean_products
-- Dedup -> English category -> impute (category average, then global average)
-- -> winsorise weight / dimensions at the 1st and 99th percentile.
DROP TABLE IF EXISTS clean.products CASCADE;
CREATE TABLE clean.products AS
WITH dedup AS (
    SELECT p.*,
           ROW_NUMBER() OVER (
               PARTITION BY p.product_id
               ORDER BY (CASE WHEN p.product_category_name IS NULL THEN 1 ELSE 0 END),
                        (CASE WHEN p.product_weight_g IS NULL THEN 1 ELSE 0 END)
           ) AS rn
    FROM products p
    WHERE p.product_id IS NOT NULL
),
base AS (
    SELECT d.product_id,
           COALESCE(NULLIF(TRIM(t.product_category_name_english), ''),
                    NULLIF(TRIM(d.product_category_name), ''),
                    'unknown') AS product_category,
           d.product_name_lenght        AS name_length,
           d.product_description_lenght AS description_length,
           d.product_photos_qty         AS photos_qty,
           NULLIF(d.product_weight_g, 0) AS weight_g,
           d.product_length_cm          AS length_cm,
           d.product_height_cm          AS height_cm,
           d.product_width_cm           AS width_cm
    FROM dedup d
    LEFT JOIN product_category_name_translation t
           ON t.product_category_name = d.product_category_name
    WHERE d.rn = 1
),
imputed AS (
    SELECT b.product_id,
           b.product_category,
           COALESCE(b.name_length, ROUND(AVG(b.name_length) OVER (PARTITION BY b.product_category)),
                    ROUND(AVG(b.name_length) OVER ()))::INT AS name_length,
           COALESCE(b.description_length, ROUND(AVG(b.description_length) OVER (PARTITION BY b.product_category)),
                    ROUND(AVG(b.description_length) OVER ()))::INT AS description_length,
           COALESCE(b.photos_qty, ROUND(AVG(b.photos_qty) OVER (PARTITION BY b.product_category)),
                    ROUND(AVG(b.photos_qty) OVER ()))::INT AS photos_qty,
           COALESCE(b.weight_g, ROUND(AVG(b.weight_g) OVER (PARTITION BY b.product_category)),
                    ROUND(AVG(b.weight_g) OVER ()))::INT AS weight_g,
           COALESCE(b.length_cm, ROUND(AVG(b.length_cm) OVER (PARTITION BY b.product_category)),
                    ROUND(AVG(b.length_cm) OVER ()))::INT AS length_cm,
           COALESCE(b.height_cm, ROUND(AVG(b.height_cm) OVER (PARTITION BY b.product_category)),
                    ROUND(AVG(b.height_cm) OVER ()))::INT AS height_cm,
           COALESCE(b.width_cm, ROUND(AVG(b.width_cm) OVER (PARTITION BY b.product_category)),
                    ROUND(AVG(b.width_cm) OVER ()))::INT AS width_cm
    FROM base b
),
pct AS (
    SELECT PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY weight_g) AS w_lo,
           PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY weight_g) AS w_hi,
           PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY length_cm) AS l_lo,
           PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY length_cm) AS l_hi,
           PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY height_cm) AS h_lo,
           PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY height_cm) AS h_hi,
           PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY width_cm)  AS d_lo,
           PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY width_cm)  AS d_hi
    FROM imputed
)
SELECT i.product_id,
       i.product_category,
       i.name_length,
       i.description_length,
       i.photos_qty,
       LEAST(GREATEST(i.weight_g,  p.w_lo), p.w_hi)::INT AS weight_g,
       LEAST(GREATEST(i.length_cm, p.l_lo), p.l_hi)::INT AS length_cm,
       LEAST(GREATEST(i.height_cm, p.h_lo), p.h_hi)::INT AS height_cm,
       LEAST(GREATEST(i.width_cm,  p.d_lo), p.d_hi)::INT AS width_cm
FROM imputed i
CROSS JOIN pct p;
ALTER TABLE clean.products ADD PRIMARY KEY (product_id);

-- name: 05_clean_orders
-- Dedup, normalise status, null-out impossible timestamps and flag the
-- analysis cohort. All orders are kept (needed for customer / seller history
-- windows); only in_cohort = TRUE rows reach the Feature Store.
DROP TABLE IF EXISTS clean.orders CASCADE;
CREATE TABLE clean.orders AS
SELECT d.order_id,
       d.customer_id,
       d.order_status,
       d.order_purchase_timestamp,
       CASE WHEN d.order_approved_at >= d.order_purchase_timestamp
            THEN d.order_approved_at END AS order_approved_at,
       CASE WHEN d.order_delivered_carrier_date >= d.order_purchase_timestamp
            THEN d.order_delivered_carrier_date END AS order_delivered_carrier_date,
       d.order_delivered_customer_date,
       d.order_estimated_delivery_date,
       COALESCE(d.order_status = 'delivered'
                AND d.order_delivered_customer_date IS NOT NULL
                AND d.order_estimated_delivery_date IS NOT NULL
                AND d.order_delivered_customer_date >= d.order_purchase_timestamp,
                FALSE) AS in_cohort
FROM (
    SELECT o.order_id,
           o.customer_id,
           LOWER(TRIM(o.order_status)) AS order_status,
           o.order_purchase_timestamp,
           o.order_approved_at,
           o.order_delivered_carrier_date,
           o.order_delivered_customer_date,
           o.order_estimated_delivery_date,
           ROW_NUMBER() OVER (PARTITION BY o.order_id
                              ORDER BY o.order_purchase_timestamp DESC NULLS LAST) AS rn
    FROM orders o
    WHERE o.order_id IS NOT NULL
      AND o.order_purchase_timestamp IS NOT NULL
) d
WHERE d.rn = 1;
ALTER TABLE clean.orders ADD PRIMARY KEY (order_id);

-- name: 06_clean_order_items
-- Dedup on (order_id, order_item_id), drop non-positive prices, impute missing
-- freight with 0, winsorise price / freight at the 99th percentile.
DROP TABLE IF EXISTS clean.order_items CASCADE;
CREATE TABLE clean.order_items AS
WITH dedup AS (
    SELECT oi.*,
           ROW_NUMBER() OVER (PARTITION BY oi.order_id, oi.order_item_id
                              ORDER BY oi.shipping_limit_date DESC NULLS LAST) AS rn
    FROM order_items oi
    WHERE oi.order_id IS NOT NULL
      AND oi.order_item_id IS NOT NULL
      AND oi.price IS NOT NULL
      AND oi.price > 0
),
valid AS (
    SELECT * FROM dedup WHERE rn = 1
),
pct AS (
    SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY price) AS price_p99,
           PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY COALESCE(freight_value, 0)) AS freight_p99
    FROM valid
)
SELECT v.order_id,
       v.order_item_id,
       v.product_id,
       v.seller_id,
       v.shipping_limit_date,
       v.price AS price_raw,
       LEAST(v.price, p.price_p99)::NUMERIC(12,2) AS price,
       LEAST(COALESCE(v.freight_value, 0), p.freight_p99)::NUMERIC(12,2) AS freight_value
FROM valid v
CROSS JOIN pct p;
ALTER TABLE clean.order_items ADD PRIMARY KEY (order_id, order_item_id);

-- name: 07_clean_order_payments
DROP TABLE IF EXISTS clean.order_payments CASCADE;
CREATE TABLE clean.order_payments AS
WITH dedup AS (
    SELECT op.*,
           ROW_NUMBER() OVER (PARTITION BY op.order_id, op.payment_sequential
                              ORDER BY op.payment_value DESC NULLS LAST) AS rn
    FROM order_payments op
    WHERE op.order_id IS NOT NULL
      AND op.payment_sequential IS NOT NULL
      AND op.payment_value IS NOT NULL
      AND op.payment_value >= 0
),
valid AS (
    SELECT * FROM dedup WHERE rn = 1
),
pct AS (
    SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY payment_value) AS value_p99
    FROM valid
)
SELECT v.order_id,
       v.payment_sequential,
       COALESCE(NULLIF(LOWER(TRIM(v.payment_type)), ''), 'unknown') AS payment_type,
       GREATEST(COALESCE(v.payment_installments, 1), 1) AS payment_installments,
       LEAST(v.payment_value, p.value_p99)::NUMERIC(12,2) AS payment_value
FROM valid v
CROSS JOIN pct p;
ALTER TABLE clean.order_payments ADD PRIMARY KEY (order_id, payment_sequential);

-- name: 08_clean_order_reviews
-- Cleaned for completeness. Reviews are written AFTER delivery, so they are
-- deliberately NOT used as features (they would leak the target).
DROP TABLE IF EXISTS clean.order_reviews CASCADE;
CREATE TABLE clean.order_reviews AS
SELECT d.review_id,
       d.order_id,
       d.review_score,
       NULLIF(TRIM(d.review_comment_title), '')   AS review_comment_title,
       NULLIF(TRIM(d.review_comment_message), '') AS review_comment_message,
       d.review_creation_date,
       d.review_answer_timestamp
FROM (
    SELECT r.*,
           ROW_NUMBER() OVER (PARTITION BY r.review_id, r.order_id
                              ORDER BY r.review_answer_timestamp DESC NULLS LAST) AS rn
    FROM order_reviews r
    WHERE r.review_id IS NOT NULL
      AND r.order_id IS NOT NULL
      AND r.review_score BETWEEN 1 AND 5
) d
WHERE d.rn = 1;
ALTER TABLE clean.order_reviews ADD PRIMARY KEY (review_id, order_id);
