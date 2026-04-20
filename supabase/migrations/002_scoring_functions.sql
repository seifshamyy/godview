-- ============================================================
-- PF EYE — SCORING & PIPELINE FUNCTIONS
-- ============================================================

-- ============================================================
-- fn_build_daily_snapshots
-- ============================================================
CREATE OR REPLACE FUNCTION fn_build_daily_snapshots()
RETURNS void AS $$
BEGIN
  INSERT INTO listing_daily_snapshots (
    pf_listing_id, snapshot_date, total_leads, new_leads_today,
    pf_quality_score, current_tier, effective_price, is_live, days_live,
    total_credits_spent, cpl
  )
  SELECT
    l.pf_listing_id,
    CURRENT_DATE,
    COALESCE(lc.total_leads, 0),
    COALESCE(lc.new_today, 0),
    l.pf_quality_score,
    l.current_tier,
    l.effective_price,
    l.is_live,
    l.days_live,
    COALESCE(cc.total_credits, 0),
    CASE WHEN COALESCE(lc.total_leads, 0) > 0
      THEN ROUND(COALESCE(cc.total_credits, 0) / lc.total_leads, 2)
      ELSE NULL
    END
  FROM pf_listings l
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) AS total_leads,
      COUNT(*) FILTER (WHERE lead_created_at::date = CURRENT_DATE) AS new_today
    FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_deleted = false AND l.is_live = true
  ON CONFLICT (pf_listing_id, snapshot_date) DO UPDATE SET
    total_leads         = EXCLUDED.total_leads,
    new_leads_today     = EXCLUDED.new_leads_today,
    pf_quality_score    = EXCLUDED.pf_quality_score,
    current_tier        = EXCLUDED.current_tier,
    effective_price     = EXCLUDED.effective_price,
    is_live             = EXCLUDED.is_live,
    days_live           = EXCLUDED.days_live,
    total_credits_spent = EXCLUDED.total_credits_spent,
    cpl                 = EXCLUDED.cpl;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- fn_build_segment_benchmarks
-- ============================================================
CREATE OR REPLACE FUNCTION fn_build_segment_benchmarks()
RETURNS void AS $$
BEGIN
  DELETE FROM segment_benchmarks WHERE benchmark_date = CURRENT_DATE;

  -- Level 4: location + category + type + bedrooms
  INSERT INTO segment_benchmarks (
    benchmark_date, location_id, category, property_type, bedrooms, segment_level,
    listing_count, avg_price, median_price, min_price, max_price, avg_price_per_sqft,
    avg_leads, median_leads, p25_leads, p75_leads, avg_leads_per_day,
    avg_cpl, median_cpl, avg_quality_score,
    pct_featured, pct_premium, pct_standard
  )
  SELECT
    CURRENT_DATE, l.location_id, l.category, l.property_type, l.bedrooms, 4,
    COUNT(*),
    AVG(l.effective_price),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY l.effective_price),
    MIN(l.effective_price), MAX(l.effective_price),
    AVG(l.price_per_sqft),
    AVG(lc.lead_count),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lc.lead_count),
    CASE WHEN AVG(l.days_live) > 0 THEN AVG(lc.lead_count::numeric / NULLIF(l.days_live, 0)) ELSE 0 END,
    AVG(CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END),
    PERCENTILE_CONT(0.5) WITHIN GROUP (
      ORDER BY CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END
    ),
    AVG(l.pf_quality_score),
    COUNT(*) FILTER (WHERE l.current_tier = 'featured')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'premium')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'standard')::numeric / NULLIF(COUNT(*), 0) * 100
  FROM pf_listings l
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS lead_count FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS credit_total
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_live = true AND l.is_deleted = false
    AND l.location_id IS NOT NULL AND l.category IS NOT NULL
    AND l.property_type IS NOT NULL AND l.bedrooms IS NOT NULL
  GROUP BY l.location_id, l.category, l.property_type, l.bedrooms
  HAVING COUNT(*) >= 1;

  -- Level 3: location + category + type
  INSERT INTO segment_benchmarks (
    benchmark_date, location_id, category, property_type, bedrooms, segment_level,
    listing_count, avg_price, median_price, min_price, max_price, avg_price_per_sqft,
    avg_leads, median_leads, p25_leads, p75_leads, avg_leads_per_day,
    avg_cpl, median_cpl, avg_quality_score,
    pct_featured, pct_premium, pct_standard
  )
  SELECT
    CURRENT_DATE, l.location_id, l.category, l.property_type, NULL, 3,
    COUNT(*),
    AVG(l.effective_price),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY l.effective_price),
    MIN(l.effective_price), MAX(l.effective_price),
    AVG(l.price_per_sqft),
    AVG(lc.lead_count),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lc.lead_count),
    CASE WHEN AVG(l.days_live) > 0 THEN AVG(lc.lead_count::numeric / NULLIF(l.days_live, 0)) ELSE 0 END,
    AVG(CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END),
    PERCENTILE_CONT(0.5) WITHIN GROUP (
      ORDER BY CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END
    ),
    AVG(l.pf_quality_score),
    COUNT(*) FILTER (WHERE l.current_tier = 'featured')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'premium')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'standard')::numeric / NULLIF(COUNT(*), 0) * 100
  FROM pf_listings l
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS lead_count FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS credit_total
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_live = true AND l.is_deleted = false
    AND l.location_id IS NOT NULL AND l.category IS NOT NULL AND l.property_type IS NOT NULL
  GROUP BY l.location_id, l.category, l.property_type
  HAVING COUNT(*) >= 1;

  -- Level 2: location + category
  INSERT INTO segment_benchmarks (
    benchmark_date, location_id, category, property_type, bedrooms, segment_level,
    listing_count, avg_price, median_price, min_price, max_price, avg_price_per_sqft,
    avg_leads, median_leads, p25_leads, p75_leads, avg_leads_per_day,
    avg_cpl, median_cpl, avg_quality_score,
    pct_featured, pct_premium, pct_standard
  )
  SELECT
    CURRENT_DATE, l.location_id, l.category, NULL, NULL, 2,
    COUNT(*),
    AVG(l.effective_price),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY l.effective_price),
    MIN(l.effective_price), MAX(l.effective_price),
    AVG(l.price_per_sqft),
    AVG(lc.lead_count),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lc.lead_count),
    CASE WHEN AVG(l.days_live) > 0 THEN AVG(lc.lead_count::numeric / NULLIF(l.days_live, 0)) ELSE 0 END,
    AVG(CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END),
    PERCENTILE_CONT(0.5) WITHIN GROUP (
      ORDER BY CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END
    ),
    AVG(l.pf_quality_score),
    COUNT(*) FILTER (WHERE l.current_tier = 'featured')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'premium')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'standard')::numeric / NULLIF(COUNT(*), 0) * 100
  FROM pf_listings l
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS lead_count FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS credit_total
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_live = true AND l.is_deleted = false
    AND l.location_id IS NOT NULL AND l.category IS NOT NULL
  GROUP BY l.location_id, l.category
  HAVING COUNT(*) >= 1;

