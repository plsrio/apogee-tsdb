-- Enable TimescaleDB extension
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE SCHEMA IF NOT EXISTS options;

-- Define ENUM types
-- Option type ENUM: Call (C), Put (P)
CREATE TYPE options.option_type AS ENUM ('C', 'P');
-- Exercise style ENUM: American (A), European (E)
CREATE TYPE options.exercise_style AS ENUM ('A', 'E');
-- Moneyness ENUM: In the Money (I), At the Money (A), Out of the Money (O)
CREATE TYPE options.moneyness AS ENUM ('I', 'A', 'O');

-- option contracts table
-- stores static information about each option contract
CREATE TABLE options.contracts (
  ticker TEXT NOT NULL,
  expiration_date TIMESTAMP WITH TIME ZONE NOT NULL,
  created_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  underlying TEXT NOT NULL,
  strike_price DECIMAL(12, 4) NOT NULL,
  shares_per_contract INTEGER NOT NULL,
  option_type options.option_type NOT NULL,
  exercise_style options.exercise_style DEFAULT 'A',
  PRIMARY KEY (ticker, expiration_date)
) WITH (
  timescaledb.hypertable,
  timescaledb.partition_column = 'expiration_date',
  timescaledb.orderby = 'expiration_date DESC',
  timescaledb.segmentby = 'option_type, underlying',
  timescaledb.compress
);

SELECT set_chunk_time_interval('options.contracts', INTERVAL '30 days');
SELECT add_compression_policy('options.contracts', INTERVAL '90 days');

-- option contracts indexes
CREATE INDEX IF NOT EXISTS idx_option_contracts_ticker ON options.contracts (ticker DESC);
CREATE INDEX IF NOT EXISTS idx_option_contracts_underlying_expiration ON options.contracts (underlying, expiration_date DESC);

-- options snapshots hypertable
-- Stores time-series data for option contracts
CREATE TABLE options.snapshots (
  timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
  ticker TEXT NOT NULL,
  underlying TEXT NOT NULL,
  strike_price DECIMAL(12, 4) NOT NULL,
  expiration_date TIMESTAMP WITH TIME ZONE NOT NULL,
  option_type options.option_type NOT NULL,
  data_src TEXT NOT NULL,
  underlying_price DECIMAL(12, 4) NOT NULL,
  underlying_last_updated TIMESTAMP WITH TIME ZONE DEFAULT NULL,
  -- open interest
  open_interest DECIMAL(12, 4) DEFAULT 0 NOT NULL,
  -- Bid/Ask
  bid DECIMAL(12, 4) NOT NULL,
  ask DECIMAL(12, 4) NOT NULL,
  midpoint DECIMAL(12, 4) GENERATED ALWAYS AS ((bid + ask) / 2) STORED,
  bid_size DECIMAL(12, 4) NOT NULL,
  ask_size DECIMAL(12, 4) NOT NULL,
  -- intrinsic value
  intrinsic_value DECIMAL(12, 4) GENERATED ALWAYS AS (
    CASE
      WHEN option_type = 'C' THEN (underlying_price - strike_price)
      ELSE (strike_price - underlying_price)
    END
  ) STORED,
  -- moneyness
  moneyness options.moneyness GENERATED ALWAYS AS (
    CASE
      WHEN option_type = 'C' THEN CASE
        WHEN underlying_price > strike_price THEN options.moneyness('I')
        WHEN underlying_price = strike_price THEN options.moneyness('A')
        ELSE options.moneyness('O')
      END
      ELSE CASE
        WHEN underlying_price < strike_price THEN options.moneyness('I')
        WHEN underlying_price = strike_price THEN options.moneyness('A')
        ELSE options.moneyness('O')
      END
    END
  ) STORED,
  -- Greeks
  delta DECIMAL(10, 6) NOT NULL,
  gamma DECIMAL(10, 6) NOT NULL,
  theta DECIMAL(10, 6) NOT NULL,
  vega DECIMAL(10, 6) NOT NULL,
  -- Rho is not always available
  rho DECIMAL(10, 6) DEFAULT NULL,
  -- Implied volatility
  implied_volatility DECIMAL(10, 6),
  -- Metadata
  last_updated_src TIMESTAMP WITH TIME ZONE DEFAULT NULL,
  start_load_time TIMESTAMP WITH TIME ZONE,
  end_load_time TIMESTAMP WITH TIME ZONE,
  PRIMARY KEY (timestamp, ticker)
) WITH (
  timescaledb.hypertable,
  timescaledb.partition_column = 'timestamp',
  timescaledb.orderby = 'timestamp DESC',
  timescaledb.segmentby = 'expiration_date',
  timescaledb.compress
);

