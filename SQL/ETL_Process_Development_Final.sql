/* =====================================================================
   Task 5: ETL Process Development
   =====================================================================
   What it does (in order):
     1. Creates staging tables (Stg_*) only if they don't exist (never drops them)
     2. Extracts JSON sources (order_reviews + geolocation) via
        OPENROWSET + OPENJSON
        (Excel / CSV / relational sources are assumed to be loaded
         into the matching Stg_* tables by SSIS Data Flow Tasks —
         see Task 5 documentation Section 5.2)
     3. Transforms: geo clean + region derivation, payment proration,
        delivery attributes (delivery_days, is_late_delivery)
     4. Truncates & rebuilds all dimensions + Fact_Sales from scratch
        using the corrected rules:
          • Geography match on zip_code_prefix only
          • Unknown geography fallback + quarantine log
          • Review fan-out eliminated (most recent review per order)
          • delivery_days and is_late_delivery loaded onto Fact_Sales
     5. Runs full validation suite

   Prerequisites:
     • Database assignment_dw already exists
     • Dimension and Fact tables already exist
     • JSON files are present at the paths used in the OPENROWSET
       statements
     • Staging tables for Excel/CSV/relational sources are already
       populated by SSIS before this script is executed
   ===================================================================== */

USE assignment_dw;
GO

/* =====================================================================
   1. STAGING TABLES  (landing zone — one per source file)
   ===================================================================== */
IF OBJECT_ID('Stg_Orders', 'U') IS NULL
CREATE TABLE Stg_Orders (
    order_id                        VARCHAR(64),
    customer_id                     VARCHAR(64),
    order_status                    VARCHAR(20),
    order_purchase_timestamp        DATETIME,
    order_approved_at               DATETIME,
    order_delivered_carrier_date    DATETIME,
    order_delivered_customer_date   DATETIME,
    order_estimated_delivery_date   DATETIME
);

IF OBJECT_ID('Stg_OrderItems', 'U') IS NULL
CREATE TABLE Stg_OrderItems (
    order_id            VARCHAR(64),
    order_item_id       INT,
    product_id          VARCHAR(64),
    seller_id           VARCHAR(64),
    shipping_limit_date DATETIME,
    price               DECIMAL(10,2),
    freight_value       DECIMAL(10,2)
);

IF OBJECT_ID('Stg_Customers', 'U') IS NULL
CREATE TABLE Stg_Customers (
    customer_id                 VARCHAR(64),
    customer_unique_id          VARCHAR(64),
    customer_zip_code_prefix    VARCHAR(10),
    customer_city               VARCHAR(100),
    customer_state              CHAR(2)
);

IF OBJECT_ID('Stg_Sellers', 'U') IS NULL
CREATE TABLE Stg_Sellers (
    seller_id               VARCHAR(64),
    seller_zip_code_prefix  VARCHAR(10),
    seller_city             VARCHAR(100),
    seller_state            CHAR(2)
);

IF OBJECT_ID('Stg_Products', 'U') IS NULL
CREATE TABLE Stg_Products (
    product_id                  VARCHAR(64),
    product_category_name       VARCHAR(100),
    product_weight_g            DECIMAL(10,2),
    product_length_cm           DECIMAL(10,2),
    product_height_cm           DECIMAL(10,2),
    product_width_cm            DECIMAL(10,2)
);

IF OBJECT_ID('Stg_CategoryTranslation', 'U') IS NULL
CREATE TABLE Stg_CategoryTranslation (
    product_category_name           VARCHAR(100),
    product_category_name_english   VARCHAR(100)
);

IF OBJECT_ID('Stg_OrderPayments', 'U') IS NULL
CREATE TABLE Stg_OrderPayments (
    order_id                VARCHAR(64),
    payment_sequential      INT,
    payment_type            VARCHAR(20),
    payment_installments    INT,
    payment_value           DECIMAL(10,2)
);

IF OBJECT_ID('Stg_OrderReviews', 'U') IS NULL
CREATE TABLE Stg_OrderReviews (
    review_id               VARCHAR(64),
    order_id                VARCHAR(64),
    review_score            TINYINT,
    review_comment_title    VARCHAR(200) NULL,
    review_comment_message  VARCHAR(MAX) NULL,
    review_creation_date    DATETIME,
    review_answer_timestamp DATETIME
);

IF OBJECT_ID('Stg_Geolocation', 'U') IS NULL
CREATE TABLE Stg_Geolocation (
    geolocation_zip_code_prefix VARCHAR(10),
    geolocation_lat             DECIMAL(9,6),
    geolocation_lng             DECIMAL(9,6),
    geolocation_city            VARCHAR(100),
    geolocation_state           CHAR(2)
);
GO