END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- fn_score_all_listings — 9-component scoring engine
-- ============================================================
CREATE OR REPLACE FUNCTION fn_score_all_listings()
RETURNS void AS $$
DECLARE
  cfg         scoring_config%ROWTYPE;
  r           RECORD;
  -- segment benchmarks
  seg         RECORD;
  seg_level   integer;
  -- component scores
  s_lead_vol      numeric;
  s_lead_vel      numeric;
  s_cost_eff      numeric;
  s_tier_roi      numeric;
  s_quality       numeric;
  s_price_pos     numeric;
  s_completeness  numeric;
  s_freshness     numeric;
  s_competitive   numeric;
  -- lead data
  total_leads     integer;
  leads_30d       integer;
  leads_7d        integer;
  leads_prior_7d  integer;
  total_credits   numeric;
  listing_cpl     numeric;
  -- peer data
  peer_lead_pct   numeric;
  peer_price_pct  numeric;
  peer_qual_pct   numeric;
  -- scoring intermediates
  velocity_ratio  numeric;
  cpl_ratio       numeric;
  tier_multiplier numeric;
  expected_mult   numeric;
  actual_mult     numeric;
  completeness_pts numeric;
  penalty         numeric;
  raw_score       numeric;
  final_score     numeric;
  band            text;
