/* =====================================================================
   Data Warehouse — Dimensional Schema (Star + Snowflake hybrid)
   Task 4: Dimensional Data Warehouse Design and Implementation
   ===================================================================== */

IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = 'assignment_dw')
BEGIN
    CREATE DATABASE assignment_dw;
END
GO

USE assignment_dw;
GO

/* ---------------------------------------------------------------------
   Dim_Geography (snowflake outrigger, shared by Customer and Seller)
   --------------------------------------------------------------------- */
CREATE TABLE Dim_Geography (
    geography_key   INT IDENTITY(1,1) PRIMARY KEY,
    zip_code_prefix VARCHAR(10)  NOT NULL,
    city            VARCHAR(100) NOT NULL,
    state           CHAR(2)      NOT NULL,
    region          VARCHAR(20)  NOT NULL,   -- North / Northeast / Central-West / Southeast / South
    country         VARCHAR(50)  NOT NULL DEFAULT 'Brazil',
    CONSTRAINT UQ_Geography_Natural UNIQUE (zip_code_prefix, city, state)
);
GO

/* ---------------------------------------------------------------------
   Dim_Customer
   --------------------------------------------------------------------- */
CREATE TABLE Dim_Customer (
    customer_key       INT IDENTITY(1,1) PRIMARY KEY,
    customer_id        VARCHAR(64) NOT NULL,   -- natural key
    customer_unique_id VARCHAR(64) NOT NULL,
    geography_key      INT NOT NULL,
    CONSTRAINT UQ_Customer_Natural UNIQUE (customer_id),
    CONSTRAINT FK_Customer_Geography FOREIGN KEY (geography_key)
        REFERENCES Dim_Geography(geography_key)
);
GO

/* ---------------------------------------------------------------------
   Dim_Seller
   --------------------------------------------------------------------- */
CREATE TABLE Dim_Seller (
    seller_key     INT IDENTITY(1,1) PRIMARY KEY,
    seller_id      VARCHAR(64) NOT NULL,       -- natural key
    geography_key  INT NOT NULL,
    CONSTRAINT UQ_Seller_Natural UNIQUE (seller_id),
    CONSTRAINT FK_Seller_Geography FOREIGN KEY (geography_key)
        REFERENCES Dim_Geography(geography_key)
);
GO

/* ---------------------------------------------------------------------
   Dim_Product
   --------------------------------------------------------------------- */
CREATE TABLE Dim_Product (
    product_key            INT IDENTITY(1,1) PRIMARY KEY,
    product_id              VARCHAR(64) NOT NULL,   -- natural key
    category_name_pt        VARCHAR(100) NULL,
    category_name_english   VARCHAR(100) NULL,
    weight_g                DECIMAL(10,2) NULL,
    length_cm                DECIMAL(10,2) NULL,
    height_cm                DECIMAL(10,2) NULL,
    width_cm                DECIMAL(10,2) NULL,
    CONSTRAINT UQ_Product_Natural UNIQUE (product_id)
);
GO

/* ---------------------------------------------------------------------
   Dim_Date
   --------------------------------------------------------------------- */
CREATE TABLE Dim_Date (
    date_key      INT PRIMARY KEY,        -- format YYYYMMDD
    full_date     DATE NOT NULL,
    day           TINYINT NOT NULL,
    day_name      VARCHAR(10) NOT NULL,
    day_of_week   TINYINT NOT NULL,
    month         TINYINT NOT NULL,
    month_name    VARCHAR(10) NOT NULL,
    quarter       TINYINT NOT NULL,
    year          SMALLINT NOT NULL,
    is_weekend    BIT NOT NULL,
    CONSTRAINT UQ_Date_Natural UNIQUE (full_date)
);
GO

/* ---------------------------------------------------------------------
   Fact_Sales  (grain: one row per order line item)
   --------------------------------------------------------------------- */
CREATE TABLE Fact_Sales (
    order_item_key  BIGINT IDENTITY(1,1) PRIMARY KEY,
    order_id        VARCHAR(64) NOT NULL,      -- degenerate dimension
    customer_key    INT NOT NULL,
    seller_key      INT NOT NULL,
    product_key     INT NOT NULL,
    date_key        INT NOT NULL,
    price           DECIMAL(10,2) NOT NULL,
    freight_value   DECIMAL(10,2) NOT NULL,
    payment_value   DECIMAL(10,2) NOT NULL,     -- prorated per item, see design assumptions
    item_count      INT NOT NULL DEFAULT 1,
    review_score    TINYINT NULL,               -- 1-5, repeated per item of the same order
    delivery_days    INT NULL,
    is_late_delivery BIT NULL,

    CONSTRAINT FK_Fact_Customer FOREIGN KEY (customer_key) REFERENCES Dim_Customer(customer_key),
    CONSTRAINT FK_Fact_Seller   FOREIGN KEY (seller_key)   REFERENCES Dim_Seller(seller_key),
    CONSTRAINT FK_Fact_Product  FOREIGN KEY (product_key)  REFERENCES Dim_Product(product_key),
    CONSTRAINT FK_Fact_Date     FOREIGN KEY (date_key)     REFERENCES Dim_Date(date_key)
);
GO