/* =====================================================================
   2. EXTRACT — JSON sources via OPENROWSET + OPENJSON
   (Excel and CSV sources are populated by SSIS Data Flow Tasks
    directly into the staging tables above; no T-SQL needed for those.)
   ===================================================================== */

-- order_reviews.json --------------------------------------------------
TRUNCATE TABLE Stg_OrderReviews;
INSERT INTO Stg_OrderReviews
SELECT
    j.review_id,
    j.order_id,
    j.review_score,
    j.review_comment_title,
    j.review_comment_message,
    j.review_creation_date,
    j.review_answer_timestamp
FROM OPENROWSET(BULK 'C:\DWBI\Converted Dataset\order_reviews.json', SINGLE_CLOB) AS raw
CROSS APPLY OPENJSON(raw.BulkColumn)
WITH (
    review_id               VARCHAR(64)  '$.review_id',
    order_id                VARCHAR(64)  '$.order_id',
    review_score            TINYINT      '$.review_score',
    review_comment_title    VARCHAR(200) '$.review_comment_title',
    review_comment_message  VARCHAR(MAX) '$.review_comment_message',
    review_creation_date    DATETIME     '$.review_creation_date',
    review_answer_timestamp DATETIME     '$.review_answer_timestamp'
) AS j;

-- geolocation.json ----------------------------------------------------
TRUNCATE TABLE Stg_Geolocation;
INSERT INTO Stg_Geolocation
SELECT
    j.geolocation_zip_code_prefix,
    j.geolocation_lat,
    j.geolocation_lng,
    j.geolocation_city,
    j.geolocation_state
FROM OPENROWSET(BULK 'C:\DWBI\Converted Dataset\geolocation.json', SINGLE_CLOB) AS raw
CROSS APPLY OPENJSON(raw.BulkColumn)
WITH (
    geolocation_zip_code_prefix VARCHAR(10)  '$.geolocation_zip_code_prefix',
    geolocation_lat              DECIMAL(9,6) '$.geolocation_lat',
    geolocation_lng              DECIMAL(9,6) '$.geolocation_lng',
    geolocation_city             VARCHAR(100) '$.geolocation_city',
    geolocation_state            CHAR(2)      '$.geolocation_state'
) AS j;
GO

/* =====================================================================
   3. TRANSFORM  (reads staging tables only — never modifies them)
   ===================================================================== */

-- 3.1 De-duplicate geolocation: average lat/lng per zip prefix,
--     and validate coordinates fall within Brazil's bounding box
IF OBJECT_ID('tempdb..#GeoClean') IS NOT NULL DROP TABLE #GeoClean;
SELECT
    geolocation_zip_code_prefix AS zip_code_prefix,
    MIN(geolocation_city)  AS city,
    MIN(geolocation_state) AS state,
    AVG(geolocation_lat)   AS avg_lat,
    AVG(geolocation_lng)   AS avg_lng
INTO #GeoClean
FROM Stg_Geolocation
WHERE geolocation_lat BETWEEN -33.75 AND 5.27    -- Brazil latitude bounds
  AND geolocation_lng BETWEEN -73.99 AND -34.79  -- Brazil longitude bounds
GROUP BY geolocation_zip_code_prefix;