BEGIN
  SELECT * INTO cfg FROM scoring_config WHERE is_active = true ORDER BY version DESC LIMIT 1;

  DELETE FROM listing_scores WHERE score_date = CURRENT_DATE;

  FOR r IN
    SELECT
      l.pf_listing_id,
      l.reference,
      l.category,
      l.property_type,
      l.bedrooms,
      l.location_id,
      l.current_tier,
      l.days_live,
      l.pf_quality_score,
      l.price_per_sqft,
      l.price_on_request,
      l.effective_price,
      l.image_count,
      l.has_video,
      l.amenities,
      l.floor_number,
      l.developer,
      l.has_parking,
      l.furnishing,
      l.built_up_area_sqft,
      l.first_seen_at
    FROM pf_listings l
    WHERE l.is_live = true AND l.is_deleted = false
  LOOP

    -- ---- Lead data ----
    SELECT
      COUNT(*)::integer,
      COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '30 days')::integer,
      COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '7 days')::integer,
      COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '14 days'
                         AND lead_created_at < now() - interval '7 days')::integer
    INTO total_leads, leads_30d, leads_7d, leads_prior_7d
    FROM pf_leads WHERE listing_reference = r.reference;

    SELECT COALESCE(SUM(ABS(credit_amount)), 0)
    INTO total_credits
    FROM pf_credit_transactions WHERE listing_reference = r.reference;

    listing_cpl := CASE WHEN COALESCE(total_leads, 0) > 0
      THEN total_credits / total_leads ELSE NULL END;

    -- ---- Find best segment ----
    seg_level := 0;
    seg := NULL;

    -- Try level 4
    SELECT * INTO seg FROM segment_benchmarks
    WHERE benchmark_date = CURRENT_DATE
      AND location_id = r.location_id
      AND category = r.category
      AND property_type = r.property_type
      AND bedrooms = r.bedrooms
      AND segment_level = 4
    LIMIT 1;
    IF FOUND AND seg.listing_count >= cfg.min_segment_size THEN
      seg_level := 4;
    END IF;

    -- Try level 3
    IF seg_level = 0 THEN
      SELECT * INTO seg FROM segment_benchmarks
      WHERE benchmark_date = CURRENT_DATE
        AND location_id = r.location_id
        AND category = r.category
        AND property_type = r.property_type
        AND segment_level = 3
      LIMIT 1;
      IF FOUND AND seg.listing_count >= cfg.min_segment_size THEN
        seg_level := 3;
      END IF;
    END IF;

    -- Try level 2
    IF seg_level = 0 THEN
      SELECT * INTO seg FROM segment_benchmarks
      WHERE benchmark_date = CURRENT_DATE
        AND location_id = r.location_id
        AND category = r.category
        AND segment_level = 2
      LIMIT 1;
      IF FOUND AND seg.listing_count >= cfg.min_segment_size THEN
        seg_level := 2;
      END IF;
    END IF;

    -- ---- Component 1: Lead Volume (20) ----
    IF seg_level > 0 AND seg.avg_leads IS NOT NULL AND seg.avg_leads > 0 THEN
      -- Percentile rank approximation using available stats
      SELECT (
        COUNT(*) FILTER (WHERE subq.lead_count < leads_30d)::numeric /
        NULLIF(COUNT(*), 0) * 100
      ) INTO peer_lead_pct
      FROM (
        SELECT COUNT(*) AS lead_count
        FROM pf_listings pl
        LEFT JOIN LATERAL (
          SELECT COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '30 days') AS lead_count
          FROM pf_leads WHERE listing_reference = pl.reference
        ) lc ON true
        WHERE pl.is_live = true AND pl.is_deleted = false
          AND pl.location_id = r.location_id
          AND (seg_level >= 3 OR pl.property_type = r.property_type)
          AND (seg_level >= 4 OR pl.bedrooms = r.bedrooms)
      ) subq;
      s_lead_vol := COALESCE(peer_lead_pct, 50);
    ELSE
      s_lead_vol := 50;
    END IF;

    -- ---- Component 2: Lead Velocity (10) ----
    IF COALESCE(r.days_live, 0) < 14 THEN
      s_lead_vel := 50;
    ELSIF leads_prior_7d = 0 THEN
      IF leads_7d = 0 THEN
        s_lead_vel := 0;
      ELSE
        s_lead_vel := 100;
      END IF;
    ELSE
      velocity_ratio := leads_7d::numeric / leads_prior_7d;
      IF velocity_ratio >= 1.5 THEN
        s_lead_vel := 100;
      ELSIF velocity_ratio >= 1.0 THEN
        s_lead_vel := 70 + (velocity_ratio - 1.0) / 0.5 * 30;
      ELSIF velocity_ratio >= 0.5 THEN
        s_lead_vel := 40 + (velocity_ratio - 0.5) / 0.5 * 30;
      ELSE
        s_lead_vel := 10 + velocity_ratio / 0.5 * 30;
      END IF;
    END IF;

    -- ---- Component 3: Cost Efficiency (20) ----
    IF total_leads = 0 THEN
      IF total_credits > 0 THEN
        s_cost_eff := 0;
      ELSE
        s_cost_eff := 50;
      END IF;
    ELSIF seg_level > 0 AND seg.median_cpl IS NOT NULL AND seg.median_cpl > 0
          AND listing_cpl IS NOT NULL AND listing_cpl > 0 THEN
      cpl_ratio := seg.median_cpl / listing_cpl;
      IF cpl_ratio >= 2.0 THEN
        s_cost_eff := 100;
      ELSIF cpl_ratio >= 1.0 THEN
        s_cost_eff := 60 + (cpl_ratio - 1.0) / 1.0 * 40;
      ELSIF cpl_ratio >= 0.5 THEN
        s_cost_eff := 30 + (cpl_ratio - 0.5) / 0.5 * 30;
      ELSE
        s_cost_eff := cpl_ratio / 0.5 * 30;
      END IF;
    ELSE
      s_cost_eff := 50;
    END IF;

    -- ---- Component 4: Tier ROI (10) ----
    IF r.current_tier IN ('none', 'standard') THEN
      s_tier_roi := 50;
    ELSE
      IF r.current_tier = 'featured' THEN expected_mult := 2.5;
      ELSE expected_mult := 1.8; END IF;

      -- actual lead multiplier vs standard peers
      SELECT AVG(lc2.lead_count)
      INTO actual_mult
      FROM pf_listings pl2
      LEFT JOIN LATERAL (
        SELECT COUNT(*) AS lead_count FROM pf_leads WHERE listing_reference = pl2.reference
      ) lc2 ON true
      WHERE pl2.is_live = true AND pl2.is_deleted = false
        AND pl2.location_id = r.location_id
        AND pl2.current_tier = 'standard'
        AND (seg_level >= 3 OR pl2.property_type = r.property_type);

      IF actual_mult IS NULL OR actual_mult = 0 THEN
        s_tier_roi := 50;
      ELSE
        tier_multiplier := COALESCE(total_leads, 0)::numeric / actual_mult;
        cpl_ratio := tier_multiplier / expected_mult;
        IF cpl_ratio >= 1.0 THEN
          s_tier_roi := 60 + LEAST(40, (cpl_ratio - 1.0) * 40);
        ELSIF cpl_ratio >= 0.5 THEN
          s_tier_roi := 30 + (cpl_ratio - 0.5) / 0.5 * 30;
        ELSE
          s_tier_roi := cpl_ratio / 0.5 * 30;
        END IF;
      END IF;
    END IF;

    -- ---- Component 5: PF Quality Score (10) ----
    s_quality := COALESCE(r.pf_quality_score, 50);

    -- ---- Component 6: Price Position (10) ----
    IF r.price_on_request THEN
      s_price_pos := 40;
    ELSIF r.price_per_sqft IS NULL THEN
      s_price_pos := 50;
    ELSIF seg_level > 0 AND seg.avg_price_per_sqft IS NOT NULL THEN
      IF r.price_per_sqft BETWEEN seg.avg_price_per_sqft * 0.75 AND seg.avg_price_per_sqft * 1.25 THEN
        s_price_pos := 100;
      ELSIF r.price_per_sqft BETWEEN seg.avg_price_per_sqft * 0.5 AND seg.avg_price_per_sqft * 1.5 THEN
        s_price_pos := 60;
      ELSE
        s_price_pos := 30;
      END IF;
    ELSE
      s_price_pos := 50;
    END IF;

    -- ---- Component 7: Listing Completeness (5) ----
    completeness_pts := 0;
    IF COALESCE(r.image_count, 0) >= 5  THEN completeness_pts := completeness_pts + 15; END IF;
    IF COALESCE(r.image_count, 0) >= 10 THEN completeness_pts := completeness_pts + 10; END IF;
    IF r.has_video = true               THEN completeness_pts := completeness_pts + 15; END IF;
    IF array_length(r.amenities, 1) >= 3 THEN completeness_pts := completeness_pts + 10; END IF;
    IF r.floor_number IS NOT NULL       THEN completeness_pts := completeness_pts + 10; END IF;
    IF r.developer IS NOT NULL          THEN completeness_pts := completeness_pts + 5;  END IF;
    IF r.has_parking = true             THEN completeness_pts := completeness_pts + 5;  END IF;
    IF r.built_up_area_sqft IS NOT NULL THEN completeness_pts := completeness_pts + 5;  END IF;
    IF r.furnishing IS NOT NULL         THEN completeness_pts := completeness_pts + 5;  END IF;
    -- 2 * 10 pts for bilingual titles/desc (assume 20 pts if data present)
    completeness_pts := completeness_pts + 20;
    s_completeness := LEAST(100, completeness_pts);

    -- ---- Component 8: Freshness (5) ----
    IF COALESCE(r.days_live, 0) <= cfg.freshness_decay_start_days THEN
      s_freshness := 100;
    ELSIF r.days_live >= cfg.freshness_decay_end_days THEN
      s_freshness := 0;
    ELSE
      s_freshness := 100.0 * (cfg.freshness_decay_end_days - r.days_live)::numeric
        / (cfg.freshness_decay_end_days - cfg.freshness_decay_start_days);
    END IF;

    -- ---- Component 9: Competitive Position (10) ----
    IF seg_level > 0 THEN
      -- Lead rank percentile
      SELECT (COUNT(*) FILTER (WHERE subq.total_leads < COALESCE(total_leads, 0)))::numeric /
             NULLIF(COUNT(*), 0) * 100
      INTO peer_lead_pct
      FROM (
        SELECT COUNT(*) AS total_leads
        FROM pf_listings pl3
        LEFT JOIN LATERAL (
          SELECT COUNT(*) AS total_leads FROM pf_leads WHERE listing_reference = pl3.reference
        ) lc3 ON true
        WHERE pl3.is_live = true AND pl3.is_deleted = false
          AND pl3.location_id = r.location_id
          AND (seg_level < 3 OR pl3.property_type = r.property_type)
      ) subq;

      -- Price rank (closeness to median → higher = better)
      IF r.effective_price IS NOT NULL AND seg.median_price IS NOT NULL AND seg.median_price > 0 THEN
        peer_price_pct := GREATEST(0, 100 - ABS(r.effective_price - seg.median_price)::numeric / seg.median_price * 100);
      ELSE
        peer_price_pct := 50;
      END IF;

      -- Quality rank
      IF r.pf_quality_score IS NOT NULL AND seg.avg_quality_score IS NOT NULL THEN
        peer_qual_pct := LEAST(100, r.pf_quality_score::numeric / NULLIF(seg.avg_quality_score, 0) * 50);
      ELSE
        peer_qual_pct := 50;
      END IF;

      s_competitive := (COALESCE(peer_lead_pct, 50) + COALESCE(peer_price_pct, 50) + COALESCE(peer_qual_pct, 50)) / 3;
    ELSE
      s_competitive := 50;
    END IF;

    -- ---- Final Score ----
    raw_score := (
      s_lead_vol    * cfg.w_lead_volume +
      s_lead_vel    * cfg.w_lead_velocity +
      s_cost_eff    * cfg.w_cost_efficiency +
      s_tier_roi    * cfg.w_tier_roi +
      s_quality     * cfg.w_quality_score +
      s_price_pos   * cfg.w_price_position +
      s_completeness * cfg.w_listing_completeness +
      s_freshness   * cfg.w_freshness +
      s_competitive * cfg.w_competitive_position
    ) / 100.0;

    penalty := 0;
    IF COALESCE(total_leads, 0) = 0 AND COALESCE(r.days_live, 0) >= cfg.zero_lead_days_threshold THEN
      penalty := raw_score * cfg.zero_lead_penalty_pct / 100.0;
    END IF;

    final_score := GREATEST(0, LEAST(100, ROUND(raw_score - penalty, 1)));

    band := CASE
      WHEN final_score >= 85 THEN 'S'
      WHEN final_score >= 70 THEN 'A'
      WHEN final_score >= 55 THEN 'B'
      WHEN final_score >= 40 THEN 'C'
      WHEN final_score >= 25 THEN 'D'
      ELSE 'F'
    END;

    INSERT INTO listing_scores (
      pf_listing_id, score_date, scoring_config_version,
      s_lead_volume, s_lead_velocity, s_cost_efficiency, s_tier_roi,
      s_quality_score, s_price_position, s_listing_completeness,
      s_freshness, s_competitive_position,
      zero_lead_penalty, total_score, segment_level_used,
      segment_listing_count, score_band
    ) VALUES (
      r.pf_listing_id, CURRENT_DATE, cfg.version,
      ROUND(s_lead_vol,1), ROUND(s_lead_vel,1), ROUND(s_cost_eff,1), ROUND(s_tier_roi,1),
      ROUND(s_quality,1), ROUND(s_price_pos,1), ROUND(s_completeness,1),
      ROUND(s_freshness,1), ROUND(s_competitive,1),
      ROUND(penalty,1), final_score, seg_level,
      CASE WHEN seg_level > 0 THEN seg.listing_count ELSE NULL END, band
    ) ON CONFLICT (pf_listing_id, score_date) DO UPDATE SET
      scoring_config_version  = EXCLUDED.scoring_config_version,
      s_lead_volume           = EXCLUDED.s_lead_volume,
      s_lead_velocity         = EXCLUDED.s_lead_velocity,
      s_cost_efficiency       = EXCLUDED.s_cost_efficiency,
      s_tier_roi              = EXCLUDED.s_tier_roi,
      s_quality_score         = EXCLUDED.s_quality_score,
      s_price_position        = EXCLUDED.s_price_position,
      s_listing_completeness  = EXCLUDED.s_listing_completeness,
      s_freshness             = EXCLUDED.s_freshness,
      s_competitive_position  = EXCLUDED.s_competitive_position,
      zero_lead_penalty       = EXCLUDED.zero_lead_penalty,
      total_score             = EXCLUDED.total_score,
      segment_level_used      = EXCLUDED.segment_level_used,
      segment_listing_count   = EXCLUDED.segment_listing_count,
      score_band              = EXCLUDED.score_band,
      computed_at             = now();

  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- fn_build_aggregate_scores
