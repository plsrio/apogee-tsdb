-- ============================================================================
-- SQLC QUERIES FOR OPTION_SNAPSHOTS TABLE
-- ============================================================================
-- ----------------------------------------------------------------------------
-- CREATE (INSERT) OPERATIONS
-- ----------------------------------------------------------------------------
-- name: InsertOptionSnapshot :one
INSERT INTO option_snapshots (
    time,
    ticker,
    underlying,
    underlying_price,
    strike_price,
    shares_per_contract,
    expiration_date,
    option_type,
    option_style,
    underlying_last_updated,
    volume,
    open_interest,
    bid,
    ask,
    bid_size,
    ask_size,
    delta,
    gamma,
    theta,
    vega,
    rho,
    implied_volatility,
    last_updated_src,
    start_load_time,
    end_load_time
  )
VALUES (
    $1,
    $2,
    $3,
    $4,
    $5,
    $6,
    $7,
    $8,
    $9,
    $10,
    $11,
    $12,
    $13,
    $14,
    $15,
    $16,
    $17,
    $18,
    $19,
    $20,
    $21,
    $22,
    $23,
    $24,
    $25
  )
RETURNING *;

-- name: BulkInsertOptionSnapshots :exec
INSERT INTO option_snapshots (
    time,
    ticker,
    underlying,
    underlying_price,
    strike_price,
    shares_per_contract,
    expiration_date,
    option_type,
    option_style,
    underlying_last_updated,
    volume,
    open_interest,
    bid,
    ask,
    bid_size,
    ask_size,
    delta,
    gamma,
    theta,
    vega,
    rho,
    implied_volatility,
    last_updated_src,
    start_load_time,
    end_load_time
  )
VALUES (
    $1,
    $2,
    $3,
    $4,
    $5,
    $6,
    $7,
    $8,
    $9,
    $10,
    $11,
    $12,
    $13,
    $14,
    $15,
    $16,
    $17,
    $18,
    $19,
    $20,
    $21,
    $22,
    $23,
    $24,
    $25
  );

-- name: UpsertOptionSnapshot :one
INSERT INTO option_snapshots (
    time,
    ticker,
    underlying,
    underlying_price,
    strike_price,
    shares_per_contract,
    expiration_date,
    option_type,
    option_style,
    underlying_last_updated,
    volume,
    open_interest,
    bid,
    ask,
    bid_size,
    ask_size,
    delta,
    gamma,
    theta,
    vega,
    rho,
    implied_volatility,
    last_updated_src,
    start_load_time,
    end_load_time
  )
VALUES (
    $1,
    $2,
    $3,
    $4,
    $5,
    $6,
    $7,
    $8,
    $9,
    $10,
    $11,
    $12,
    $13,
    $14,
    $15,
    $16,
    $17,
    $18,
    $19,
    $20,
    $21,
    $22,
    $23,
    $24,
    $25
  ) ON CONFLICT (
    time,
    ticker,
    strike_price,
    expiration_date,
    option_type
  ) DO
UPDATE
SET underlying = EXCLUDED.underlying,
  underlying_price = EXCLUDED.underlying_price,
  shares_per_contract = EXCLUDED.shares_per_contract,
  option_style = EXCLUDED.option_style,
  underlying_last_updated = EXCLUDED.underlying_last_updated,
  volume = EXCLUDED.volume,
  open_interest = EXCLUDED.open_interest,
  bid = EXCLUDED.bid,
  ask = EXCLUDED.ask,
  bid_size = EXCLUDED.bid_size,
  ask_size = EXCLUDED.ask_size,
  delta = EXCLUDED.delta,
  gamma = EXCLUDED.gamma,
  theta = EXCLUDED.theta,
  vega = EXCLUDED.vega,
  rho = EXCLUDED.rho,
  implied_volatility = EXCLUDED.implied_volatility,
  last_updated_src = EXCLUDED.last_updated_src,
  end_load_time = EXCLUDED.end_load_time
RETURNING *;

-- ----------------------------------------------------------------------------
-- READ (SELECT) OPERATIONS - BASIC
-- ----------------------------------------------------------------------------
-- name: GetLatestSnapshotByTicker :one
SELECT *
FROM option_snapshots
WHERE ticker = $1
ORDER BY time DESC
LIMIT 1;

-- name: GetSnapshotsByTickerTimeRange :many
SELECT *
FROM option_snapshots
WHERE ticker = @ticker
  AND time >= @start_time
  AND time <= @end_time
ORDER BY time DESC;

-- name: GetLatestSnapshotsByUnderlying :many
SELECT DISTINCT ON (
    ticker,
    strike_price,
    expiration_date,
    option_type
  ) *
FROM option_snapshots
WHERE underlying = $1
ORDER BY ticker,
  strike_price,
  expiration_date,
  option_type,
  time DESC;

-- name: GetSnapshotsByExpiration :many
SELECT *
FROM option_snapshots
WHERE expiration_date = $1
  AND time >= $2
ORDER BY underlying,
  strike_price,
  option_type;

-- name: GetSnapshotsByStrikeRange :many
SELECT *
FROM option_snapshots
WHERE underlying = $1
  AND expiration_date = $2
  AND strike_price BETWEEN $3 AND $4
  AND time >= $5
ORDER BY strike_price,
  option_type;

-- name: GetSnapshotsByID :one
SELECT *
FROM option_snapshots
WHERE time = $1
  AND ticker = $2
  AND strike_price = $3
  AND expiration_date = $4
  AND option_type = $5;

-- name: GetHighVolumeOptions :many
SELECT *
FROM option_snapshots
WHERE time >= $1
  AND volume > $2
