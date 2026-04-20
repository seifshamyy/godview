-- ============================================================
-- PF EYE — COMPLETE SCHEMA
-- Project ID: oidizmsasvtffjhhzsmg
-- Run in Supabase SQL Editor
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 1. LOCATIONS
CREATE TABLE IF NOT EXISTS pf_locations (
  location_id     integer PRIMARY KEY,
  name            text NOT NULL,
  lat             numeric,
  lng             numeric,
  parent_id       integer REFERENCES pf_locations(location_id),
  raw_payload     jsonb,
  synced_at       timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_locations_parent ON pf_locations(parent_id);

-- 2. AGENTS
CREATE TABLE IF NOT EXISTS pf_agents (
  public_profile_id   integer PRIMARY KEY,
  user_id             integer,
  first_name          text,
  last_name           text,
  email               text,
  phone               text,
  status              text,
  role_name           text,
  is_super_agent      boolean DEFAULT false,
  verification_status text,
  raw_payload         jsonb,
  synced_at           timestamptz DEFAULT now()
);

-- 3. LISTINGS
CREATE TABLE IF NOT EXISTS pf_listings (
  pf_listing_id           text PRIMARY KEY,
  reference               text UNIQUE NOT NULL,
  category                text,
  property_type           text,
  bedrooms                text,
  bathrooms               text,
  size_sqft               numeric,
  built_up_area_sqft      numeric,
  plot_size_sqft          numeric,
  property_age            integer,
  furnishing              text,
  finishing               text,
  amenities               text[],
  developer               text,
  project_status          text,
  floor_number            text,
  num_floors              integer,
  parking_slots           integer,
  has_garden              boolean,
  has_kitchen             boolean,
  has_parking             boolean,
  street_direction        text,
  street_width            numeric,
  unit_number             text,
  location_id             integer REFERENCES pf_locations(location_id),
  price_type              text,
  price_sale              bigint,
  price_yearly            bigint,
  price_monthly           bigint,
  price_weekly            bigint,
  price_daily             bigint,
  downpayment             bigint,
  num_cheques             integer,
  price_on_request        boolean DEFAULT false,
  effective_price         bigint,
  price_per_sqft          numeric,
  agent_public_profile_id integer REFERENCES pf_agents(public_profile_id),
  agent_name              text,
  created_by_profile_id   integer,
  tier_featured           jsonb,
  tier_premium            jsonb,
  tier_standard           jsonb,
  current_tier            text,
  tier_expires_at         timestamptz,
  pf_quality_score        integer,
  pf_quality_color        text,
  pf_quality_details      jsonb,
  listing_stage           text,
  listing_state_type      text,
  state_reasons           jsonb,
  is_live                 boolean DEFAULT false,
  published_at            timestamptz,
  compliance              jsonb,
  rnpm                    jsonb,
  verification_status     text,
  image_count             integer DEFAULT 0,
  has_video               boolean DEFAULT false,
  cts_priority            integer,
  days_live               integer,
  pf_created_at           timestamptz,
  pf_updated_at           timestamptz,
  last_synced_at          timestamptz DEFAULT now(),
  first_seen_at           timestamptz DEFAULT now(),
  is_deleted              boolean DEFAULT false,
  deleted_at              timestamptz
);

CREATE INDEX IF NOT EXISTS idx_listings_location ON pf_listings(location_id);
CREATE INDEX IF NOT EXISTS idx_listings_agent ON pf_listings(agent_public_profile_id);
CREATE INDEX IF NOT EXISTS idx_listings_tier ON pf_listings(current_tier);
CREATE INDEX IF NOT EXISTS idx_listings_type ON pf_listings(property_type);
CREATE INDEX IF NOT EXISTS idx_listings_category ON pf_listings(category);
CREATE INDEX IF NOT EXISTS idx_listings_bedrooms ON pf_listings(bedrooms);
CREATE INDEX IF NOT EXISTS idx_listings_is_live ON pf_listings(is_live);
CREATE INDEX IF NOT EXISTS idx_listings_reference ON pf_listings(reference);
CREATE INDEX IF NOT EXISTS idx_listings_stage ON pf_listings(listing_stage);
CREATE INDEX IF NOT EXISTS idx_listings_composite_segment ON pf_listings(location_id, category, property_type, bedrooms);

-- 4. LEADS
CREATE TABLE IF NOT EXISTS pf_leads (
  pf_lead_id          text PRIMARY KEY,
  listing_reference   text REFERENCES pf_listings(reference),
  lead_created_at     timestamptz,
  response_link       text,
  raw_payload         jsonb,
  synced_at           timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_leads_listing ON pf_leads(listing_reference);
CREATE INDEX IF NOT EXISTS idx_leads_created ON pf_leads(lead_created_at);

-- 5. CREDIT TRANSACTIONS
CREATE TABLE IF NOT EXISTS pf_credit_transactions (
  pf_transaction_id   text PRIMARY KEY,
  transaction_type    text,
  credit_amount       numeric,
  listing_reference   text,
  transaction_at      timestamptz,
  raw_payload         jsonb,
  synced_at           timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_credits_listing ON pf_credit_transactions(listing_reference);
CREATE INDEX IF NOT EXISTS idx_credits_type ON pf_credit_transactions(transaction_type);
CREATE INDEX IF NOT EXISTS idx_credits_date ON pf_credit_transactions(transaction_at);

-- 6. CREDIT SNAPSHOTS
CREATE TABLE IF NOT EXISTS pf_credit_snapshots (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  credit_balance  numeric,
  snapshot_at     timestamptz DEFAULT now()
);

-- 7. AGENT STATS
CREATE TABLE IF NOT EXISTS pf_agent_stats (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  agent_public_profile_id integer REFERENCES pf_agents(public_profile_id),
  stats_payload           jsonb,
  snapshot_date           date DEFAULT CURRENT_DATE,
  synced_at               timestamptz DEFAULT now(),
  UNIQUE(agent_public_profile_id, snapshot_date)
);

-- 8. DAILY LISTING SNAPSHOTS
CREATE TABLE IF NOT EXISTS listing_daily_snapshots (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pf_listing_id       text NOT NULL REFERENCES pf_listings(pf_listing_id),
  snapshot_date       date NOT NULL DEFAULT CURRENT_DATE,
  total_leads         integer DEFAULT 0,
  new_leads_today     integer DEFAULT 0,
  pf_quality_score    integer,
  current_tier        text,
  effective_price     bigint,
  is_live             boolean,
  days_live           integer,
  total_credits_spent numeric DEFAULT 0,
  cpl                 numeric,
  created_at          timestamptz DEFAULT now(),
  UNIQUE(pf_listing_id, snapshot_date)
);
CREATE INDEX IF NOT EXISTS idx_snapshots_listing_date ON listing_daily_snapshots(pf_listing_id, snapshot_date);
CREATE INDEX IF NOT EXISTS idx_snapshots_date ON listing_daily_snapshots(snapshot_date);

-- 9. SEGMENT BENCHMARKS
CREATE TABLE IF NOT EXISTS segment_benchmarks (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  benchmark_date      date NOT NULL DEFAULT CURRENT_DATE,
  location_id         integer,
  category            text,
  property_type       text,
  bedrooms            text,
  segment_level       integer NOT NULL DEFAULT 4,
  listing_count       integer,
  avg_price           numeric,
  median_price        numeric,
  min_price           numeric,
  max_price           numeric,
  avg_price_per_sqft  numeric,
  avg_leads           numeric,
  median_leads        numeric,
  p25_leads           numeric,
  p75_leads           numeric,
  avg_leads_per_day   numeric,
  avg_cpl             numeric,
  median_cpl          numeric,
  avg_quality_score   numeric,
  pct_featured        numeric,
  pct_premium         numeric,
  pct_standard        numeric,
  computed_at         timestamptz DEFAULT now(),
  UNIQUE(benchmark_date, location_id, category, property_type, bedrooms, segment_level)
);
CREATE INDEX IF NOT EXISTS idx_benchmarks_segment ON segment_benchmarks(location_id, category, property_type, bedrooms, segment_level);
CREATE INDEX IF NOT EXISTS idx_benchmarks_date ON segment_benchmarks(benchmark_date);

-- 10. SCORING CONFIG
CREATE TABLE IF NOT EXISTS scoring_config (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  version         integer NOT NULL DEFAULT 1,
  is_active       boolean DEFAULT true,
  w_lead_volume         numeric NOT NULL DEFAULT 20,
  w_lead_velocity       numeric NOT NULL DEFAULT 10,
  w_cost_efficiency     numeric NOT NULL DEFAULT 20,
  w_tier_roi            numeric NOT NULL DEFAULT 10,
  w_quality_score       numeric NOT NULL DEFAULT 10,
  w_price_position      numeric NOT NULL DEFAULT 10,
  w_listing_completeness numeric NOT NULL DEFAULT 5,
  w_freshness           numeric NOT NULL DEFAULT 5,
  w_competitive_position numeric NOT NULL DEFAULT 10,
  zero_lead_days_threshold    integer DEFAULT 14,
  zero_lead_penalty_pct       numeric DEFAULT 25,
  min_segment_size            integer DEFAULT 3,
  freshness_decay_start_days  integer DEFAULT 30,
  freshness_decay_end_days    integer DEFAULT 180,
  created_at      timestamptz DEFAULT now(),
  created_by      text,
  notes           text,
  CONSTRAINT weights_sum_100 CHECK (
    w_lead_volume + w_lead_velocity + w_cost_efficiency + w_tier_roi +
    w_quality_score + w_price_position + w_listing_completeness +
    w_freshness + w_competitive_position = 100
  )
);

INSERT INTO scoring_config (
  version, is_active,
  w_lead_volume, w_lead_velocity, w_cost_efficiency, w_tier_roi,
  w_quality_score, w_price_position, w_listing_completeness,
  w_freshness, w_competitive_position,
  created_by, notes
) VALUES (
  1, true, 20, 10, 20, 10, 10, 10, 5, 5, 10,
  'system', 'Initial default weights'
) ON CONFLICT DO NOTHING;

-- 11. LISTING SCORES
CREATE TABLE IF NOT EXISTS listing_scores (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pf_listing_id           text NOT NULL REFERENCES pf_listings(pf_listing_id),
  score_date              date NOT NULL DEFAULT CURRENT_DATE,
  scoring_config_version  integer NOT NULL,
  s_lead_volume           numeric,
  s_lead_velocity         numeric,
  s_cost_efficiency       numeric,
  s_tier_roi              numeric,
  s_quality_score         numeric,
  s_price_position        numeric,
  s_listing_completeness  numeric,
  s_freshness             numeric,
  s_competitive_position  numeric,
  zero_lead_penalty       numeric DEFAULT 0,
  total_score             numeric NOT NULL,
  segment_level_used      integer,
  segment_listing_count   integer,
  score_band              text,
  computed_at             timestamptz DEFAULT now(),
  UNIQUE(pf_listing_id, score_date)
);
CREATE INDEX IF NOT EXISTS idx_scores_listing ON listing_scores(pf_listing_id);
CREATE INDEX IF NOT EXISTS idx_scores_date ON listing_scores(score_date);
CREATE INDEX IF NOT EXISTS idx_scores_band ON listing_scores(score_band);
CREATE INDEX IF NOT EXISTS idx_scores_total ON listing_scores(total_score DESC);

-- 12. AGGREGATE SCORES
CREATE TABLE IF NOT EXISTS aggregate_scores (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  score_date      date NOT NULL DEFAULT CURRENT_DATE,
  dimension_type  text NOT NULL,
  dimension_value text NOT NULL,
  listing_count   integer,
  total_credits   numeric,
  total_leads     integer,
  avg_score       numeric,
  min_score       numeric,
  max_score       numeric,
  avg_cpl         numeric,
  count_s         integer DEFAULT 0,
  count_a         integer DEFAULT 0,
  count_b         integer DEFAULT 0,
  count_c         integer DEFAULT 0,
  count_d         integer DEFAULT 0,
  count_f         integer DEFAULT 0,
  computed_at     timestamptz DEFAULT now(),
  UNIQUE(score_date, dimension_type, dimension_value)
);
CREATE INDEX IF NOT EXISTS idx_agg_dimension ON aggregate_scores(dimension_type, dimension_value);
CREATE INDEX IF NOT EXISTS idx_agg_date ON aggregate_scores(score_date);

-- 13. RECOMMENDATIONS
CREATE TABLE IF NOT EXISTS recommendations (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pf_listing_id       text NOT NULL REFERENCES pf_listings(pf_listing_id),
  recommendation_date date NOT NULL DEFAULT CURRENT_DATE,
  action_type         text NOT NULL,
  priority            text NOT NULL,
  reason_summary      text NOT NULL,
  reason_details      jsonb,
  status              text DEFAULT 'PENDING',
  reviewed_by         text,
  reviewed_at         timestamptz,
  notes               text,
  created_at          timestamptz DEFAULT now(),
  UNIQUE(pf_listing_id, recommendation_date, action_type)
);
CREATE INDEX IF NOT EXISTS idx_recs_listing ON recommendations(pf_listing_id);
CREATE INDEX IF NOT EXISTS idx_recs_status ON recommendations(status);
CREATE INDEX IF NOT EXISTS idx_recs_action ON recommendations(action_type);
CREATE INDEX IF NOT EXISTS idx_recs_priority ON recommendations(priority);

-- 14. SYNC LOG
CREATE TABLE IF NOT EXISTS sync_log (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sync_type       text NOT NULL,
  started_at      timestamptz DEFAULT now(),
  completed_at    timestamptz,
  status          text DEFAULT 'RUNNING',
  records_synced  integer DEFAULT 0,
  records_created integer DEFAULT 0,
  records_updated integer DEFAULT 0,
  error_message   text,
  metadata        jsonb
);
CREATE INDEX IF NOT EXISTS idx_sync_type ON sync_log(sync_type);
CREATE INDEX IF NOT EXISTS idx_sync_status ON sync_log(status);

-- 15. TRIGGER: Auto-compute derived fields
CREATE OR REPLACE FUNCTION fn_listing_derived_fields()
RETURNS TRIGGER AS $$
BEGIN
  NEW.effective_price := COALESCE(
    NEW.price_sale,
    NEW.price_yearly,
    NEW.price_monthly * 12,
    NEW.price_weekly * 52,
    NEW.price_daily * 365
  );

  IF NEW.size_sqft IS NOT NULL AND NEW.size_sqft > 0 AND NEW.effective_price IS NOT NULL THEN
    NEW.price_per_sqft := ROUND(NEW.effective_price::numeric / NEW.size_sqft, 2);
  ELSE
    NEW.price_per_sqft := NULL;
  END IF;

  IF NEW.tier_featured IS NOT NULL
     AND (NEW.tier_featured->>'expiresAt') IS NOT NULL
     AND (NEW.tier_featured->>'expiresAt')::timestamptz > now() THEN
    NEW.current_tier := 'featured';
    NEW.tier_expires_at := (NEW.tier_featured->>'expiresAt')::timestamptz;
  ELSIF NEW.tier_premium IS NOT NULL
     AND (NEW.tier_premium->>'expiresAt') IS NOT NULL
     AND (NEW.tier_premium->>'expiresAt')::timestamptz > now() THEN
    NEW.current_tier := 'premium';
    NEW.tier_expires_at := (NEW.tier_premium->>'expiresAt')::timestamptz;
  ELSIF NEW.tier_standard IS NOT NULL
     AND (NEW.tier_standard->>'expiresAt') IS NOT NULL
     AND (NEW.tier_standard->>'expiresAt')::timestamptz > now() THEN
    NEW.current_tier := 'standard';
    NEW.tier_expires_at := (NEW.tier_standard->>'expiresAt')::timestamptz;
  ELSE
    NEW.current_tier := 'none';
    NEW.tier_expires_at := NULL;
  END IF;

  IF NEW.published_at IS NOT NULL AND NEW.is_live THEN
    NEW.days_live := EXTRACT(DAY FROM now() - NEW.published_at)::integer;
  ELSE
    NEW.days_live := NULL;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_listing_derived ON pf_listings;
CREATE TRIGGER trg_listing_derived
  BEFORE INSERT OR UPDATE ON pf_listings
  FOR EACH ROW EXECUTE FUNCTION fn_listing_derived_fields();

-- 16. VIEWS
CREATE OR REPLACE VIEW v_portfolio_overview AS
SELECT
  l.pf_listing_id,
  l.reference,
  l.category,
  l.property_type,
  l.bedrooms,
  l.bathrooms,
  l.size_sqft,
  l.effective_price,
  l.price_per_sqft,
  l.price_type,
  l.current_tier,
  l.tier_expires_at,
  l.agent_name,
  l.agent_public_profile_id,
  l.pf_quality_score,
  l.pf_quality_color,
  l.is_live,
  l.published_at,
  l.days_live,
  l.image_count,
  l.has_video,
  l.furnishing,
  l.developer,
  l.project_status,
  l.location_id,
  loc.name AS location_name,
  COALESCE(lead_counts.total_leads, 0) AS total_leads,
  COALESCE(lead_counts.leads_7d, 0) AS leads_7d,
  COALESCE(lead_counts.leads_30d, 0) AS leads_30d,
  COALESCE(credit_sums.total_credits, 0) AS total_credits_spent,
  CASE
    WHEN COALESCE(lead_counts.total_leads, 0) > 0
    THEN ROUND(COALESCE(credit_sums.total_credits, 0) / lead_counts.total_leads, 2)
    ELSE NULL
  END AS cpl,
  ls.total_score,
  ls.score_band
FROM pf_listings l
LEFT JOIN pf_locations loc ON l.location_id = loc.location_id
LEFT JOIN LATERAL (
  SELECT
    COUNT(*) AS total_leads,
    COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '7 days') AS leads_7d,
    COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '30 days') AS leads_30d
  FROM pf_leads
  WHERE listing_reference = l.reference
) lead_counts ON true
LEFT JOIN LATERAL (
  SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
  FROM pf_credit_transactions
  WHERE listing_reference = l.reference
) credit_sums ON true
LEFT JOIN LATERAL (
  SELECT total_score, score_band
  FROM listing_scores
  WHERE pf_listing_id = l.pf_listing_id
  ORDER BY score_date DESC
  LIMIT 1
) ls ON true
WHERE l.is_deleted = false;

CREATE OR REPLACE VIEW v_agent_leaderboard AS
SELECT
  a.public_profile_id,
  a.first_name || ' ' || a.last_name AS agent_name,
  a.status,
  a.is_super_agent,
  COUNT(l.pf_listing_id) FILTER (WHERE l.is_live) AS live_listings,
  COUNT(l.pf_listing_id) AS total_listings,
  AVG(l.pf_quality_score) FILTER (WHERE l.is_live) AS avg_quality_score,
  SUM(COALESCE(lc.lead_count, 0)) AS total_leads,
  SUM(COALESCE(cc.credit_total, 0)) AS total_credits_spent,
  CASE
    WHEN SUM(COALESCE(lc.lead_count, 0)) > 0
    THEN ROUND(SUM(COALESCE(cc.credit_total, 0)) / SUM(lc.lead_count), 2)
    ELSE NULL
  END AS avg_cpl
FROM pf_agents a
LEFT JOIN pf_listings l ON a.public_profile_id = l.agent_public_profile_id AND l.is_deleted = false
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS lead_count
  FROM pf_leads WHERE listing_reference = l.reference
) lc ON true
LEFT JOIN LATERAL (
  SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS credit_total
  FROM pf_credit_transactions WHERE listing_reference = l.reference
) cc ON true
GROUP BY a.public_profile_id, a.first_name, a.last_name, a.status, a.is_super_agent;