SELECT set_chunk_time_interval('options.snapshots', INTERVAL '1 day');
SELECT add_compression_policy('options.snapshots', INTERVAL '7 days');

CREATE INDEX IF NOT EXISTS idx_option_snapshots_underlying ON options.snapshots (underlying, timestamp DESC);

--
-- Create OHLC aggregates
--
-- 30-minute OHLC aggregates
CREATE MATERIALIZED VIEW options.snapshots_ohlc_30m WITH (timescaledb.continuous) AS
SELECT time_bucket('30 minutes', s.timestamp) AS bucket,
  s.ticker AS ticker,
  s.underlying AS underlying,
  s.strike_price AS strike_price,
  s.expiration_date AS expiration_date,
  s.option_type AS option_type,
  MIN(s.timestamp) AS first_record_time,
  MAX(s.timestamp) AS last_record_time,
  -- moneyness open / close
  FIRST(s.moneyness, s.timestamp) AS moneyness_open,
  LAST(s.moneyness, s.timestamp) AS moneyness_close,
  -- open interest
  LAST(s.open_interest, s.timestamp) AS open_interest_close,
  MAX(s.open_interest) AS open_interest_high,
  MIN(s.open_interest) AS open_interest_low,
  FIRST(s.open_interest, s.timestamp) AS open_interest_open,
  -- implied volatility
  LAST(s.implied_volatility, s.timestamp) AS implied_volatility_close,
  MAX(s.implied_volatility) AS implied_volatility_high,
  MIN(s.implied_volatility) AS implied_volatility_low,
  FIRST(s.implied_volatility, s.timestamp) AS implied_volatility_open,
  -- underlying OHLC
  FIRST(s.underlying_price, s.timestamp) AS underlying_open,
  MAX(s.underlying_price) AS underlying_high,
  MIN(s.underlying_price) AS underlying_low,
  LAST(s.underlying_price, s.timestamp) AS underlying_close,
  -- midpoint OHLC
  FIRST(s.midpoint, s.timestamp) AS mid_open,
  MAX(s.midpoint) AS mid_high,
  MIN(s.midpoint) AS mid_low,
  LAST(s.midpoint, s.timestamp) AS mid_close,
  -- bid OHLC
  FIRST(s.bid, s.timestamp) AS bid_open,
  MAX(s.bid) AS bid_high,
  MIN(s.bid) AS bid_low,
  LAST(bid, s.timestamp) AS bid_close,
  -- ask OHLC
  FIRST(s.ask, s.timestamp) AS ask_open,
  MAX(s.ask) AS ask_high,
  MIN(s.ask) AS ask_low,
  LAST(ask, s.timestamp) AS ask_close,
  -- delta OHLC
  FIRST(s.delta, s.timestamp) AS delta_open,
  MAX(s.delta) AS delta_high,
  MIN(s.delta) AS delta_low,
  LAST(s.delta, s.timestamp) AS delta_close,
  -- gamma OHLC
  FIRST(s.gamma, s.timestamp) AS gamma_open,
  MAX(s.gamma) AS gamma_high,
  MIN(s.gamma) AS gamma_low,
  LAST(s.gamma, s.timestamp) AS gamma_close,
  -- theta OHLC
  FIRST(s.theta, s.timestamp) AS theta_open,
  MAX(s.theta) AS theta_high,
  MIN(s.theta) AS theta_low,
  LAST(s.theta, s.timestamp) AS theta_close,
  -- vega OHLC
  FIRST(s.vega, s.timestamp) AS vega_open,
  MAX(s.vega) AS vega_high,
  MIN(s.vega) AS vega_low,
  LAST(s.vega, s.timestamp) AS vega_close
FROM options.snapshots s
GROUP BY bucket,
  ticker,
  underlying,
  strike_price,
  expiration_date,
  option_type;

SELECT add_continuous_aggregate_policy(
    'options.snapshots_ohlc_30m',
    start_offset => INTERVAL '6 hour',
    end_offset => INTERVAL '30 minutes',
    schedule_interval => INTERVAL '30 minutes'
  );

ALTER MATERIALIZED VIEW options.snapshots_ohlc_30m
SET (timescaledb.enable_columnstore = TRUE);

