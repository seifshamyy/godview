-- ============================================================
-- 009 — Phase 1 Governance, Versioning & Cost-Weighted Aggregation
-- ============================================================

-- ------------------------------------------------------------
-- 1. scoring_config_history — append-only audit log
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS scoring_config_history (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  config_id       bigint NOT NULL,
  version         integer NOT NULL,
  operation       text NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
  changed_at      timestamptz NOT NULL DEFAULT now(),
  changed_by      text,
  reason          text,
  old_row         jsonb,
  new_row         jsonb
);
CREATE INDEX IF NOT EXISTS idx_cfg_hist_version ON scoring_config_history(version);
CREATE INDEX IF NOT EXISTS idx_cfg_hist_changed_at ON scoring_config_history(changed_at DESC);

-- ------------------------------------------------------------
-- 2. Audit trigger on scoring_config
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scoring_config_audit()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO scoring_config_history (config_id, version, operation, changed_by, reason, new_row)
    VALUES (NEW.id, NEW.version, 'INSERT', NEW.created_by, NEW.notes, to_jsonb(NEW));
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO scoring_config_history (config_id, version, operation, changed_by, reason, old_row, new_row)
    VALUES (NEW.id, NEW.version, 'UPDATE', NEW.created_by, NEW.notes, to_jsonb(OLD), to_jsonb(NEW));
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO scoring_config_history (config_id, version, operation, old_row)
    VALUES (OLD.id, OLD.version, 'DELETE', to_jsonb(OLD));
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_scoring_config_audit ON scoring_config;
CREATE TRIGGER trg_scoring_config_audit
AFTER INSERT OR UPDATE OR DELETE ON scoring_config
FOR EACH ROW EXECUTE FUNCTION fn_scoring_config_audit();

-- ------------------------------------------------------------
-- 3. fn_publish_scoring_config — the ONLY supported way to
--    change weights. Creates a new versioned row and deactivates
--    the previous one. Never UPDATE scoring_config directly.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_publish_scoring_config(
  p_w_lead_volume          numeric,
  p_w_lead_velocity        numeric,
  p_w_cost_efficiency      numeric,
  p_w_tier_roi             numeric,
  p_w_quality_score        numeric,
  p_w_price_position       numeric,
  p_w_listing_completeness numeric,
  p_w_freshness            numeric,
  p_w_competitive_position numeric,
  p_zero_lead_days_threshold integer,
  p_zero_lead_penalty_pct    numeric,
  p_min_segment_size         integer,
  p_freshness_decay_start_days integer,
  p_freshness_decay_end_days   integer,
  p_changed_by               text,
  p_reason                   text
) RETURNS integer AS $$
DECLARE
  v_new_version integer;
BEGIN
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'A non-empty reason is required for scoring config changes';
  END IF;

  UPDATE scoring_config SET is_active = false WHERE is_active = true;

  SELECT COALESCE(MAX(version), 0) + 1 INTO v_new_version FROM scoring_config;

  INSERT INTO scoring_config (
    version, is_active,
    w_lead_volume, w_lead_velocity, w_cost_efficiency, w_tier_roi,
    w_quality_score, w_price_position, w_listing_completeness,
    w_freshness, w_competitive_position,
    zero_lead_days_threshold, zero_lead_penalty_pct, min_segment_size,
    freshness_decay_start_days, freshness_decay_end_days,
    created_by, notes
  ) VALUES (
    v_new_version, true,
    p_w_lead_volume, p_w_lead_velocity, p_w_cost_efficiency, p_w_tier_roi,
    p_w_quality_score, p_w_price_position, p_w_listing_completeness,
    p_w_freshness, p_w_competitive_position,
    p_zero_lead_days_threshold, p_zero_lead_penalty_pct, p_min_segment_size,
    p_freshness_decay_start_days, p_freshness_decay_end_days,
    p_changed_by, p_reason
  );

  RETURN v_new_version;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- 4. Capture project_id / project_name on pf_listings
-- ------------------------------------------------------------
ALTER TABLE pf_listings
  ADD COLUMN IF NOT EXISTS project_id   text,
  ADD COLUMN IF NOT EXISTS project_name text;

CREATE INDEX IF NOT EXISTS idx_listings_project ON pf_listings(project_id);

