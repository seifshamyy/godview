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
