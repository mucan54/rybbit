#!/usr/bin/env bash
set -euo pipefail

clickhouse-client --host 127.0.0.1 --user default --password frog -n <<'SQL'
-- Create DB
CREATE DATABASE IF NOT EXISTS analytics;

-- Session settings (speed up ingest; session-scoped)
SET async_insert = 1;
SET wait_for_async_insert = 0;
SET input_format_parallel_parsing = 1;

-- Drop old (safe on fresh)
DROP TABLE IF EXISTS analytics.session_replay_events_buf;
DROP TABLE IF EXISTS analytics.session_replay_metadata_buf;
DROP TABLE IF EXISTS analytics.session_replay_events SYNC;
DROP TABLE IF EXISTS analytics.session_replay_metadata SYNC;
DROP TABLE IF EXISTS analytics.monitor_events SYNC;
DROP TABLE IF EXISTS analytics.events SYNC;

-- EVENTS: hot 14d -> cold (S3)
CREATE TABLE analytics.events
(
  site_id UInt16,
  timestamp DateTime,
  session_id String,
  user_id String,
  hostname String,
  pathname String,
  querystring String,
  url_parameters Map(String, String),
  page_title String,
  referrer String,
  channel String,
  browser LowCardinality(String),
  browser_version LowCardinality(String),
  operating_system LowCardinality(String),
  operating_system_version LowCardinality(String),
  language LowCardinality(String),
  country LowCardinality(FixedString(2)),
  region LowCardinality(String),
  city String,
  lat Float64,
  lon Float64,
  screen_width UInt16,
  screen_height UInt16,
  device_type LowCardinality(String),
  type LowCardinality(String) DEFAULT 'pageview',
  event_name String,
  props JSON,
  lcp Nullable(Float64),
  cls Nullable(Float64),
  inp Nullable(Float64),
  fcp Nullable(Float64),
  ttfb Nullable(Float64),

  -- ClickHouse 25.4 requires 3 args for tokenbf_v1
  INDEX idx_event_name event_name TYPE tokenbf_v1(8192, 3, 0) GRANULARITY 1,
  INDEX idx_hostname   hostname   TYPE tokenbf_v1(8192, 3, 0) GRANULARITY 1,
  INDEX idx_pathname   pathname   TYPE tokenbf_v1(8192, 3, 0) GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (site_id, timestamp)
TTL timestamp + INTERVAL 14 DAY TO VOLUME 'cold'
SETTINGS index_granularity = 8192, storage_policy = 'tiered_s3_policy';

-- MONITOR EVENTS: hot 30d -> cold (S3)
CREATE TABLE analytics.monitor_events
(
  monitor_id UInt32,
  organization_id String,
  timestamp DateTime,
  monitor_type LowCardinality(String),
  monitor_url String,
  monitor_name String,
  region LowCardinality(String) DEFAULT 'local',
  status LowCardinality(String),
  status_code Nullable(UInt16),
  response_time_ms UInt32,
  dns_time_ms Nullable(UInt32),
  tcp_time_ms Nullable(UInt32),
  tls_time_ms Nullable(UInt32),
  ttfb_ms Nullable(UInt32),
  transfer_time_ms Nullable(UInt32),
  validation_errors Array(String),
  response_headers Map(String, String),
  response_size_bytes Nullable(UInt32),
  port Nullable(UInt16),
  error_message Nullable(String),
  error_type Nullable(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (organization_id, monitor_id, timestamp)
TTL timestamp + INTERVAL 30 DAY TO VOLUME 'cold'
SETTINGS ttl_only_drop_parts = 1, index_granularity = 8192, storage_policy = 'tiered_s3_policy';

-- SESSION REPLAY EVENTS (“videos”): move to cold after 12h; DELETE after 3d
CREATE TABLE analytics.session_replay_events
(
  site_id UInt16,
  session_id String,
  user_id String,
  timestamp DateTime64(3),
  event_type LowCardinality(String),
  event_data String,
  event_data_key Nullable(String),
  batch_index Nullable(UInt16),
  sequence_number UInt32,
  event_size_bytes UInt32,
  viewport_width Nullable(UInt16),
  viewport_height Nullable(UInt16),
  is_complete UInt8 DEFAULT 0
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (site_id, session_id, sequence_number)
TTL
  toDateTime(timestamp) + INTERVAL 12 HOUR TO VOLUME 'cold',
  toDateTime(timestamp) + INTERVAL 3 DAY  DELETE
SETTINGS index_granularity = 8192, storage_policy = 'tiered_s3_policy';

-- SESSION REPLAY METADATA: same (12h -> cold; 3d DELETE)
CREATE TABLE analytics.session_replay_metadata
(
  site_id UInt16,
  session_id String,
  user_id String,
  start_time DateTime,
  end_time Nullable(DateTime),
  duration_ms Nullable(UInt32),
  event_count UInt32,
  compressed_size_bytes UInt32,
  page_url String,
  country LowCardinality(FixedString(2)),
  region LowCardinality(String),
  city String,
  lat Float64,
  lon Float64,
  browser LowCardinality(String),
  browser_version LowCardinality(String),
  operating_system LowCardinality(String),
  operating_system_version LowCardinality(String),
  language LowCardinality(String),
  screen_width UInt16,
  screen_height UInt16,
  device_type LowCardinality(String),
  channel String,
  hostname String,
  referrer String,
  has_replay_data UInt8 DEFAULT 1,
  created_at DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(created_at)
PARTITION BY toYYYYMM(start_time)
ORDER BY (site_id, session_id)
TTL
  start_time + INTERVAL 12 HOUR TO VOLUME 'cold',
  start_time + INTERVAL 3 DAY  DELETE
SETTINGS index_granularity = 8192, storage_policy = 'tiered_s3_policy';

-- Buffer tables (insert here for high-QPS; base tables get TTL/moves)
CREATE TABLE analytics.session_replay_events_buf AS analytics.session_replay_events
ENGINE = Buffer(analytics, session_replay_events,
  16, 3, 30, 50000, 250000, 5242880, 67108864
);

CREATE TABLE analytics.session_replay_metadata_buf AS analytics.session_replay_metadata
ENGINE = Buffer(analytics, session_replay_metadata,
  16, 3, 30, 10000, 100000, 1048576, 16777216
);

-- Apply TTL now (no-op on empty tables, safe)
ALTER TABLE analytics.session_replay_events   MATERIALIZE TTL;
ALTER TABLE analytics.session_replay_metadata MATERIALIZE TTL;

-- Compact (safe even if empty)
OPTIMIZE TABLE analytics.session_replay_events   FINAL;
OPTIMIZE TABLE analytics.session_replay_metadata FINAL;
OPTIMIZE TABLE analytics.events                 FINAL;
OPTIMIZE TABLE analytics.monitor_events         FINAL;

-- Verify
SELECT name, engine, data_paths
FROM system.tables
WHERE database='analytics'
ORDER BY name;

SELECT table, partition, disk_name, sum(bytes_on_disk) AS bytes
FROM system.parts
WHERE database='analytics' AND active
GROUP BY table, partition, disk_name
ORDER BY table, partition, disk_name;
SQL