/* ---------------------------------------------------------------------
   Indexes to support common BI query patterns (drill-down / roll-up)
   --------------------------------------------------------------------- */
CREATE INDEX IX_Fact_Customer ON Fact_Sales(customer_key);
CREATE INDEX IX_Fact_Seller   ON Fact_Sales(seller_key);
CREATE INDEX IX_Fact_Product  ON Fact_Sales(product_key);
CREATE INDEX IX_Fact_Date     ON Fact_Sales(date_key);
CREATE INDEX IX_Fact_Order    ON Fact_Sales(order_id);
GO


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
   Task 6: Data Mart Development — Sales & Logistics Data Mart
   1. Created View
   2. Created Data-Mart
   ===================================================================== */

/* =====================================================================
   1. vw_Mart_SalesLogistics — row-level, flattened view
   ===================================================================== */
IF OBJECT_ID('vw_Mart_SalesLogistics', 'V') IS NOT NULL
    DROP VIEW vw_Mart_SalesLogistics;
GO

CREATE VIEW vw_Mart_SalesLogistics AS
SELECT
    f.order_id,
    dt.full_date                    AS order_date,
    dt.year, dt.month, dt.month_name,
    pr.category_name_english        AS product_category,
    sg.city                          AS seller_city,
    sg.state                         AS seller_state,
    sg.region                        AS seller_region,
    cg.state                         AS customer_state,
    cg.region                        AS customer_region,
    f.price,
    f.freight_value,
    f.payment_value,
    f.delivery_days,
    f.is_late_delivery,
    f.review_score
FROM Fact_Sales f
INNER JOIN Dim_Date     dt ON dt.date_key     = f.date_key
INNER JOIN Dim_Product  pr ON pr.product_key  = f.product_key
INNER JOIN Dim_Seller   sl ON sl.seller_key   = f.seller_key
INNER JOIN Dim_Geography sg ON sg.geography_key = sl.geography_key
INNER JOIN Dim_Customer cu ON cu.customer_key = f.customer_key
INNER JOIN Dim_Geography cg ON cg.geography_key = cu.geography_key;
GO

/* =====================================================================
   2. Mart_SalesLogistics_Monthly — pre-aggregated physical table
   Grain: one row per Year-Month x Seller Region x Product Category
   ===================================================================== */
IF OBJECT_ID('Mart_SalesLogistics_Monthly', 'U') IS NOT NULL
    DROP TABLE Mart_SalesLogistics_Monthly;
GO

CREATE TABLE Mart_SalesLogistics_Monthly (
    year                SMALLINT,
    month               TINYINT,
    seller_region       VARCHAR(20),
    product_category    VARCHAR(100),
    total_sales         DECIMAL(14,2),
    total_freight       DECIMAL(14,2),
    order_item_count    INT,
    avg_delivery_days   DECIMAL(5,2),
    late_delivery_rate  DECIMAL(5,4),
    avg_review_score    DECIMAL(3,2)
);
GO

INSERT INTO Mart_SalesLogistics_Monthly
SELECT
    year, month, seller_region, product_category,
    SUM(price)                                            AS total_sales,
    SUM(freight_value)                                    AS total_freight,
    COUNT(*)                                              AS order_item_count,
    AVG(CAST(delivery_days AS DECIMAL(5,2)))              AS avg_delivery_days,
    AVG(CAST(is_late_delivery AS DECIMAL(5,4)))           AS late_delivery_rate,
    AVG(CAST(review_score AS DECIMAL(3,2)))               AS avg_review_score
FROM vw_Mart_SalesLogistics
GROUP BY year, month, seller_region, product_category;
GO

/* =====================================================================
   3. Quick checks
   ===================================================================== */
SELECT TOP 10 * FROM vw_Mart_SalesLogistics ORDER BY order_date DESC;
SELECT TOP 10 * FROM Mart_SalesLogistics_Monthly ORDER BY total_sales DESC;
GO

/* =====================================================================
   END OF SCRIPT
   ===================================================================== */