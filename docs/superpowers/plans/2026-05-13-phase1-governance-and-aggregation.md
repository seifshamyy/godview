# Phase 1 — Governance, Versioning & Cost-Weighted Aggregation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the PRD's credibility gaps that don't depend on CRM or Finance data — score versioning, weight-change audit, cost-weighted aggregation, developer/project peer groups, recommendation approval workflow, and in-app score transparency.

**Architecture:** Phase 1 is delivered as a single new SQL migration (`009_phase1_governance.sql`) plus a small sync-mapper change and two frontend additions. The migration adds (a) a `scoring_config_history` table + immutability trigger, (b) `project_id`/`project_name` columns on `pf_listings`, (c) a rewritten `fn_build_aggregate_scores` with cost-weighted math and developer/project dimensions, (d) extended `fn_score_all_listings` Competitive Position with developer/project peer partitions, (e) approval-state columns + `fn_review_recommendation` RPC. The frontend adds a transparency panel in `ListingDetail.tsx` and approve/reject controls in `Recommendations.tsx`.

**Tech Stack:** PostgreSQL (Supabase), PL/pgSQL, Supabase Edge Functions (Deno/TypeScript), React + TypeScript + Tailwind (Vite). Migrations are applied via the **Supabase CLI** (`supabase db push`) — the CLI is already installed and linked to the correct project. Verification is done by running SQL assertion queries against the live database via `supabase db query` or the Supabase SQL editor. There is no JS test runner in the repo today — do **not** add one for Phase 1; use SQL assertions as the "tests".

**Conventions for this plan:**
- Every migration is additive. No destructive changes to `001_schema.sql` or `002_scoring_functions.sql`.
- The Supabase CLI is installed and linked to the correct project. Apply the new migration with `supabase db push` after each task that modifies `009_phase1_governance.sql`.
- The existing migrations (`001`–`008`) were originally applied via [scripts/run-schema.js](../../../scripts/run-schema.js), not the CLI. **One-time setup**: before the first `supabase db push`, mark them as already applied so the CLI doesn't try to re-run them. Run once:

  ```bash
  for f in supabase/migrations/00{1,2,3,4,5,6,7,8}_*.sql; do
    v=$(basename "$f" .sql)
    supabase migration repair --status applied "$v"
  done
  supabase migration list   # confirm 001–008 show as Applied, 009 as Local-only
  ```

  If that errors with "version must be a timestamp", rename the existing files to timestamp-prefixed names (`20240101000001_schema.sql` etc.) **or** skip `db push` for this plan and use the direct-execute fallback below.

- **Direct-execute fallback** (use if migration repair is awkward): run the new SQL file straight through `psql` using the CLI's connection string:

  ```bash
  psql "$(supabase status -o json | jq -r '.DB_URL')" -f supabase/migrations/009_phase1_governance.sql
  ```

  Either path is acceptable — pick one and use it consistently for every "apply the migration" step.

- "Run test" steps are SQL queries whose expected output is shown. Run them via `supabase db query "<sql>"` or in the Supabase SQL editor. If output differs, the implementation is wrong.
- Commit after each task completes and its assertion passes.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `supabase/migrations/009_phase1_governance.sql` | Create | All Phase 1 schema + function changes in one migration |
| `supabase/functions/sync-listings/index.ts` | Modify | Add `project_id` / `project_name` to `mapListing()` |
| `dashboard/src/lib/types.ts` | Modify | Extend `Recommendation` and `ListingScore` types |
| `dashboard/src/pages/ListingDetail.tsx` | Modify | Add "Score Breakdown" transparency panel |
| `dashboard/src/pages/Recommendations.tsx` | Modify | Add Approve / Reject / Execute action buttons |
| `docs/superpowers/plans/2026-05-13-phase1-governance-and-aggregation.md` | (this file) | Plan |

The migration is intentionally a single file. Splitting it across multiple migrations would force ordering constraints across functions that depend on the same column additions. Reviewers should read it in sections — each task below corresponds to one section of the SQL file separated by a banner comment.

---

## Task 1: Scoring Config History & Immutability

**Why:** PRD §3 invariant 5 ("Configuration changes must be logged and versioned") and §8B ("All adjustments must be logged… scoring_version must increment on change… Historical scores must retain their original version"). Today, `scoring_config` rows can be silently `UPDATE`d, which retroactively changes how every historical score was computed.

**Files:**
- Create: `supabase/migrations/009_phase1_governance.sql` (this task creates the file; subsequent tasks append to it)

- [ ] **Step 1.1: Create the migration file with the history table**

Create `supabase/migrations/009_phase1_governance.sql` containing exactly:

```sql
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
```

- [ ] **Step 1.2: Add the audit trigger to the same migration**

Append to `supabase/migrations/009_phase1_governance.sql`:

```sql
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
```

- [ ] **Step 1.3: Add the immutability-enforcement RPC**

Append to `supabase/migrations/009_phase1_governance.sql`:

```sql
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
```

Note: we intentionally do **not** add a BEFORE-UPDATE trigger that blocks updates on `scoring_config`. Blocking direct updates would break the `is_active = false` toggle in this RPC. The convention is documented: editors use the RPC; the audit table records every change either way.

- [ ] **Step 1.4: Run the migration**

```bash
supabase db push
# (or, if not using migration-repair) :
# psql "$(supabase status -o json | jq -r '.DB_URL')" -f supabase/migrations/009_phase1_governance.sql
```

Expected output: `Applying migration 009_phase1_governance.sql...` followed by `Finished supabase db push.` (or, for the psql fallback, a series of `CREATE FUNCTION` / `CREATE TABLE` notices with no `ERROR` lines).