-- ============================================================
CREATE OR REPLACE FUNCTION fn_build_aggregate_scores()
RETURNS void AS $$
BEGIN
  DELETE FROM aggregate_scores WHERE score_date = CURRENT_DATE;

  -- By agent
  INSERT INTO aggregate_scores (
    score_date, dimension_type, dimension_value,
    listing_count, total_credits, total_leads,
    avg_score, min_score, max_score, avg_cpl,
    count_s, count_a, count_b, count_c, count_d, count_f
  )
  SELECT
    CURRENT_DATE, 'agent', l.agent_name,
    COUNT(DISTINCT l.pf_listing_id),
    SUM(COALESCE(cc.total_credits, 0)),
    SUM(COALESCE(lc.total_leads, 0))::integer,
    AVG(ls.total_score),
    MIN(ls.total_score),
    MAX(ls.total_score),
    CASE WHEN SUM(COALESCE(lc.total_leads, 0)) > 0
      THEN ROUND(SUM(COALESCE(cc.total_credits, 0)) / SUM(COALESCE(lc.total_leads, 0)), 2)
      ELSE NULL END,
    COUNT(*) FILTER (WHERE ls.score_band = 'S'),
    COUNT(*) FILTER (WHERE ls.score_band = 'A'),
    COUNT(*) FILTER (WHERE ls.score_band = 'B'),
    COUNT(*) FILTER (WHERE ls.score_band = 'C'),
    COUNT(*) FILTER (WHERE ls.score_band = 'D'),
    COUNT(*) FILTER (WHERE ls.score_band = 'F')
  FROM pf_listings l
  LEFT JOIN listing_scores ls ON l.pf_listing_id = ls.pf_listing_id AND ls.score_date = CURRENT_DATE
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS total_leads FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_live = true AND l.is_deleted = false AND l.agent_name IS NOT NULL
  GROUP BY l.agent_name
  ON CONFLICT (score_date, dimension_type, dimension_value) DO UPDATE SET
    listing_count = EXCLUDED.listing_count,
    total_credits = EXCLUDED.total_credits,
    total_leads   = EXCLUDED.total_leads,
    avg_score     = EXCLUDED.avg_score,
    min_score     = EXCLUDED.min_score,
    max_score     = EXCLUDED.max_score,
    avg_cpl       = EXCLUDED.avg_cpl,
    count_s = EXCLUDED.count_s, count_a = EXCLUDED.count_a,
    count_b = EXCLUDED.count_b, count_c = EXCLUDED.count_c,
    count_d = EXCLUDED.count_d, count_f = EXCLUDED.count_f;

  -- By location
  INSERT INTO aggregate_scores (
    score_date, dimension_type, dimension_value,
    listing_count, total_credits, total_leads,
    avg_score, min_score, max_score, avg_cpl,
    count_s, count_a, count_b, count_c, count_d, count_f
  )
  SELECT
    CURRENT_DATE, 'location', loc.name,
    COUNT(DISTINCT l.pf_listing_id),
    SUM(COALESCE(cc.total_credits, 0)),
    SUM(COALESCE(lc.total_leads, 0))::integer,
    AVG(ls.total_score),
    MIN(ls.total_score),
    MAX(ls.total_score),
    CASE WHEN SUM(COALESCE(lc.total_leads, 0)) > 0
      THEN ROUND(SUM(COALESCE(cc.total_credits, 0)) / SUM(COALESCE(lc.total_leads, 0)), 2)
      ELSE NULL END,
    COUNT(*) FILTER (WHERE ls.score_band = 'S'),
    COUNT(*) FILTER (WHERE ls.score_band = 'A'),
    COUNT(*) FILTER (WHERE ls.score_band = 'B'),
    COUNT(*) FILTER (WHERE ls.score_band = 'C'),
    COUNT(*) FILTER (WHERE ls.score_band = 'D'),
    COUNT(*) FILTER (WHERE ls.score_band = 'F')
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
  WHERE l.is_live = true AND l.is_deleted = false AND loc.name IS NOT NULL
  GROUP BY loc.name
  ON CONFLICT (score_date, dimension_type, dimension_value) DO UPDATE SET
    listing_count = EXCLUDED.listing_count,
    total_credits = EXCLUDED.total_credits,
    total_leads   = EXCLUDED.total_leads,
    avg_score     = EXCLUDED.avg_score,
    min_score     = EXCLUDED.min_score,
    max_score     = EXCLUDED.max_score,
    avg_cpl       = EXCLUDED.avg_cpl,
    count_s = EXCLUDED.count_s, count_a = EXCLUDED.count_a,
    count_b = EXCLUDED.count_b, count_c = EXCLUDED.count_c,
    count_d = EXCLUDED.count_d, count_f = EXCLUDED.count_f;

  -- By property_type
  INSERT INTO aggregate_scores (
    score_date, dimension_type, dimension_value,
    listing_count, total_credits, total_leads,
    avg_score, min_score, max_score, avg_cpl,
    count_s, count_a, count_b, count_c, count_d, count_f
  )
  SELECT
    CURRENT_DATE, 'property_type', l.property_type,
    COUNT(DISTINCT l.pf_listing_id),
    SUM(COALESCE(cc.total_credits, 0)),
    SUM(COALESCE(lc.total_leads, 0))::integer,
    AVG(ls.total_score),
    MIN(ls.total_score),
    MAX(ls.total_score),
    CASE WHEN SUM(COALESCE(lc.total_leads, 0)) > 0
      THEN ROUND(SUM(COALESCE(cc.total_credits, 0)) / SUM(COALESCE(lc.total_leads, 0)), 2)
      ELSE NULL END,
    COUNT(*) FILTER (WHERE ls.score_band = 'S'),
    COUNT(*) FILTER (WHERE ls.score_band = 'A'),
    COUNT(*) FILTER (WHERE ls.score_band = 'B'),
    COUNT(*) FILTER (WHERE ls.score_band = 'C'),
    COUNT(*) FILTER (WHERE ls.score_band = 'D'),
    COUNT(*) FILTER (WHERE ls.score_band = 'F')
  FROM pf_listings l
  LEFT JOIN listing_scores ls ON l.pf_listing_id = ls.pf_listing_id AND ls.score_date = CURRENT_DATE
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS total_leads FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_live = true AND l.is_deleted = false AND l.property_type IS NOT NULL
  GROUP BY l.property_type
  ON CONFLICT (score_date, dimension_type, dimension_value) DO UPDATE SET
    listing_count = EXCLUDED.listing_count,
    total_credits = EXCLUDED.total_credits,
    total_leads   = EXCLUDED.total_leads,
    avg_score     = EXCLUDED.avg_score,
    count_s = EXCLUDED.count_s, count_a = EXCLUDED.count_a,
    count_b = EXCLUDED.count_b, count_c = EXCLUDED.count_c,
    count_d = EXCLUDED.count_d, count_f = EXCLUDED.count_f;

  -- By tier
  INSERT INTO aggregate_scores (
    score_date, dimension_type, dimension_value,
    listing_count, total_credits, total_leads,
    avg_score, min_score, max_score, avg_cpl,
    count_s, count_a, count_b, count_c, count_d, count_f
  )
  SELECT
    CURRENT_DATE, 'tier', l.current_tier,
    COUNT(DISTINCT l.pf_listing_id),
    SUM(COALESCE(cc.total_credits, 0)),
    SUM(COALESCE(lc.total_leads, 0))::integer,
    AVG(ls.total_score),
    MIN(ls.total_score),
    MAX(ls.total_score),
    CASE WHEN SUM(COALESCE(lc.total_leads, 0)) > 0
      THEN ROUND(SUM(COALESCE(cc.total_credits, 0)) / SUM(COALESCE(lc.total_leads, 0)), 2)
      ELSE NULL END,
    COUNT(*) FILTER (WHERE ls.score_band = 'S'),
    COUNT(*) FILTER (WHERE ls.score_band = 'A'),
    COUNT(*) FILTER (WHERE ls.score_band = 'B'),
    COUNT(*) FILTER (WHERE ls.score_band = 'C'),
    COUNT(*) FILTER (WHERE ls.score_band = 'D'),
    COUNT(*) FILTER (WHERE ls.score_band = 'F')
  FROM pf_listings l
  LEFT JOIN listing_scores ls ON l.pf_listing_id = ls.pf_listing_id AND ls.score_date = CURRENT_DATE
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS total_leads FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_live = true AND l.is_deleted = false AND l.current_tier IS NOT NULL
  GROUP BY l.current_tier
  ON CONFLICT (score_date, dimension_type, dimension_value) DO UPDATE SET
    listing_count = EXCLUDED.listing_count,
    total_credits = EXCLUDED.total_credits,
    total_leads   = EXCLUDED.total_leads,
    avg_score     = EXCLUDED.avg_score,
    count_s = EXCLUDED.count_s, count_a = EXCLUDED.count_a,
    count_b = EXCLUDED.count_b, count_c = EXCLUDED.count_c,
    count_d = EXCLUDED.count_d, count_f = EXCLUDED.count_f;