-- 3.2 Derive region from state (Brazil's 5 official macro-regions)
IF OBJECT_ID('tempdb..#GeoWithRegion') IS NOT NULL DROP TABLE #GeoWithRegion;
SELECT *,
    region = CASE
        WHEN state IN ('AC','AP','AM','PA','RO','RR','TO') THEN 'North'
        WHEN state IN ('AL','BA','CE','MA','PB','PE','PI','RN','SE') THEN 'Northeast'
        WHEN state IN ('DF','GO','MT','MS') THEN 'Central-West'
        WHEN state IN ('ES','MG','RJ','SP') THEN 'Southeast'
        WHEN state IN ('PR','RS','SC') THEN 'South'
        ELSE 'Unknown'
    END
INTO #GeoWithRegion
FROM #GeoClean;

-- 3.3 Prorate payment_value per order item using a windowed SUM
--     (cannot be done in the SSIS Aggregate transformation)
IF OBJECT_ID('tempdb..#ItemPayments') IS NOT NULL DROP TABLE #ItemPayments;
SELECT
    oi.order_id,
    oi.order_item_id,
    oi.product_id,
    oi.seller_id,
    oi.price,
    oi.freight_value,
    op.order_total_payment * (oi.price / oi.order_price_sum) AS payment_value
INTO #ItemPayments
FROM (
    SELECT *,
           order_price_sum = SUM(price) OVER (PARTITION BY order_id)
    FROM Stg_OrderItems
) oi
INNER JOIN (
    SELECT order_id,
           order_total_payment = SUM(payment_value)
    FROM Stg_OrderPayments
    GROUP BY order_id
) op ON op.order_id = oi.order_id;

-- 3.4 Derived delivery attributes on the order header
--     (only delivered orders are retained for analysis)
IF OBJECT_ID('tempdb..#OrdersClean') IS NOT NULL DROP TABLE #OrdersClean;
SELECT
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    delivery_days    = DATEDIFF(DAY, order_purchase_timestamp, order_delivered_customer_date),
    is_late_delivery = CASE
                           WHEN order_delivered_customer_date > order_estimated_delivery_date
                           THEN 1 ELSE 0
                       END,
    date_key         = CONVERT(INT, FORMAT(order_purchase_timestamp, 'yyyyMMdd'))
INTO #OrdersClean
FROM Stg_Orders
WHERE order_status = 'delivered';
GO

/* =====================================================================
   4. TRUNCATE — dimensions + fact only, in FK-safe order
   (Fact_Sales first since it references every dimension;
    Dim_Geography last since Dim_Customer / Dim_Seller reference it)
   ===================================================================== */
TRUNCATE TABLE Fact_Sales;
TRUNCATE TABLE Dim_Customer;
TRUNCATE TABLE Dim_Seller;
TRUNCATE TABLE Dim_Product;
TRUNCATE TABLE Dim_Date;
TRUNCATE TABLE Dim_Geography;

IF OBJECT_ID('Quarantine_UnmatchedGeography', 'U') IS NOT NULL
    TRUNCATE TABLE Quarantine_UnmatchedGeography;
GO

/* =====================================================================
   5. LOAD DIMENSIONS
   ===================================================================== */

-- 5.1 Dim_Geography (first — Customer/Seller depend on it)
INSERT INTO Dim_Geography (zip_code_prefix, city, state, region, country)
SELECT DISTINCT
    zip_code_prefix,
    city,
    state,
    region,
    'Brazil'
FROM #GeoWithRegion;

-- 5.2 "Unknown" fallback member + quarantine log for zip prefixes
--     that have no match at all in the geolocation file
INSERT INTO Dim_Geography (zip_code_prefix, city, state, region, country)
VALUES ('UNKNOWN', 'Unknown', 'NA', 'Unknown', 'Brazil');

IF OBJECT_ID('Quarantine_UnmatchedGeography', 'U') IS NULL
    CREATE TABLE Quarantine_UnmatchedGeography (
        source_table    VARCHAR(20),
        natural_key     VARCHAR(64),
        zip_code_prefix VARCHAR(10),
        logged_at       DATETIME DEFAULT GETDATE()
    );

INSERT INTO Quarantine_UnmatchedGeography (source_table, natural_key, zip_code_prefix)
SELECT 'Customer', c.customer_id, c.customer_zip_code_prefix
FROM Stg_Customers c
WHERE NOT EXISTS (
    SELECT 1 FROM Dim_Geography g
    WHERE g.zip_code_prefix = c.customer_zip_code_prefix
);

INSERT INTO Quarantine_UnmatchedGeography (source_table, natural_key, zip_code_prefix)
SELECT 'Seller', s.seller_id, s.seller_zip_code_prefix
FROM Stg_Sellers s
WHERE NOT EXISTS (
    SELECT 1 FROM Dim_Geography g
    WHERE g.zip_code_prefix = s.seller_zip_code_prefix
);

-- 5.3 Dim_Customer (zip-prefix-only match, Unknown fallback)
INSERT INTO Dim_Customer (customer_id, customer_unique_id, geography_key)
SELECT
    c.customer_id,
    c.customer_unique_id,
    COALESCE(
        g.geography_key,
        (SELECT geography_key FROM Dim_Geography WHERE zip_code_prefix = 'UNKNOWN')
    )
FROM Stg_Customers c
LEFT JOIN Dim_Geography g
    ON g.zip_code_prefix = c.customer_zip_code_prefix;

-- 5.4 Dim_Seller (zip-prefix-only match, Unknown fallback)
INSERT INTO Dim_Seller (seller_id, geography_key)
SELECT
    s.seller_id,
    COALESCE(
        g.geography_key,
        (SELECT geography_key FROM Dim_Geography WHERE zip_code_prefix = 'UNKNOWN')
    )
FROM Stg_Sellers s
LEFT JOIN Dim_Geography g
    ON g.zip_code_prefix = s.seller_zip_code_prefix;

-- 5.5 Dim_Product (joined with translated category name)
INSERT INTO Dim_Product (
    product_id,
    category_name_pt,
    category_name_english,
    weight_g,
    length_cm,
    height_cm,
    width_cm
)
SELECT
    p.product_id,
    p.product_category_name,
    ct.product_category_name_english,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm
FROM Stg_Products p
LEFT JOIN Stg_CategoryTranslation ct
    ON ct.product_category_name = p.product_category_name;

-- 5.6 Dim_Date (one-time population, 2016-01-01 to 2018-12-31)
DECLARE @d   DATE = '2016-01-01',
        @end DATE = '2018-12-31';
WHILE @d <= @end
BEGIN
    INSERT INTO Dim_Date (
        date_key, full_date, day, day_name, day_of_week,
        month, month_name, quarter, year, is_weekend
    )
    VALUES (
        CONVERT(INT, FORMAT(@d, 'yyyyMMdd')),
        @d,
        DAY(@d),
        DATENAME(WEEKDAY, @d),
        DATEPART(WEEKDAY, @d),
        MONTH(@d),
        DATENAME(MONTH, @d),
        DATEPART(QUARTER, @d),
        YEAR(@d),
        CASE WHEN DATEPART(WEEKDAY, @d) IN (1, 7) THEN 1 ELSE 0 END
    );
    SET @d = DATEADD(DAY, 1, @d);
END
GO

/* =====================================================================
   6. LOAD FACT_SALES
   (review join is de-duplicated: keeps only the most recent review
    per order to prevent fan-out when an order has multiple reviews)
   ===================================================================== */
INSERT INTO Fact_Sales (
    order_id,
    customer_key,
    seller_key,
    product_key,
    date_key,
    price,
    freight_value,
    payment_value,
    item_count,
    review_score,
    delivery_days,
    is_late_delivery
)
SELECT
    ip.order_id,
    dc.customer_key,
    ds.seller_key,
    dp.product_key,
    oc.date_key,
    ip.price,
    ip.freight_value,
    ip.payment_value,
    1 AS item_count,
    r.review_score,
    oc.delivery_days,
    oc.is_late_delivery
FROM #ItemPayments ip
INNER JOIN #OrdersClean oc
    ON oc.order_id = ip.order_id
INNER JOIN Dim_Customer dc
    ON dc.customer_id = oc.customer_id
INNER JOIN Dim_Seller ds
    ON ds.seller_id = ip.seller_id
INNER JOIN Dim_Product dp
    ON dp.product_id = ip.product_id
LEFT JOIN (
    SELECT
        order_id,
        review_score,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY review_answer_timestamp DESC
        ) AS rn
    FROM Stg_OrderReviews
) r ON r.order_id = ip.order_id
   AND r.rn = 1;