- [ ] **Step 1.5: Verify with an assertion query**

Run this SQL via Supabase SQL editor or the same `runSQL` path:

```sql
-- Verify: publishing a new config creates audit rows and a new version
SELECT fn_publish_scoring_config(
  20, 10, 20, 10, 10, 10, 5, 5, 10,
  14, 25, 3, 30, 180,
  'test-user', 'Phase 1 verification — same weights, new version'
);

SELECT
  (SELECT COUNT(*) FROM scoring_config WHERE is_active = true) AS active_count,
  (SELECT MAX(version) FROM scoring_config)                    AS max_version,
  (SELECT COUNT(*) FROM scoring_config_history)                AS history_rows;
```

Expected: `active_count = 1`, `max_version >= 2`, `history_rows >= 1`.

- [ ] **Step 1.6: Commit**

```bash
git add supabase/migrations/009_phase1_governance.sql
git commit -m "feat(governance): scoring_config audit log + immutable publish RPC"
```

---

## Task 2: Capture project_id and project_name from PF Atlas

**Why:** PRD §9 requires project-level aggregation. The current `pf_listings` schema captures `developer` but no project identifier. PF Atlas listings expose `project` data in their JSON payload (`project.id`, `project.name` or similar — engineer must confirm by inspecting one raw payload). Without this column, project-level rollups are impossible.

**Files:**
- Modify: `supabase/migrations/009_phase1_governance.sql` (append section)
- Modify: `supabase/functions/sync-listings/index.ts:mapListing()`

- [ ] **Step 2.1: Inspect one raw PF listing payload**

Run in Supabase SQL editor:

```sql
SELECT raw_payload->'project' AS project_obj,
       raw_payload->'projectId' AS project_id_flat
FROM pf_listings
WHERE raw_payload IS NOT NULL
LIMIT 5;
```

Record the actual shape. The remaining steps assume `raw_payload->'project'->>'id'` and `raw_payload->'project'->>'name'`. If the shape is different (for example `projectId` at top level, or a different nested key), substitute the correct path in steps 2.3 and 2.4 — the rest of the plan does not depend on which exact JSON path is used, only that two new columns are populated.

- [ ] **Step 2.2: Add project columns to pf_listings**

Append to `supabase/migrations/009_phase1_governance.sql`:

```sql
-- ------------------------------------------------------------
-- 4. Capture project_id / project_name on pf_listings
-- ------------------------------------------------------------
ALTER TABLE pf_listings
  ADD COLUMN IF NOT EXISTS project_id   text,
  ADD COLUMN IF NOT EXISTS project_name text;

CREATE INDEX IF NOT EXISTS idx_listings_project ON pf_listings(project_id);

-- Backfill from existing raw_payload (best-effort; null where not present)
UPDATE pf_listings
SET project_id   = COALESCE(project_id,   raw_payload->'project'->>'id'),
    project_name = COALESCE(project_name, raw_payload->'project'->>'name')
WHERE project_id IS NULL OR project_name IS NULL;
```

- [ ] **Step 2.3: Run the migration**

```bash
supabase db push
# (or, if not using migration-repair) :
# psql "$(supabase status -o json | jq -r '.DB_URL')" -f supabase/migrations/009_phase1_governance.sql
```

Expected: `Finished supabase db push.` with no `ERROR` lines (or, for the psql fallback, only `ALTER TABLE` / `CREATE FUNCTION` / `NOTICE` lines).

- [ ] **Step 2.4: Update mapListing() to write project fields**

Find the `mapListing` function in `supabase/functions/sync-listings/index.ts`. It already maps fields like `agent_public_profile_id` and `developer`. Add two new properties to the returned object (alongside `developer`):

```typescript
  developer: raw.developer ?? null,
  project_id: raw.project?.id ?? null,
  project_name: raw.project?.name ?? null,
```

(If step 2.1 revealed a different JSON shape, mirror that path here. The mapper must read from `raw`, not from `raw_payload` — `raw_payload` is the persisted copy of `raw`.)

- [ ] **Step 2.5: Run a single sync to verify population**

Trigger the sync from a terminal:

```bash
curl -X POST "$SUPABASE_URL/functions/v1/sync-listings" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
```

Wait for the run to complete (visible in `sync_log`). Then assert:

```sql
SELECT COUNT(*) FILTER (WHERE project_id IS NOT NULL)   AS with_project_id,
       COUNT(*) FILTER (WHERE project_name IS NOT NULL) AS with_project_name,
       COUNT(*) AS total
FROM pf_listings
WHERE is_live = true;
```

Expected: `with_project_id` and `with_project_name` should be **> 0**. If they are both 0, the JSON path in `mapListing()` is wrong — go back to Step 2.1 and re-inspect.

- [ ] **Step 2.6: Commit**

```bash
git add supabase/migrations/009_phase1_governance.sql supabase/functions/sync-listings/index.ts
git commit -m "feat(sync): capture project_id and project_name from PF Atlas"
```

---

## Task 3: Cost-Weighted Aggregation

