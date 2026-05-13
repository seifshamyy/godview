-- ============================================================
-- 010 — Fix fn_build_daily_snapshots timeout at scale
-- ============================================================
-- The original (in 002) ran two LATERAL subqueries per listing,
-- which is O(N × index_lookups). At ~24k listings it exceeds the
-- statement_timeout. This rewrite pre-aggregates pf_leads and
-- pf_credit_transactions once each, then joins — same pattern as
-- fn_score_all_listings in migration 008.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_build_daily_snapshots()
RETURNS void AS $$
BEGIN
  INSERT INTO listing_daily_snapshots (
    pf_listing_id, snapshot_date, total_leads, new_leads_today,
    pf_quality_score, current_tier, effective_price, is_live, days_live,
    total_credits_spent, cpl
  )
  WITH lead_agg AS (
    SELECT
      listing_reference,
      COUNT(*)::integer AS total_leads,
      COUNT(*) FILTER (WHERE lead_created_at::date = CURRENT_DATE)::integer AS new_today
    FROM pf_leads
    WHERE listing_reference IS NOT NULL
    GROUP BY listing_reference
  ),
  credit_agg AS (
    SELECT
      listing_reference,
      COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
    FROM pf_credit_transactions
    WHERE listing_reference IS NOT NULL
    GROUP BY listing_reference
  )
  SELECT
    l.pf_listing_id,
    CURRENT_DATE,
    COALESCE(la.total_leads, 0),
    COALESCE(la.new_today, 0),
    l.pf_quality_score,
    l.current_tier,
    l.effective_price,
    l.is_live,
    l.days_live,
    COALESCE(ca.total_credits, 0),
    CASE WHEN COALESCE(la.total_leads, 0) > 0
      THEN ROUND(COALESCE(ca.total_credits, 0) / la.total_leads, 2)
      ELSE NULL
    END
  FROM pf_listings l
  LEFT JOIN lead_agg   la ON la.listing_reference = l.reference
  LEFT JOIN credit_agg ca ON ca.listing_reference = l.reference
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
