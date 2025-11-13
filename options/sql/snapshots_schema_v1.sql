-- Enable TimescaleDB extension
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE SCHEMA IF NOT EXISTS options;

-- Create enum types for option attributes
CREATE TYPE options.option_type AS ENUM ('call', 'put');
CREATE TYPE options.option_style AS ENUM ('american', 'european');
CREATE TYPE options.option_exercise AS ENUM ('long', 'short');
CREATE TYPE options.option_position AS ENUM ('buy', 'sell');
CREATE TYPE options.option_moneyness AS ENUM ('ITM', 'ATM', 'OTM');

-- Main options snapshots table
CREATE TABLE options.snapshots (
  -- rounded timestamp for partitioning
  time TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  ticker TEXT NOT NULL,
  strike_price DECIMAL(12, 4) NOT NULL,
  shares_per_contract INTEGER NOT NULL,
  expiration_date DATE NOT NULL,
  option_type options.option_type NOT NULL,
  option_style options.option_style DEFAULT 'american',
  -- Underlying info
  underlying TEXT NOT NULL,
  underlying_price DECIMAL(12, 4),
  underlying_last_updated TIMESTAMP WITH TIME ZONE DEFAULT NULL,
  -- Volume and interest
  volume BIGINT,
  open_interest DECIMAL(12, 4),
  -- Bid/Ask
  bid DECIMAL(12, 4),
  ask DECIMAL(12, 4),
  bid_size INTEGER,
  ask_size INTEGER,
  -- Greeks
  delta DECIMAL(10, 6),
  gamma DECIMAL(10, 6),
  theta DECIMAL(10, 6),
  vega DECIMAL(10, 6),
  rho DECIMAL(10, 6) DEFAULT NULL,
  -- Implied volatility
  implied_volatility DECIMAL(10, 6),
  -- Metadata
  last_updated_src TIMESTAMP WITH TIME ZONE DEFAULT NULL,
  start_load_time TIMESTAMP WITH TIME ZONE,
  end_load_time TIMESTAMP WITH TIME ZONE,
  PRIMARY KEY (
    time,
    ticker,
    strike_price,
    expiration_date,
    option_type
  )
);

-- Convert to hypertable (partitioned by time)
SELECT create_hypertable(
    'options.snapshots',
    'time',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
  );

-- Create indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_option_ticker_time ON option_snapshots (ticker, time DESC);
CREATE INDEX IF NOT EXISTS idx_option_udr ON option_snapshots (underlying, time DESC);
CREATE INDEX IF NOT EXISTS idx_option_udr_exp ON option_snapshots (underlying, expiration_date, time DESC);
CREATE INDEX IF NOT EXISTS idx_option_exp ON option_snapshots (expiration_date, time DESC);
CREATE INDEX IF NOT EXISTS idx_option_stk ON option_snapshots (strike_price, time DESC);
CREATE INDEX IF NOT EXISTS idx_option_type ON option_snapshots (option_type, ticker, time DESC);

-- Composite index for common queries
CREATE INDEX IF NOT EXISTS idx_option_ticker_exp_stk ON option_snapshots (ticker, expiration_date, strike_price, time DESC);

-- Enable compression after 7 days
ALTER TABLE options.snapshots
SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'ticker, strike_price, expiration_date, option_type',
    timescaledb.compress_orderby = 'time DESC'
  );

SELECT add_compression_policy('options.snapshots', INTERVAL '7 days');


-- Create enriched view with calculated fields
CREATE VIEW options.snapshots_enriched AS
SELECT *,
  (bid + ask) / 2 AS mid,
  (ask - bid) AS spread,
  (end_load_time - start_load_time) AS load_time,
  CASE
    WHEN option_type = 'call' THEN (underlying_price - strike_price)
    ELSE (strike_price - underlying_price)
  END AS intrinsic_value,
  CASE
    WHEN option_type = 'call' THEN CASE
      WHEN underlying_price > strike_price THEN 'ITM'
      WHEN underlying_price = strike_price THEN 'ATM'
      ELSE 'OTM'
    END
    ELSE CASE
      WHEN underlying_price < strike_price THEN 'ITM'
      WHEN underlying_price = strike_price THEN 'ATM'
      ELSE 'OTM'
    END
  END AS moneyness
FROM option_snapshots
GROUP BY time,
  ticker,
  strike_price,
  expiration_date,
  option_type;

