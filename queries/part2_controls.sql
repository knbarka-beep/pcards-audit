-- Part II: internal-control tests, OSU calendar year 2014.
-- Every row in pcards.db is OSU (AgencyNumber 1000), so only the Year filter is needed.
-- Year and Month are the transaction year and month (checked against TransactionDate: 0 mismatches).
-- TransactionDate is text in M/D/YYYY 0:00:00, so sorting by date uses a rebuilt ISO date (TxDate).
-- Split tests (4 to 6) use positive charges only, so a return cannot hide or create a split.

-- name: Question1
SELECT FullName,
       ROUND(SUM(Amount), 2) AS TotalSpent
FROM pcards
WHERE Year = 2014
GROUP BY FullName
HAVING SUM(Amount) > 50000
ORDER BY TotalSpent DESC;

-- name: Question2
SELECT FullName,
       ROUND(SUM(Amount), 2) AS TotalSpent,
       Month
FROM pcards
WHERE Year = 2014
GROUP BY FullName, Month
HAVING SUM(Amount) > 10000
ORDER BY Month ASC, TotalSpent DESC;

-- name: Question3
SELECT Amount, FullName, Description, Vendor, TransactionDate, PostedDate, MCC
FROM pcards
WHERE Year = 2014
  AND Amount > 5000
ORDER BY Amount DESC;

-- name: Question4
WITH tx AS (
  SELECT *, printf('%04d-%02d-%02d', Year, Month,
         CAST(substr(TransactionDate, instr(TransactionDate, '/') + 1) AS INTEGER)) AS TxDate
  FROM pcards
  WHERE Year = 2014 AND Amount > 0
),
flagged AS (
  SELECT FullName, Vendor, TxDate
  FROM tx
  GROUP BY FullName, Vendor, TxDate
  HAVING COUNT(*) > 1 AND SUM(Amount) > 5000
)
SELECT tx.ID, tx.Amount, tx.FullName, tx.Description, tx.Vendor,
       tx.TransactionDate, tx.PostedDate, tx.MCC
FROM tx
JOIN flagged f ON f.FullName = tx.FullName AND f.Vendor = tx.Vendor AND f.TxDate = tx.TxDate
ORDER BY tx.TxDate ASC, tx.FullName, tx.Vendor, tx.Amount DESC;

-- name: Question5
-- Exactly two cardholders at the vendor that day, one charge each (COUNT(*) = 2),
-- which excludes a cardholder who paid the same vendor twice.
WITH tx AS (
  SELECT *, printf('%04d-%02d-%02d', Year, Month,
         CAST(substr(TransactionDate, instr(TransactionDate, '/') + 1) AS INTEGER)) AS TxDate
  FROM pcards
  WHERE Year = 2014 AND Amount > 0
),
flagged AS (
  SELECT Vendor, TxDate
  FROM tx
  GROUP BY Vendor, TxDate
  HAVING COUNT(DISTINCT FullName) = 2 AND COUNT(*) = 2 AND SUM(Amount) > 5000
)
SELECT tx.ID, tx.Amount, tx.FullName, tx.Description, tx.Vendor,
       tx.TransactionDate, tx.PostedDate, tx.MCC
FROM tx
JOIN flagged f ON f.Vendor = tx.Vendor AND f.TxDate = tx.TxDate
ORDER BY tx.TxDate ASC, tx.Vendor, tx.FullName;

-- name: Question6
-- One cardholder, exactly two vendors that day, one charge at each (COUNT(*) = 2),
-- which excludes double payments at one vendor.
WITH tx AS (
  SELECT *, printf('%04d-%02d-%02d', Year, Month,
         CAST(substr(TransactionDate, instr(TransactionDate, '/') + 1) AS INTEGER)) AS TxDate
  FROM pcards
  WHERE Year = 2014 AND Amount > 0
),
flagged AS (
  SELECT FullName, TxDate
  FROM tx
  GROUP BY FullName, TxDate
  HAVING COUNT(DISTINCT Vendor) = 2 AND COUNT(*) = 2 AND SUM(Amount) > 5000
)
SELECT tx.ID, tx.Amount, tx.FullName, tx.Description, tx.Vendor,
       tx.TransactionDate, tx.PostedDate, tx.MCC
FROM tx
JOIN flagged f ON f.FullName = tx.FullName AND f.TxDate = tx.TxDate
ORDER BY tx.TxDate ASC, tx.FullName, tx.Vendor;

-- name: Question7
-- Food or restaurant charges on a day the same cardholder also had a hotel/motel/resort/inn charge.
-- Literal keyword match, so 'PET SHOPS,PET FOOD AND SUPPLIES' is included as a known false positive.
WITH hotel_days AS (
  SELECT DISTINCT FullName, TransactionDate
  FROM pcards
  WHERE Year = 2014
    AND (MCC LIKE '%hotel%' OR MCC LIKE '%motel%' OR MCC LIKE '%resort%' OR MCC LIKE '%inn%')
)
SELECT p.ID, p.FullName, p.Amount, p.Description, p.Vendor,
       p.TransactionDate, p.PostedDate, p.MCC
FROM pcards p
JOIN hotel_days h ON h.FullName = p.FullName AND h.TransactionDate = p.TransactionDate
WHERE p.Year = 2014
  AND (p.MCC LIKE '%food%' OR p.MCC LIKE '%restaurant%')