ORDER BY volume DESC
LIMIT $3;

-- name: GetHighIVOptions :many
SELECT *
FROM option_snapshots
WHERE time >= $1
  AND implied_volatility IS NOT NULL
ORDER BY implied_volatility DESC
LIMIT $2;

-- name: GetAllUnderlying :many
SELECT DISTINCT underlying
FROM option_snapshots
WHERE time >= $1
ORDER BY underlying;

-- name: GetExpirationDates :many
SELECT DISTINCT expiration_date
FROM option_snapshots
WHERE underlying = $1
  AND time >= $2
ORDER BY expiration_date;

-- ----------------------------------------------------------------------------
-- READ FROM ENRICHED VIEW
-- ----------------------------------------------------------------------------
-- name: GetEnrichedSnapshots :many
SELECT *
FROM option_snapshots_enriched
WHERE underlying = $1
  AND time >= $2
ORDER BY time DESC,
  strike_price;

-- name: GetEnrichedSnapshotsBetween :many
SELECT *
FROM option_snapshots_enriched
WHERE underlying = @underlying
  AND time >= @start_time
  AND time <= @end_time
ORDER BY time DESC,
  strike_price;


-- ----------------------------------------------------------------------------
-- READ FROM OHLC MATERIALIZED VIEWS
-- ----------------------------------------------------------------------------
-- name: GetOHLC30m :many
SELECT
  sqlc.embed(option_snapshots),
  
FROM option_snapshots_ohlc_30m
WHERE ticker = $1::string
  AND bucket >= $2::time
ORDER BY bucket ASC;

-- name: GetOHLC1h :many
SELECT *
FROM option_snapshots_ohlc_1h
WHERE ticker = $1::string
  AND bucket >= $2::time
ORDER BY bucket ASC;

-- name: GetOHLC30mByUnderlying :many
SELECT *
FROM option_snapshots_ohlc_30m
WHERE ticker LIKE $1::string || '%'
  AND bucket >= $2::time
ORDER BY bucket ASC,
  strike_price;

-- name: GetOHLC1hByUnderlying :many
SELECT *
FROM option_snapshots_ohlc_1h
WHERE ticker LIKE $1::string || '%'
  AND bucket >= $2::time
ORDER BY bucket ASC,
  strike_price;

-- ----------------------------------------------------------------------------
-- AGGREGATION QUERIES
-- ----------------------------------------------------------------------------
-- name: GetPortfolioGreeks :many
SELECT underlying,
  SUM(delta * shares_per_contract) AS portfolio_delta,
  SUM(gamma * shares_per_contract) AS portfolio_gamma,
  SUM(theta * shares_per_contract) AS portfolio_theta,
  SUM(vega * shares_per_contract) AS portfolio_vega
FROM option_snapshots
WHERE time >= $1
GROUP BY underlying
ORDER BY underlying;

-- name: GetRowCountByDay :many
SELECT time_bucket('1 day', time) AS DAY,
  COUNT(*) AS row_count,
  COUNT(DISTINCT ticker) AS unique_tickers
FROM option_snapshots
WHERE time >= $1
GROUP BY DAY
ORDER BY DAY DESC;

-- name: GetAverageVolumeByTicker :many
SELECT ticker,
  AVG(volume) AS avg_volume,
  STDDEV(volume) AS stddev_volume
FROM option_snapshots
WHERE time >= $1
GROUP BY ticker
ORDER BY avg_volume DESC;

-- ----------------------------------------------------------------------------
-- UPDATE OPERATIONS
-- ----------------------------------------------------------------------------
-- name: UpdateGreeks :exec
UPDATE option_snapshots
SET delta = $6,
  gamma = $7,
  theta = $8,
  vega = $9,
  rho = $10,
  implied_volatility = $11
WHERE time = $1
  AND ticker = $2
  AND strike_price = $3
  AND expiration_date = $4
  AND option_type = $5;

-- name: UpdateBidAsk :exec
UPDATE option_snapshots
SET bid = $6,
  ask = $7,
  bid_size = $8,
  ask_size = $9,
  last_updated_src = $10
WHERE time = $1
  AND ticker = $2
  AND strike_price = $3
  AND expiration_date = $4
  AND option_type = $5;

-- name: UpdateVolume :exec
UPDATE option_snapshots
SET volume = $2,
  open_interest = $3
WHERE ticker = $1
  AND time >= $4;

-- name: UpdateUnderlyingPrice :exec
UPDATE option_snapshots
SET underlying_price = $2,
  underlying_last_updated = $3
WHERE underlying = $1
  AND time >= $4;

-- ----------------------------------------------------------------------------
-- DELETE OPERATIONS
-- ----------------------------------------------------------------------------
-- name: DeleteOldSnapshots :exec
DELETE FROM option_snapshots
WHERE time < $1;

-- name: DeleteByTicker :exec
DELETE FROM option_snapshots
WHERE ticker = $1;

-- name: DeleteByTickerTimeRange :exec
DELETE FROM option_snapshots
WHERE ticker = @ticker
  AND time >= @start_time
  AND time <= @end_time;

-- name: DeleteExpiredOptions :exec
DELETE FROM option_snapshots
WHERE expiration_date < $1;

-- name: DeleteInvalidSnapshots :exec
DELETE FROM option_snapshots
WHERE bid IS NULL
  AND ask IS NULL
  AND volume = 0;

-- name: DeleteByID :exec
DELETE FROM option_snapshots
WHERE time = $1
  AND ticker = $2
  AND strike_price = $3
  AND expiration_date = $4
  AND option_type = $5;