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