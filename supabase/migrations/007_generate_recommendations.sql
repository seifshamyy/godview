-- Smart recommendation generator.
-- Runs against today's listing_scores + live listing data.
-- Produces exactly one recommendation per listing (highest-priority rule wins).
-- Returns count of recommendations inserted.

CREATE OR REPLACE FUNCTION fn_generate_recommendations()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_count integer;
BEGIN
  -- Regenerate: wipe today's pending recommendations fresh each run
  DELETE FROM recommendations
  WHERE recommendation_date = CURRENT_DATE AND status = 'PENDING';

  WITH

  -- ── Pre-aggregate leads (all windows at once, one pass) ─────────────────
  lead_agg AS (
    SELECT
      listing_reference,
      COUNT(*)::integer                                                              AS total_leads,
      COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '30 days')::integer AS leads_30d,
      COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '7 days')::integer  AS leads_7d,
      COUNT(*) FILTER (
        WHERE lead_created_at >= now() - interval '14 days'
          AND lead_created_at <  now() - interval '7 days'
      )::integer                                                                     AS leads_prior_7d
    FROM pf_leads
    GROUP BY listing_reference
  ),

  -- ── Pre-aggregate credit spend ───────────────────────────────────────────
  credit_agg AS (
    SELECT listing_reference, SUM(ABS(credit_amount))::numeric AS total_credits
    FROM pf_credit_transactions
    GROUP BY listing_reference
  ),

  -- ── Best-fit segment benchmark per listing (prefer level 4 → 3 → 2) ─────
  seg AS (
    SELECT DISTINCT ON (location_id, category, property_type, bedrooms)
      location_id, category, property_type, bedrooms,
      avg_leads, median_cpl, median_price, avg_price_per_sqft,
      listing_count AS seg_listing_count, segment_level
    FROM segment_benchmarks
    WHERE benchmark_date = CURRENT_DATE
    ORDER BY location_id, category, property_type, bedrooms, segment_level DESC
  ),

  -- ── Base: one row per scored live listing with all context ───────────────
  base AS (
    SELECT
      l.pf_listing_id,
      l.reference,
      l.current_tier,
      l.days_live,
      l.pf_quality_score,
      l.price_on_request,
      l.price_per_sqft,
      l.effective_price,
      l.image_count,
      l.has_video,
      l.category,
      l.property_type,
      l.bedrooms,
      l.location_id,
      -- Scores
      ls.total_score,
      ls.score_band,
      ls.s_lead_volume,
      ls.s_lead_velocity,
      ls.s_cost_efficiency,
      ls.s_tier_roi,
      ls.s_quality_score   AS sc_quality,
      ls.s_price_position,
      ls.s_listing_completeness,
      ls.s_freshness,
      ls.s_competitive_position,
      ls.zero_lead_penalty,
      ls.segment_level_used,
      -- Lead aggregates (zero-safe)
      COALESCE(la.total_leads,    0) AS total_leads,
      COALESCE(la.leads_30d,      0) AS leads_30d,
      COALESCE(la.leads_7d,       0) AS leads_7d,
      COALESCE(la.leads_prior_7d, 0) AS leads_prior_7d,
      -- Credit spend (zero-safe)
      COALESCE(ca.total_credits,  0) AS total_credits,
      -- Segment benchmarks
      sg.avg_leads         AS seg_avg_leads,
      sg.median_cpl        AS seg_median_cpl,
      sg.median_price      AS seg_median_price,
      sg.avg_price_per_sqft AS seg_avg_psf,
      sg.seg_listing_count
    FROM pf_listings l
    JOIN listing_scores ls
      ON ls.pf_listing_id = l.pf_listing_id AND ls.score_date = CURRENT_DATE
    LEFT JOIN lead_agg   la ON la.listing_reference = l.reference
    LEFT JOIN credit_agg ca ON ca.listing_reference = l.reference
    LEFT JOIN seg sg
      ON sg.location_id   = l.location_id
     AND sg.category      = l.category
     AND sg.property_type = l.property_type
     AND sg.bedrooms      = l.bedrooms
    WHERE l.is_live = true AND l.is_deleted = false
  ),

  -- ── Rule evaluation ──────────────────────────────────────────────────────
  -- Each rule gets a rule_rank (lower = higher priority).
  -- ROW_NUMBER() over pf_listing_id picks the best match per listing.
  rules AS (

    -- ── 1. REMOVE CRITICAL ───────────────────────────────────────────────
    -- Paid tier, 30+ days live, zero leads, credits already spent.
    -- Most expensive mistake — surface it first.
    SELECT
      pf_listing_id, 'REMOVE' AS action_type, 'CRITICAL' AS priority, 1 AS rule_rank,
      format(
        '%s listing is %s days old with 0 leads and %s credits spent — not converting at all. Remove or relist with a fresh approach.',
        initcap(current_tier), days_live, total_credits::integer
      ) AS reason_summary,
      jsonb_build_object(
        'trigger',       'zero_leads_paid_tier_30d',
        'tier',          current_tier,
        'days_live',     days_live,
        'total_leads',   0,
        'total_credits', total_credits,
        'total_score',   total_score,
        'score_band',    score_band
      ) AS reason_details
    FROM base
    WHERE current_tier IN ('featured','premium')
      AND total_leads = 0
      AND days_live   >= 30
      AND total_credits > 0

    UNION ALL

    -- ── 2. DOWNGRADE CRITICAL ────────────────────────────────────────────
    -- Paid tier, zero leads after ≥14 days, tier ROI score catastrophic.
    -- Credits burning, zero return — act now.
    SELECT
      pf_listing_id, 'DOWNGRADE', 'CRITICAL', 2,
      format(
        '%s tier has generated 0 leads in %s days (tier ROI score: %s/100). Credits are being spent with no return. Downgrade to stop the bleed.',
        initcap(current_tier), days_live, s_tier_roi::integer
      ),
      jsonb_build_object(
        'trigger',        'tier_roi_critical_zero_leads',
        'tier',           current_tier,
        's_tier_roi',     s_tier_roi,
        's_lead_volume',  s_lead_volume,
        'total_leads',    0,
        'total_credits',  total_credits,
        'days_live',      days_live,
        'score_band',     score_band,
        'seg_avg_leads',  seg_avg_leads
      )
    FROM base
    WHERE current_tier IN ('featured','premium')
      AND total_leads   = 0
      AND s_tier_roi    < 25
      AND days_live     >= 14
      AND score_band    IN ('C','D','F')

    UNION ALL

    -- ── 3. DOWNGRADE HIGH ────────────────────────────────────────────────
    -- Paid tier, poor tier ROI after 3 weeks, getting far fewer leads than peers.
    SELECT
      pf_listing_id, 'DOWNGRADE', 'HIGH', 3,
      format(
        '%s tier is underperforming — tier ROI score %s/100 after %s days. Getting %s%% fewer leads than standard-tier peers in this segment. Downgrade to recoup spend.',
        initcap(current_tier), s_tier_roi::integer, days_live,
        GREATEST(0, ROUND(100 - s_lead_volume))::integer
      ),
      jsonb_build_object(
        'trigger',       'tier_roi_high',
        'tier',          current_tier,
        's_tier_roi',    s_tier_roi,
        's_lead_volume', s_lead_volume,
        'total_leads',   total_leads,
        'leads_30d',     leads_30d,
        'total_credits', total_credits,
        'days_live',     days_live,
        'score_band',    score_band,
        'seg_avg_leads', seg_avg_leads
      )
    FROM base
    WHERE current_tier IN ('featured','premium')
      AND s_tier_roi  < 30
      AND days_live   >= 21
      AND score_band  IN ('D','F')
      AND total_leads < 2

    UNION ALL

    -- ── 4. REPRICE HIGH ──────────────────────────────────────────────────
    -- Price significantly above segment median, lead volume well below peers.
    -- Price is the single biggest controllable lever.
    SELECT
      pf_listing_id, 'REPRICE', 'HIGH', 4,
      format(
        'Price (%s AED) is %s%% above segment median (%s AED). Lead volume score: %s/100 — peers are outperforming by a wide margin. Repricing closer to market could unlock demand.',
        effective_price::integer,
        ROUND((effective_price - seg_median_price) / NULLIF(seg_median_price,0) * 100)::integer,
        seg_median_price::integer,
        s_lead_volume::integer
      ),
      jsonb_build_object(
        'trigger',           'overpriced_vs_segment',
        'effective_price',   effective_price,
        'seg_median_price',  seg_median_price,
        'pct_above_median',  ROUND((effective_price - seg_median_price) / NULLIF(seg_median_price,0) * 100),
        's_price_position',  s_price_position,
        's_lead_volume',     s_lead_volume,
        'total_leads',       total_leads,
        'seg_avg_leads',     seg_avg_leads,
        'days_live',         days_live
      )
    FROM base
    WHERE s_price_position  < 35
      AND price_on_request  = false
      AND effective_price   IS NOT NULL
      AND seg_median_price  IS NOT NULL
      AND effective_price   > seg_median_price * 1.3
      AND s_lead_volume     < 50
      AND days_live         >= 14

    UNION ALL

    -- ── 5. UPGRADE HIGH ──────────────────────────────────────────────────
    -- Standard/none tier, top-quartile lead performer in segment.
    -- These are the listings most likely to see ROI from a boost.
    SELECT
      pf_listing_id, 'UPGRADE', 'HIGH', 5,
      format(
        'Top performer in its segment — lead volume score %s/100 (%s %s in 30 days vs segment avg %s). Upgrading to Featured could significantly amplify reach.',
        s_lead_volume::integer,
        leads_30d,
        CASE WHEN leads_30d = 1 THEN 'lead' ELSE 'leads' END,
        COALESCE(ROUND(seg_avg_leads)::text, 'n/a')
      ),
      jsonb_build_object(
        'trigger',               'top_performer_upgrade',
        's_lead_volume',         s_lead_volume,
        's_competitive_position',s_competitive_position,
        'leads_30d',             leads_30d,
        'total_leads',           total_leads,
        'score_band',            score_band,
        'total_score',           total_score,
        'seg_avg_leads',         seg_avg_leads,
        'days_live',             days_live,
        'current_tier',          current_tier
      )
    FROM base
    WHERE current_tier IN ('standard','none')
      AND s_lead_volume  > 75
      AND score_band     IN ('A','B')
      AND days_live      >= 14

    UNION ALL

    -- ── 6. REPRICE MEDIUM (price on request) ────────────────────────────
    -- Price-on-request listings with zero leads — hiding the price is killing enquiries.
    SELECT
      pf_listing_id, 'REPRICE', 'MEDIUM', 6,
      format(
        'Price on request listing has received 0 leads in %s days. POR listings typically generate 60–70%% fewer enquiries than priced equivalents. Consider displaying the price.',
        days_live
      ),
      jsonb_build_object(
        'trigger',         'price_on_request_no_leads',
        'price_on_request', true,
        'total_leads',     0,
        'days_live',       days_live,
        's_lead_volume',   s_lead_volume,
        'score_band',      score_band
      )
    FROM base
    WHERE price_on_request = true
      AND total_leads      = 0
      AND days_live        >= 14

    UNION ALL

    -- ── 7. UPGRADE MEDIUM ────────────────────────────────────────────────
    -- Good performers on standard who aren't top-quartile yet — still worth surfacing.
    SELECT
      pf_listing_id, 'UPGRADE', 'MEDIUM', 7,
      format(
        'Above-average performer — %s %s in 30 days (segment avg: %s), lead volume score %s/100. Featured or Premium placement could push this into the top tier.',
        leads_30d,
        CASE WHEN leads_30d = 1 THEN 'lead' ELSE 'leads' END,
        COALESCE(ROUND(seg_avg_leads)::text, 'n/a'),
        s_lead_volume::integer
      ),
      jsonb_build_object(
        'trigger',       'good_performer_upgrade',
        's_lead_volume', s_lead_volume,
        'leads_30d',     leads_30d,
        'score_band',    score_band,
        'total_score',   total_score,
        'seg_avg_leads', seg_avg_leads,
        'days_live',     days_live,
        'current_tier',  current_tier
      )
    FROM base
    WHERE current_tier  IN ('standard','none')
      AND s_lead_volume  > 55
      AND score_band     = 'B'
      AND days_live      >= 14
      AND leads_30d       > 0

    UNION ALL

    -- ── 8. BOOST MEDIUM ──────────────────────────────────────────────────
    -- Strong competitive position but leads decelerating — a nudge could re-ignite.
    SELECT
      pf_listing_id, 'BOOST', 'MEDIUM', 8,
      format(
        'Lead velocity declining — %s leads last 7 days vs %s the prior week (velocity score: %s/100). Competitive position is strong (%s/100). A targeted boost could reverse the dip.',
        leads_7d, leads_prior_7d,
        s_lead_velocity::integer,
        s_competitive_position::integer
      ),
      jsonb_build_object(
        'trigger',                'lead_velocity_decline',
        's_competitive_position', s_competitive_position,
        's_lead_velocity',        s_lead_velocity,
        'leads_7d',               leads_7d,
        'leads_prior_7d',         leads_prior_7d,
        'total_leads',            total_leads,
        'days_live',              days_live,
        'score_band',             score_band
      )
    FROM base
    WHERE s_competitive_position > 60
      AND leads_prior_7d          > 0
      AND leads_7d                < leads_prior_7d
      AND s_lead_velocity         < 40
      AND days_live               > 21
      AND current_tier            = 'standard'

    UNION ALL

    -- ── 9. WATCHLIST MEDIUM ──────────────────────────────────────────────
    -- Chronic underperformer on standard tier — not paying for a tier but still dead weight.
    -- Flag for review before they age further.
    SELECT
      pf_listing_id, 'WATCHLIST', 'MEDIUM', 9,
      format(
        'Band %s after %s days live — only %s total leads in this segment. Persistently underperforming. Review pricing, quality, or consider relisting with a fresh strategy.',
        score_band, days_live, total_leads
      ),
      jsonb_build_object(
        'trigger',       'persistent_underperformer',
        'score_band',    score_band,
        'total_score',   total_score,
        's_lead_volume', s_lead_volume,
        's_price_position', s_price_position,
        'total_leads',   total_leads,
        'days_live',     days_live,
        'seg_avg_leads', seg_avg_leads
      )
    FROM base
    WHERE score_band  IN ('D','F')
      AND current_tier = 'standard'
      AND days_live    >= 45
      AND total_leads  < 3

    UNION ALL

    -- ── 10. IMPROVE_QUALITY LOW ──────────────────────────────────────────
    -- Low completeness dragging the score — easiest self-serve fix the agent can do.
    SELECT
      pf_listing_id, 'IMPROVE_QUALITY', 'LOW', 10,
      format(
        'Listing completeness score: %s/100. %s Adding it could improve the overall score by up to 20 points and increase search visibility.',
        s_listing_completeness::integer,
        CASE
          WHEN (has_video IS NOT TRUE) AND COALESCE(image_count,0) < 10
            THEN 'Missing a video (+15 pts) and fewer than 10 photos (+10 pts).'
          WHEN has_video IS NOT TRUE
            THEN 'Missing a video — adding one adds 15 completeness points.'
          ELSE
            'Missing details: floor number, amenities list, or parking info.'
        END
      ),
      jsonb_build_object(
        'trigger',               'low_completeness',
        's_listing_completeness', s_listing_completeness,
        'has_video',             has_video,
        'image_count',           image_count,
        'score_band',            score_band,
        'total_score',           total_score,
        's_lead_volume',         s_lead_volume
      )
    FROM base
    WHERE s_listing_completeness < 55
      AND score_band IN ('C','D','F')
      AND (has_video IS NOT TRUE OR COALESCE(image_count,0) < 10)
      AND days_live >= 7

  ),

  -- ── Dedup: one rec per listing, pick the highest-priority rule ───────────
  ranked AS (
    SELECT *,
      ROW_NUMBER() OVER (PARTITION BY pf_listing_id ORDER BY rule_rank) AS rn
    FROM rules
  )

  INSERT INTO recommendations
    (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details, status)
  SELECT
    pf_listing_id, CURRENT_DATE, action_type, priority, reason_summary, reason_details, 'PENDING'
  FROM ranked
  WHERE rn = 1;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