END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- fn_generate_recommendations
-- ============================================================
CREATE OR REPLACE FUNCTION fn_generate_recommendations()
RETURNS void AS $$
DECLARE
  cfg scoring_config%ROWTYPE;
  r   RECORD;
  seg_avg   numeric;
  seg_min   numeric;
  seg_max   numeric;
BEGIN
  SELECT * INTO cfg FROM scoring_config WHERE is_active = true ORDER BY version DESC LIMIT 1;

  DELETE FROM recommendations WHERE recommendation_date = CURRENT_DATE;

  FOR r IN
    SELECT
      l.pf_listing_id,
      l.reference,
      l.current_tier,
      l.days_live,
      l.pf_quality_score,
      l.pf_quality_color,
      l.effective_price,
      l.price_per_sqft,
      l.agent_name,
      l.location_id,
      l.property_type,
      l.bedrooms,
      l.image_count,
      l.category,
      ls.total_score,
      ls.score_band,
      ls.s_lead_volume,
      ls.s_cost_efficiency,
      ls.s_tier_roi,
      ls.s_quality_score,
      ls.s_freshness,
      COALESCE(lc.total_leads, 0) AS total_leads,
      COALESCE(lc.leads_30d, 0) AS leads_30d,
      COALESCE(cc.total_credits, 0) AS total_credits
    FROM pf_listings l
    LEFT JOIN LATERAL (
      SELECT total_score, score_band, s_lead_volume, s_cost_efficiency,
             s_tier_roi, s_quality_score, s_freshness
      FROM listing_scores WHERE pf_listing_id = l.pf_listing_id
      ORDER BY score_date DESC LIMIT 1
    ) ls ON true
    LEFT JOIN LATERAL (
      SELECT COUNT(*) AS total_leads,
        COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '30 days') AS leads_30d
      FROM pf_leads WHERE listing_reference = l.reference
    ) lc ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
      FROM pf_credit_transactions WHERE listing_reference = l.reference
    ) cc ON true
    WHERE l.is_live = true AND l.is_deleted = false
  LOOP

    -- RULE 1: REMOVE
    IF r.score_band = 'F' AND r.total_leads = 0 AND r.total_credits > 0 AND COALESCE(r.days_live, 0) > 21 THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'REMOVE', 'CRITICAL',
        format('Score %s (F-band), %s days live, %s credits spent, 0 leads. Complete waste of budget.',
          r.total_score, r.days_live, r.total_credits),
        jsonb_build_object('score', r.total_score, 'days_live', r.days_live, 'credits', r.total_credits, 'leads', 0)
      ) ON CONFLICT DO NOTHING;
    END IF;

    -- RULE 2: DOWNGRADE (only if listing > 14 days old per spec 10.1)
    IF r.score_band IN ('D', 'F') AND r.current_tier IN ('featured', 'premium')
       AND COALESCE(r.days_live, 0) > 14 THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'DOWNGRADE', 'HIGH',
        format('Score %s (%s-band) but on %s tier. Tier ROI score: %s. Downgrade to save credits.',
          r.total_score, r.score_band, r.current_tier, r.s_tier_roi),
        jsonb_build_object('score', r.total_score, 'tier', r.current_tier, 'tier_roi', r.s_tier_roi)
      ) ON CONFLICT DO NOTHING;
    END IF;

    -- RULE 3: UPGRADE
    IF r.score_band = 'S' AND r.current_tier = 'standard' THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'UPGRADE', 'HIGH',
        format('Score %s (S-band) on standard tier. %s leads in 30d. High performer — upgrade could amplify.',
          r.total_score, r.leads_30d),
        jsonb_build_object('score', r.total_score, 'leads_30d', r.leads_30d)
      ) ON CONFLICT DO NOTHING;
    END IF;

    -- RULE 4: BOOST
    IF r.score_band = 'A' AND r.current_tier = 'standard' AND r.leads_30d >= 3 THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'BOOST', 'MEDIUM',
        format('Score %s (A-band), %s leads in 30d on standard. Consider premium upgrade.',
          r.total_score, r.leads_30d),
        jsonb_build_object('score', r.total_score, 'leads_30d', r.leads_30d)
      ) ON CONFLICT DO NOTHING;
    END IF;

    -- RULE 5: WATCHLIST
    IF r.score_band = 'C' AND COALESCE(r.days_live, 0) > 14 THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'WATCHLIST', 'LOW',
        format('Score %s (C-band). Lead volume score: %s, cost efficiency: %s. Monitor for 7 days.',
          r.total_score, r.s_lead_volume, r.s_cost_efficiency),
        jsonb_build_object('score', r.total_score, 's_lead_volume', r.s_lead_volume, 's_cost_efficiency', r.s_cost_efficiency)
      ) ON CONFLICT DO NOTHING;
    END IF;

    -- RULE 6: IMPROVE_QUALITY
    IF r.pf_quality_score IS NOT NULL AND r.pf_quality_score < 40 THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'IMPROVE_QUALITY', 'MEDIUM',
        format('PF Quality Score %s (%s). Low quality hurts ranking. Check images (%s), descriptions, and completeness.',
          r.pf_quality_score, r.pf_quality_color, r.image_count),
        jsonb_build_object('quality_score', r.pf_quality_score, 'image_count', r.image_count)
      ) ON CONFLICT DO NOTHING;
    END IF;

    -- RULE 7: REPRICE
    IF r.price_per_sqft IS NOT NULL THEN
      SELECT avg_price_per_sqft, min_price, max_price INTO seg_avg, seg_min, seg_max
      FROM segment_benchmarks
      WHERE benchmark_date = CURRENT_DATE
        AND location_id = r.location_id
        AND property_type = r.property_type
        AND segment_level <= 3
      ORDER BY segment_level DESC
      LIMIT 1;

      IF seg_avg IS NOT NULL AND r.price_per_sqft > seg_avg * 1.5 THEN
        INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
        VALUES (r.pf_listing_id, CURRENT_DATE, 'REPRICE', 'MEDIUM',
          format('Price/sqft (%s) is >50%% above segment average (%s). Overpriced listings get fewer leads.',
            r.price_per_sqft, ROUND(seg_avg, 2)),
          jsonb_build_object('listing_ppsf', r.price_per_sqft, 'segment_avg_ppsf', seg_avg)
        ) ON CONFLICT DO NOTHING;
      END IF;
    END IF;

  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- pg_cron Schedules
