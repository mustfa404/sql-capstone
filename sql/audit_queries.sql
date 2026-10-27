-- ============================================================================
-- audit_queries.sql  |  Phase 1 + Phase 2 (Business & Data Understanding)
-- Every block starts with "-- name: <block_name>" and is loaded by
-- config.load_queries(). All statistics are computed inside PostgreSQL.
-- ============================================================================

-- name: baseline_row_counts
-- Exact row count of every raw table (set-based, no Python loop).
SELECT t.table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('SELECT COUNT(*) AS c FROM %I.%I',
                                  t.table_schema, t.table_name),
                           FALSE, TRUE, '')))[1]::TEXT::BIGINT AS row_count
FROM information_schema.tables t
WHERE t.table_schema = 'public'
  AND t.table_type = 'BASE TABLE'
  AND t.table_name <> 'pipeline_metadata'
ORDER BY t.table_name;

-- name: table_constraints_summary
-- Declared primary / foreign keys per raw table.
SELECT t.table_name,
       COUNT(*) FILTER (WHERE tc.constraint_type = 'PRIMARY KEY') AS pk_count,
       COUNT(*) FILTER (WHERE tc.constraint_type = 'FOREIGN KEY') AS fk_count
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints tc
       ON tc.table_schema = t.table_schema
      AND tc.table_name = t.table_name
WHERE t.table_schema = 'public'
  AND t.table_type = 'BASE TABLE'
  AND t.table_name <> 'pipeline_metadata'
GROUP BY t.table_name
ORDER BY t.table_name;

-- name: target_baseline
-- Baseline of the mandatory target: is_late_delivery.
SELECT COUNT(*) AS total_orders,
       COUNT(*) FILTER (WHERE order_delivered_customer_date IS NOT NULL) AS delivered_with_date,
       COUNT(*) FILTER (WHERE order_delivered_customer_date > order_estimated_delivery_date) AS late_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_delivered_customer_date > order_estimated_delivery_date)
             / NULLIF(COUNT(*) FILTER (WHERE order_delivered_customer_date IS NOT NULL), 0), 2) AS late_pct
FROM orders;

-- name: table_columns
-- Structural audit: columns and datatypes per table (one row per table).
SELECT c.table_name,
       COUNT(*) AS column_count,
       STRING_AGG(c.column_name::TEXT || ' ' || c.data_type::TEXT, ', '
                  ORDER BY c.ordinal_position) AS columns
FROM information_schema.columns c
JOIN information_schema.tables t
  ON t.table_schema = c.table_schema AND t.table_name = c.table_name
WHERE c.table_schema = 'public'
  AND t.table_type = 'BASE TABLE'
  AND c.table_name <> 'pipeline_metadata'
GROUP BY c.table_name
ORDER BY c.table_name;

-- name: foreign_keys
-- Declared foreign keys (expected to be empty for the raw Olist load).
SELECT tc.table_name,
       kcu.column_name,
       ccu.table_name  AS references_table,
       ccu.column_name AS references_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'public'
ORDER BY tc.table_name, kcu.column_name;

-- name: eda_summary
-- Descriptive statistics (COUNT, MIN, MAX, AVG, STDDEV, MEDIAN) computed with
-- SQL aggregates. LATERAL VALUES "unpivots" the numeric columns of each table.
SELECT 'order_items' AS table_name, v.column_name,
       COUNT(v.val) AS non_null_count,
       ROUND(MIN(v.val)::NUMERIC, 4) AS min_value,
       ROUND(MAX(v.val)::NUMERIC, 4) AS max_value,
       ROUND(AVG(v.val)::NUMERIC, 4) AS avg_value,
       ROUND(STDDEV(v.val)::NUMERIC, 4) AS stddev_value,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v.val))::NUMERIC, 4) AS median_value
