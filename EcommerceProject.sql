-- =====================================================
-- STEP 1: CREATE ANALYSIS-READY DATASET
-- =====================================================
-- Purpose:
-- Clean raw event data by:
-- - converting timestamps
-- - standardizing text fields
-- - handling missing values
-- - removing duplicates
-- - extracting category hierarchy
-- =====================================================

CREATE OR REPLACE VIEW ECOMMERCE.PUBLIC.EVENTS_ANALYSIS_READY AS

WITH base AS (

    -- Convert timestamp and clean fields
    SELECT
        TRY_TO_TIMESTAMP_NTZ(REPLACE(event_time, ' UTC', ''), 'YYYY-MM-DD HH24:MI:SS') AS event_ts,
        LOWER(TRIM(event_type)) AS event_type,
        product_id,
        category_id,

        -- Handle missing category and brand
        COALESCE(NULLIF(TRIM(LOWER(category_code)), ''), 'unknown') AS category_code,
        COALESCE(NULLIF(TRIM(LOWER(brand)), ''), 'unknown') AS brand,

        price,
        user_id,
        TRIM(user_session) AS user_session

    FROM ECOMMERCE.PUBLIC.EVENTS
),

validated AS (

    -- Remove critical nulls
    SELECT *
    FROM base
    WHERE event_ts IS NOT NULL
      AND user_session IS NOT NULL
),

deduplicated AS (

    -- Remove duplicate events
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY user_id, user_session, product_id, event_ts, event_type
            ORDER BY event_ts
        ) AS rn
    FROM validated
),

final_clean AS (

    -- Final cleaned dataset
    SELECT
        event_ts,
        CAST(event_ts AS DATE) AS event_date,
        event_type,
        product_id,
        category_id,
        category_code,

        -- Extract category hierarchy
        SPLIT_PART(category_code, '.', 1) AS main_category,
        SPLIT_PART(category_code, '.', 2) AS sub_category,
        SPLIT_PART(category_code, '.', 3) AS sub_sub_category,

        brand,
        price,
        user_id,
        user_session

    FROM deduplicated
    WHERE rn = 1
)

SELECT * FROM final_clean;


-- =====================================================
-- STEP 2: OVERALL FUNNEL METRICS
-- =====================================================
-- Purpose:
-- Calculate conversion rates across funnel stages
-- =====================================================

WITH funnel AS (
    SELECT
        COUNT_IF(event_type = 'view') AS views,
        COUNT_IF(event_type = 'cart') AS carts,
        COUNT_IF(event_type = 'purchase') AS purchases
    FROM ECOMMERCE.PUBLIC.EVENTS_ANALYSIS_READY
)

SELECT
    views,
    carts,
    purchases,

    ROUND(carts * 100.0 / views, 2) AS view_to_cart_pct,
    ROUND(purchases * 100.0 / carts, 2) AS cart_to_purchase_pct,
    ROUND(purchases * 100.0 / views, 2) AS overall_conversion_pct

FROM funnel;


-- =====================================================
-- STEP 3: CATEGORY PERFORMANCE ANALYSIS
-- =====================================================
-- Purpose:
-- Identify high-performing and underperforming categories
-- =====================================================

WITH category_perf AS (

    SELECT
        main_category,
        COUNT(DISTINCT user_session) AS sessions,
        COUNT_IF(event_type = 'view') AS views,
        COUNT_IF(event_type = 'cart') AS carts,
        COUNT_IF(event_type = 'purchase') AS purchases,

        ROUND(
            COUNT_IF(event_type = 'cart') * 100.0 
            / NULLIF(COUNT_IF(event_type = 'view'), 0), 2
        ) AS view_to_cart_pct

    FROM ECOMMERCE.PUBLIC.EVENTS_ANALYSIS_READY
    GROUP BY main_category
),

benchmarks AS (

    SELECT
        AVG(views) AS avg_views,
        AVG(view_to_cart_pct) AS avg_conversion
    FROM category_perf
)

SELECT
    c.*,

    -- Categorize performance
    CASE
        WHEN c.views > b.avg_views AND c.view_to_cart_pct < b.avg_conversion
            THEN 'High Traffic - Low Conversion (Problem)'
        WHEN c.views < b.avg_views AND c.view_to_cart_pct > b.avg_conversion
            THEN 'Low Traffic - High Conversion (Opportunity)'
        WHEN c.views > b.avg_views AND c.view_to_cart_pct > b.avg_conversion
            THEN 'Strong Performer'
        ELSE 'Average'
    END AS category_type

FROM category_perf c
CROSS JOIN benchmarks b
ORDER BY views DESC;

-- =====================================================
-- STEP 4: PATH TO PURCHASE
-- =====================================================
-- Purpose:
-- Understand how many sessions and views occur before purchase
-- =====================================================

WITH session_stats AS (

    SELECT
        user_id,
        user_session,
        MIN(event_ts) AS session_start,

        COUNT_IF(event_type = 'view') AS views,
        COUNT_IF(event_type = 'purchase') AS purchases

    FROM ECOMMERCE.PUBLIC.EVENTS_ANALYSIS_READY
    GROUP BY user_id, user_session
),

user_purchase AS (

    SELECT
        user_id,
        MIN(CASE WHEN purchases > 0 THEN session_start END) AS first_purchase_session
    FROM session_stats
    GROUP BY user_id
),

pre_purchase AS (

    SELECT
        s.user_id,
        COUNT(*) AS sessions_before_purchase,
        SUM(s.views) AS views_before_purchase

    FROM session_stats s
    JOIN user_purchase u
        ON s.user_id = u.user_id

    WHERE u.first_purchase_session IS NOT NULL
      AND s.session_start <= u.first_purchase_session

    GROUP BY s.user_id
)

SELECT
    AVG(sessions_before_purchase) AS avg_sessions_before_purchase,
    AVG(views_before_purchase) AS avg_views_before_purchase

FROM pre_purchase;

-- =====================================================
-- STEP 5: CUSTOMER SEGMENTATION
-- =====================================================
-- Purpose:
-- Segment users based on behavior and spending
-- =====================================================

WITH user_agg AS (

    SELECT
        user_id,
        COUNT(DISTINCT user_session) AS total_sessions,
        COUNT_IF(event_type = 'purchase') AS total_purchases,
        SUM(CASE WHEN event_type = 'purchase' THEN price ELSE 0 END) AS total_spend

    FROM ECOMMERCE.PUBLIC.EVENTS_ANALYSIS_READY
    GROUP BY user_id
),

user_metrics AS (

    SELECT *,
        CASE 
            WHEN total_purchases = 0 THEN 0
            ELSE total_spend / total_purchases
        END AS avg_order_value
    FROM user_agg
),

segmented AS (

    SELECT
        user_id,

        CASE
            WHEN total_purchases = 0 THEN 'Browsers'
            WHEN total_spend > 500 AND total_purchases >= 3 THEN 'High-Value'
            WHEN total_purchases = 1 THEN 'One-Time Buyers'
            WHEN total_purchases >= 2 THEN 'Repeat Customers'
            ELSE 'Other'
        END AS customer_segment

    FROM user_metrics
)

SELECT
    customer_segment,
    COUNT(*) AS users
FROM segmented
GROUP BY customer_segment
ORDER BY users DESC;