CALL add_columnstore_policy(
  'options.snapshots_ohlc_30m',
  AFTER => INTERVAL '90 days'
);

CREATE VIEW options.snapshots_ohlc_30m_detailed AS
SELECT o.*,
  d.shares_per_contract,
  d.exercise_style
FROM options.snapshots_ohlc_30m o
  JOIN options.contracts d ON o.ticker = d.ticker;

-- 60-minute OHLC aggregate
CREATE MATERIALIZED VIEW options.snapshots_ohlc_60m WITH (timescaledb.continuous) AS
SELECT time_bucket('60 minutes', s.timestamp) AS bucket,
  s.ticker AS ticker,
  s.underlying AS underlying,
  s.strike_price AS strike_price,
  s.expiration_date AS expiration_date,
  s.option_type AS option_type,
  MIN(s.timestamp) AS first_record_time,
  MAX(s.timestamp) AS last_record_time,
  -- moneyness open / close
  FIRST(s.moneyness, s.timestamp) AS moneyness_open,
  LAST(s.moneyness, s.timestamp) AS moneyness_close,
  -- open interest
  LAST(s.open_interest, s.timestamp) AS open_interest_close,
  MAX(s.open_interest) AS open_interest_high,
  MIN(s.open_interest) AS open_interest_low,
  FIRST(s.open_interest, s.timestamp) AS open_interest_open,
  -- implied volatility
  LAST(s.implied_volatility, s.timestamp) AS implied_volatility_close,
  MAX(s.implied_volatility) AS implied_volatility_high,
  MIN(s.implied_volatility) AS implied_volatility_low,
  FIRST(s.implied_volatility, s.timestamp) AS implied_volatility_open,
  -- underlying OHLC
  FIRST(s.underlying_price, s.timestamp) AS underlying_open,
  MAX(s.underlying_price) AS underlying_high,
  MIN(s.underlying_price) AS underlying_low,
  LAST(s.underlying_price, s.timestamp) AS underlying_close,
  -- midpoint OHLC
  FIRST(s.midpoint, s.timestamp) AS mid_open,
  MAX(s.midpoint) AS mid_high,
  MIN(s.midpoint) AS mid_low,
  LAST(s.midpoint, s.timestamp) AS mid_close,
  -- bid OHLC
  FIRST(s.bid, s.timestamp) AS bid_open,
  MAX(s.bid) AS bid_high,
  MIN(s.bid) AS bid_low,
  LAST(bid, s.timestamp) AS bid_close,
  -- ask OHLC
  FIRST(s.ask, s.timestamp) AS ask_open,
  MAX(s.ask) AS ask_high,
  MIN(s.ask) AS ask_low,
  LAST(ask, s.timestamp) AS ask_close,
  -- delta OHLC
  FIRST(s.delta, s.timestamp) AS delta_open,
  MAX(s.delta) AS delta_high,
  MIN(s.delta) AS delta_low,
  LAST(s.delta, s.timestamp) AS delta_close,
  -- gamma OHLC
  FIRST(s.gamma, s.timestamp) AS gamma_open,
  MAX(s.gamma) AS gamma_high,
  MIN(s.gamma) AS gamma_low,
  LAST(s.gamma, s.timestamp) AS gamma_close,
  -- theta OHLC
  FIRST(s.theta, s.timestamp) AS theta_open,
  MAX(s.theta) AS theta_high,
  MIN(s.theta) AS theta_low,
  LAST(s.theta, s.timestamp) AS theta_close,
  -- vega OHLC
  FIRST(s.vega, s.timestamp) AS vega_open,
  MAX(s.vega) AS vega_high,
  MIN(s.vega) AS vega_low,
  LAST(s.vega, s.timestamp) AS vega_close
FROM options.snapshots s
GROUP BY bucket,
  ticker,
  underlying,
  strike_price,
  expiration_date,
  option_type;

SELECT add_continuous_aggregate_policy(
    'options.snapshots_ohlc_60m',
    start_offset => INTERVAL '12 hour',
    end_offset => INTERVAL '60 minutes',
    schedule_interval => INTERVAL '60 minutes'
  );

ALTER MATERIALIZED VIEW options.snapshots_ohlc_60m
SET (timescaledb.enable_columnstore = TRUE);

CALL add_columnstore_policy(
  'options.snapshots_ohlc_60m',
  AFTER => INTERVAL '180 days'
);

