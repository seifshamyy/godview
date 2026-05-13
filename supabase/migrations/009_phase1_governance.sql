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

-- ------------------------------------------------------------
-- 7. fn_score_all_listings — extend Competitive Position with
--    developer + project peer partitions (PRD §8A relative ctx)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_score_all_listings()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM listing_scores WHERE score_date = CURRENT_DATE;

  INSERT INTO listing_scores (
    pf_listing_id, score_date, scoring_config_version,
    s_lead_volume, s_lead_velocity, s_cost_efficiency, s_tier_roi,
    s_quality_score, s_price_position, s_listing_completeness,
    s_freshness, s_competitive_position,
    zero_lead_penalty, total_score, segment_level_used,
    segment_listing_count, score_band
  )
  WITH

  cfg AS (
    SELECT * FROM scoring_config WHERE is_active ORDER BY version DESC LIMIT 1
  ),

  lead_agg AS (
    SELECT
      listing_reference,
      COUNT(*)::integer                                                               AS total_leads,
      COUNT(*) FILTER (WHERE lead_created_at >= now()-'30 days'::interval)::integer  AS leads_30d,
      COUNT(*) FILTER (WHERE lead_created_at >= now()-'7 days'::interval)::integer   AS leads_7d,
      COUNT(*) FILTER (WHERE lead_created_at >= now()-'14 days'::interval
                         AND lead_created_at <  now()-'7 days'::interval)::integer   AS leads_prior_7d
    FROM pf_leads GROUP BY listing_reference
  ),

  credit_agg AS (
    SELECT listing_reference, COALESCE(SUM(ABS(credit_amount)),0)::numeric AS total_credits
    FROM pf_credit_transactions GROUP BY listing_reference
  ),

  base AS (
    SELECT
      l.pf_listing_id, l.reference, l.category, l.property_type, l.bedrooms,
      l.location_id, l.current_tier, l.days_live, l.pf_quality_score,
      l.price_per_sqft, l.price_on_request, l.effective_price,
      l.image_count, l.has_video, l.amenities, l.floor_number,
      l.developer, l.project_id,
      l.has_parking, l.furnishing, l.built_up_area_sqft,
      COALESCE(la.total_leads,    0)::integer AS v_total_leads,
      COALESCE(la.leads_30d,      0)::integer AS v_leads_30d,
      COALESCE(la.leads_7d,       0)::integer AS v_leads_7d,
      COALESCE(la.leads_prior_7d, 0)::integer AS v_leads_prior_7d,
      COALESCE(ca.total_credits,  0)          AS v_total_credits
    FROM pf_listings l
    LEFT JOIN lead_agg   la ON la.listing_reference = l.reference
    LEFT JOIN credit_agg ca ON ca.listing_reference = l.reference
    WHERE l.is_live AND NOT l.is_deleted
  ),

  listing_seg AS (
    SELECT DISTINCT ON (b.pf_listing_id)
      b.pf_listing_id,
      sb.avg_leads, sb.median_cpl, sb.median_price, sb.avg_price_per_sqft,
      sb.avg_quality_score, sb.listing_count, sb.segment_level
    FROM base b
    CROSS JOIN cfg
    LEFT JOIN segment_benchmarks sb ON
      sb.benchmark_date = CURRENT_DATE
      AND sb.location_id   = b.location_id
      AND sb.category      = b.category
      AND sb.listing_count >= cfg.min_segment_size
      AND CASE sb.segment_level
            WHEN 4 THEN sb.property_type = b.property_type AND sb.bedrooms = b.bedrooms
            WHEN 3 THEN sb.property_type = b.property_type
            WHEN 2 THEN true
            ELSE false
          END
    ORDER BY b.pf_listing_id, COALESCE(sb.segment_level, 0) DESC
  ),

  std_leads_l3 AS (
    SELECT location_id, category, property_type,
      AVG(v_total_leads::numeric) FILTER (WHERE current_tier = 'standard') AS avg_std_leads
    FROM base GROUP BY location_id, category, property_type
  ),
  std_leads_l2 AS (
    SELECT location_id, category,
      AVG(v_total_leads::numeric) FILTER (WHERE current_tier = 'standard') AS avg_std_leads
    FROM base GROUP BY location_id, category
  ),

  lead_vol_pct AS (
    SELECT
      pf_listing_id,
      (100 * PERCENT_RANK() OVER (PARTITION BY location_id,category,property_type,bedrooms ORDER BY v_leads_30d))::numeric AS pct_l4,
      COUNT(*) OVER (PARTITION BY location_id,category,property_type,bedrooms)                                             AS cnt_l4,
      (100 * PERCENT_RANK() OVER (PARTITION BY location_id,category,property_type ORDER BY v_leads_30d))::numeric          AS pct_l3,
      COUNT(*) OVER (PARTITION BY location_id,category,property_type)                                                     AS cnt_l3,
      (100 * PERCENT_RANK() OVER (PARTITION BY location_id,category ORDER BY v_leads_30d))::numeric                       AS pct_l2,
      COUNT(*) OVER (PARTITION BY location_id,category)                                                                   AS cnt_l2
    FROM base
  ),

  comp_vol_pct AS (
    SELECT
      pf_listing_id,
      (100 * PERCENT_RANK() OVER (PARTITION BY location_id,category,property_type ORDER BY v_total_leads))::numeric AS lead_pct_l3,
      COUNT(*) OVER (PARTITION BY location_id,category,property_type)                                              AS comp_cnt
    FROM base
  ),

  dev_lead_pct AS (
    SELECT pf_listing_id,
           CASE
             WHEN COUNT(*) OVER (PARTITION BY developer) >= 3
               THEN PERCENT_RANK() OVER (PARTITION BY developer ORDER BY v_total_leads) * 100
             ELSE NULL
           END AS dev_pct
    FROM base
    WHERE developer IS NOT NULL
  ),

  proj_lead_pct AS (
    SELECT pf_listing_id,
           CASE
             WHEN COUNT(*) OVER (PARTITION BY project_id) >= 3
               THEN PERCENT_RANK() OVER (PARTITION BY project_id ORDER BY v_total_leads) * 100
             ELSE NULL
           END AS proj_pct
    FROM base
    WHERE project_id IS NOT NULL
  ),

  scored AS (
    SELECT
      b.pf_listing_id,
      cfg.version        AS config_version,
      s.segment_level,
      s.listing_count    AS seg_listing_count,

      -- 1. Lead Volume
      ROUND(CASE
        WHEN s.avg_leads IS NOT NULL AND s.avg_leads > 0 THEN
          COALESCE(
            CASE
              WHEN lv.cnt_l4 >= cfg.min_segment_size THEN lv.pct_l4
              WHEN lv.cnt_l3 >= cfg.min_segment_size THEN lv.pct_l3
              WHEN lv.cnt_l2 >= cfg.min_segment_size THEN lv.pct_l2
            END, 50)
        ELSE 50
      END, 1) AS s_lead_vol,

      -- 2. Lead Velocity
      ROUND(CASE
        WHEN COALESCE(b.days_live,0) < 14 THEN 50
        WHEN b.v_leads_prior_7d = 0 AND b.v_leads_7d = 0 THEN 0
        WHEN b.v_leads_prior_7d = 0 THEN 100
        ELSE LEAST(100, GREATEST(0,
          CASE
            WHEN b.v_leads_7d::numeric/b.v_leads_prior_7d >= 1.5 THEN 100
            WHEN b.v_leads_7d::numeric/b.v_leads_prior_7d >= 1.0 THEN 70+(b.v_leads_7d::numeric/b.v_leads_prior_7d-1.0)/0.5*30
            WHEN b.v_leads_7d::numeric/b.v_leads_prior_7d >= 0.5 THEN 40+(b.v_leads_7d::numeric/b.v_leads_prior_7d-0.5)/0.5*30
            ELSE 10+b.v_leads_7d::numeric/b.v_leads_prior_7d/0.5*30
          END))
      END, 1) AS s_lead_vel,

      -- 3. Cost Efficiency
      ROUND(CASE
        WHEN b.v_total_leads = 0 AND b.v_total_credits > 0 THEN 0
        WHEN b.v_total_leads = 0 THEN 50
        WHEN s.median_cpl IS NOT NULL AND s.median_cpl > 0 AND b.v_total_credits > 0 THEN
          LEAST(100, GREATEST(0,
            CASE
              WHEN s.median_cpl/(b.v_total_credits/b.v_total_leads) >= 2.0 THEN 100
              WHEN s.median_cpl/(b.v_total_credits/b.v_total_leads) >= 1.0 THEN 60+(s.median_cpl/(b.v_total_credits/b.v_total_leads)-1.0)*40
              WHEN s.median_cpl/(b.v_total_credits/b.v_total_leads) >= 0.5 THEN 30+(s.median_cpl/(b.v_total_credits/b.v_total_leads)-0.5)/0.5*30
              ELSE (s.median_cpl/(b.v_total_credits/b.v_total_leads))/0.5*30
            END))
        ELSE 50
      END, 1) AS s_cost_eff,

      -- 4. Tier ROI
      ROUND(CASE
        WHEN b.current_tier IN ('none','standard') THEN 50
        ELSE
          CASE WHEN COALESCE(
              CASE WHEN COALESCE(s.segment_level,0)>=3 THEN sl3.avg_std_leads ELSE sl2.avg_std_leads END,0) = 0
            THEN 50
            ELSE
              LEAST(100, GREATEST(0,
                CASE
                  WHEN b.v_total_leads::numeric /
                       COALESCE(CASE WHEN COALESCE(s.segment_level,0)>=3 THEN sl3.avg_std_leads ELSE sl2.avg_std_leads END,1) /
                       CASE WHEN b.current_tier='featured' THEN 2.5 ELSE 1.8 END >= 1.0
                    THEN 60+LEAST(40,(b.v_total_leads::numeric/COALESCE(CASE WHEN COALESCE(s.segment_level,0)>=3 THEN sl3.avg_std_leads ELSE sl2.avg_std_leads END,1)/CASE WHEN b.current_tier='featured' THEN 2.5 ELSE 1.8 END-1.0)*40)
                  WHEN b.v_total_leads::numeric /
                       COALESCE(CASE WHEN COALESCE(s.segment_level,0)>=3 THEN sl3.avg_std_leads ELSE sl2.avg_std_leads END,1) /
                       CASE WHEN b.current_tier='featured' THEN 2.5 ELSE 1.8 END >= 0.5
                    THEN 30+(b.v_total_leads::numeric/COALESCE(CASE WHEN COALESCE(s.segment_level,0)>=3 THEN sl3.avg_std_leads ELSE sl2.avg_std_leads END,1)/CASE WHEN b.current_tier='featured' THEN 2.5 ELSE 1.8 END-0.5)/0.5*30
                  ELSE (b.v_total_leads::numeric/COALESCE(CASE WHEN COALESCE(s.segment_level,0)>=3 THEN sl3.avg_std_leads ELSE sl2.avg_std_leads END,1)/CASE WHEN b.current_tier='featured' THEN 2.5 ELSE 1.8 END)/0.5*30
                END))
          END
      END, 1) AS s_tier_roi,

      -- 5. PF Quality Score
      ROUND(COALESCE(b.pf_quality_score,50)::numeric, 1) AS s_quality,

      -- 6. Price Position
      ROUND(CASE
        WHEN b.price_on_request THEN 40
        WHEN b.price_per_sqft IS NULL THEN 50
        WHEN s.avg_price_per_sqft IS NOT NULL THEN
          CASE
            WHEN b.price_per_sqft BETWEEN s.avg_price_per_sqft*0.75 AND s.avg_price_per_sqft*1.25 THEN 100
            WHEN b.price_per_sqft BETWEEN s.avg_price_per_sqft*0.5  AND s.avg_price_per_sqft*1.5  THEN 60
            ELSE 30
          END
        ELSE 50
      END, 1) AS s_price_pos,

      -- 7. Listing Completeness
      ROUND(LEAST(100,
        20 +
        CASE WHEN COALESCE(b.image_count,0) >= 5  THEN 15 ELSE 0 END +
        CASE WHEN COALESCE(b.image_count,0) >= 10 THEN 10 ELSE 0 END +
        CASE WHEN b.has_video = true               THEN 15 ELSE 0 END +
        CASE WHEN array_length(b.amenities,1) >= 3 THEN 10 ELSE 0 END +
        CASE WHEN b.floor_number IS NOT NULL        THEN 10 ELSE 0 END +
        CASE WHEN b.developer IS NOT NULL           THEN  5 ELSE 0 END +
        CASE WHEN b.has_parking = true              THEN  5 ELSE 0 END +
        CASE WHEN b.built_up_area_sqft IS NOT NULL  THEN  5 ELSE 0 END +
        CASE WHEN b.furnishing IS NOT NULL          THEN  5 ELSE 0 END
      )::numeric, 1) AS s_completeness,

      -- 8. Freshness
      ROUND(CASE
        WHEN COALESCE(b.days_live,0) <= cfg.freshness_decay_start_days THEN 100
        WHEN COALESCE(b.days_live,0) >= cfg.freshness_decay_end_days   THEN 0
        ELSE 100.0*(cfg.freshness_decay_end_days-b.days_live)::numeric
                  /(cfg.freshness_decay_end_days-cfg.freshness_decay_start_days)
      END, 1) AS s_freshness,

      -- 9. Competitive Position (blended lead percentile across loc/dev/project + price + quality)
      ROUND(CASE
        WHEN s.segment_level IS NOT NULL THEN
          (
            COALESCE(
              (
                COALESCE(cp.lead_pct_l3, 0) * (CASE WHEN cp.lead_pct_l3 IS NOT NULL AND cp.comp_cnt >= cfg.min_segment_size THEN 1 ELSE 0 END)
              + COALESCE(dlp.dev_pct,    0) * (CASE WHEN dlp.dev_pct    IS NOT NULL THEN 1 ELSE 0 END)
              + COALESCE(plp.proj_pct,   0) * (CASE WHEN plp.proj_pct   IS NOT NULL THEN 1 ELSE 0 END)
              )
              /
              NULLIF(
                (CASE WHEN cp.lead_pct_l3 IS NOT NULL AND cp.comp_cnt >= cfg.min_segment_size THEN 1 ELSE 0 END)
              + (CASE WHEN dlp.dev_pct    IS NOT NULL THEN 1 ELSE 0 END)
              + (CASE WHEN plp.proj_pct   IS NOT NULL THEN 1 ELSE 0 END), 0)
            , 50)
           +
           CASE WHEN b.effective_price IS NOT NULL AND s.median_price IS NOT NULL AND s.median_price > 0
                THEN GREATEST(0, 100-ABS(b.effective_price-s.median_price)::numeric/s.median_price*100)
                ELSE 50 END
           +
           CASE WHEN b.pf_quality_score IS NOT NULL AND s.avg_quality_score IS NOT NULL
                THEN LEAST(100, b.pf_quality_score::numeric/NULLIF(s.avg_quality_score,0)*50)
                ELSE 50 END
          ) / 3
        ELSE 50
      END, 1) AS s_competitive,

      b.v_total_leads, b.days_live,
      cfg.w_lead_volume, cfg.w_lead_velocity, cfg.w_cost_efficiency, cfg.w_tier_roi,
      cfg.w_quality_score, cfg.w_price_position, cfg.w_listing_completeness,
      cfg.w_freshness, cfg.w_competitive_position,
      cfg.zero_lead_days_threshold, cfg.zero_lead_penalty_pct

    FROM base b
    CROSS JOIN cfg
    LEFT JOIN listing_seg   s   ON s.pf_listing_id   = b.pf_listing_id
    LEFT JOIN lead_vol_pct  lv  ON lv.pf_listing_id  = b.pf_listing_id
    LEFT JOIN comp_vol_pct  cp  ON cp.pf_listing_id  = b.pf_listing_id
    LEFT JOIN dev_lead_pct  dlp ON dlp.pf_listing_id = b.pf_listing_id
    LEFT JOIN proj_lead_pct plp ON plp.pf_listing_id = b.pf_listing_id
    LEFT JOIN std_leads_l3  sl3 ON sl3.location_id   = b.location_id AND sl3.category = b.category AND sl3.property_type = b.property_type
    LEFT JOIN std_leads_l2  sl2 ON sl2.location_id   = b.location_id AND sl2.category = b.category
  ),

  final AS (
    SELECT *,
      ROUND((s_lead_vol*w_lead_volume + s_lead_vel*w_lead_velocity + s_cost_eff*w_cost_efficiency +
             s_tier_roi*w_tier_roi + s_quality*w_quality_score + s_price_pos*w_price_position +
             s_completeness*w_listing_completeness + s_freshness*w_freshness +
             s_competitive*w_competitive_position) / 100.0, 1) AS raw_score,
      CASE
        WHEN v_total_leads = 0 AND COALESCE(days_live,0) >= zero_lead_days_threshold
        THEN ROUND((s_lead_vol*w_lead_volume + s_lead_vel*w_lead_velocity + s_cost_eff*w_cost_efficiency +
                    s_tier_roi*w_tier_roi + s_quality*w_quality_score + s_price_pos*w_price_position +
                    s_completeness*w_listing_completeness + s_freshness*w_freshness +
                    s_competitive*w_competitive_position) / 100.0
                   * zero_lead_penalty_pct / 100.0, 1)
        ELSE 0
      END AS penalty
    FROM scored
  )

  SELECT
    pf_listing_id, CURRENT_DATE, config_version,
    s_lead_vol, s_lead_vel, s_cost_eff, s_tier_roi, s_quality,
    s_price_pos, s_completeness, s_freshness, s_competitive,
    penalty,
    GREATEST(0, LEAST(100, ROUND(raw_score - penalty, 1))),
    COALESCE(segment_level, 0),
    seg_listing_count,
    CASE
      WHEN GREATEST(0,LEAST(100,ROUND(raw_score-penalty,1))) >= 85 THEN 'S'
      WHEN GREATEST(0,LEAST(100,ROUND(raw_score-penalty,1))) >= 70 THEN 'A'
      WHEN GREATEST(0,LEAST(100,ROUND(raw_score-penalty,1))) >= 55 THEN 'B'
      WHEN GREATEST(0,LEAST(100,ROUND(raw_score-penalty,1))) >= 40 THEN 'C'
      WHEN GREATEST(0,LEAST(100,ROUND(raw_score-penalty,1))) >= 25 THEN 'D'
      ELSE 'F'
    END
  FROM final;
END;
$$;