FROM order_items t
CROSS JOIN LATERAL (VALUES
    ('price', t.price::DOUBLE PRECISION),
    ('freight_value', t.freight_value::DOUBLE PRECISION),
    ('order_item_id', t.order_item_id::DOUBLE PRECISION)
) AS v(column_name, val)
GROUP BY v.column_name
UNION ALL
SELECT 'order_payments', v.column_name,
       COUNT(v.val),
       ROUND(MIN(v.val)::NUMERIC, 4), ROUND(MAX(v.val)::NUMERIC, 4),
       ROUND(AVG(v.val)::NUMERIC, 4), ROUND(STDDEV(v.val)::NUMERIC, 4),
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v.val))::NUMERIC, 4)
FROM order_payments t
CROSS JOIN LATERAL (VALUES
    ('payment_value', t.payment_value::DOUBLE PRECISION),
    ('payment_installments', t.payment_installments::DOUBLE PRECISION),
    ('payment_sequential', t.payment_sequential::DOUBLE PRECISION)
) AS v(column_name, val)
GROUP BY v.column_name
UNION ALL
SELECT 'products', v.column_name,
       COUNT(v.val),
       ROUND(MIN(v.val)::NUMERIC, 4), ROUND(MAX(v.val)::NUMERIC, 4),
       ROUND(AVG(v.val)::NUMERIC, 4), ROUND(STDDEV(v.val)::NUMERIC, 4),
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v.val))::NUMERIC, 4)
FROM products t
CROSS JOIN LATERAL (VALUES
    ('product_weight_g', t.product_weight_g::DOUBLE PRECISION),
    ('product_length_cm', t.product_length_cm::DOUBLE PRECISION),
    ('product_height_cm', t.product_height_cm::DOUBLE PRECISION),
    ('product_width_cm', t.product_width_cm::DOUBLE PRECISION),
    ('product_photos_qty', t.product_photos_qty::DOUBLE PRECISION),
    ('product_name_lenght', t.product_name_lenght::DOUBLE PRECISION),
    ('product_description_lenght', t.product_description_lenght::DOUBLE PRECISION)
) AS v(column_name, val)
GROUP BY v.column_name
UNION ALL
SELECT 'order_reviews', v.column_name,
       COUNT(v.val),
       ROUND(MIN(v.val)::NUMERIC, 4), ROUND(MAX(v.val)::NUMERIC, 4),
       ROUND(AVG(v.val)::NUMERIC, 4), ROUND(STDDEV(v.val)::NUMERIC, 4),
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v.val))::NUMERIC, 4)
FROM order_reviews t
CROSS JOIN LATERAL (VALUES
    ('review_score', t.review_score::DOUBLE PRECISION)
) AS v(column_name, val)
GROUP BY v.column_name
UNION ALL
SELECT 'geolocation', v.column_name,
       COUNT(v.val),
       ROUND(MIN(v.val)::NUMERIC, 4), ROUND(MAX(v.val)::NUMERIC, 4),
       ROUND(AVG(v.val)::NUMERIC, 4), ROUND(STDDEV(v.val)::NUMERIC, 4),
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v.val))::NUMERIC, 4)
FROM geolocation t
CROSS JOIN LATERAL (VALUES
    ('geolocation_lat', t.geolocation_lat::DOUBLE PRECISION),
    ('geolocation_lng', t.geolocation_lng::DOUBLE PRECISION)
) AS v(column_name, val)
GROUP BY v.column_name
UNION ALL
SELECT 'orders (derived)', v.column_name,
       COUNT(v.val),
       ROUND(MIN(v.val)::NUMERIC, 4), ROUND(MAX(v.val)::NUMERIC, 4),
       ROUND(AVG(v.val)::NUMERIC, 4), ROUND(STDDEV(v.val)::NUMERIC, 4),
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v.val))::NUMERIC, 4)
FROM orders t
CROSS JOIN LATERAL (VALUES
    ('delivery_days (delivered - purchase)',
     (EXTRACT(EPOCH FROM (t.order_delivered_customer_date - t.order_purchase_timestamp)) / 86400.0)::DOUBLE PRECISION),
    ('estimated_days (estimated - purchase)',
     (EXTRACT(EPOCH FROM (t.order_estimated_delivery_date - t.order_purchase_timestamp)) / 86400.0)::DOUBLE PRECISION),
    ('delay_days (delivered - estimated)',
     (EXTRACT(EPOCH FROM (t.order_delivered_customer_date - t.order_estimated_delivery_date)) / 86400.0)::DOUBLE PRECISION),
    ('approval_hours (approved - purchase)',
     (EXTRACT(EPOCH FROM (t.order_approved_at - t.order_purchase_timestamp)) / 3600.0)::DOUBLE PRECISION)
) AS v(column_name, val)
GROUP BY v.column_name
ORDER BY table_name, column_name;

