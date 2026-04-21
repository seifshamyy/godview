-- Add destination column to pf_locations
ALTER TABLE pf_locations ADD COLUMN IF NOT EXISTS destination text;

-- Expose destination through the portfolio view
CREATE OR REPLACE VIEW v_portfolio_overview AS
 SELECT l.pf_listing_id,
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
    loc.name        AS location_name,
    loc.destination AS destination,
    COALESCE(lead_counts.total_leads, 0::bigint) AS total_leads,
    COALESCE(lead_counts.leads_7d, 0::bigint) AS leads_7d,
    COALESCE(lead_counts.leads_30d, 0::bigint) AS leads_30d,
    COALESCE(credit_sums.total_credits, 0::numeric) AS total_credits_spent,
    CASE
        WHEN COALESCE(lead_counts.total_leads, 0::bigint) > 0
        THEN round(COALESCE(credit_sums.total_credits, 0::numeric) / lead_counts.total_leads::numeric, 2)
        ELSE NULL::numeric
    END AS cpl,
    ls.total_score,
    ls.score_band
   FROM pf_listings l
     LEFT JOIN pf_locations loc ON l.location_id = loc.location_id
     LEFT JOIN LATERAL (
       SELECT count(*) AS total_leads,
              count(*) FILTER (WHERE pf_leads.lead_created_at >= (now() - '7 days'::interval)) AS leads_7d,
              count(*) FILTER (WHERE pf_leads.lead_created_at >= (now() - '30 days'::interval)) AS leads_30d
         FROM pf_leads
        WHERE pf_leads.listing_reference = l.reference
     ) lead_counts ON true
     LEFT JOIN LATERAL (
       SELECT COALESCE(sum(abs(pf_credit_transactions.credit_amount)), 0::numeric) AS total_credits
         FROM pf_credit_transactions
        WHERE pf_credit_transactions.listing_reference = l.reference
     ) credit_sums ON true
     LEFT JOIN LATERAL (
       SELECT listing_scores.total_score, listing_scores.score_band
         FROM listing_scores
        WHERE listing_scores.pf_listing_id = l.pf_listing_id
        ORDER BY listing_scores.score_date DESC
        LIMIT 1
     ) ls ON true
  WHERE l.is_deleted = false;

-- RPC to bypass PostgREST 1000-row limit
CREATE OR REPLACE FUNCTION get_portfolio_overview()
RETURNS SETOF v_portfolio_overview
LANGUAGE sql SECURITY DEFINER STABLE
AS $$ SELECT * FROM v_portfolio_overview ORDER BY total_score DESC NULLS LAST; $$;
