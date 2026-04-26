-- ============================================================
-- 1. FAST SCORING  — rewrite from O(n²) PL/pgSQL loop to a
--    single set-based INSERT using pre-aggregated CTEs and
--    PERCENT_RANK() window functions.
-- ============================================================

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

  -- One pass through pf_leads for all time windows
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

  -- One pass through pf_credit_transactions
  credit_agg AS (
    SELECT listing_reference, COALESCE(SUM(ABS(credit_amount)),0)::numeric AS total_credits
    FROM pf_credit_transactions GROUP BY listing_reference
  ),

  -- Base: all live listings with aggregated lead/credit data
  base AS (
    SELECT
      l.pf_listing_id, l.reference, l.category, l.property_type, l.bedrooms,
      l.location_id, l.current_tier, l.days_live, l.pf_quality_score,
      l.price_per_sqft, l.price_on_request, l.effective_price,
      l.image_count, l.has_video, l.amenities, l.floor_number,
      l.developer, l.has_parking, l.furnishing, l.built_up_area_sqft,
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

  -- Best segment per listing: level 4 > 3 > 2, skip if below min_segment_size
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

  -- Avg leads for standard-tier peers (Component 4: Tier ROI)
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

  -- Component 1: lead volume percentile using window functions (O(n log n), not O(n²))
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

  -- Component 9: competitive lead-volume percentile
  comp_vol_pct AS (
    SELECT
      pf_listing_id,
      (100 * PERCENT_RANK() OVER (PARTITION BY location_id,category,property_type ORDER BY v_total_leads))::numeric AS lead_pct_l3
    FROM base
  ),

  -- Compute all 9 component scores
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

      -- 9. Competitive Position
      ROUND(CASE
        WHEN s.segment_level IS NOT NULL THEN
          (COALESCE(cp.lead_pct_l3, 50) +
           CASE WHEN b.effective_price IS NOT NULL AND s.median_price IS NOT NULL AND s.median_price > 0
                THEN GREATEST(0, 100-ABS(b.effective_price-s.median_price)::numeric/s.median_price*100)
                ELSE 50 END +
           CASE WHEN b.pf_quality_score IS NOT NULL AND s.avg_quality_score IS NOT NULL
                THEN LEAST(100, b.pf_quality_score::numeric/NULLIF(s.avg_quality_score,0)*50)
                ELSE 50 END) / 3
        ELSE 50
      END, 1) AS s_competitive,

      -- Carry forward for final score
      b.v_total_leads, b.days_live,
      cfg.w_lead_volume, cfg.w_lead_velocity, cfg.w_cost_efficiency, cfg.w_tier_roi,
      cfg.w_quality_score, cfg.w_price_position, cfg.w_listing_completeness,
      cfg.w_freshness, cfg.w_competitive_position,
      cfg.zero_lead_days_threshold, cfg.zero_lead_penalty_pct

    FROM base b
    CROSS JOIN cfg
    LEFT JOIN listing_seg  s   ON s.pf_listing_id  = b.pf_listing_id
    LEFT JOIN lead_vol_pct lv  ON lv.pf_listing_id = b.pf_listing_id
    LEFT JOIN comp_vol_pct cp  ON cp.pf_listing_id = b.pf_listing_id
    LEFT JOIN std_leads_l3 sl3 ON sl3.location_id  = b.location_id AND sl3.category = b.category AND sl3.property_type = b.property_type
    LEFT JOIN std_leads_l2 sl2 ON sl2.location_id  = b.location_id AND sl2.category = b.category
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


-- ============================================================
-- 2. PORTFOLIO STATS  — fast aggregate + filter-option endpoint
-- ============================================================

DROP FUNCTION IF EXISTS get_portfolio_stats();
CREATE FUNCTION get_portfolio_stats()
RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
WITH
  lead_agg AS (
    SELECT listing_reference,
      COUNT(*) FILTER (WHERE lead_created_at >= now()-'30 days'::interval) AS leads_30d,
      COUNT(*) AS total_leads
    FROM pf_leads GROUP BY listing_reference
  ),
  credit_agg AS (
    SELECT listing_reference, SUM(ABS(credit_amount)) AS total_credits
    FROM pf_credit_transactions GROUP BY listing_reference
  ),
  listing_base AS (
    SELECT l.pf_listing_id, l.is_live, loc.destination, l.property_type, l.current_tier,
      COALESCE(la.leads_30d, 0)      AS leads_30d,
      COALESCE(la.total_leads, 0)    AS total_leads,
      COALESCE(ca.total_credits, 0)  AS total_credits,
      CASE WHEN COALESCE(la.total_leads,0) > 0
           THEN COALESCE(ca.total_credits,0) / la.total_leads END AS cpl
    FROM pf_listings l
    LEFT JOIN pf_locations loc ON loc.location_id = l.location_id
    LEFT JOIN lead_agg   la ON la.listing_reference = l.reference
    LEFT JOIN credit_agg ca ON ca.listing_reference = l.reference
    WHERE NOT l.is_deleted
  ),
  scores_today AS (
    SELECT pf_listing_id, score_band FROM listing_scores WHERE score_date = CURRENT_DATE
  ),
  locs AS (
    SELECT DISTINCT loc.name AS location_name, loc.destination
    FROM pf_listings l
    JOIN pf_locations loc ON loc.location_id = l.location_id
    WHERE NOT l.is_deleted AND loc.name IS NOT NULL
    ORDER BY loc.destination NULLS LAST, loc.name
  )
SELECT json_build_object(
  'total',      (SELECT COUNT(*)                                       FROM listing_base),
  'live',       (SELECT COUNT(*) FILTER (WHERE is_live)                FROM listing_base),
  'leads_30d',  (SELECT COALESCE(SUM(leads_30d),0)                    FROM listing_base WHERE is_live),
  'scored',     (SELECT COUNT(*)                                       FROM scores_today),
  'avg_cpl',    (SELECT ROUND(AVG(cpl)::numeric,0)
                 FROM listing_base WHERE cpl IS NOT NULL AND total_leads > 0),
  'band_dist',  (SELECT COALESCE(json_agg(
                    json_build_object('band', score_band, 'count', cnt) ORDER BY score_band
                  ), '[]'::json)
                 FROM (SELECT score_band, COUNT(*) AS cnt FROM scores_today
                       WHERE score_band IS NOT NULL GROUP BY score_band) x),
  'destinations',(SELECT COALESCE(json_agg(DISTINCT destination ORDER BY destination), '[]'::json)
                  FROM listing_base WHERE destination IS NOT NULL),
  'types',       (SELECT COALESCE(json_agg(DISTINCT property_type ORDER BY property_type), '[]'::json)
                  FROM listing_base WHERE property_type IS NOT NULL),
  'locations',   (SELECT COALESCE(json_agg(json_build_object(
                    'name', location_name, 'destination', destination)), '[]'::json)
                  FROM locs)
);
$$;


-- ============================================================
-- 3. PORTFOLIO PAGE  — server-side filter + sort + pagination
--    Starts from listing_scores index for fast sort, evaluates
--    expensive lead/credit laterals only for the page rows.
-- ============================================================

DROP FUNCTION IF EXISTS get_portfolio_page(text,text,text,text,text,text,text,boolean,integer,integer);
CREATE FUNCTION get_portfolio_page(
  p_search   text    DEFAULT NULL,
  p_dest     text    DEFAULT NULL,
  p_location text    DEFAULT NULL,
  p_tier     text    DEFAULT NULL,
  p_band     text    DEFAULT NULL,
  p_type     text    DEFAULT NULL,
  p_sort     text    DEFAULT 'total_score',
  p_asc      boolean DEFAULT false,
  p_limit    integer DEFAULT 300,
  p_offset   integer DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE v_result json;
BEGIN
  -- Dynamic SQL needed for column-name sort
  EXECUTE format($q$
    WITH
    total AS (
      SELECT COUNT(*)::integer AS n
      FROM listing_scores ls
      JOIN pf_listings l ON l.pf_listing_id = ls.pf_listing_id
      LEFT JOIN pf_locations loc ON loc.location_id = l.location_id
      WHERE ls.score_date = CURRENT_DATE AND NOT l.is_deleted
        AND ($1 IS NULL OR l.reference ILIKE '%%'||$1||'%%'
                        OR loc.name     ILIKE '%%'||$1||'%%'
                        OR loc.destination ILIKE '%%'||$1||'%%')
        AND ($2 IS NULL OR loc.destination  = $2)
        AND ($3 IS NULL OR loc.name         = $3)
        AND ($4 IS NULL OR l.current_tier   = $4)
        AND ($5 IS NULL OR ls.score_band    = $5)
        AND ($6 IS NULL OR l.property_type  = $6)
    ),
    page AS (
      SELECT
        l.pf_listing_id, l.reference, l.category, l.property_type, l.bedrooms, l.bathrooms,
        l.effective_price, l.price_per_sqft, l.price_type, l.price_on_request,
        l.current_tier, l.tier_expires_at,
        l.agent_name, l.agent_public_profile_id,
        l.pf_quality_score, l.pf_quality_color,
        l.is_live, l.published_at, l.days_live,
        l.image_count, l.has_video, l.furnishing, l.developer, l.project_status,
        l.location_id, loc.name AS location_name, loc.destination,
        ls.total_score, ls.score_band,
        ls.s_lead_volume, ls.s_lead_velocity, ls.s_cost_efficiency, ls.s_tier_roi,
        ls.s_quality_score, ls.s_price_position, ls.s_listing_completeness,
        ls.s_freshness, ls.s_competitive_position
      FROM listing_scores ls
      JOIN pf_listings l ON l.pf_listing_id = ls.pf_listing_id
      LEFT JOIN pf_locations loc ON loc.location_id = l.location_id
      WHERE ls.score_date = CURRENT_DATE AND NOT l.is_deleted
        AND ($1 IS NULL OR l.reference ILIKE '%%'||$1||'%%'
                        OR loc.name     ILIKE '%%'||$1||'%%'
                        OR loc.destination ILIKE '%%'||$1||'%%')
        AND ($2 IS NULL OR loc.destination  = $2)
        AND ($3 IS NULL OR loc.name         = $3)
        AND ($4 IS NULL OR l.current_tier   = $4)
        AND ($5 IS NULL OR ls.score_band    = $5)
        AND ($6 IS NULL OR l.property_type  = $6)
      ORDER BY %s %s NULLS LAST
      LIMIT $7 OFFSET $8
    ),
    with_leads AS (
      SELECT p.*,
        COALESCE(lc.total_leads, 0)  AS total_leads,
        COALESCE(lc.leads_7d,    0)  AS leads_7d,
        COALESCE(lc.leads_30d,   0)  AS leads_30d
      FROM page p
      LEFT JOIN LATERAL (
        SELECT COUNT(*)::integer                                                              AS total_leads,
               COUNT(*) FILTER (WHERE lead_created_at >= now()-'7 days'::interval)::integer  AS leads_7d,
               COUNT(*) FILTER (WHERE lead_created_at >= now()-'30 days'::interval)::integer AS leads_30d
        FROM pf_leads WHERE listing_reference = p.reference
      ) lc ON true
    ),
    with_credits AS (
      SELECT wl.*,
        COALESCE(cc.total_credits, 0) AS total_credits_spent,
        CASE WHEN COALESCE(wl.total_leads,0) > 0
             THEN ROUND(COALESCE(cc.total_credits,0) / wl.total_leads, 2) END AS cpl
      FROM with_leads wl
      LEFT JOIN LATERAL (
        SELECT COALESCE(SUM(ABS(credit_amount)),0)::numeric AS total_credits
        FROM pf_credit_transactions WHERE listing_reference = wl.reference
      ) cc ON true
    )
    SELECT json_build_object(
      'total', (SELECT n FROM total),
      'rows',  COALESCE((SELECT json_agg(t) FROM with_credits t), '[]'::json)
    )
  $q$,
    -- Sort column (whitelist to prevent injection)
    CASE p_sort
      WHEN 'effective_price'   THEN 'l.effective_price'
      WHEN 'leads_30d'         THEN 'ls.s_lead_volume'
      WHEN 'cpl'               THEN 'ls.s_cost_efficiency'
      WHEN 'days_live'         THEN 'l.days_live'
      WHEN 'pf_quality_score'  THEN 'l.pf_quality_score'
      WHEN 'score_band'        THEN 'ls.score_band'
      WHEN 'reference'         THEN 'l.reference'
      WHEN 'agent_name'        THEN 'l.agent_name'
      ELSE 'ls.total_score'
    END,
    CASE WHEN p_asc THEN 'ASC' ELSE 'DESC' END
  )
  INTO v_result
  USING p_search, p_dest, p_location, p_tier, p_band, p_type, p_limit, p_offset;

  RETURN v_result;
END;
$$;


-- ============================================================
-- 4. INDEXES for pagination performance
-- ============================================================

-- Composite index: today's scores sorted by total_score (default portfolio sort)
CREATE INDEX IF NOT EXISTS idx_scores_date_score
  ON listing_scores(score_date, total_score DESC NULLS LAST);

-- Cover score_band for band filter on listing_scores
CREATE INDEX IF NOT EXISTS idx_scores_date_band
  ON listing_scores(score_date, score_band);
