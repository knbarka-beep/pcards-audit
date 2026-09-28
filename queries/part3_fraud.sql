-- Part III: forensic fraud tests, OSU calendar year 2014.
-- Naming follows the assignment: qry_T3_Question#, with Final on the query that gives the final output
-- when a question needs more than one query.

-- name: qry_T3_Question1
-- Benford first-digit test. Amounts below $1.00 (and returns) are excluded.
WITH digits AS (
  SELECT CAST(substr(CAST(Amount AS TEXT), 1, 1) AS INTEGER) AS FirstDigit
  FROM pcards
  WHERE Year = 2014 AND Amount >= 1
),
counts AS (
  SELECT FirstDigit, COUNT(*) AS n FROM digits GROUP BY FirstDigit
),
benford AS (  -- expected share = log10(1 + 1/d), written out because not every SQLite build has log10
  SELECT 1 AS d, 30.103 AS pct UNION ALL SELECT 2, 17.609 UNION ALL SELECT 3, 12.494
  UNION ALL SELECT 4, 9.691 UNION ALL SELECT 5, 7.918 UNION ALL SELECT 6, 6.695
  UNION ALL SELECT 7, 5.799 UNION ALL SELECT 8, 5.115 UNION ALL SELECT 9, 4.576
)
SELECT c.FirstDigit,
       c.n AS Transactions,
       ROUND(100.0 * c.n / (SELECT COUNT(*) FROM digits), 3) AS ActualPct,
       b.pct AS BenfordPct,
       ROUND(100.0 * c.n / (SELECT COUNT(*) FROM digits) - b.pct, 3) AS DifferencePct
FROM counts c
JOIN benford b ON b.d = c.FirstDigit
ORDER BY c.FirstDigit;

-- name: qry_T3_Question2
-- Possible duplicates: same date, vendor, first initial, last name and amount, positive charges only.
-- All rows in a matching group are returned, so a triple shows as three rows.
WITH dup_groups AS (
  SELECT TransactionDate, Vendor, CardholderFirstInitial, CardholderLastName, Amount
  FROM pcards
  WHERE Year = 2014 AND Amount > 0
  GROUP BY TransactionDate, Vendor, CardholderFirstInitial, CardholderLastName, Amount
  HAVING COUNT(*) > 1
)
SELECT p.TransactionDate, p.Vendor, p.FullName, p.Amount
FROM pcards p
JOIN dup_groups d
  ON d.TransactionDate = p.TransactionDate AND d.Vendor = p.Vendor
 AND d.CardholderFirstInitial = p.CardholderFirstInitial
 AND d.CardholderLastName = p.CardholderLastName AND d.Amount = p.Amount
WHERE p.Year = 2014 AND p.Amount > 0
ORDER BY printf('%04d-%02d-%02d', p.Year, p.Month,
         CAST(substr(p.TransactionDate, instr(p.TransactionDate, '/') + 1) AS INTEGER)) ASC,
         p.Vendor ASC;

-- name: qry_T3_Question3
-- Step 1: one row per duplicate occasion (a date, vendor, cardholder and amount group).
SELECT CardholderFirstInitial, CardholderLastName, FullName, TransactionDate, Vendor, Amount,
       COUNT(*) AS RowsInOccasion
FROM pcards
WHERE Year = 2014 AND Amount > 0
GROUP BY TransactionDate, Vendor, CardholderFirstInitial, CardholderLastName, Amount
HAVING COUNT(*) > 1;

-- name: qry_T3_Question3Final
-- Step 2: occasions per employee, highest first.
WITH occasions AS (
  SELECT FullName, TransactionDate, Vendor, Amount
  FROM pcards
  WHERE Year = 2014 AND Amount > 0
  GROUP BY TransactionDate, Vendor, CardholderFirstInitial, CardholderLastName, Amount
  HAVING COUNT(*) > 1
)
SELECT FullName,
       COUNT(*) AS DuplicateOccasions,
       ROUND(SUM(Amount), 2) AS AmountPerOccasionSum
FROM occasions
GROUP BY FullName
ORDER BY DuplicateOccasions DESC, AmountPerOccasionSum DESC;

-- name: qry_T3_Question4
-- Four-digit whole-dollar amounts ending in 000 (1000, 2000 ... 9000), cents ignored.
SELECT Amount, Vendor, Description, FullName
FROM pcards
WHERE Year = 2014
  AND Amount > 0
  AND CAST(Amount AS INTEGER) BETWEEN 1000 AND 9999
  AND CAST(Amount AS INTEGER) % 1000 = 0
ORDER BY Vendor ASC, FullName ASC;

-- name: qry_T3_Question5
-- Hypothesis: threshold avoidance. A cardholder who knows the $5,000 single-transaction limit
-- keeps charges just under it. Test: charges from $4,500 to $4,999.99 in 2014.
SELECT ID, FullName, Amount, Vendor, Description, TransactionDate, MCC
FROM pcards
WHERE Year = 2014 AND Amount >= 4500 AND Amount < 5000
ORDER BY FullName, Amount DESC;

-- name: qry_T3_Question5Final
-- Cardholders with two or more just-below-limit charges, which removes one-off purchases.
SELECT FullName,
       COUNT(*) AS NearLimitCharges,
       COUNT(DISTINCT Vendor) AS Vendors,
       ROUND(SUM(Amount), 2) AS TotalAmount
FROM pcards
WHERE Year = 2014 AND Amount >= 4500 AND Amount < 5000
GROUP BY FullName
HAVING COUNT(*) >= 2
ORDER BY NearLimitCharges DESC, TotalAmount DESC;