CREATE MATERIALIZED VIEW options.snapshots_ohlc_30m WITH (timescaledb.continuous) AS
SELECT time_bucket('30 minutes', time) AS bucket,
  ticker,
  strike_price,
  expiration_date,
  option_type,
  MIN(time) AS first_record_time,
  MAX(time) AS last_record_time,
  -- volume
  SUM(volume) AS volume_total,
  -- volume delta
  (
    CASE
      WHEN FIRST(volume, time) IS NULL THEN NULL
      ELSE LAST(volume, time) - FIRST(volume, time)
    END
  ) AS volume_delta,
  -- open interest
  LAST(open_interest, time) AS open_interest_close,
  MAX(open_interest) AS open_interest_high,
  MIN(open_interest) AS open_interest_low,
  FIRST(open_interest, time) AS open_interest_open,
  -- implied volatility
  LAST(implied_volatility, time) AS implied_volatility_close,
  MAX(implied_volatility) AS implied_volatility_high,
  MIN(implied_volatility) AS implied_volatility_low,
  FIRST(implied_volatility, time) AS implied_volatility_open,
  -- underlying OHLC
  FIRST(underlying_price, time) AS underlying_open,
  MAX(underlying_price) AS underlying_high,
  MIN(underlying_price) AS underlying_low,
  LAST(underlying_price, time) AS underlying_close,
  -- bid OHLC
  FIRST(bid, time) AS bid_open,
  MAX(bid) AS bid_high,
  MIN(bid) AS bid_low,
  LAST(bid, time) AS bid_close,
  -- ask OHLC
  FIRST(ask, time) AS ask_open,
  MAX(ask) AS ask_high,
  MIN(ask) AS ask_low,
  LAST(ask, time) AS ask_close,
  -- delta OHLC
  FIRST(delta, time) AS delta_open,
  MAX(delta) AS delta_high,
  MIN(delta) AS delta_low,
  LAST(delta, time) AS delta_close,
  -- gamma OHLC
  FIRST(gamma, time) AS gamma_open,
  MAX(gamma) AS gamma_high,
  MIN(gamma) AS gamma_low,
  LAST(gamma, time) AS gamma_close,
  -- theta OHLC
  FIRST(theta, time) AS theta_open,
  MAX(theta) AS theta_high,
  MIN(theta) AS theta_low,
  LAST(theta, time) AS theta_close,
  -- vega OHLC
  FIRST(vega, time) AS vega_open,
  MAX(vega) AS vega_high,
  MIN(vega) AS vega_low,
  LAST(vega, time) AS vega_close
FROM options.snapshots
GROUP BY bucket,
  ticker,
  strike_price,
  expiration_date,
  option_type;

SELECT add_continuous_aggregate_policy(
    'options.snapshots_ohlc_30m',
    start_offset => INTERVAL '6 hour',
    end_offset => INTERVAL '30 minutes',
    schedule_interval => INTERVAL '30 minutes'
  );

-- Create 1-hour OHLC aggregates
CREATE MATERIALIZED VIEW options.snapshots_ohlc_1h WITH (timescaledb.continuous) AS
SELECT time_bucket('1 hour', time) AS bucket,
  ticker,
  strike_price,
  expiration_date,
  option_type,
  MIN(time) AS first_record_time,
  MAX(time) AS last_record_time,
  -- volume
  SUM(volume) AS volume_total,
  -- volume delta
  (
    CASE
      WHEN FIRST(volume, time) IS NULL THEN NULL
      ELSE LAST(volume, time) - FIRST(volume, time)
    END
  ) AS volume_delta,
  -- open interest
  LAST(open_interest, time) AS open_interest_close,
  MAX(open_interest) AS open_interest_high,
  MIN(open_interest) AS open_interest_low,
  FIRST(open_interest, time) AS open_interest_open,
  -- implied volatility
  LAST(implied_volatility, time) AS implied_volatility_close,
  MAX(implied_volatility) AS implied_volatility_high,
  MIN(implied_volatility) AS implied_volatility_low,
  FIRST(implied_volatility, time) AS implied_volatility_open,
  -- underlying OHLC
  FIRST(underlying_price, time) AS underlying_open,
  MAX(underlying_price) AS underlying_high,
  MIN(underlying_price) AS underlying_low,
  LAST(underlying_price, time) AS underlying_close,
  -- bid OHLC
  FIRST(bid, time) AS bid_open,
  MAX(bid) AS bid_high,
  MIN(bid) AS bid_low,
  LAST(bid, time) AS bid_close,
  -- ask OHLC
  FIRST(ask, time) AS ask_open,
  MAX(ask) AS ask_high,
  MIN(ask) AS ask_low,
  LAST(ask, time) AS ask_close,
  -- delta OHLC  FIRST(delta, time) AS delta_open,
  FIRST(delta, time) AS delta_open,
  MAX(delta) AS delta_high,
  MIN(delta) AS delta_low,
  LAST(delta, time) AS delta_close,
  -- gamma OHLC
  FIRST(gamma, time) AS gamma_open,
  MAX(gamma) AS gamma_high,
  MIN(gamma) AS gamma_low,
  LAST(gamma, time) AS gamma_close,
  -- theta OHLC
  FIRST(theta, time) AS theta_open,
  MAX(theta) AS theta_high,
  MIN(theta) AS theta_low,
  LAST(theta, time) AS theta_close,
  -- vega OHLC
  FIRST(vega, time) AS vega_open,
  MAX(vega) AS vega_high,
  MIN(vega) AS vega_low,
  LAST(vega, time) AS vega_close
FROM options.snapshots
GROUP BY bucket,
  ticker,
  strike_price,
  expiration_date,
  option_type;

SELECT add_continuous_aggregate_policy(
    'options.snapshots_ohlc_1h',
    start_offset => INTERVAL '12 hours',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour'
  );