-- 17. RLS
ALTER TABLE pf_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE pf_leads ENABLE ROW LEVEL SECURITY;
ALTER TABLE pf_credit_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE listing_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE recommendations ENABLE ROW LEVEL SECURITY;
ALTER TABLE aggregate_scores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated read all" ON pf_listings;
DROP POLICY IF EXISTS "Authenticated read all" ON pf_leads;
DROP POLICY IF EXISTS "Authenticated read all" ON pf_credit_transactions;
DROP POLICY IF EXISTS "Authenticated read all" ON listing_scores;
DROP POLICY IF EXISTS "Authenticated read all" ON recommendations;
DROP POLICY IF EXISTS "Authenticated read all" ON aggregate_scores;
DROP POLICY IF EXISTS "Service full access" ON pf_listings;
DROP POLICY IF EXISTS "Service full access" ON pf_leads;
DROP POLICY IF EXISTS "Service full access" ON pf_credit_transactions;
DROP POLICY IF EXISTS "Service full access" ON listing_scores;
DROP POLICY IF EXISTS "Service full access" ON recommendations;
DROP POLICY IF EXISTS "Service full access" ON aggregate_scores;

CREATE POLICY "Authenticated read all" ON pf_listings FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read all" ON pf_leads FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read all" ON pf_credit_transactions FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read all" ON listing_scores FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read all" ON recommendations FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read all" ON aggregate_scores FOR SELECT TO authenticated USING (true);

CREATE POLICY "Service full access" ON pf_listings FOR ALL TO service_role USING (true);
CREATE POLICY "Service full access" ON pf_leads FOR ALL TO service_role USING (true);
CREATE POLICY "Service full access" ON pf_credit_transactions FOR ALL TO service_role USING (true);
CREATE POLICY "Service full access" ON listing_scores FOR ALL TO service_role USING (true);
CREATE POLICY "Service full access" ON recommendations FOR ALL TO service_role USING (true);
CREATE POLICY "Service full access" ON aggregate_scores FOR ALL TO service_role USING (true);
