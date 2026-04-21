-- Fix "column reference total_leads is ambiguous" in fn_score_all_listings.
-- The original function used bare column aliases (total_leads, lead_count) that
-- conflicted with PL/pgSQL variable names. Renamed all subquery aliases to
-- per_listing_leads_30d / per_listing_lead_total / lead_cnt to avoid ambiguity.
CREATE OR REPLACE FUNCTION public.fn_score_all_listings()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  cfg         scoring_config%ROWTYPE;
  r           RECORD;
  seg         RECORD;
  seg_level   integer;
  s_lead_vol      numeric;
  s_lead_vel      numeric;
  s_cost_eff      numeric;
  s_tier_roi      numeric;
  s_quality       numeric;
  s_price_pos     numeric;
  s_completeness  numeric;
  s_freshness     numeric;
  s_competitive   numeric;
  v_total_leads    integer;
  v_leads_30d      integer;
  v_leads_7d       integer;
  v_leads_prior_7d integer;
  v_total_credits  numeric;
  v_listing_cpl    numeric;
  peer_lead_pct   numeric;
  peer_price_pct  numeric;
  peer_qual_pct   numeric;
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
    SELECT l.pf_listing_id, l.reference, l.category, l.property_type, l.bedrooms,
           l.location_id, l.current_tier, l.days_live, l.pf_quality_score,
           l.price_per_sqft, l.price_on_request, l.effective_price,
           l.image_count, l.has_video, l.amenities, l.floor_number,
           l.developer, l.has_parking, l.furnishing, l.built_up_area_sqft, l.first_seen_at
    FROM pf_listings l
    WHERE l.is_live = true AND l.is_deleted = false
  LOOP

    SELECT
      COUNT(*)::integer,
      COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '30 days')::integer,
      COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '7 days')::integer,
      COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '14 days'
                         AND lead_created_at <  now() - interval '7 days')::integer
    INTO v_total_leads, v_leads_30d, v_leads_7d, v_leads_prior_7d
    FROM pf_leads WHERE listing_reference = r.reference;

    SELECT COALESCE(SUM(ABS(credit_amount)), 0)
    INTO v_total_credits
    FROM pf_credit_transactions WHERE listing_reference = r.reference;

    v_listing_cpl := CASE WHEN COALESCE(v_total_leads, 0) > 0
      THEN v_total_credits / v_total_leads ELSE NULL END;

    seg_level := 0; seg := NULL;

    SELECT * INTO seg FROM segment_benchmarks
    WHERE benchmark_date = CURRENT_DATE AND location_id = r.location_id
      AND category = r.category AND property_type = r.property_type
      AND bedrooms = r.bedrooms AND segment_level = 4 LIMIT 1;
    IF FOUND AND seg.listing_count >= cfg.min_segment_size THEN seg_level := 4; END IF;

    IF seg_level = 0 THEN
      SELECT * INTO seg FROM segment_benchmarks
      WHERE benchmark_date = CURRENT_DATE AND location_id = r.location_id
        AND category = r.category AND property_type = r.property_type
        AND segment_level = 3 LIMIT 1;
      IF FOUND AND seg.listing_count >= cfg.min_segment_size THEN seg_level := 3; END IF;
    END IF;

    IF seg_level = 0 THEN
      SELECT * INTO seg FROM segment_benchmarks
      WHERE benchmark_date = CURRENT_DATE AND location_id = r.location_id
        AND category = r.category AND segment_level = 2 LIMIT 1;
      IF FOUND AND seg.listing_count >= cfg.min_segment_size THEN seg_level := 2; END IF;
    END IF;

    -- Component 1: Lead Volume (20)
    IF seg_level > 0 AND seg.avg_leads IS NOT NULL AND seg.avg_leads > 0 THEN
      SELECT (
        COUNT(*) FILTER (WHERE subq.per_listing_leads_30d < v_leads_30d)::numeric /
        NULLIF(COUNT(*), 0) * 100
      ) INTO peer_lead_pct
      FROM (
        SELECT lc.per_listing_leads_30d
        FROM pf_listings pl
        LEFT JOIN LATERAL (
          SELECT COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '30 days')::integer AS per_listing_leads_30d
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

    -- Component 2: Lead Velocity (10)
    IF COALESCE(r.days_live, 0) < 14 THEN
      s_lead_vel := 50;
    ELSIF v_leads_prior_7d = 0 THEN
      IF v_leads_7d = 0 THEN s_lead_vel := 0; ELSE s_lead_vel := 100; END IF;
    ELSE
      velocity_ratio := v_leads_7d::numeric / v_leads_prior_7d;
      IF    velocity_ratio >= 1.5 THEN s_lead_vel := 100;
      ELSIF velocity_ratio >= 1.0 THEN s_lead_vel := 70 + (velocity_ratio - 1.0) / 0.5 * 30;
      ELSIF velocity_ratio >= 0.5 THEN s_lead_vel := 40 + (velocity_ratio - 0.5) / 0.5 * 30;
      ELSE                              s_lead_vel := 10 + velocity_ratio / 0.5 * 30;
      END IF;
    END IF;

    -- Component 3: Cost Efficiency (20)
    IF v_total_leads = 0 THEN
      IF v_total_credits > 0 THEN s_cost_eff := 0; ELSE s_cost_eff := 50; END IF;
    ELSIF seg_level > 0 AND seg.median_cpl IS NOT NULL AND seg.median_cpl > 0
          AND v_listing_cpl IS NOT NULL AND v_listing_cpl > 0 THEN
      cpl_ratio := seg.median_cpl / v_listing_cpl;
      IF    cpl_ratio >= 2.0 THEN s_cost_eff := 100;
      ELSIF cpl_ratio >= 1.0 THEN s_cost_eff := 60 + (cpl_ratio - 1.0) / 1.0 * 40;
      ELSIF cpl_ratio >= 0.5 THEN s_cost_eff := 30 + (cpl_ratio - 0.5) / 0.5 * 30;
      ELSE                         s_cost_eff := cpl_ratio / 0.5 * 30;
      END IF;
    ELSE
      s_cost_eff := 50;
    END IF;

    -- Component 4: Tier ROI (10)
    IF r.current_tier IN ('none', 'standard') THEN
      s_tier_roi := 50;
    ELSE
      IF r.current_tier = 'featured' THEN expected_mult := 2.5; ELSE expected_mult := 1.8; END IF;
      SELECT AVG(lc2.lead_cnt)
      INTO actual_mult
      FROM pf_listings pl2
      LEFT JOIN LATERAL (
        SELECT COUNT(*) AS lead_cnt FROM pf_leads WHERE listing_reference = pl2.reference
      ) lc2 ON true
      WHERE pl2.is_live = true AND pl2.is_deleted = false
        AND pl2.location_id = r.location_id AND pl2.current_tier = 'standard'
        AND (seg_level >= 3 OR pl2.property_type = r.property_type);

      IF actual_mult IS NULL OR actual_mult = 0 THEN
        s_tier_roi := 50;
      ELSE
        tier_multiplier := COALESCE(v_total_leads, 0)::numeric / actual_mult;
        cpl_ratio := tier_multiplier / expected_mult;
        IF    cpl_ratio >= 1.0 THEN s_tier_roi := 60 + LEAST(40, (cpl_ratio - 1.0) * 40);
        ELSIF cpl_ratio >= 0.5 THEN s_tier_roi := 30 + (cpl_ratio - 0.5) / 0.5 * 30;
        ELSE                         s_tier_roi := cpl_ratio / 0.5 * 30;
        END IF;
      END IF;
    END IF;

    -- Component 5: PF Quality Score (10)
    s_quality := COALESCE(r.pf_quality_score, 50);

    -- Component 6: Price Position (10)
    IF r.price_on_request THEN
      s_price_pos := 40;
    ELSIF r.price_per_sqft IS NULL THEN
      s_price_pos := 50;
    ELSIF seg_level > 0 AND seg.avg_price_per_sqft IS NOT NULL THEN
      IF r.price_per_sqft BETWEEN seg.avg_price_per_sqft * 0.75 AND seg.avg_price_per_sqft * 1.25 THEN s_price_pos := 100;
      ELSIF r.price_per_sqft BETWEEN seg.avg_price_per_sqft * 0.5 AND seg.avg_price_per_sqft * 1.5  THEN s_price_pos := 60;
      ELSE s_price_pos := 30;
      END IF;
    ELSE
      s_price_pos := 50;
    END IF;

    -- Component 7: Listing Completeness (5)
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
    completeness_pts := completeness_pts + 20;
    s_completeness := LEAST(100, completeness_pts);

    -- Component 8: Freshness (5)
    IF COALESCE(r.days_live, 0) <= cfg.freshness_decay_start_days THEN
      s_freshness := 100;
    ELSIF r.days_live >= cfg.freshness_decay_end_days THEN
      s_freshness := 0;
    ELSE
      s_freshness := 100.0 * (cfg.freshness_decay_end_days - r.days_live)::numeric
        / (cfg.freshness_decay_end_days - cfg.freshness_decay_start_days);
    END IF;

    -- Component 9: Competitive Position (10)
    IF seg_level > 0 THEN
      SELECT (COUNT(*) FILTER (WHERE subq.per_listing_lead_total < COALESCE(v_total_leads, 0)))::numeric /
             NULLIF(COUNT(*), 0) * 100
      INTO peer_lead_pct
      FROM (
        SELECT lc3.per_listing_lead_total
        FROM pf_listings pl3
        LEFT JOIN LATERAL (
          SELECT COUNT(*)::integer AS per_listing_lead_total
          FROM pf_leads WHERE listing_reference = pl3.reference
        ) lc3 ON true
        WHERE pl3.is_live = true AND pl3.is_deleted = false
          AND pl3.location_id = r.location_id
          AND (seg_level < 3 OR pl3.property_type = r.property_type)
      ) subq;

      IF r.effective_price IS NOT NULL AND seg.median_price IS NOT NULL AND seg.median_price > 0 THEN
        peer_price_pct := GREATEST(0, 100 - ABS(r.effective_price - seg.median_price)::numeric / seg.median_price * 100);
      ELSE peer_price_pct := 50; END IF;

      IF r.pf_quality_score IS NOT NULL AND seg.avg_quality_score IS NOT NULL THEN
        peer_qual_pct := LEAST(100, r.pf_quality_score::numeric / NULLIF(seg.avg_quality_score, 0) * 50);
      ELSE peer_qual_pct := 50; END IF;

      s_competitive := (COALESCE(peer_lead_pct, 50) + COALESCE(peer_price_pct, 50) + COALESCE(peer_qual_pct, 50)) / 3;
    ELSE
      s_competitive := 50;
    END IF;

    -- Final Score
    raw_score := (
      s_lead_vol     * cfg.w_lead_volume +
      s_lead_vel     * cfg.w_lead_velocity +
      s_cost_eff     * cfg.w_cost_efficiency +
      s_tier_roi     * cfg.w_tier_roi +
      s_quality      * cfg.w_quality_score +
      s_price_pos    * cfg.w_price_position +
      s_completeness * cfg.w_listing_completeness +
      s_freshness    * cfg.w_freshness +
      s_competitive  * cfg.w_competitive_position
    ) / 100.0;

    penalty := 0;
    IF COALESCE(v_total_leads, 0) = 0 AND COALESCE(r.days_live, 0) >= cfg.zero_lead_days_threshold THEN
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
$function$;