-- name: qry_T3_Question6
-- Hypothesis: personal use. Weekend purchases at merchants that are not travel related.
-- Travel MCCs (lodging, airlines, car rental, travel agencies, taxis, parking, restaurants) are
-- excluded because staff legitimately travel at weekends. Only charges of $250 or more.
WITH tx AS (
  SELECT *, printf('%04d-%02d-%02d', Year, Month,
         CAST(substr(TransactionDate, instr(TransactionDate, '/') + 1) AS INTEGER)) AS TxDate
  FROM pcards
  WHERE Year = 2014 AND Amount >= 250
)
SELECT ID, FullName, TxDate,
       CASE strftime('%w', TxDate) WHEN '0' THEN 'Sunday' ELSE 'Saturday' END AS Weekday,
       Amount, Vendor, Description, MCC
FROM tx
WHERE strftime('%w', TxDate) IN ('0', '6')
  AND NOT (MCC LIKE '%hotel%' OR MCC LIKE '%motel%' OR MCC LIKE '%resort%' OR MCC LIKE '%inn%'
           OR MCC LIKE '%airline%' OR MCC LIKE '%air line%' OR MCC LIKE '%car rental%'
           OR MCC LIKE '%travel agenc%' OR MCC LIKE '%taxi%' OR MCC LIKE '%parking%'
           OR MCC LIKE '%restaurant%' OR MCC LIKE '%eating place%' OR MCC LIKE '%lodging%'
           OR Description IN ('ROOM CHARGES', 'AIR TRAVEL'))
ORDER BY Amount DESC;

-- name: qry_T3_Question6Final
-- Cardholders with three or more such weekend charges.
WITH tx AS (
  SELECT *, printf('%04d-%02d-%02d', Year, Month,
         CAST(substr(TransactionDate, instr(TransactionDate, '/') + 1) AS INTEGER)) AS TxDate
  FROM pcards
  WHERE Year = 2014 AND Amount >= 250
)
SELECT FullName,
       COUNT(*) AS WeekendCharges,
       ROUND(SUM(Amount), 2) AS TotalAmount,
       GROUP_CONCAT(DISTINCT Vendor) AS Vendors
FROM tx
WHERE strftime('%w', TxDate) IN ('0', '6')
  AND NOT (MCC LIKE '%hotel%' OR MCC LIKE '%motel%' OR MCC LIKE '%resort%' OR MCC LIKE '%inn%'
           OR MCC LIKE '%airline%' OR MCC LIKE '%air line%' OR MCC LIKE '%car rental%'
           OR MCC LIKE '%travel agenc%' OR MCC LIKE '%taxi%' OR MCC LIKE '%parking%'
           OR MCC LIKE '%restaurant%' OR MCC LIKE '%eating place%' OR MCC LIKE '%lodging%'
           OR Description IN ('ROOM CHARGES', 'AIR TRAVEL'))
GROUP BY FullName
HAVING COUNT(*) >= 3
ORDER BY WeekendCharges DESC, TotalAmount DESC;

-- name: qry_T3_Question7
-- Hypothesis: conflict of interest or a fictitious vendor. A vendor that only one OSU cardholder
-- ever uses, repeatedly and for real money, fits the pattern of buying from a related party.
-- Test: vendors with exactly one cardholder across all years in the database, at least
-- 5 charges and more than $5,000 in 2014.
WITH single_holder_vendors AS (
  SELECT Vendor
  FROM pcards
  GROUP BY Vendor
  HAVING COUNT(DISTINCT FullName) = 1
)
SELECT p.Vendor, p.FullName, p.MCC,
       COUNT(*) AS Charges2014,
       ROUND(SUM(p.Amount), 2) AS Total2014
FROM pcards p
JOIN single_holder_vendors s ON s.Vendor = p.Vendor
WHERE p.Year = 2014 AND p.Amount > 0
GROUP BY p.Vendor, p.FullName, p.MCC
HAVING COUNT(*) >= 5 AND SUM(p.Amount) > 5000
ORDER BY Total2014 DESC;

-- name: qry_T3_Question8
-- Hypothesis: refund fraud. A credit to the card from a vendor the cardholder never bought from
-- can mean cash or store credit taken off a university card.
-- Test: 2014 returns of $100 or more where the same cardholder has no positive charge at that vendor
-- on or before the return date. Partial returns are therefore not flagged. The lookup reaches back
-- into 2013 so returns of late-2013 purchases do not flag. 'CLAIM ADJ' vendors are bank dispute
-- credits whose vendor name never matches the original purchase, so they are excluded.
WITH tx AS (
  SELECT *, printf('%04d-%02d-%02d', Year, Month,
         CAST(substr(TransactionDate, instr(TransactionDate, '/') + 1) AS INTEGER)) AS TxDate
  FROM pcards
  WHERE Year IN (2013, 2014)
),
first_purchase AS (
  SELECT FullName, Vendor, MIN(TxDate) AS FirstPurchase
  FROM tx
  WHERE Amount > 0
  GROUP BY FullName, Vendor
)
SELECT r.ID, r.FullName, r.Amount, r.Vendor, r.Description, r.TransactionDate, r.MCC
FROM tx r
LEFT JOIN first_purchase f ON f.FullName = r.FullName AND f.Vendor = r.Vendor
WHERE r.Year = 2014 AND r.Amount <= -100
  AND upper(r.Vendor) NOT LIKE 'CLAIM ADJ%'
  AND (f.FirstPurchase IS NULL OR f.FirstPurchase > r.TxDate)
ORDER BY r.Amount ASC;
