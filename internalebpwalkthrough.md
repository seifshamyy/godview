# EBP Slash — Internal System Walkthrough

> Everything about how this application works, scores, syncs, and decides.  
> Every concept has a **Technical** explanation and a **Plain English** explanation.

---

## Table of Contents

1. [What Is This Application?](#1-what-is-this-application)
2. [Architecture Overview](#2-architecture-overview)
3. [Database Tables](#3-database-tables)
4. [Sync Pipeline — Data Ingestion](#4-sync-pipeline--data-ingestion)
   - [sync-listings](#41-sync-listings)
   - [sync-leads](#42-sync-leads)
   - [sync-credits](#43-sync-credits)
   - [sync-agents](#44-sync-agents)
   - [sync-locations](#45-sync-locations)
5. [Scoring Pipeline — Daily Run](#5-scoring-pipeline--daily-run)
   - [Step 1: fn_build_daily_snapshots](#51-step-1-fn_build_daily_snapshots)
   - [Step 2: fn_build_segment_benchmarks](#52-step-2-fn_build_segment_benchmarks)
   - [Step 3: fn_score_all_listings](#53-step-3-fn_score_all_listings)
   - [Step 4: fn_build_aggregate_scores](#54-step-4-fn_build_aggregate_scores)
   - [Step 5: fn_generate_recommendations](#55-step-5-fn_generate_recommendations)
6. [Scoring Deep Dive — Every Component](#6-scoring-deep-dive--every-component)
   - [Component 1: Lead Volume (weight: 20)](#component-1-lead-volume-weight-20)
   - [Component 2: Lead Velocity (weight: 10)](#component-2-lead-velocity-weight-10)
   - [Component 3: Cost Efficiency (weight: 20)](#component-3-cost-efficiency-weight-20)
   - [Component 4: Tier ROI (weight: 10)](#component-4-tier-roi-weight-10)
   - [Component 5: PF Quality Score (weight: 10)](#component-5-pf-quality-score-weight-10)
   - [Component 6: Price Position (weight: 10)](#component-6-price-position-weight-10)
   - [Component 7: Listing Completeness (weight: 5)](#component-7-listing-completeness-weight-5)
   - [Component 8: Freshness (weight: 5)](#component-8-freshness-weight-5)
   - [Component 9: Competitive Position (weight: 10)](#component-9-competitive-position-weight-10)
   - [Zero-Lead Penalty](#zero-lead-penalty)
   - [Final Score Formula](#final-score-formula)
   - [Score Bands](#score-bands)
7. [Segment Benchmarks — How Peer Groups Work](#7-segment-benchmarks--how-peer-groups-work)
8. [Recommendations Engine — All 7 Rules](#8-recommendations-engine--all-7-rules)
9. [Portfolio Stats and Pagination](#9-portfolio-stats-and-pagination)
10. [Key Metrics Glossary](#10-key-metrics-glossary)
11. [Schedules — When Everything Runs](#11-schedules--when-everything-runs)

---

## 1. What Is This Application?

**Technical:** EBP Slash is an internal business intelligence dashboard built on Supabase (PostgreSQL + Edge Functions) with a React/TypeScript/Tailwind frontend. It mirrors data from the PropertyFinder (PF) Atlas API into a local database, runs a nightly scoring pipeline over all live listings, and surfaces actionable insights via a web dashboard.

**Plain English:** We have ~15,000 property listings on PropertyFinder. This tool pulls all of that data into our own database every few hours, runs a nightly analysis to grade each listing (like a report card), and shows us a dashboard so we can immediately see which listings are performing well, which are wasting money, and what we should do about each one.

---

## 2. Architecture Overview

```
PropertyFinder API (atlas.propertyfinder.com)
        |
        | (every 2-6 hours via pg_cron → Supabase Edge Functions)
        ↓
Supabase PostgreSQL Database
  ├── pf_listings        (all listing details)
  ├── pf_leads           (every lead received)
  ├── pf_credit_transactions (every credit spent)
  ├── pf_agents          (agent details)
  ├── pf_locations       (location data)
  ├── segment_benchmarks (peer group stats, rebuilt nightly)
  ├── listing_scores     (daily score per listing)
  ├── aggregate_scores   (rolled up by agent/location/tier)
  ├── recommendations    (action items, rebuilt nightly)
  └── listing_daily_snapshots (historical record)
        |
        | (nightly at 3am via pg_cron → run-scoring-pipeline Edge Function)
        ↓
React Dashboard (EBP Slash)
  ├── Portfolio — browse/filter/sort all listings with scores
  ├── Recommendations Hub — actionable alerts per listing
  ├── Analytics — aggregated performance by agent/location/tier
  └── Sync Log — audit trail of every data sync
```

**Technical:** The system uses Supabase Edge Functions (Deno runtime) as the sync layer, calling the PF Atlas REST API with JWT authentication. Results are upserted into PostgreSQL. The nightly scoring pipeline is a chain of PL/pgSQL functions orchestrated by a single `run-scoring-pipeline` Edge Function. The dashboard reads directly from Supabase using the JS client with Row Level Security disabled for the service role.

**Plain English:** Think of it as a three-layer cake. The bottom layer is PropertyFinder's system where all the listing data lives. The middle layer is our own database that copies everything from PF and processes it. The top layer is the dashboard you look at. The middle layer is what makes this powerful — it can do analysis that PF's interface never could.

---

## 3. Database Tables

| Table | What It Stores |
|---|---|
| `pf_listings` | Every live listing: price, tier, quality score, images, agent, location, days live, etc. |
| `pf_leads` | Every lead received, linked back to the listing by `reference` |
| `pf_credit_transactions` | Every credit charge (featured/premium/boost fees), linked to listing |
| `pf_agents` | Agent profiles — name, status, verification |
| `pf_locations` | Hierarchical location tree from PF |
| `pf_credit_snapshots` | Daily snapshot of total credit balance |
| `segment_benchmarks` | Peer group averages (median price, avg leads, CPL) at 3 granularity levels |
| `listing_scores` | Daily score record per listing: all 9 component scores + total |
| `listing_daily_snapshots` | Historical snapshot of each listing's key metrics per day |
| `aggregate_scores` | Rolled-up scores by dimension (agent, location, property type, tier) |
| `recommendations` | Action items per listing with priority, reason, and supporting data |
| `scoring_config` | Scoring weights and thresholds (versioned, sum must equal 100) |
| `sync_log` | Audit log of every sync run: start time, status, records synced, errors |

---

## 4. Sync Pipeline — Data Ingestion

### 4.1 sync-listings

**Schedule:** Every 4 hours (`0 */4 * * *`)

**Technical:** Uses a two-phase pagination strategy to work around the PF API's hard cap of 100 pages (10,000 records per sort direction). Phase 1 sorts by `createdAt DESC` (newest 10k), Phase 2 sorts by `createdAt ASC` (oldest 10k). Each phase runs in chunks of 15 pages per Edge Function invocation; the function calls itself asynchronously with a `logId + page + phase` payload to continue without hitting Supabase's Edge Function timeout. Each page of 100 listings is mapped from raw PF JSON to our schema and upserted on `pf_listing_id` conflict. This covers all ~15k live listings without ever hitting page 101.

Each raw listing is transformed by `mapListing()` which extracts:
- Identifiers: `pf_listing_id`, `reference`
- Property details: category, type, bedrooms, bathrooms, size, amenities, furnishing, floor, developer, parking
- Pricing: sale/yearly/monthly/daily amounts, price-on-request flag, effective_price, price_per_sqft
- Tier data: `tier_featured`, `tier_premium`, `tier_standard` (JSON objects with createdAt/expiresAt), `current_tier`, `tier_expires_at`
- Quality: `pf_quality_score` (0-100), `pf_quality_color`, `pf_quality_details`
- Media: `image_count`, `has_video`
- State: `is_live`, `published_at`, `listing_stage`
- Agent: `agent_public_profile_id`, `agent_name`
- Location: `location_id`

A database trigger (`trg_set_current_tier`) fires on every upsert to compute `current_tier` (featured > premium > standard > none) and `tier_expires_at` from the JSON tier objects.

**Plain English:** Every 4 hours we go to PropertyFinder and download every listing we have live. Because PF limits how many you can fetch in one go, we do two sweeps — once from the newest listings down, once from the oldest listings up. Together they cover everything. All the data (price, photos, tier, quality) gets saved into our own database so we can analyze it freely.

---

### 4.2 sync-leads

**Schedule:** Every 2 hours (`0 */2 * * *`)

**Technical:** Fetches `/leads` from PF API ordered by `createdAt DESC`, 50 per page, paginating in chunks of 15 pages per invocation (self-chaining like sync-listings). Each lead is mapped to `pf_lead_id`, `listing_reference`, `lead_created_at`, `response_link`, and the raw payload. Upserting on `pf_lead_id`. No date cutoff — fetches all available leads to ensure nothing is missed.

**Plain English:** Every 2 hours we download all the leads (enquiries from buyers/renters) from PropertyFinder and store them in our database linked to the listing they came from. This is what powers the lead-count metrics across the whole system.

---

### 4.3 sync-credits

**Schedule:** Every 6 hours (`0 */6 * * *`)

**Technical:** First calls `/credits/balance` to capture a point-in-time balance snapshot. Then pages through `/credits/transactions` newest-first, stopping as soon as it finds a page where no transactions are from today. This means it only syncs today's transactions, keeping the run fast. Each transaction is keyed by a composite ID `{createdAt}_{listingId}_{amount}` since PF doesn't provide a stable transaction ID. The `credit_amount` is stored as-is (negative for charges, positive for refunds) and `ABS()` is applied wherever costs are calculated.

**Plain English:** Every 6 hours we check how many credits were spent today. We snap the current balance, then download today's credit charges (for featured/premium placements) and link them to the listings that were charged. This is how we know how much each listing costs to run.

---

### 4.4 sync-agents

**Schedule:** Daily at 1am (`0 1 * * *`)

**Technical:** Calls the `upsert_agents_from_listings` SQL function, which builds the `pf_agents` table directly from `agent_public_profile_id` and `agent_name` columns on `pf_listings`. This is intentional — the PF `/users` API returns internal user IDs that don't match the public profile IDs referenced by listings. Also attempts to sync `/stats/public-profiles` for agent performance stats (non-fatal if it fails).

**Plain English:** Once a day we update our list of agents based on who has active listings. We derive agent data from the listings themselves rather than the agent API because the two systems use different ID formats and the listing data is always accurate.

---

### 4.5 sync-locations

**Technical:** Fetches the PF location hierarchy and stores all location nodes in `pf_locations` with `location_id`, `name`, lat/lng, and `parent_id` (for tree traversal). This is used to join human-readable location names and "destination" groupings onto listings.

**Plain English:** We maintain a local copy of all the area/district names that PF uses so we can show "Dubai Marina" instead of "location ID 2000".

---

## 5. Scoring Pipeline — Daily Run

**Schedule:** Every night at 3am (`0 3 * * *`)

The pipeline is triggered by the `run-scoring-pipeline` Edge Function, which calls 5 SQL functions in sequence. If any step fails, the pipeline aborts and logs the error. Each step's execution time is recorded.

```
fn_build_daily_snapshots
        ↓
fn_build_segment_benchmarks
        ↓
fn_score_all_listings
        ↓
fn_build_aggregate_scores
        ↓
fn_generate_recommendations
```

---

### 5.1 Step 1: fn_build_daily_snapshots

**Technical:** Inserts one row per live listing into `listing_daily_snapshots` for today's date. Data includes: `total_leads`, `new_leads_today`, `pf_quality_score`, `current_tier`, `effective_price`, `is_live`, `days_live`, `total_credits_spent`, and `cpl` (cost per lead = total_credits / total_leads, NULL if no leads). Uses `ON CONFLICT DO UPDATE` so re-running is safe. Uses lateral subqueries against `pf_leads` and `pf_credit_transactions` for per-listing aggregates.

**Plain English:** This is the "end of day photo" step. Before any analysis, we take a snapshot of every listing's current state — how many leads it has, how much was spent on it, what tier it's on, etc. This lets us look back at any day historically and see exactly what was happening.

---

### 5.2 Step 2: fn_build_segment_benchmarks

**Technical:** Deletes and rebuilds `segment_benchmarks` for today at three granularity levels:
- **Level 4:** `location_id + category + property_type + bedrooms` (most specific)
- **Level 3:** `location_id + category + property_type`
- **Level 2:** `location_id + category` (broadest)

For each group it computes: `listing_count`, `avg_price`, `median_price`, `min/max_price`, `avg_price_per_sqft`, `avg_leads`, `median_leads`, `p25_leads`, `p75_leads`, `avg_leads_per_day`, `avg_cpl`, `median_cpl`, `avg_quality_score`, and tier mix percentages (% featured, % premium, % standard). Only groups with at least 1 listing qualify (controlled by `scoring_config.min_segment_size`). Uses `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ...)` for true median calculations.

**Plain English:** This is the "compare with similar listings" step. We group all listings by their characteristics — same area, same type, same bedroom count — and calculate averages for that group. A 2-bedroom apartment in Dubai Marina gets compared to other 2-bedroom apartments in Dubai Marina. If we don't have enough listings at that level, we zoom out to just "apartments in Dubai Marina", or if still not enough, just "Dubai Marina properties". These group averages become the yardstick every listing is measured against.

---

### 5.3 Step 3: fn_score_all_listings

**Technical:** The core scoring engine. Deletes today's scores and rebuilds them in a single SQL `INSERT ... WITH` statement using CTEs and window functions (no row-by-row loops). Architecture:

1. **`lead_agg` CTE:** One full-table scan of `pf_leads` — computes `total_leads`, `leads_30d`, `leads_7d`, `leads_prior_7d` per listing in a single GROUP BY.
2. **`credit_agg` CTE:** One full-table scan of `pf_credit_transactions` — computes `total_credits` per listing.
3. **`base` CTE:** Joins listings with lead/credit aggregates. All subsequent CTEs work against this precomputed set.
4. **`listing_seg` CTE:** Uses `DISTINCT ON ... ORDER BY segment_level DESC` to pick the best (most granular) available segment for each listing.
5. **`std_leads_l3/l2` CTEs:** Average leads for standard-tier listings at level 3 and 2 granularity — used for Tier ROI.
6. **`lead_vol_pct` CTE:** `PERCENT_RANK()` window functions compute each listing's percentile rank within its peer group at all three segment levels simultaneously — O(n log n) vs the old O(n²) correlated subqueries.
7. **`comp_vol_pct` CTE:** `PERCENT_RANK()` for competitive position.
8. **`scored` CTE:** All 9 component scores computed as CASE expressions.
9. **`final` CTE:** Raw score weighted sum + zero-lead penalty.
10. **SELECT:** Writes to `listing_scores`.

**Plain English:** This is the grading step. For every live listing, we calculate 9 separate scores (like grades in different subjects), weight them by importance, add them up, and apply any penalties. The result is a number from 0-100 and a band from F to S. This used to run one listing at a time and would time out on 15,000 listings. Now it processes all 15,000 in one optimized database operation.

---

### 5.4 Step 4: fn_build_aggregate_scores

**Technical:** Deletes and rebuilds `aggregate_scores` for today across four dimensions:
- **By agent:** Groups all listings by `agent_name`
- **By location:** Groups by `pf_locations.name`
- **By property_type:** Groups by listing property type
- **By tier:** Groups by `current_tier`

For each group: `listing_count`, `total_credits`, `total_leads`, `avg_score`, `min_score`, `max_score`, `avg_cpl`, and band distribution counts (S/A/B/C/D/F). Uses `ON CONFLICT DO UPDATE` for idempotency.

**Plain English:** After scoring individual listings, we roll those scores up into summaries. This powers the analytics screens — "Agent X has 45 listings with an average score of 62" or "Featured listings in Dubai Marina have a CPL of 120 AED". Without this step you'd have to recalculate on the fly every time you loaded the analytics page.

---

### 5.5 Step 5: fn_generate_recommendations

**Technical:** Deletes today's PENDING recommendations, then loops through all live listings (joined with their latest score and aggregated lead/credit data) and evaluates 7 rules via conditional inserts. A listing can match multiple rules, but because rules are evaluated independently and each uses `ON CONFLICT DO NOTHING`, only the first matching insert per listing per date lands. Rules are ordered implicitly by evaluation order in the loop.

See [Section 8](#8-recommendations-engine--all-7-rules) for the full rule breakdown.

**Plain English:** The final step is the advisor. After all the scoring is done, we look at each listing's score, leads, spend, and tier, and decide if there's something actionable to tell the team. This generates the "Recommendations Hub" you see in the dashboard — a prioritized to-do list.

---

## 6. Scoring Deep Dive — Every Component

The scoring config is stored in the `scoring_config` table. The weights listed below are the defaults (must sum to 100 — enforced by a DB constraint).

---

### Component 1: Lead Volume (weight: 20)

**Technical:** Uses `PERCENT_RANK()` window functions over three segment partitions simultaneously in the `lead_vol_pct` CTE. The metric being ranked is `v_leads_30d` (leads in the last 30 days). The system picks the most granular level (L4 → L3 → L2) that has at least `min_segment_size` listings.

```
s_lead_volume = PERCENT_RANK() × 100
              (within segment: location + category + type + bedrooms, or fallback)
```

If no valid segment exists, defaults to 50 (neutral).

**Plain English:** This measures how many leads this listing got in the last 30 days compared to similar listings in the same area. If this is a 2-bed apartment in Downtown Dubai and 80% of similar apartments got fewer leads, this listing scores 80 here. If it got fewer leads than most similar listings, it scores low. It's not about the raw number — it's about how you compare to your peers.

---

### Component 2: Lead Velocity (weight: 10)

**Technical:** Compares leads in the last 7 days vs leads in the 7 days before that (days 8-14). Listings live fewer than 14 days get a neutral score of 50 (not enough history). The velocity ratio = `leads_7d / leads_prior_7d`.

```
ratio ≥ 1.5  → 100    (accelerating strongly)
ratio ≥ 1.0  → 70 + (ratio - 1.0)/0.5 × 30   (growing)
ratio ≥ 0.5  → 40 + (ratio - 0.5)/0.5 × 30   (slowing)
ratio < 0.5  → 10 + ratio/0.5 × 30            (dropping fast)

Special: prior_7d = 0 AND current_7d = 0 → 0
Special: prior_7d = 0 AND current_7d > 0 → 100 (new momentum)
```

**Plain English:** This measures whether interest in the listing is growing or shrinking. Compare last week's leads to the week before. If more people are enquiring now than before, the listing is gaining momentum (high score). If enquiries are drying up, the score drops. New listings (under 2 weeks) get a neutral score because there isn't enough history to judge yet.

---

### Component 3: Cost Efficiency (weight: 20)

**Technical:** Measures cost-per-lead (CPL) relative to segment median CPL. The listing's CPL = `total_credits_spent / total_leads`. The ratio = `segment_median_cpl / listing_cpl`. A higher ratio means the listing's CPL is *lower* than the median (more efficient).

```
ratio ≥ 2.0  → 100    (CPL is less than half the median — very efficient)
ratio ≥ 1.0  → 60 + (ratio - 1.0) × 40   (below median CPL)
ratio ≥ 0.5  → 30 + (ratio - 0.5)/0.5 × 30  (above median CPL)
ratio < 0.5  → ratio/0.5 × 30             (very expensive per lead)

Special: 0 leads AND credits spent → 0 (worst case — money spent, nothing gained)
Special: 0 leads AND 0 credits → 50 (neutral — free tier, no data)
```

**Plain English:** This measures how cheaply we're generating leads. If the average listing in our segment spends 200 AED per lead but this listing only spends 80 AED per lead, it's doing great. If it's spending 500 AED per lead while others spend 200, something is wrong. If we're spending credits but getting zero leads, this scores 0 — that's the worst outcome.

---

### Component 4: Tier ROI (weight: 10)

**Technical:** Only applies to featured and premium tiers. For standard and none, defaults to 50 (neutral — no premium spend to justify). Measures whether the listing is generating the expected lead multiplier for its tier.

Expected multipliers:
- `featured` → 2.5× the leads of a standard listing in the same segment
- `premium` → 1.8× the leads of a standard listing

`std_avg_leads` = average total_leads of standard-tier listings in the same (location + category + property_type) group.

`tier_multiplier = listing_total_leads / std_avg_leads`

`roi_ratio = tier_multiplier / expected_multiplier`

```
roi_ratio ≥ 1.0  → 60 + min(40, (roi_ratio - 1.0) × 40)
roi_ratio ≥ 0.5  → 30 + (roi_ratio - 0.5)/0.5 × 30
roi_ratio < 0.5  → roi_ratio/0.5 × 30
```

**Plain English:** If a listing is paying for "featured" placement, it should be getting 2.5× more leads than a standard listing in the same area. If it's achieving that, great — the spend is justified. If a featured listing is getting the same leads as standard listings, or fewer, then we're wasting money on the upgrade. This score captures how well the tier is actually working.

---

### Component 5: PF Quality Score (weight: 10)

**Technical:** Directly uses `pf_quality_score` from the PropertyFinder API (0-100). If null, defaults to 50.

`s_quality = COALESCE(pf_quality_score, 50)`

**Plain English:** PropertyFinder scores each listing on quality (completeness of description, photo count, accuracy, etc.) and shows it as a colored indicator. We use their score directly. A green quality score from PF maps to a high score here.

---

### Component 6: Price Position (weight: 10)

**Technical:** Compares `price_per_sqft` against `avg_price_per_sqft` from the segment benchmark. Measures how well the price fits within the segment range.

```
price_on_request = true  → 40   (can't compare, slight penalty)
price_per_sqft IS NULL   → 50   (neutral, no data)

vs segment avg_price_per_sqft:
  within ±25%   → 100  (competitively priced)
  within ±50%   → 60   (somewhat competitive)
  outside ±50%  → 30   (significant outlier)
```

**Plain English:** Is this listing priced sensibly compared to similar properties? If it's priced within 25% of what similar listings charge per square foot, it's well-positioned for leads. If it's massively over or underpriced compared to the segment, it scores lower. "Price on request" listings can't be compared, so they get a slightly below-neutral score.

---

### Component 7: Listing Completeness (weight: 5)

**Technical:** A checklist of optional fields. Points are additive up to a max of 100.

```
Base:                    +20  (bilingual title/description assumed present)
image_count ≥ 5:         +15
image_count ≥ 10:        +10  (cumulative with above)
has_video = true:        +15
amenities ≥ 3 items:     +10
floor_number present:    +10
developer present:        +5
has_parking = true:       +5
built_up_area_sqft:       +5
furnishing type present:  +5
```

Maximum: 100. Score = LEAST(100, sum of all applicable points).

**Plain English:** Does this listing have all the information a buyer or renter would want? More photos, a video tour, the floor number, parking info, furnishing details — all of these help convert enquiries. A listing with 15 photos, a video, and all fields filled out scores 100 here. A bare-bones listing with 2 photos and no details scores around 20-30.

---

### Component 8: Freshness (weight: 5)

**Technical:** Linear decay based on `days_live`. Parameters from `scoring_config`:
- `freshness_decay_start_days` (default: 30) — starts decaying after this many days
- `freshness_decay_end_days` (default: 180) — scores 0 at this age

```
days_live ≤ decay_start   → 100  (still fresh)
days_live ≥ decay_end     → 0    (very stale)
else → 100 × (decay_end - days_live) / (decay_end - decay_start)
```

**Plain English:** Newer listings tend to perform better. A listing that just went live today gets full marks here. As it ages past 30 days, this score gradually drops. After 180 days live, it hits 0. This nudges the system toward flagging very old listings that might need to be refreshed or removed.

---

### Component 9: Competitive Position (weight: 10)

**Technical:** Composite of three sub-metrics, averaged:

1. **Lead percentile (L3 granularity):** `PERCENT_RANK() OVER (PARTITION BY location, category, property_type ORDER BY v_total_leads)` — how this listing's all-time lead count ranks among same-type listings in the same area.

2. **Price closeness to median:** `GREATEST(0, 100 - ABS(effective_price - segment_median_price) / segment_median_price × 100)` — how close the listing price is to the segment median (0% deviation = 100, >100% deviation = 0 or below).

3. **Quality ratio:** `LEAST(100, pf_quality_score / avg_quality_score × 50)` — is this listing's quality above or below the segment average? Scoring at 50 even at 1:1 ratio, maxing at 100 when 2× above average.

`s_competitive = (lead_pct + price_closeness + quality_ratio) / 3`

If no segment, defaults to 50.

**Plain English:** This is a holistic "how do you stack up overall?" score. It combines three things: how your total lead history compares to similar listings, whether your price is near the market median, and whether your listing quality is above or below average for your segment. A listing that ranks highly on all three will get close to 100 here.

---

### Zero-Lead Penalty

**Technical:** Applied after the weighted sum. If `total_leads = 0` AND `days_live ≥ zero_lead_days_threshold` (default: 14), then:

`penalty = raw_score × zero_lead_penalty_pct / 100`
`penalty_pct` default: 25%

A listing live for 14+ days with zero leads loses 25% of its raw score. This is multiplicative — a listing that would score 60 drops to 45.

**Plain English:** If a listing has been live for 2+ weeks and hasn't received a single lead, that's a serious red flag regardless of how good the photos and description are. We cut the score by 25% as a penalty signal. This is separate from the lead volume score — it's an additional punishment for complete lead failure.

---

### Final Score Formula

```
raw_score = (
  s_lead_volume          × 20 +
  s_lead_velocity        × 10 +
  s_cost_efficiency      × 20 +
  s_tier_roi             × 10 +
  s_quality_score        × 10 +
  s_price_position       × 10 +
  s_listing_completeness ×  5 +
  s_freshness            ×  5 +
  s_competitive_position × 10
) / 100

penalty = raw_score × 25% (if 0 leads AND days_live ≥ 14, else 0)

total_score = GREATEST(0, LEAST(100, ROUND(raw_score - penalty, 1)))
```

**Plain English:** Each subject gets multiplied by its importance weight, they're all added together, and divided by 100 to get a 0-100 score. Then if there's a zero-lead penalty, we subtract a quarter of the score. The result is clamped between 0 and 100 and rounded to one decimal place.

---

### Score Bands

| Band | Score Range | Meaning |
|---|---|---|
| **S** | 85–100 | Exceptional performer |
| **A** | 70–84 | Strong performer |
| **B** | 55–69 | Above average |
| **C** | 40–54 | Average / needs monitoring |
| **D** | 25–39 | Underperforming |
| **F** | 0–24 | Poor — action required |

---

## 7. Segment Benchmarks — How Peer Groups Work

**Technical:** Three tiers of peer grouping, applied in order of specificity:

- **Level 4** — `location_id + category + property_type + bedrooms`
  Example: location=Dubai Marina, category=residential, type=apartment, bedrooms=2
  
- **Level 3** — `location_id + category + property_type`
  Example: location=Dubai Marina, category=residential, type=apartment (all bedrooms)
  
- **Level 2** — `location_id + category`
  Example: location=Dubai Marina, category=residential (all types and bedrooms)

The system tries Level 4 first. If the group has fewer than `min_segment_size` listings, it falls back to Level 3, then Level 2. If none qualify, the listing gets neutral scores (50) for all peer-dependent components.

Stats computed per benchmark group: `listing_count`, `avg_price`, `median_price`, `min/max price`, `avg_price_per_sqft`, `avg_leads`, `median_leads`, `p25_leads` (25th percentile), `p75_leads` (75th percentile), `avg_leads_per_day`, `avg_cpl`, `median_cpl`, `avg_quality_score`, and tier mix (% featured/premium/standard).

**Plain English:** Before scoring, we need to know what "normal" looks like. We define "normal" by grouping similar listings together. The most specific grouping is "same area + same category + same property type + same bedroom count." If there aren't enough listings in that precise group to make a fair comparison, we zoom out to "same area + type" and then "same area + category." The averages from whichever group qualifies become the benchmark every score component compares against.

---

## 8. Recommendations Engine — All 7 Rules

The engine runs after scoring. It evaluates every live listing against 7 rules. The final version (migration 007) generates recommendations using a simplified row-by-row loop. Each rule uses `ON CONFLICT DO NOTHING` so if a listing matches multiple rules, only the first one that fires (earliest in the loop) is saved.

| # | Action | Priority | Trigger Conditions |
|---|---|---|---|
| 1 | REMOVE | CRITICAL | Score band = F AND total_leads = 0 AND credits > 0 AND days_live > 21 |
| 2 | DOWNGRADE | HIGH | Score band IN (D, F) AND tier IN (featured, premium) AND days_live > 14 |
| 3 | UPGRADE | HIGH | Score band = S AND tier = standard |
| 4 | BOOST | MEDIUM | Score band = A AND tier = standard AND leads_30d ≥ 3 |
| 5 | WATCHLIST | LOW | Score band = C AND days_live > 14 |
| 6 | IMPROVE_QUALITY | MEDIUM | pf_quality_score < 40 |
| 7 | REPRICE | MEDIUM | price_per_sqft > segment avg_price_per_sqft × 1.5 |

---

**Rule 1 — REMOVE (CRITICAL)**

**Technical:** Band=F + zero leads + positive credit spend + 21+ days live. The listing has failed completely and is burning budget.

**Plain English:** This listing has been live for 3 weeks, we've spent real money on it, and it hasn't gotten a single lead. The quality score is at the bottom (F). There is no upside. Remove it from PropertyFinder entirely.

---

**Rule 2 — DOWNGRADE (HIGH)**

**Technical:** D or F band on a paid tier (featured or premium) after 14+ days. The premium placement isn't justified by performance.

**Plain English:** This listing is on an expensive tier (featured or premium) but scoring in the bottom third. We're paying for premium exposure and getting poor results. Downgrade it to standard to stop the bleeding.

---

**Rule 3 — UPGRADE (HIGH)**

**Technical:** S-band (85+) on standard tier.

**Plain English:** This listing is our best performer — top 15% quality — and it's only on the basic tier. Upgrading it to premium or featured could amplify already-strong performance and generate even more leads.

---

**Rule 4 — BOOST (MEDIUM)**

**Technical:** A-band on standard tier with at least 3 leads in the last 30 days.

**Plain English:** This listing is performing well and has real lead momentum, but it's still on the standard tier. Consider a temporary boost or upgrade — the fundamentals are strong and extra visibility could push it over the top.

---

**Rule 5 — WATCHLIST (LOW)**

**Technical:** C-band + 14+ days live.

**Plain English:** This listing is average. Not bad enough to act on immediately, but not good enough to ignore. Keep an eye on it over the next week. If it doesn't improve, stronger action may be needed.

---

**Rule 6 — IMPROVE_QUALITY (MEDIUM)**

**Technical:** `pf_quality_score < 40` — PropertyFinder's own quality indicator is in the red zone.

**Plain English:** PropertyFinder's algorithm says this listing is low quality — probably missing photos, has a thin description, or is missing key details. PF actively penalizes low-quality listings in search rankings. Fixing this is one of the highest-ROI actions available.

---

**Rule 7 — REPRICE (MEDIUM)**

**Technical:** `price_per_sqft > segment avg_price_per_sqft × 1.5` — listing is priced 50%+ above the per-sqft average for its type in its area.

**Plain English:** This listing is significantly more expensive per square foot than comparable properties in the same area. Overpriced listings get fewer leads regardless of tier or quality. The recommendation is to consider reducing the price to be more competitive.

---

## 9. Portfolio Stats and Pagination

The Portfolio page uses two separate database functions:

### get_portfolio_stats()

**Technical:** A single SQL function (no PL/pgSQL loop) that returns one JSON object with all stats needed for the portfolio header and filter dropdowns. Uses CTEs to pre-aggregate leads and credits, then computes:
- `total` — all non-deleted listings
- `live` — live listings only
- `leads_30d` — sum of leads in last 30 days across all live listings
- `scored` — count of listings with a score today
- `avg_cpl` — average cost-per-lead across listings that have both leads and credits
- `band_dist` — JSON array of `{band, count}` for the bar chart
- `destinations` — distinct destination names for the filter dropdown
- `types` — distinct property types for the filter dropdown
- `locations` — `{name, destination}` pairs for the location filter

This runs once on page load and represents ALL listings (not paginated).

**Plain English:** When you first open the Portfolio page, we fetch a summary of your entire portfolio in one fast database call. The header stats (total listings, leads, average CPL) and all the filter dropdown options come from this single call. It covers everything — not just what's on screen.

---

### get_portfolio_page()

**Technical:** PL/pgSQL function with dynamic SQL (via `EXECUTE format(...)`) to support variable sort column. Parameters: `p_search`, `p_dest`, `p_location`, `p_tier`, `p_band`, `p_type`, `p_sort`, `p_asc`, `p_limit` (default 300), `p_offset` (default 0).

Architecture:
1. **`total` CTE:** Counts matching rows for the current filter — used to show "X of Y" without fetching all data.
2. **`page` CTE:** Pulls 300 rows from `listing_scores` (indexed on `score_date + total_score`) filtered and sorted, then joins to `pf_listings` and `pf_locations`. Starting from the scores index means the database doesn't have to scan 15k listings — it only evaluates 300.
3. **`with_leads` CTE:** Lateral subquery against `pf_leads` for only those 300 listings.
4. **`with_credits` CTE:** Lateral subquery against `pf_credit_transactions` for only those 300 listings, computes CPL.
5. Returns `{total: N, rows: [...300 rows...]}`.

Sort column is whitelisted against a CASE expression to prevent SQL injection:
- `total_score` (default) → `ls.total_score`
- `effective_price` → `l.effective_price`
- `leads_30d` → `ls.s_lead_volume` (proxy)
- `cpl` → `ls.s_cost_efficiency` (proxy)
- `days_live`, `pf_quality_score`, `score_band`, `reference`, `agent_name`

**Plain English:** The Portfolio table loads 300 listings at a time. You can scroll through the first 300, then click "Load next 300" to append more. The filters (destination, tier, band, type, search) narrow down the results on the server side — we never send you data you didn't ask for. The key efficiency trick: we sort by score first (using a database index), then only calculate the lead and credit numbers for those 300 rows, not all 15,000.

---

## 10. Key Metrics Glossary

| Metric | Definition |
|---|---|
| `total_leads` | All leads ever received for a listing (lifetime) |
| `leads_30d` | Leads received in the last 30 days |
| `leads_7d` | Leads received in the last 7 days |
| `leads_prior_7d` | Leads received in the 7 days before last week (days 8-14 ago) |
| `total_credits` | Sum of all credit charges for the listing (lifetime), using ABS() since charges are stored negative |
| `cpl` (Cost Per Lead) | `total_credits / total_leads`. NULL if no leads. |
| `days_live` | How many days the listing has been live on PF |
| `current_tier` | The active tier: `featured` > `premium` > `standard` > `none` |
| `pf_quality_score` | PropertyFinder's own 0-100 quality rating |
| `score_band` | Letter grade: S (≥85), A (≥70), B (≥55), C (≥40), D (≥25), F (<25) |
| `total_score` | Final EBP score (0-100) after weighting all 9 components and applying any penalty |
| `segment_level_used` | 4 = most specific peer group, 3 = mid, 2 = broadest, 0 = no segment found |
| `effective_price` | The applicable price (sale price for sale listings, yearly for rentals) |
| `price_per_sqft` | `effective_price / size_sqft` — for price position comparisons |
| `has_video` | Whether the listing has at least one video in media |
| `image_count` | Number of photos on the listing |
| `price_on_request` | Whether the price is hidden (always shown as "call for price") |
| `is_live` | Whether the listing is currently active on PF |
| `is_deleted` | Whether the listing was removed from PF (soft delete) |

---

## 11. Schedules — When Everything Runs

| Job | Schedule | What It Does |
|---|---|---|
| `sync-listings` | Every 4 hours | Pulls all live listings from PF API |
| `sync-leads` | Every 2 hours | Pulls all leads from PF API |
| `sync-credits` | Every 6 hours | Pulls today's credit transactions + balance |
| `sync-agents` | Daily at 1am | Rebuilds agent list from listing data |
| `run-scoring-pipeline` | Daily at 3am | Runs all 5 scoring steps in sequence |

All jobs are scheduled via `pg_cron` (a PostgreSQL extension) which fires HTTP requests to Supabase Edge Functions. The `sync_log` table records every run — start time, finish time, records processed, and any error message.

**Plain English:** The system runs on autopilot. Data from PF is refreshed every 2-6 hours throughout the day. Every night at 3am the full scoring and recommendations pipeline runs. By the time you open the dashboard in the morning, everything is fresh and scored.

---

*Last updated: April 2026 — covers migrations 001 through 008.*