-- ============================================================
SELECT cron.unschedule('sync-listings')   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sync-listings');
SELECT cron.unschedule('sync-leads')      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sync-leads');
SELECT cron.unschedule('sync-credits')    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sync-credits');
SELECT cron.unschedule('sync-agents')     WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sync-agents');
SELECT cron.unschedule('run-scoring')     WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'run-scoring');

SELECT cron.schedule(
  'sync-listings', '0 */4 * * *',
  $$SELECT net.http_post(
    url := 'https://oidizmsasvtffjhhzsmg.supabase.co/functions/v1/sync-listings',
    headers := '{"Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9pZGl6bXNhc3Z0ZmZqaGh6c21nIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1NDE1MjMyMCwiZXhwIjoyMDY5NzI4MzIwfQ.ZLXQnuQwCs0QZ5_UoxAS9vG63Eyg7yuTvY4LJ_9nSLE","Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb
  )$$
);

SELECT cron.schedule(
  'sync-leads', '0 */2 * * *',
  $$SELECT net.http_post(
    url := 'https://oidizmsasvtffjhhzsmg.supabase.co/functions/v1/sync-leads',
    headers := '{"Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9pZGl6bXNhc3Z0ZmZqaGh6c21nIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1NDE1MjMyMCwiZXhwIjoyMDY5NzI4MzIwfQ.ZLXQnuQwCs0QZ5_UoxAS9vG63Eyg7yuTvY4LJ_9nSLE","Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb
  )$$
);

