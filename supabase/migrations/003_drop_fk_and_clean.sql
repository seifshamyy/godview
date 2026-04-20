-- Drop FK constraints that cause silent upsert failures
ALTER TABLE pf_leads DROP CONSTRAINT IF EXISTS pf_leads_listing_reference_fkey;
ALTER TABLE pf_credit_transactions DROP CONSTRAINT IF EXISTS pf_credit_transactions_listing_reference_fkey;

-- Clean slate
TRUNCATE TABLE recommendations, listing_scores, aggregate_scores, segment_benchmarks,
  listing_daily_snapshots, pf_agent_stats, pf_agents, pf_credit_snapshots,
  pf_credit_transactions, pf_leads, pf_listings, sync_log RESTART IDENTITY CASCADE;