GO

/* =====================================================================
   7. VALIDATION
   ===================================================================== */

-- 7.1 Row-count reconciliation
SELECT 'Stg_OrderItems'              AS tbl, COUNT(*) AS row_count FROM Stg_OrderItems
UNION ALL
SELECT 'Fact_Sales',                        COUNT(*) FROM Fact_Sales
UNION ALL
SELECT 'Quarantine_UnmatchedGeography',     COUNT(*) FROM Quarantine_UnmatchedGeography;

-- 7.2 Orphan foreign-key check (should return 0 rows)
SELECT f.*
FROM Fact_Sales f
LEFT JOIN Dim_Customer c ON c.customer_key = f.customer_key
LEFT JOIN Dim_Seller   s ON s.seller_key   = f.seller_key
LEFT JOIN Dim_Product  p ON p.product_key  = f.product_key
LEFT JOIN Dim_Date     d ON d.date_key     = f.date_key
WHERE c.customer_key IS NULL
   OR s.seller_key   IS NULL
   OR p.product_key  IS NULL
   OR d.date_key     IS NULL;

-- 7.3 Payment reconciliation
--     (should return 0 rows — or very close — outside 0.05 tolerance)
SELECT
    f.order_id,
    SUM(f.payment_value) AS fact_total,
    op.order_total_payment
FROM Fact_Sales f
INNER JOIN (
    SELECT order_id,
           SUM(payment_value) AS order_total_payment
    FROM Stg_OrderPayments
    GROUP BY order_id
) op ON op.order_id = f.order_id
GROUP BY f.order_id, op.order_total_payment
HAVING ABS(SUM(f.payment_value) - op.order_total_payment) > 0.05;

-- 7.4 Review-score range check (should return 0 rows)
SELECT *
FROM Fact_Sales
WHERE review_score IS NOT NULL
  AND review_score NOT BETWEEN 1 AND 5;

-- 7.5 Final dimension & fact row counts
SELECT 'Dim_Customer'  AS table_name, COUNT(*) AS row_count FROM Dim_Customer
UNION ALL SELECT 'Dim_Date',      COUNT(*) FROM Dim_Date
UNION ALL SELECT 'Dim_Geography', COUNT(*) FROM Dim_Geography
UNION ALL SELECT 'Dim_Product',   COUNT(*) FROM Dim_Product
UNION ALL SELECT 'Dim_Seller',    COUNT(*) FROM Dim_Seller
UNION ALL SELECT 'Fact_Sales',    COUNT(*) FROM Fact_Sales;
GO

/* =====================================================================
   END OF SCRIPT
   ===================================================================== */