ORDER BY p.FullName ASC, p.Amount ASC;

-- name: Question8
-- Control 8: Oklahoma sales tax must not be charged (Part I, Prohibited Purchases: Sales Tax).
-- Test: 2014 transactions whose description names tax as a separate item.
-- Word match on ' TAX ' so that TAXI and similar words are not picked up.
SELECT ID, Amount, FullName, Description, Vendor, TransactionDate, MCC
FROM pcards
WHERE Year = 2014
  AND (' ' || upper(replace(replace(Description, '|', ' '), '-', ' ')) || ' ' LIKE '% TAX %'
       OR upper(Description) LIKE '%SALES TAX%'
       OR upper(Description) LIKE '%TAXREFUND%')
ORDER BY Amount DESC;

-- name: Question9
-- Control 9: gasoline must be bought from Transportation Services or with the vehicle fuel card.
-- Test: 2014 charges at service stations and automated fuel dispensers, totalled per cardholder.
SELECT FullName,
       COUNT(*) AS Transactions,
       ROUND(SUM(Amount), 2) AS TotalAmount,
       GROUP_CONCAT(DISTINCT MCC) AS MCCs
FROM pcards
WHERE Year = 2014
  AND (MCC LIKE 'SERVICE STATIONS%' OR MCC = 'AUTOMATED FUEL DISPENSER')
GROUP BY FullName
ORDER BY TotalAmount DESC;

-- name: Question10
-- Control 10: all US mail must go through University Mailing, not on the P-card.
-- Test: 2014 charges at USPS or post office vendors, or in the POSTAGE STAMPS merchant category.
SELECT ID, Amount, FullName, Description, Vendor, TransactionDate, MCC
FROM pcards
WHERE Year = 2014
  AND (upper(Vendor) LIKE 'USPS%' OR upper(Vendor) LIKE '%POST OFFICE%'
       OR MCC = 'POSTAGE STAMPS')
ORDER BY FullName ASC, Amount DESC;

-- name: Question11
-- Control 11: goods and services from University departments and auxiliaries must go through
-- the campus vendor invoice (CVI) system, not the P-card.
-- Test: 2014 charges where the vendor is an OSU unit, totalled per vendor and cardholder.
SELECT Vendor, FullName,
       COUNT(*) AS Transactions,
       ROUND(SUM(Amount), 2) AS TotalAmount
FROM pcards
WHERE Year = 2014
  AND (upper(Vendor) LIKE 'OSU%' OR upper(Vendor) LIKE '%OKLAHOMA STATE UNIV%')
GROUP BY Vendor, FullName
ORDER BY TotalAmount DESC;

-- name: Question12
-- Control 12: Apple products must be bought through the Student Union Bookstore (Stillwater).
-- Test: 2014 charges at Apple retail and online stores. Restaurants and shops that only
-- contain the word APPLE (Applebee's, Apple Market) are excluded.
SELECT ID, Amount, FullName, Description, Vendor, TransactionDate, MCC
FROM pcards
WHERE Year = 2014
  AND (upper(Vendor) LIKE 'APL APPLE%' OR upper(Vendor) LIKE 'APPLE STORE%'
       OR upper(Vendor) LIKE '%APPLECARE%')
ORDER BY Amount DESC;

-- name: Question13
-- Control 13: regular monthly payments (maintenance, lease, rental, service agreements) above
-- $5,000 a year must go on a requisition and purchase order, not the P-card.
-- Test: cardholder and vendor pairs charged in 6 or more different months of 2014, a yearly total
-- above $5,000, and a stable amount (largest charge at most 1.25 times the smallest), which is what
-- a recurring agreement looks like and separates it from a frequently used supplier.
-- Calendar year is used as a proxy for the fiscal year.
SELECT FullName, Vendor, MCC,
       COUNT(DISTINCT Month) AS MonthsCharged,
       COUNT(*) AS Transactions,
       MIN(Amount) AS SmallestCharge,
       MAX(Amount) AS LargestCharge,
       ROUND(SUM(Amount), 2) AS TotalAmount
FROM pcards
WHERE Year = 2014 AND Amount > 0
GROUP BY FullName, Vendor
HAVING COUNT(DISTINCT Month) >= 6 AND SUM(Amount) > 5000 AND MAX(Amount) <= 1.25 * MIN(Amount)
ORDER BY TotalAmount DESC;

-- name: Question14
-- Control 14: cardholder limits are reviewed annually and inactive cards should be cancelled.
-- Test: cardholders with 2014 activity whose last 2014 transaction was before 1 July 2014,
-- so the card was unused for at least the last six months of the year.
SELECT FullName,
       COUNT(*) AS Transactions,
       ROUND(SUM(Amount), 2) AS TotalAmount,
       MIN(printf('%04d-%02d-%02d', Year, Month,
           CAST(substr(TransactionDate, instr(TransactionDate, '/') + 1) AS INTEGER))) AS FirstTx,
       MAX(printf('%04d-%02d-%02d', Year, Month,
           CAST(substr(TransactionDate, instr(TransactionDate, '/') + 1) AS INTEGER))) AS LastTx
FROM pcards
WHERE Year = 2014
GROUP BY FullName
HAVING MAX(Month) < 7
ORDER BY LastTx ASC, TotalAmount DESC;