CREATE VIEW options.snapshots_ohlc_60m_detailed AS
SELECT o.*,
  d.shares_per_contract,
  d.exercise_style
FROM options.snapshots_ohlc_60m o
  JOIN options.contracts d ON o.ticker = d.ticker;

-- daily aggregate
CREATE MATERIALIZED VIEW options.snapshots_ohlc_daily WITH (timescaledb.continuous) AS
SELECT time_bucket('1 day', s.timestamp) AS bucket,
  s.ticker AS ticker,
  s.underlying AS underlying,
  s.strike_price AS strike_price,
  s.expiration_date AS expiration_date,
  s.option_type AS option_type,
  MIN(s.timestamp) AS first_record_time,
  MAX(s.timestamp) AS last_record_time,
  -- moneyness open / close
  FIRST(s.moneyness, s.timestamp) AS moneyness_open,
  LAST(s.moneyness, s.timestamp) AS moneyness_close,
  -- open interest
  LAST(s.open_interest, s.timestamp) AS open_interest_close,
  MAX(s.open_interest) AS open_interest_high,
  MIN(s.open_interest) AS open_interest_low,
  FIRST(s.open_interest, s.timestamp) AS open_interest_open,
  -- implied volatility
  LAST(s.implied_volatility, s.timestamp) AS implied_volatility_close,
  MAX(s.implied_volatility) AS implied_volatility_high,
  MIN(s.implied_volatility) AS implied_volatility_low,
  FIRST(s.implied_volatility, s.timestamp) AS implied_volatility_open,
  -- underlying OHLC
  FIRST(s.underlying_price, s.timestamp) AS underlying_open,
  MAX(s.underlying_price) AS underlying_high,
  MIN(s.underlying_price) AS underlying_low,
  LAST(s.underlying_price, s.timestamp) AS underlying_close,
  -- midpoint OHLC
  FIRST(s.midpoint, s.timestamp) AS mid_open,
  MAX(s.midpoint) AS mid_high,
  MIN(s.midpoint) AS mid_low,
  LAST(s.midpoint, s.timestamp) AS mid_close,
  -- bid OHLC
  FIRST(s.bid, s.timestamp) AS bid_open,
  MAX(s.bid) AS bid_high,
  MIN(s.bid) AS bid_low,
  LAST(bid, s.timestamp) AS bid_close,
  -- ask OHLC
  FIRST(s.ask, s.timestamp) AS ask_open,
  MAX(s.ask) AS ask_high,
  MIN(s.ask) AS ask_low,
  LAST(ask, s.timestamp) AS ask_close,
  -- delta OHLC
  FIRST(s.delta, s.timestamp) AS delta_open,
  MAX(s.delta) AS delta_high,
  MIN(s.delta) AS delta_low,
  LAST(s.delta, s.timestamp) AS delta_close,
  -- gamma OHLC
  FIRST(s.gamma, s.timestamp) AS gamma_open,
  MAX(s.gamma) AS gamma_high,
  MIN(s.gamma) AS gamma_low,
  LAST(s.gamma, s.timestamp) AS gamma_close,
  -- theta OHLC
  FIRST(s.theta, s.timestamp) AS theta_open,
  MAX(s.theta) AS theta_high,
  MIN(s.theta) AS theta_low,
  LAST(s.theta, s.timestamp) AS theta_close,
  -- vega OHLC
  FIRST(s.vega, s.timestamp) AS vega_open,
  MAX(s.vega) AS vega_high,
  MIN(s.vega) AS vega_low,
  LAST(s.vega, s.timestamp) AS vega_close
FROM options.snapshots s
GROUP BY bucket,
  ticker,
  underlying,
  strike_price,
  expiration_date,
  option_type;

SELECT add_continuous_aggregate_policy(
    'options.snapshots_ohlc_daily',
    start_offset => INTERVAL '3 days',
    end_offset => INTERVAL '1 day',
    schedule_interval => INTERVAL '30 day'
  );

ALTER MATERIALIZED VIEW options.snapshots_ohlc_daily
SET (timescaledb.enable_columnstore = TRUE);

CALL add_columnstore_policy(
  'options.snapshots_ohlc_daily',
  AFTER => INTERVAL '1 year'
);

CREATE VIEW options.snapshots_ohlc_daily_detailed AS
SELECT o.*,
  d.shares_per_contract,
  d.exercise_style
FROM options.snapshots_ohlc_daily o
  JOIN options.contracts d ON o.ticker = d.ticker;