-- Note: pf_listings does not retain a raw_payload column; project_id /
-- project_name will be populated going forward by the sync-listings
-- Edge Function's mapListing() once it reads raw.project.{id,name}.
-- ------------------------------------------------------------
-- 5. aggregate_scores: cost-weighted score column
-- ------------------------------------------------------------
ALTER TABLE aggregate_scores
  ADD COLUMN IF NOT EXISTS cost_weighted_score numeric;

-- ------------------------------------------------------------
-- 6. fn_build_aggregate_scores — cost-weighted + new dimensions
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION _agg_insert_dimension(
  p_dim_type   text,
  p_dim_column text
) RETURNS void AS $$
BEGIN
  EXECUTE format($f$
    INSERT INTO aggregate_scores (
      score_date, dimension_type, dimension_value,
      listing_count, total_credits, total_leads,
      avg_score, cost_weighted_score, min_score, max_score, avg_cpl,
      count_s, count_a, count_b, count_c, count_d, count_f
    )
    SELECT
      CURRENT_DATE,
      %1$L,
      %2$I,
      COUNT(DISTINCT pf_listing_id),
      SUM(total_credits),
      SUM(total_leads)::integer,
      AVG(total_score),
      CASE
        WHEN SUM(total_credits) > 0
          THEN ROUND(SUM(total_score * total_credits) / SUM(total_credits), 2)
        ELSE ROUND(AVG(total_score), 2)
      END,
      MIN(total_score),
      MAX(total_score),
      CASE WHEN SUM(total_leads) > 0
        THEN ROUND(SUM(total_credits) / SUM(total_leads), 2)
        ELSE NULL END,
      COUNT(*) FILTER (WHERE score_band = 'S'),
      COUNT(*) FILTER (WHERE score_band = 'A'),
      COUNT(*) FILTER (WHERE score_band = 'B'),
      COUNT(*) FILTER (WHERE score_band = 'C'),
      COUNT(*) FILTER (WHERE score_band = 'D'),
      COUNT(*) FILTER (WHERE score_band = 'F')
    FROM _agg_base
    WHERE %2$I IS NOT NULL
    GROUP BY %2$I
    ON CONFLICT (score_date, dimension_type, dimension_value) DO UPDATE SET
      listing_count       = EXCLUDED.listing_count,
      total_credits       = EXCLUDED.total_credits,
      total_leads         = EXCLUDED.total_leads,
      avg_score           = EXCLUDED.avg_score,
      cost_weighted_score = EXCLUDED.cost_weighted_score,
      min_score           = EXCLUDED.min_score,
      max_score           = EXCLUDED.max_score,
      avg_cpl             = EXCLUDED.avg_cpl,
      count_s = EXCLUDED.count_s, count_a = EXCLUDED.count_a,
      count_b = EXCLUDED.count_b, count_c = EXCLUDED.count_c,
      count_d = EXCLUDED.count_d, count_f = EXCLUDED.count_f
  $f$, p_dim_type, p_dim_column);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_build_aggregate_scores()
RETURNS void AS $$
BEGIN
  DELETE FROM aggregate_scores WHERE score_date = CURRENT_DATE;

  CREATE TEMP TABLE _agg_base ON COMMIT DROP AS
  SELECT
    l.pf_listing_id,
    l.agent_name,
    loc.name           AS location_name,
    l.property_type,
    l.current_tier,
    l.developer,
    l.project_name,
    ls.total_score,
    ls.score_band,
    COALESCE(lc.total_leads, 0)::integer AS total_leads,
    COALESCE(cc.total_credits, 0)        AS total_credits
  FROM pf_listings l
  LEFT JOIN pf_locations loc ON l.location_id = loc.location_id
  LEFT JOIN listing_scores ls ON l.pf_listing_id = ls.pf_listing_id AND ls.score_date = CURRENT_DATE
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS total_leads FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_live = true AND l.is_deleted = false;

  PERFORM _agg_insert_dimension('agent',         'agent_name');
  PERFORM _agg_insert_dimension('location',      'location_name');
  PERFORM _agg_insert_dimension('property_type', 'property_type');
  PERFORM _agg_insert_dimension('tier',          'current_tier');
  PERFORM _agg_insert_dimension('developer',     'developer');
  PERFORM _agg_insert_dimension('project',       'project_name');
END;
$$ LANGUAGE plpgsql;