**Why:** PRD §9 ("Capital exposure must influence aggregate performance. Equal-weight averaging is not permitted."). Today, [fn_build_aggregate_scores in supabase/migrations/002_scoring_functions.sql:579](../../../supabase/migrations/002_scoring_functions.sql#L579) computes `AVG(ls.total_score)`. A 200,000 AED-cost premium listing scoring 50 is weighted identically to a free standard listing scoring 50, which is exactly what the PRD forbids.

Cost-weighted formula: `weighted_avg = SUM(score × total_credits) / SUM(total_credits)`. If a group has zero total credits (e.g. all standard tier and never boosted), fall back to a simple average so the column never becomes NULL.

**Files:**
- Modify: `supabase/migrations/009_phase1_governance.sql` (append section)

- [ ] **Step 3.1: Add cost_weighted_score column to aggregate_scores**

Append to `supabase/migrations/009_phase1_governance.sql`:

```sql
-- ------------------------------------------------------------
-- 5. aggregate_scores: cost-weighted score column
-- ------------------------------------------------------------
ALTER TABLE aggregate_scores
  ADD COLUMN IF NOT EXISTS cost_weighted_score numeric;
```

We keep `avg_score` so the UI doesn't break and so the two can be compared during the rollout. The frontend will switch to `cost_weighted_score` in Task 7.

- [ ] **Step 3.2: Rewrite fn_build_aggregate_scores**

Append to `supabase/migrations/009_phase1_governance.sql`. This redefines the function to (a) compute `cost_weighted_score` for every dimension, (b) add `developer` and `project` dimensions, and (c) preserve the existing `agent`, `location`, `property_type`, `tier` dimensions. Functions in PG are replaced wholesale by `CREATE OR REPLACE FUNCTION`; this safely overrides the original from 002:

```sql
-- ------------------------------------------------------------
-- 6. fn_build_aggregate_scores — cost-weighted + new dimensions
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_build_aggregate_scores()
RETURNS void AS $$
BEGIN
  DELETE FROM aggregate_scores WHERE score_date = CURRENT_DATE;

  -- Per-listing materialization (compute once, reuse across all dimensions)
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

  -- Generic insert per dimension via a single dynamic block
  PERFORM _agg_insert_dimension('agent',         'agent_name');
  PERFORM _agg_insert_dimension('location',      'location_name');
  PERFORM _agg_insert_dimension('property_type', 'property_type');
  PERFORM _agg_insert_dimension('tier',          'current_tier');
  PERFORM _agg_insert_dimension('developer',     'developer');
  PERFORM _agg_insert_dimension('project',       'project_name');
END;
$$ LANGUAGE plpgsql;

-- Helper to keep the six dimension inserts DRY.
-- Uses dynamic SQL because the GROUP BY column varies.
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
```

The original `fn_build_aggregate_scores` in 002 had four hard-coded copies of nearly-identical SQL (one per dimension). This rewrite consolidates them into a single dynamic helper. `_agg_base` is a `TEMP TABLE ON COMMIT DROP` so it materializes only for the duration of one pipeline run.

- [ ] **Step 3.3: Run the migration**

```bash
supabase db push
# (or, if not using migration-repair) :
# psql "$(supabase status -o json | jq -r '.DB_URL')" -f supabase/migrations/009_phase1_governance.sql
```

Expected: `Finished supabase db push.` with no `ERROR` lines (or, for the psql fallback, only `ALTER TABLE` / `CREATE FUNCTION` / `NOTICE` lines).

- [ ] **Step 3.4: Run the pipeline and verify**

Trigger the nightly pipeline manually:

```bash
curl -X POST "$SUPABASE_URL/functions/v1/run-scoring-pipeline" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
```

Then assert:

```sql
SELECT dimension_type, COUNT(*) AS rows
FROM aggregate_scores
WHERE score_date = CURRENT_DATE
GROUP BY dimension_type
ORDER BY dimension_type;
```

Expected: six rows, one per dimension — `agent`, `developer`, `location`, `project`, `property_type`, `tier`. Every dimension should have `rows > 0`.

Then verify cost-weighting is actually different from the unweighted mean for at least one group:

```sql
SELECT dimension_type, dimension_value, avg_score, cost_weighted_score,
       ROUND(cost_weighted_score - avg_score, 2) AS delta
FROM aggregate_scores
WHERE score_date = CURRENT_DATE
  AND total_credits > 0
ORDER BY ABS(cost_weighted_score - avg_score) DESC NULLS LAST
LIMIT 10;
```

Expected: at least a few rows where `delta` is non-zero. If every row shows `delta = 0`, either every group has zero credits (unlikely with 15k listings) or the formula was not applied — re-check the `CASE` expression in `_agg_insert_dimension`.

- [ ] **Step 3.5: Commit**

```bash
git add supabase/migrations/009_phase1_governance.sql
git commit -m "feat(scoring): cost-weighted aggregation + developer & project dimensions"
```

---

## Task 4: Developer & Project Peer Partitions in Competitive Position

**Why:** PRD §8A Relative Context Layer requires peer comparison against "same project, same area, same developer". The current scoring engine only uses `location + category + property_type` for Competitive Position. We add two additional `PERCENT_RANK()` window functions partitioned by `developer` and `project_id`, then average all three lead-percentile signals into the existing Competitive Position score.

**Files:**
- Modify: `supabase/migrations/009_phase1_governance.sql` (append section that redefines `fn_score_all_listings`)

This task overrides the fast-scoring function from [supabase/migrations/008_fast_scoring_and_portfolio_pagination.sql:7](../../../supabase/migrations/008_fast_scoring_and_portfolio_pagination.sql#L7). Because 008's version is large (~300 lines), we will not paste it in full here — the engineer should **copy the entire `CREATE OR REPLACE FUNCTION fn_score_all_listings() RETURNS void AS $$ DECLARE … BEGIN … END; $$ LANGUAGE plpgsql;` block from 008** into the new migration and apply the surgical edits described below. This keeps Task 4 reviewable as a diff.

- [ ] **Step 4.1: Copy fn_score_all_listings from 008 into 009**

Open [supabase/migrations/008_fast_scoring_and_portfolio_pagination.sql](../../../supabase/migrations/008_fast_scoring_and_portfolio_pagination.sql) and copy the `CREATE OR REPLACE FUNCTION fn_score_all_listings()` block (it runs roughly lines 7–300 in that file — copy the entire function from `CREATE OR REPLACE FUNCTION` to its closing `$$ LANGUAGE plpgsql;`). Paste it at the end of `supabase/migrations/009_phase1_governance.sql` under a banner:

```sql
-- ------------------------------------------------------------
-- 7. fn_score_all_listings — extend Competitive Position with
--    developer + project peer partitions (PRD §8A relative ctx)
-- ------------------------------------------------------------
-- (paste the entire fn_score_all_listings body from migration 008 here,
--  then apply the edits below)
```

- [ ] **Step 4.2: Extend the `base` CTE to expose developer and project_id**

Inside the pasted function, locate the `base` CTE (it joins `pf_listings` to `lead_agg` and `credit_agg`). Add `l.developer` and `l.project_id` to its SELECT list. Concretely, find the line that selects `l.pf_listing_id, l.reference, l.location_id, l.category, l.property_type, l.bedrooms, ...` and add the two columns:

```sql
      l.developer,
      l.project_id,
```

If the `base` CTE already selects `l.*`, no change is needed here — skip to 4.3.

- [ ] **Step 4.3: Add developer_pct and project_pct CTEs**

Immediately after the existing `comp_vol_pct` CTE (which computes lead percentile partitioned by location + category + property_type), insert two new CTEs:

```sql
    , dev_lead_pct AS (
      SELECT pf_listing_id,
             CASE
               WHEN COUNT(*) OVER (PARTITION BY developer) >= 3
                 THEN PERCENT_RANK() OVER (PARTITION BY developer ORDER BY v_total_leads) * 100
               ELSE NULL
             END AS dev_pct
      FROM base
      WHERE developer IS NOT NULL
    )
    , proj_lead_pct AS (
      SELECT pf_listing_id,
             CASE
               WHEN COUNT(*) OVER (PARTITION BY project_id) >= 3
                 THEN PERCENT_RANK() OVER (PARTITION BY project_id ORDER BY v_total_leads) * 100
               ELSE NULL
             END AS proj_pct
      FROM base
      WHERE project_id IS NOT NULL
    )
```

The peer-group-size floor of 3 mirrors `scoring_config.min_segment_size` (default 3) and matches PRD §8A: "If peer group size is insufficient, fallback logic must exclude that group."

- [ ] **Step 4.4: Plumb the new percentiles through to the `scored` CTE**

Find the existing JOIN to `comp_vol_pct` in the `scored` CTE and add two more LEFT JOINs alongside it:

```sql
    LEFT JOIN dev_lead_pct  dlp ON dlp.pf_listing_id = base.pf_listing_id
    LEFT JOIN proj_lead_pct plp ON plp.pf_listing_id = base.pf_listing_id
```

- [ ] **Step 4.5: Update the Competitive Position formula**

Locate the existing `s_competitive_position` expression in the `scored` CTE. In migration 008 it averages three signals: `comp_lead_pct`, `price_closeness`, `quality_ratio`. Replace the lead-pct portion with an average of *all available* lead percentiles (location, developer, project), null-safe:

```sql
    -- previous: comp_lead_pct
    -- new: average of location/developer/project percentiles, only counting non-NULL signals
    (
      (
        (
          COALESCE(clp.comp_pct, 0)  * (CASE WHEN clp.comp_pct IS NOT NULL THEN 1 ELSE 0 END)
        + COALESCE(dlp.dev_pct, 0)   * (CASE WHEN dlp.dev_pct  IS NOT NULL THEN 1 ELSE 0 END)
        + COALESCE(plp.proj_pct, 0)  * (CASE WHEN plp.proj_pct IS NOT NULL THEN 1 ELSE 0 END)
        )
        /
        NULLIF(
          (CASE WHEN clp.comp_pct IS NOT NULL THEN 1 ELSE 0 END)
        + (CASE WHEN dlp.dev_pct  IS NOT NULL THEN 1 ELSE 0 END)
        + (CASE WHEN plp.proj_pct IS NOT NULL THEN 1 ELSE 0 END),
        0)
      )
    ) AS comp_lead_pct_blended,
```

…and update the `s_competitive_position` arithmetic to use `comp_lead_pct_blended` in place of the old lead-pct term, keeping `price_closeness` and `quality_ratio` unchanged.

If `NULLIF(..., 0)` returns NULL (zero peer groups available), `comp_lead_pct_blended` becomes NULL and `s_competitive_position` should fall back to 50 — the existing code already has a `COALESCE(..., 50)` around the final value; leave that intact.

- [ ] **Step 4.6: Run the migration**

```bash
supabase db push
# (or, if not using migration-repair) :
# psql "$(supabase status -o json | jq -r '.DB_URL')" -f supabase/migrations/009_phase1_governance.sql
```

Expected: `Finished supabase db push.` (or, for the psql fallback, no `ERROR` lines). If you get a syntax error, the most common cause is an unbalanced parenthesis in the blended formula — count opening and closing parens carefully.

- [ ] **Step 4.7: Run the scoring pipeline and verify**

```bash
curl -X POST "$SUPABASE_URL/functions/v1/run-scoring-pipeline" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
```

Assertion query — Competitive Position scores should still be in [0, 100]:

```sql
SELECT
  COUNT(*) AS scored_today,
  MIN(s_competitive_position) AS min_comp,
  MAX(s_competitive_position) AS max_comp,
  COUNT(*) FILTER (WHERE s_competitive_position IS NULL) AS null_comp
FROM listing_scores
WHERE score_date = CURRENT_DATE;
```

Expected: `scored_today` matches previous runs (~15k), `min_comp >= 0`, `max_comp <= 100`, `null_comp = 0`. A non-zero `null_comp` means the COALESCE fallback isn't firing — recheck Step 4.5.

- [ ] **Step 4.8: Commit**

```bash
git add supabase/migrations/009_phase1_governance.sql
git commit -m "feat(scoring): developer + project peer partitions in Competitive Position"
```

---

## Task 5: Recommendation Approval State Machine

**Why:** PRD §10 ("All recommendations require managerial approval before execution"). Today, [supabase/migrations/001_schema.sql:315](../../../supabase/migrations/001_schema.sql#L315) defines `status text DEFAULT 'PENDING'` with no constraint and no executed/rejected lifecycle. We formalize states and provide an RPC to drive transitions.

States: `PENDING → APPROVED → EXECUTED` (happy path), or `PENDING → REJECTED` (terminal). `APPROVED` and `EXECUTED` both require a reviewer identity.

**Files:**
- Modify: `supabase/migrations/009_phase1_governance.sql` (append section)

- [ ] **Step 5.1: Add lifecycle columns and CHECK constraint**

Append to `supabase/migrations/009_phase1_governance.sql`:

```sql
-- ------------------------------------------------------------
-- 8. Recommendations approval state machine
-- ------------------------------------------------------------
ALTER TABLE recommendations
  ADD COLUMN IF NOT EXISTS approved_by  text,
  ADD COLUMN IF NOT EXISTS approved_at  timestamptz,
  ADD COLUMN IF NOT EXISTS executed_by  text,
  ADD COLUMN IF NOT EXISTS executed_at  timestamptz,
  ADD COLUMN IF NOT EXISTS rejected_by  text,
  ADD COLUMN IF NOT EXISTS rejected_at  timestamptz;

-- Backfill any legacy status values to PENDING
UPDATE recommendations
SET status = 'PENDING'
WHERE status NOT IN ('PENDING','APPROVED','EXECUTED','REJECTED')
   OR status IS NULL;

ALTER TABLE recommendations
  DROP CONSTRAINT IF EXISTS recommendations_status_check;
ALTER TABLE recommendations
  ADD CONSTRAINT recommendations_status_check
    CHECK (status IN ('PENDING','APPROVED','EXECUTED','REJECTED'));
```

- [ ] **Step 5.2: Add the transition RPC**

Append to `supabase/migrations/009_phase1_governance.sql`:

```sql
CREATE OR REPLACE FUNCTION fn_review_recommendation(
  p_recommendation_id bigint,
  p_action            text,    -- 'APPROVE' | 'REJECT' | 'EXECUTE'
  p_actor             text,
  p_notes             text DEFAULT NULL
) RETURNS recommendations AS $$
DECLARE
  v_row recommendations%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM recommendations WHERE id = p_recommendation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Recommendation % not found', p_recommendation_id;
  END IF;

  IF p_action = 'APPROVE' THEN
    IF v_row.status <> 'PENDING' THEN
      RAISE EXCEPTION 'Can only approve PENDING recommendations (current: %)', v_row.status;
    END IF;
    UPDATE recommendations
       SET status = 'APPROVED',
           approved_by = p_actor, approved_at = now(),
           notes = COALESCE(p_notes, notes)
     WHERE id = p_recommendation_id
     RETURNING * INTO v_row;

  ELSIF p_action = 'REJECT' THEN
    IF v_row.status NOT IN ('PENDING','APPROVED') THEN
      RAISE EXCEPTION 'Cannot reject from status %', v_row.status;
    END IF;
    UPDATE recommendations
       SET status = 'REJECTED',
           rejected_by = p_actor, rejected_at = now(),
           notes = COALESCE(p_notes, notes)
     WHERE id = p_recommendation_id
     RETURNING * INTO v_row;

  ELSIF p_action = 'EXECUTE' THEN
    IF v_row.status <> 'APPROVED' THEN
      RAISE EXCEPTION 'Can only execute APPROVED recommendations (current: %)', v_row.status;
    END IF;
    UPDATE recommendations
       SET status = 'EXECUTED',
           executed_by = p_actor, executed_at = now(),
           notes = COALESCE(p_notes, notes)
     WHERE id = p_recommendation_id
     RETURNING * INTO v_row;

  ELSE
    RAISE EXCEPTION 'Unknown action: % (expected APPROVE|REJECT|EXECUTE)', p_action;
  END IF;

  RETURN v_row;
END;
$$ LANGUAGE plpgsql;
```

- [ ] **Step 5.3: Update fn_generate_recommendations to only delete PENDING**

Find `fn_generate_recommendations` in [supabase/migrations/007_generate_recommendations.sql:6](../../../supabase/migrations/007_generate_recommendations.sql#L6). It currently does:

```sql
DELETE FROM recommendations WHERE recommendation_date = CURRENT_DATE AND status = 'PENDING';
```

Verify this line is present. If it is, no action needed — the existing function already preserves APPROVED/REJECTED/EXECUTED rows across rebuilds. If the function instead does an unconditional delete, append an override to `009_phase1_governance.sql` that fixes it. (As of this writing, 007 already filters by `status = 'PENDING'` — confirm by reading the file.)

- [ ] **Step 5.4: Run the migration**

```bash
supabase db push
# (or, if not using migration-repair) :
# psql "$(supabase status -o json | jq -r '.DB_URL')" -f supabase/migrations/009_phase1_governance.sql
```

Expected: `Finished supabase db push.` with no `ERROR` lines (or, for the psql fallback, only `ALTER TABLE` / `CREATE FUNCTION` / `NOTICE` lines).

- [ ] **Step 5.5: Verify with an end-to-end transition**

```sql
-- Pick any pending recommendation
WITH target AS (
  SELECT id FROM recommendations
  WHERE status = 'PENDING'
  ORDER BY id LIMIT 1
)
SELECT (fn_review_recommendation((SELECT id FROM target), 'APPROVE', 'test-user', 'verification')).id,
       (SELECT status FROM recommendations WHERE id = (SELECT id FROM target));
```

Expected: returns one row; the second column is `APPROVED`.

Then attempt an invalid transition to confirm enforcement:

```sql
-- Try to EXECUTE a PENDING one (should error)
DO $$
BEGIN
  PERFORM fn_review_recommendation(
    (SELECT id FROM recommendations WHERE status = 'PENDING' LIMIT 1),
    'EXECUTE', 'test-user', NULL
  );
  RAISE EXCEPTION 'Should have failed!';
EXCEPTION
  WHEN raise_exception THEN
    IF SQLERRM LIKE '%Should have failed%' THEN
      RAISE;
    END IF;
    RAISE NOTICE 'Correctly rejected illegal transition: %', SQLERRM;
END $$;
```

Expected: a `NOTICE` is printed; no row is changed.

- [ ] **Step 5.6: Commit**

```bash
git add supabase/migrations/009_phase1_governance.sql
git commit -m "feat(recs): approval state machine (PENDING→APPROVED→EXECUTED|REJECTED)"
```

---

## Task 6: Frontend — Score Transparency Panel

**Why:** Credibility comes from explainability. A user who sees a 62 needs to be able to ask "why?" and get a deterministic answer. This task adds a panel to the listing detail page that shows every component score, its weight, its contribution, the active `scoring_config_version`, and the formula.

**Files:**
- Modify: `dashboard/src/lib/types.ts`
- Modify: `dashboard/src/pages/ListingDetail.tsx`

- [ ] **Step 6.1: Extend types**

Open `dashboard/src/lib/types.ts`. Find the `ListingScore` type (it mirrors the `listing_scores` table). Verify it includes these fields; add any that are missing:

```typescript
export interface ListingScore {
  pf_listing_id: string
  score_date: string
  scoring_config_version: number
  s_lead_volume: number | null
  s_lead_velocity: number | null
  s_cost_efficiency: number | null
  s_tier_roi: number | null
  s_quality_score: number | null
  s_price_position: number | null
  s_listing_completeness: number | null
  s_freshness: number | null
  s_competitive_position: number | null
  zero_lead_penalty: number | null
  total_score: number
  segment_level_used: number | null
  segment_listing_count: number | null
  score_band: string
}

export interface ScoringConfig {
  version: number
  w_lead_volume: number
  w_lead_velocity: number
  w_cost_efficiency: number
  w_tier_roi: number
  w_quality_score: number
  w_price_position: number
  w_listing_completeness: number
  w_freshness: number
  w_competitive_position: number
}
```

- [ ] **Step 6.2: Add a ScoreBreakdown panel to ListingDetail.tsx**

In `dashboard/src/pages/ListingDetail.tsx`, locate the section that renders the score badge (it uses the `ScoreBadge` component). Below it, render a new "Score Breakdown" section.

Add this fetch alongside the existing score fetch — both `ListingDetail` already loads `listing_scores`, so reuse that row. Also load the matching `scoring_config` row by the score's `scoring_config_version`:

```typescript
const { data: cfg } = await supabase
  .from('scoring_config')
  .select('*')
  .eq('version', score.scoring_config_version)
  .single()
```

Render the table:

```tsx
{score && cfg && (
  <section className="mt-6 rounded-lg border border-gray-200 p-4">
    <header className="mb-3 flex items-baseline justify-between">
      <h2 className="text-lg font-semibold">Score Breakdown</h2>
      <span className="text-xs text-gray-500">
        scoring_config v{score.scoring_config_version} · segment level {score.segment_level_used ?? '—'}
      </span>
    </header>

    <table className="w-full text-sm">
      <thead className="text-left text-gray-500">
        <tr>
          <th className="py-1">Component</th>
          <th className="py-1 text-right">Score</th>
          <th className="py-1 text-right">Weight</th>
          <th className="py-1 text-right">Contribution</th>
        </tr>
      </thead>
      <tbody>
        {([
          ['Lead Volume',          score.s_lead_volume,          cfg.w_lead_volume],
          ['Lead Velocity',        score.s_lead_velocity,        cfg.w_lead_velocity],
          ['Cost Efficiency',      score.s_cost_efficiency,      cfg.w_cost_efficiency],
          ['Tier ROI',             score.s_tier_roi,             cfg.w_tier_roi],
          ['PF Quality',           score.s_quality_score,        cfg.w_quality_score],
          ['Price Position',       score.s_price_position,       cfg.w_price_position],
          ['Listing Completeness', score.s_listing_completeness, cfg.w_listing_completeness],
          ['Freshness',            score.s_freshness,            cfg.w_freshness],
          ['Competitive Position', score.s_competitive_position, cfg.w_competitive_position],
        ] as const).map(([label, s, w]) => (
          <tr key={label} className="border-t border-gray-100">
            <td className="py-1">{label}</td>
            <td className="py-1 text-right">{s?.toFixed(1) ?? '—'}</td>
            <td className="py-1 text-right text-gray-500">{w}</td>
            <td className="py-1 text-right font-medium">
              {s != null ? ((s * w) / 100).toFixed(2) : '—'}
            </td>
          </tr>
        ))}
        {score.zero_lead_penalty != null && score.zero_lead_penalty > 0 && (
          <tr className="border-t border-gray-100 text-red-600">
            <td className="py-1" colSpan={3}>Zero-Lead Penalty</td>
            <td className="py-1 text-right">−{score.zero_lead_penalty.toFixed(2)}</td>
          </tr>
        )}
        <tr className="border-t-2 border-gray-300 font-semibold">
          <td className="py-2" colSpan={3}>Total</td>
          <td className="py-2 text-right">{score.total_score.toFixed(1)}</td>
        </tr>
      </tbody>
    </table>

    <p className="mt-3 text-xs text-gray-500">
      Total = Σ(component × weight) / 100, minus any zero-lead penalty (25% of raw score when
      total_leads = 0 and days_live ≥ 14). Bounded to [0, 100].
    </p>
  </section>
)}
```

- [ ] **Step 6.3: Run the dev server and visually verify**

```bash
cd dashboard && npm run dev
```

Open a listing detail page in the browser. Confirm:
- Nine component rows render with scores and weights.
- The "Contribution" column sums (visually) to approximately the Total row value.
- The header shows `scoring_config v<n>`.
- If `zero_lead_penalty > 0` for the chosen listing, the red penalty row appears.

If the panel does not render, check the browser console — most likely cause is the `scoring_config` query returning `null` because the version doesn't exist; verify with `SELECT * FROM scoring_config ORDER BY version`.

- [ ] **Step 6.4: Commit**

```bash
git add dashboard/src/lib/types.ts dashboard/src/pages/ListingDetail.tsx
git commit -m "feat(ui): score breakdown panel on listing detail"
```

---

## Task 7: Frontend — Recommendation Approve / Reject / Execute

**Why:** Without UI controls, the state machine from Task 5 is unreachable. This task adds action buttons that call `fn_review_recommendation` via Supabase RPC.

**Files:**
- Modify: `dashboard/src/lib/types.ts`
- Modify: `dashboard/src/pages/Recommendations.tsx`

- [ ] **Step 7.1: Extend the Recommendation type**

In `dashboard/src/lib/types.ts`, ensure `Recommendation` includes the lifecycle columns added in Task 5:

```typescript
export type RecommendationStatus = 'PENDING' | 'APPROVED' | 'EXECUTED' | 'REJECTED'

export interface Recommendation {
  id: number
  pf_listing_id: string
  recommendation_date: string
  action_type: string
  priority: string
  reason_summary: string
  reason_details: unknown
  status: RecommendationStatus
  approved_by: string | null
  approved_at: string | null
  executed_by: string | null
  executed_at: string | null
  rejected_by: string | null
  rejected_at: string | null
  notes: string | null
}
```

- [ ] **Step 7.2: Add an action helper to Recommendations.tsx**

Inside `dashboard/src/pages/Recommendations.tsx`, add this function (above the component, or alongside existing data fetchers):

```typescript
async function reviewRecommendation(
  id: number,
  action: 'APPROVE' | 'REJECT' | 'EXECUTE',
  actor: string,
  notes?: string,
) {
  const { data, error } = await supabase.rpc('fn_review_recommendation', {
    p_recommendation_id: id,
    p_action: action,
    p_actor: actor,
    p_notes: notes ?? null,
  })
  if (error) throw error
  return data
}
```

- [ ] **Step 7.3: Render the buttons**

In the row that displays each recommendation, render contextual buttons based on `status`. Use the currently logged-in user's email as the actor — the existing `Login.tsx` already manages a Supabase session, so read it via `supabase.auth.getUser()` and cache the email in the component.

```tsx
{r.status === 'PENDING' && (
  <div className="flex gap-2">
    <button
      className="rounded bg-red-600 px-3 py-1 text-sm text-white hover:bg-red-700"
      onClick={async () => {
        await reviewRecommendation(r.id, 'APPROVE', userEmail)
        await refetch()
      }}
    >Approve</button>
    <button
      className="rounded border border-gray-300 px-3 py-1 text-sm hover:bg-gray-50"
      onClick={async () => {
        await reviewRecommendation(r.id, 'REJECT', userEmail)
        await refetch()
      }}
    >Reject</button>
  </div>
)}
{r.status === 'APPROVED' && (
  <button
    className="rounded bg-emerald-600 px-3 py-1 text-sm text-white hover:bg-emerald-700"
    onClick={async () => {
      await reviewRecommendation(r.id, 'EXECUTE', userEmail)
      await refetch()
    }}
  >Mark Executed</button>
)}
{r.status === 'EXECUTED' && (
  <span className="text-xs text-emerald-700">
    ✓ Executed by {r.executed_by} on {new Date(r.executed_at!).toLocaleDateString()}
  </span>
)}
{r.status === 'REJECTED' && (
  <span className="text-xs text-gray-500">
    Rejected by {r.rejected_by} on {new Date(r.rejected_at!).toLocaleDateString()}
  </span>
)}
```

`refetch` should be the existing function that reloads the recommendations list — whatever it is named in the current component (likely a `useEffect`-triggered fetch; if there isn't a named refetch, lift the fetch into a `useCallback` and call it after each action).

- [ ] **Step 7.4: Add a status filter to the page**

Above the recommendations list, add a filter chip group:

```tsx
const [statusFilter, setStatusFilter] = useState<RecommendationStatus | 'ALL'>('PENDING')
// ...
<div className="mb-4 flex gap-2">
  {(['PENDING','APPROVED','EXECUTED','REJECTED','ALL'] as const).map(s => (
    <button
      key={s}
      className={`rounded px-3 py-1 text-sm ${
        statusFilter === s ? 'bg-black text-white' : 'bg-gray-100 hover:bg-gray-200'
      }`}
      onClick={() => setStatusFilter(s)}
    >{s}</button>
  ))}
</div>
```

Update the Supabase query to apply the filter:

```typescript
let q = supabase
  .from('recommendations')
  .select('*')
  .eq('recommendation_date', new Date().toISOString().slice(0, 10))
if (statusFilter !== 'ALL') {
  q = q.eq('status', statusFilter)
}
const { data } = await q.order('priority').order('id')
```

- [ ] **Step 7.5: Run the dev server and test the happy path**

```bash
cd dashboard && npm run dev
```

In the browser:
1. Open Recommendations page. Confirm only PENDING rows show by default.
2. Click Approve on one row. Confirm it disappears from the PENDING tab.
3. Switch to APPROVED tab. Confirm the same row appears with a "Mark Executed" button.
4. Click Mark Executed. Confirm it moves to EXECUTED tab with the timestamp/actor text.
5. Pick a different PENDING row, click Reject. Confirm it moves to REJECTED.

If any step throws an RPC error in the console, the most likely cause is that the migration from Task 5 didn't run — re-run `supabase db push`.

- [ ] **Step 7.6: Commit**

```bash
git add dashboard/src/lib/types.ts dashboard/src/pages/Recommendations.tsx
git commit -m "feat(ui): approve/reject/execute controls + status filter for recommendations"
```

---

## Task 8: End-to-End Verification

**Why:** Phase 1 is now complete. Run one full pipeline + UI walkthrough as the acceptance test.

- [ ] **Step 8.1: Trigger a clean pipeline run**

```bash
curl -X POST "$SUPABASE_URL/functions/v1/run-scoring-pipeline" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
```

Watch `sync_log` for completion:

```sql
SELECT sync_type, status, started_at, completed_at, error_message
FROM sync_log
ORDER BY started_at DESC
LIMIT 5;
```

Expected: a fresh `run-scoring-pipeline` row with `status = 'SUCCESS'` and no error.

- [ ] **Step 8.2: Run the master assertion query**

```sql
SELECT
  (SELECT COUNT(*) FROM listing_scores WHERE score_date = CURRENT_DATE) AS scores_today,
  (SELECT COUNT(DISTINCT scoring_config_version) FROM listing_scores WHERE score_date = CURRENT_DATE) AS versions_today,
  (SELECT COUNT(*) FROM aggregate_scores WHERE score_date = CURRENT_DATE AND dimension_type = 'developer') AS dev_rollups,
  (SELECT COUNT(*) FROM aggregate_scores WHERE score_date = CURRENT_DATE AND dimension_type = 'project')   AS project_rollups,
  (SELECT COUNT(*) FROM aggregate_scores WHERE score_date = CURRENT_DATE AND cost_weighted_score IS NOT NULL) AS cost_weighted_rollups,
  (SELECT COUNT(*) FROM scoring_config_history) AS audit_rows,
  (SELECT COUNT(*) FROM recommendations WHERE recommendation_date = CURRENT_DATE AND status = 'PENDING') AS pending_recs;
```

Expected, all in one row:
- `scores_today` ≈ 15,000
- `versions_today` = 1 (a single active config produced today's scores)
- `dev_rollups` > 0
- `project_rollups` > 0
- `cost_weighted_rollups` = total rollup row count
- `audit_rows` >= 2 (initial config + Task 1 verification)
- `pending_recs` > 0

- [ ] **Step 8.3: Walk the dashboard**

Open the dashboard. Confirm:
1. Portfolio page loads and a Score Breakdown panel renders when you click into any listing.
2. Recommendations page shows PENDING by default; clicking Approve / Reject / Execute updates the row and rotates it to the matching tab.

- [ ] **Step 8.4: Final commit (if any uncommitted polish)**

```bash
git status
# if clean, nothing to do
# if anything outstanding:
git add -A
git commit -m "chore: phase 1 polish"
```

---

## What is Explicitly Out of Scope for Phase 1

Documented so the next planner doesn't duplicate effort or confuse the boundary:

- CRM integration / confirmed-revenue ROI / Strategic Conversion scoring layer (Phase 3)
- Finance monthly cost feed / point_value calculation / activation-event modelling (Phase 2 / 3)
- Bayut sync (Phase 2)
- Impressions and clicks ingestion (Phase 2 — small, can ship independently)
- Admin Performance Engine (Phase 3, needs CRM)
- Reconciliation gating that blocks the pipeline (Phase 3, needs Finance)
- Role-based access control for admin performance visibility (Phase 3)

---

## Self-Review Notes (for the engineer)

After Task 8, re-read the [PRD](../../../PRODUCT_SPEC.md) sections 3, 8B, 9, and 10 and cross-check each invariant:

- §3.5 "Configuration changes must be logged and versioned" → Task 1 ✓
- §3.4 "Scoring must be fully reproducible" → Task 1 (every score row carries its config version) ✓
- §3.8 "All higher-level scores must derive from listing-level data only" → already true; Tasks 3–4 preserve this ✓
- §8B "Adjustments must trigger full rescore; scoring_version must increment" → `fn_publish_scoring_config` increments version; the engineer must remember to manually trigger `run-scoring-pipeline` after publishing a new config. A future enhancement could auto-trigger.
- §9 "Cost-weighted average" → Task 3 ✓
- §9 "Project, Developer, Area" rollups → Task 3 (developer, project) + existing location ✓
- §10 "All recommendations require managerial approval before execution" → Tasks 5 + 7 ✓

Anything that isn't ticked above is either out of scope (see prior section) or a bug — go back and fix the corresponding task.
