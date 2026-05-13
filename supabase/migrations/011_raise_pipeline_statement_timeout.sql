-- ============================================================
-- 011 — Raise statement_timeout for pipeline functions
-- ============================================================
-- The nightly pipeline runs via edge function -> service_role -> RPC.
-- The service_role default statement_timeout (8s on Supabase) cancels
-- the per-step functions even when their queries are well-optimized.
--
-- Solution: attach a 10-minute statement_timeout override directly to
-- the pipeline functions. The override applies for the duration of
-- each function call, regardless of caller, and reverts on exit.
-- ============================================================

ALTER FUNCTION fn_build_daily_snapshots()    SET statement_timeout = '10min';
ALTER FUNCTION fn_build_segment_benchmarks() SET statement_timeout = '10min';
ALTER FUNCTION fn_score_all_listings()       SET statement_timeout = '10min';
ALTER FUNCTION fn_build_aggregate_scores()   SET statement_timeout = '10min';
ALTER FUNCTION fn_generate_recommendations() SET statement_timeout = '10min';