-- name: quality_audit
-- Data-quality defect log: missing values, duplicates, IQR outliers,
-- structural inconsistencies, orphan keys and malformed text (regex).
WITH q_price AS (
    SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY price) AS q1,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY price) AS q3
    FROM order_items
),
q_freight AS (
    SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY freight_value) AS q1,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY freight_value) AS q3
    FROM order_items
),
q_payment AS (
    SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY payment_value) AS q1,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY payment_value) AS q3
    FROM order_payments
),
q_weight AS (
    SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY product_weight_g) AS q1,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY product_weight_g) AS q3
    FROM products
),
checks AS (
    -- ---------------------------------------------------------------- missing values
    SELECT 'orders' AS table_name, 'order_approved_at' AS column_name, 'missing_value' AS check_type,
           COUNT(*) FILTER (WHERE order_approved_at IS NULL) AS defect_count, COUNT(*) AS total_rows
    FROM orders
    UNION ALL
    SELECT 'orders', 'order_delivered_carrier_date', 'missing_value',
           COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL), COUNT(*) FROM orders
    UNION ALL
    SELECT 'orders', 'order_delivered_customer_date', 'missing_value',
           COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL), COUNT(*) FROM orders
    UNION ALL
    SELECT 'orders', 'order_estimated_delivery_date', 'missing_value',
           COUNT(*) FILTER (WHERE order_estimated_delivery_date IS NULL), COUNT(*) FROM orders
    UNION ALL
    SELECT 'order_items', 'freight_value', 'missing_value',
           COUNT(*) FILTER (WHERE freight_value IS NULL), COUNT(*) FROM order_items
    UNION ALL
    SELECT 'order_payments', 'payment_value', 'missing_value',
           COUNT(*) FILTER (WHERE payment_value IS NULL), COUNT(*) FROM order_payments
    UNION ALL
    SELECT 'products', 'product_category_name', 'missing_or_empty',
           COUNT(*) FILTER (WHERE product_category_name IS NULL OR TRIM(product_category_name) = ''), COUNT(*)
    FROM products
    UNION ALL
    SELECT 'products', 'product_name_lenght', 'missing_value',
           COUNT(*) FILTER (WHERE product_name_lenght IS NULL), COUNT(*) FROM products
    UNION ALL
    SELECT 'products', 'product_description_lenght', 'missing_value',
           COUNT(*) FILTER (WHERE product_description_lenght IS NULL), COUNT(*) FROM products
    UNION ALL
    SELECT 'products', 'product_photos_qty', 'missing_value',
           COUNT(*) FILTER (WHERE product_photos_qty IS NULL), COUNT(*) FROM products
    UNION ALL
    SELECT 'products', 'product_weight_g', 'missing_value',
           COUNT(*) FILTER (WHERE product_weight_g IS NULL), COUNT(*) FROM products
    UNION ALL
    SELECT 'products', 'product_length_cm', 'missing_value',
           COUNT(*) FILTER (WHERE product_length_cm IS NULL), COUNT(*) FROM products
    UNION ALL
    SELECT 'products', 'product_height_cm', 'missing_value',
           COUNT(*) FILTER (WHERE product_height_cm IS NULL), COUNT(*) FROM products
    UNION ALL
    SELECT 'products', 'product_width_cm', 'missing_value',
           COUNT(*) FILTER (WHERE product_width_cm IS NULL), COUNT(*) FROM products
    UNION ALL
    SELECT 'order_reviews', 'review_comment_title', 'missing_or_empty',
           COUNT(*) FILTER (WHERE review_comment_title IS NULL OR TRIM(review_comment_title) = ''), COUNT(*)
    FROM order_reviews
    UNION ALL
    SELECT 'order_reviews', 'review_comment_message', 'missing_or_empty',
           COUNT(*) FILTER (WHERE review_comment_message IS NULL OR TRIM(review_comment_message) = ''), COUNT(*)
    FROM order_reviews
    UNION ALL
    SELECT 'customers', 'customer_city', 'missing_or_empty',
           COUNT(*) FILTER (WHERE customer_city IS NULL OR TRIM(customer_city) = ''), COUNT(*) FROM customers
    UNION ALL
    SELECT 'sellers', 'seller_city', 'missing_or_empty',
           COUNT(*) FILTER (WHERE seller_city IS NULL OR TRIM(seller_city) = ''), COUNT(*) FROM sellers
    UNION ALL
    SELECT 'geolocation', 'geolocation_lat', 'missing_value',
           COUNT(*) FILTER (WHERE geolocation_lat IS NULL), COUNT(*) FROM geolocation
    UNION ALL
    SELECT 'geolocation', 'geolocation_lng', 'missing_value',
           COUNT(*) FILTER (WHERE geolocation_lng IS NULL), COUNT(*) FROM geolocation

    -- ---------------------------------------------------------------- duplicates
    UNION ALL
    SELECT 'customers', 'customer_id', 'duplicate_key',
           COUNT(*) - COUNT(DISTINCT customer_id), COUNT(*) FROM customers
    UNION ALL
    SELECT 'orders', 'order_id', 'duplicate_key',
           COUNT(*) - COUNT(DISTINCT order_id), COUNT(*) FROM orders
    UNION ALL
    SELECT 'sellers', 'seller_id', 'duplicate_key',
           COUNT(*) - COUNT(DISTINCT seller_id), COUNT(*) FROM sellers
    UNION ALL
    SELECT 'products', 'product_id', 'duplicate_key',
           COUNT(*) - COUNT(DISTINCT product_id), COUNT(*) FROM products
    UNION ALL
    SELECT 'order_reviews', 'review_id', 'duplicate_key',
           COUNT(*) - COUNT(DISTINCT review_id), COUNT(*) FROM order_reviews
    UNION ALL
    SELECT 'order_items', 'order_id+order_item_id', 'duplicate_key',
           COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT order_id, order_item_id FROM order_items) d),
           COUNT(*)
    FROM order_items
    UNION ALL
    SELECT 'order_payments', 'order_id+payment_sequential', 'duplicate_key',
           COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT order_id, payment_sequential FROM order_payments) d),
           COUNT(*)
    FROM order_payments
    UNION ALL
    SELECT 'order_reviews', 'review_id+order_id', 'duplicate_key',
           COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT review_id, order_id FROM order_reviews) d),
           COUNT(*)
    FROM order_reviews
    UNION ALL
    SELECT 'geolocation', '(all columns)', 'duplicate_row',
           COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM geolocation) d), COUNT(*)
    FROM geolocation

    -- ---------------------------------------------------------------- IQR outliers
    UNION ALL
    SELECT 'order_items', 'price', 'outlier_iqr',
           COUNT(*) FILTER (WHERE oi.price < q.q1 - 1.5 * (q.q3 - q.q1)
                               OR oi.price > q.q3 + 1.5 * (q.q3 - q.q1)), COUNT(*)
    FROM order_items oi CROSS JOIN q_price q
    UNION ALL
    SELECT 'order_items', 'freight_value', 'outlier_iqr',
           COUNT(*) FILTER (WHERE oi.freight_value < q.q1 - 1.5 * (q.q3 - q.q1)
                               OR oi.freight_value > q.q3 + 1.5 * (q.q3 - q.q1)), COUNT(*)
    FROM order_items oi CROSS JOIN q_freight q
    UNION ALL
    SELECT 'order_payments', 'payment_value', 'outlier_iqr',
           COUNT(*) FILTER (WHERE op.payment_value < q.q1 - 1.5 * (q.q3 - q.q1)
                               OR op.payment_value > q.q3 + 1.5 * (q.q3 - q.q1)), COUNT(*)
    FROM order_payments op CROSS JOIN q_payment q
    UNION ALL
    SELECT 'products', 'product_weight_g', 'outlier_iqr',
           COUNT(*) FILTER (WHERE p.product_weight_g < q.q1 - 1.5 * (q.q3 - q.q1)
                               OR p.product_weight_g > q.q3 + 1.5 * (q.q3 - q.q1)), COUNT(*)
    FROM products p CROSS JOIN q_weight q

    -- ---------------------------------------------------------------- structural inconsistencies
    UNION ALL
    SELECT 'orders', 'order_delivered_customer_date', 'delivered_before_purchase',
           COUNT(*) FILTER (WHERE order_delivered_customer_date < order_purchase_timestamp), COUNT(*) FROM orders
    UNION ALL
    SELECT 'orders', 'order_delivered_carrier_date', 'carrier_before_purchase',
           COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_purchase_timestamp), COUNT(*) FROM orders
    UNION ALL
    SELECT 'orders', 'order_approved_at', 'approved_before_purchase',
           COUNT(*) FILTER (WHERE order_approved_at < order_purchase_timestamp), COUNT(*) FROM orders
    UNION ALL
    SELECT 'orders', 'order_estimated_delivery_date', 'estimated_before_purchase',
           COUNT(*) FILTER (WHERE order_estimated_delivery_date < order_purchase_timestamp), COUNT(*) FROM orders
    UNION ALL
    SELECT 'orders', 'order_status', 'delivered_status_without_delivery_date',
           COUNT(*) FILTER (WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL), COUNT(*)
    FROM orders
    UNION ALL
    SELECT 'orders', 'order_status', 'delivery_date_on_non_delivered_status',
           COUNT(*) FILTER (WHERE order_status <> 'delivered' AND order_delivered_customer_date IS NOT NULL), COUNT(*)
    FROM orders
    UNION ALL
    SELECT 'orders', 'order_status', 'unexpected_status_value',
           COUNT(*) FILTER (WHERE order_status NOT IN ('delivered', 'shipped', 'canceled', 'unavailable',
                                                        'invoiced', 'processing', 'created', 'approved')), COUNT(*)
    FROM orders
    UNION ALL
    SELECT 'order_items', 'price', 'non_positive_value',
           COUNT(*) FILTER (WHERE price <= 0), COUNT(*) FROM order_items
    UNION ALL
    SELECT 'order_items', 'freight_value', 'negative_value',
           COUNT(*) FILTER (WHERE freight_value < 0), COUNT(*) FROM order_items
    UNION ALL
    SELECT 'order_payments', 'payment_value', 'non_positive_value',
           COUNT(*) FILTER (WHERE payment_value <= 0), COUNT(*) FROM order_payments
    UNION ALL
    SELECT 'order_payments', 'payment_installments', 'invalid_installments',
           COUNT(*) FILTER (WHERE payment_installments < 1), COUNT(*) FROM order_payments
    UNION ALL
    SELECT 'order_payments', 'payment_type', 'unexpected_value',
           COUNT(*) FILTER (WHERE payment_type NOT IN ('credit_card', 'boleto', 'voucher',
                                                       'debit_card', 'not_defined')), COUNT(*)
    FROM order_payments
    UNION ALL
    SELECT 'order_reviews', 'review_score', 'out_of_range_1_5',
           COUNT(*) FILTER (WHERE review_score NOT BETWEEN 1 AND 5), COUNT(*) FROM order_reviews
    UNION ALL
    SELECT 'order_reviews', 'review_answer_timestamp', 'answer_before_creation',
           COUNT(*) FILTER (WHERE review_answer_timestamp < review_creation_date), COUNT(*) FROM order_reviews
    UNION ALL
    SELECT 'products', 'product_weight_g', 'zero_weight',
           COUNT(*) FILTER (WHERE product_weight_g = 0), COUNT(*) FROM products

    -- ---------------------------------------------------------------- orphan keys
    UNION ALL
    SELECT 'order_items', 'order_id', 'orphan_foreign_key',
           COUNT(*) FILTER (WHERE o.order_id IS NULL), COUNT(*)
    FROM order_items oi LEFT JOIN (SELECT DISTINCT order_id FROM orders) o ON o.order_id = oi.order_id
    UNION ALL
    SELECT 'order_items', 'product_id', 'orphan_foreign_key',
           COUNT(*) FILTER (WHERE p.product_id IS NULL), COUNT(*)
    FROM order_items oi LEFT JOIN (SELECT DISTINCT product_id FROM products) p ON p.product_id = oi.product_id
    UNION ALL
    SELECT 'order_items', 'seller_id', 'orphan_foreign_key',
           COUNT(*) FILTER (WHERE s.seller_id IS NULL), COUNT(*)
    FROM order_items oi LEFT JOIN (SELECT DISTINCT seller_id FROM sellers) s ON s.seller_id = oi.seller_id
    UNION ALL
    SELECT 'orders', 'customer_id', 'orphan_foreign_key',
           COUNT(*) FILTER (WHERE c.customer_id IS NULL), COUNT(*)
    FROM orders o LEFT JOIN (SELECT DISTINCT customer_id FROM customers) c ON c.customer_id = o.customer_id
    UNION ALL
    SELECT 'order_payments', 'order_id', 'orphan_foreign_key',
           COUNT(*) FILTER (WHERE o.order_id IS NULL), COUNT(*)
    FROM order_payments op LEFT JOIN (SELECT DISTINCT order_id FROM orders) o ON o.order_id = op.order_id
    UNION ALL
    SELECT 'products', 'product_category_name', 'category_without_translation',
           COUNT(*) FILTER (WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL), COUNT(*)
    FROM products p
    LEFT JOIN (SELECT DISTINCT product_category_name FROM product_category_name_translation) t
           ON t.product_category_name = p.product_category_name

    -- ---------------------------------------------------------------- malformed text (regex)
    UNION ALL
    SELECT 'customers', 'customer_id', 'malformed_id_regex',
           COUNT(*) FILTER (WHERE customer_id !~ '^[0-9a-f]{32}$'), COUNT(*) FROM customers
    UNION ALL
    SELECT 'customers', 'customer_unique_id', 'malformed_id_regex',
           COUNT(*) FILTER (WHERE customer_unique_id !~ '^[0-9a-f]{32}$'), COUNT(*) FROM customers
    UNION ALL
    SELECT 'orders', 'order_id', 'malformed_id_regex',
           COUNT(*) FILTER (WHERE order_id !~ '^[0-9a-f]{32}$'), COUNT(*) FROM orders
    UNION ALL
    SELECT 'sellers', 'seller_id', 'malformed_id_regex',
           COUNT(*) FILTER (WHERE seller_id !~ '^[0-9a-f]{32}$'), COUNT(*) FROM sellers
    UNION ALL
    SELECT 'products', 'product_id', 'malformed_id_regex',
           COUNT(*) FILTER (WHERE product_id !~ '^[0-9a-f]{32}$'), COUNT(*) FROM products
    UNION ALL
    SELECT 'customers', 'customer_state', 'malformed_state_regex',
           COUNT(*) FILTER (WHERE customer_state !~ '^[A-Z]{2}$'), COUNT(*) FROM customers
    UNION ALL
    SELECT 'sellers', 'seller_state', 'malformed_state_regex',
           COUNT(*) FILTER (WHERE seller_state !~ '^[A-Z]{2}$'), COUNT(*) FROM sellers
    UNION ALL
    SELECT 'customers', 'customer_zip_code_prefix', 'malformed_zip_regex',
           COUNT(*) FILTER (WHERE customer_zip_code_prefix !~ '^[0-9]{1,5}$'), COUNT(*) FROM customers
    UNION ALL
    SELECT 'customers', 'customer_zip_code_prefix', 'zip_missing_leading_zero',
           COUNT(*) FILTER (WHERE customer_zip_code_prefix ~ '^[0-9]{1,4}$'), COUNT(*) FROM customers
    UNION ALL
    SELECT 'customers', 'customer_city', 'city_contains_digits_or_symbols',
           COUNT(*) FILTER (WHERE customer_city ~ '[0-9@,/]'), COUNT(*) FROM customers
    UNION ALL
    SELECT 'customers', 'customer_city', 'city_has_edge_whitespace',
           COUNT(*) FILTER (WHERE customer_city ~ '^\s|\s$'), COUNT(*) FROM customers
    UNION ALL
    SELECT 'customers', 'customer_city', 'city_has_uppercase',
           COUNT(*) FILTER (WHERE customer_city ~ '[A-Z]'), COUNT(*) FROM customers
    UNION ALL
    SELECT 'sellers', 'seller_city', 'city_contains_digits_or_symbols',
           COUNT(*) FILTER (WHERE seller_city ~ '[0-9@,/]'), COUNT(*) FROM sellers
    UNION ALL
    SELECT 'sellers', 'seller_city', 'city_has_edge_whitespace',
           COUNT(*) FILTER (WHERE seller_city ~ '^\s|\s$'), COUNT(*) FROM sellers
    UNION ALL
    SELECT 'sellers', 'seller_city', 'city_has_uppercase',
           COUNT(*) FILTER (WHERE seller_city ~ '[A-Z]'), COUNT(*) FROM sellers
    UNION ALL
    SELECT 'order_reviews', 'review_comment_message', 'whitespace_only_text',
           COUNT(*) FILTER (WHERE review_comment_message ~ '^\s+$'), COUNT(*) FROM order_reviews
)
SELECT ROW_NUMBER() OVER (ORDER BY table_name, check_type, column_name) AS check_id,
       table_name,
       column_name,
       check_type,
       defect_count,
       total_rows,
       ROUND(100.0 * defect_count / NULLIF(total_rows, 0), 2) AS defect_pct
FROM checks
ORDER BY check_id;