SELECT cron.schedule(
  'sync-credits', '0 */6 * * *',
  $$SELECT net.http_post(
    url := 'https://oidizmsasvtffjhhzsmg.supabase.co/functions/v1/sync-credits',
    headers := '{"Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9pZGl6bXNhc3Z0ZmZqaGh6c21nIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1NDE1MjMyMCwiZXhwIjoyMDY5NzI4MzIwfQ.ZLXQnuQwCs0QZ5_UoxAS9vG63Eyg7yuTvY4LJ_9nSLE","Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb
  )$$
);

SELECT cron.schedule(
  'sync-agents', '0 1 * * *',
  $$SELECT net.http_post(
    url := 'https://oidizmsasvtffjhhzsmg.supabase.co/functions/v1/sync-agents',
    headers := '{"Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9pZGl6bXNhc3Z0ZmZqaGh6c21nIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1NDE1MjMyMCwiZXhwIjoyMDY5NzI4MzIwfQ.ZLXQnuQwCs0QZ5_UoxAS9vG63Eyg7yuTvY4LJ_9nSLE","Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb
  )$$
);

SELECT cron.schedule(
  'run-scoring', '0 3 * * *',
  $$SELECT net.http_post(
    url := 'https://oidizmsasvtffjhhzsmg.supabase.co/functions/v1/run-scoring-pipeline',
    headers := '{"Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9pZGl6bXNhc3Z0ZmZqaGh6c21nIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1NDE1MjMyMCwiZXhwIjoyMDY5NzI4MzIwfQ.ZLXQnuQwCs0QZ5_UoxAS9vG63Eyg7yuTvY4LJ_9nSLE","Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb
  )$$
);
