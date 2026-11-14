/* =====================================================================
   Task 6: Data Mart Development — Sales & Logistics Data Mart
   1. Created View
   2. Created Data-Mart
   ===================================================================== */

USE assignment_dw;
GO

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