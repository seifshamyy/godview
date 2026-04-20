PF Portal Performance Engine — Product Spec v1.0
Purpose: This document is the single instruction manual for a coding agent to build the entire system from scratch. Every table, every formula, every endpoint, every edge case is defined here. No guessing.
[object Object]1. SYSTEM IDENTITY
Name: PF Eye (Property Finder God-Eye Performance Engine)
What it does: Ingests every data point from Property Finder's Enterprise API, stores it in Supabase, computes a multi-dimensional scoring engine nightly, and surfaces a React dashboard that gives the marketing manager a god-eye view of every listing, every agent, every area, every tier — with actionable recommendations.
What it does NOT do (V1):
No CRM integration (no deal/revenue data)
No ROI in monetary terms
No automated listing actions (recommendations only)
No Bayut (PF only in V1)
[object Object]2. ARCHITECTURE
┌─────────────────────────────────────────────────────┐
│                   REACT DASHBOARD                    │
│         (Vite + React + Tailwind + Recharts)         │
└──────────────────────┬──────────────────────────────┘
                       │ Supabase JS Client (RLS)
                       ▼
┌─────────────────────────────────────────────────────┐
│                    SUPABASE                          │
│  ┌──────────┐ ┌──────────┐ ┌──────────────────────┐ │
│  │  Tables   │ │  Views   │ │  Edge Functions      │ │
│  │  (data)   │ │ (scores) │ │  (sync + scoring)    │ │
│  └──────────┘ └──────────┘ └──────────────────────┘ │
└──────────────────────┬──────────────────────────────┘
                       │ HTTP calls (scheduled)
                       ▼
┌─────────────────────────────────────────────────────┐
│              PF ENTERPRISE API                       │
│  /listings  /leads  /credits  /stats  /webhooks      │
└─────────────────────────────────────────────────────┘
Tech Stack
LayerTechnologyDatabaseSupabase (Postgres)Sync EngineSupabase Edge Functions (Deno) — triggered by pg_cronScoring EnginePostgres functions (SQL/plpgsql)FrontendReact (Vite) + Tailwind CSS + Recharts + Supabase JSAuthSupabase Auth (email/password for internal team)HostingSupabase-hosted Edge Functions + static frontend on Netlify/Vercel
Why Edge Functions + pg_cron (not n8n)
Zero external dependency
pg_cron guarantees execution
Edge Functions can paginate PF API with retry logic
Scoring runs as pure SQL inside Postgres — fastest possible path
No webhook relay needed for cron jobs
[object Object]3. AUTHENTICATION — PF API
JWT Acquisition
GET https://primary-production-e1a92.up.railway.app/webhook/99a74fd0-4d49-4ceb-8b69-9e696dbea679
Returns a JWT token. This is a proxy that handles the apiKey/apiSecret exchange.
Behavior:
Returns { "accessToken": "...", "expiresIn": 1800 } (assumed)
Token valid for 30 minutes
Must be refreshed before each sync batch if sync takes >25 min
Implementation rule: Every Edge Function that calls PF API must:
1. Call the JWT endpoint first
2. Cache the token for the duration of that function execution
3. If any PF API call returns 401, refresh token and retry once
PF API Base URL
https://atlas.propertyfinder.com/v1
Rate Limits
Auth endpoint: 60/min
All other endpoints: 650/min
Implement exponential backoff with jitter on 429
[object Object]4. DATA SOURCES — WHAT WE PULL AND EVERY FIELD WE STORE
4.1 Listings (GET /v1/listings)
Paginate with page + perPage=100. Pull both draft=false (published) and draft=true (drafts).
Every field to extract and store:
PF API FieldDB ColumnTypeNotesidpf_listing_idtext PKPF's listing IDreferencereferencetext UNIQUEInternal referencecategorycategorytextresidential / commercialtypeproperty_typetextapartment, villa, land, etc.bedroomsbedroomstextstudio, 1-30bathroomsbathroomstextnone, 1-20sizesize_sqftnumericSquare feetbuiltUpAreabuilt_up_area_sqftnumericBuilt-up area (villas)plotSizeplot_size_sqftnumericPlot size (land/villas)ageproperty_ageintegerYears since handoverfurnishingTypefurnishingtextunfurnished/semi/furnishedfinishingTypefinishingtextfully-finished/semi/unfinishedamenities[]amenitiestext[]Array of amenity slugsdeveloperdevelopertextDeveloper nameprojectStatusproject_statustextcompleted/off_plan/etclocation.idlocation_idintegerPF location tree IDprice.typeprice_typetextsale/yearly/monthly/weekly/dailyprice.amounts.saleprice_salebigintSale priceprice.amounts.yearlyprice_yearlybigintYearly rentprice.amounts.monthlyprice_monthlybigintMonthly rentprice.amounts.weeklyprice_weeklybigintWeekly rentprice.amounts.dailyprice_dailybigintDaily rentprice.downpaymentdownpaymentbigintDownpayment amountprice.numberOfChequesnum_chequesintegerPayment chequesprice.onRequestprice_on_requestbooleanPrice hiddenassignedTo.idagent_public_profile_idintegerAgent profile IDassignedTo.nameagent_nametextDenormalized for speedcreatedBy.idcreated_by_profile_idintegerWho createdproducts.featuredtier_featured_*jsonb{id, createdAt, expiresAt, renewalEnabled}products.premiumtier_premium_*jsonbSame structureproducts.standardtier_standard_*jsonbSame structurequalityScore.valuepf_quality_scoreinteger0-100qualityScore.colorpf_quality_colortextred/yellow/greenqualityScore.detailspf_quality_detailsjsonbFull breakdownstate.stagelisting_stagetextdraft/live/takendown/etcstate.typelisting_state_typetextstate.reasons[]state_reasonsjsonbWhy takendown etcportals.propertyfinder.isLiveis_livebooleanCurrently liveportals.propertyfinder.publishedAtpublished_attimestamptzFirst publish datecompliancecompliancejsonbFull compliance objectrnpmrnpmjsonbRNPM stateverificationStatusverification_statustextmedia.imagesimage_countintegerCount of imagesmedia.videoshas_videobooleanHas video tourfloorNumberfloor_numbertextnumberOfFloorsnum_floorsintegerparkingSlotsparking_slotsintegerhasGardenhas_gardenbooleanhasKitchenhas_kitchenbooleanhasParkingOnSitehas_parkingbooleanstreet.directionstreet_directiontextstreet.widthstreet_widthnumericcreatedAtpf_created_attimestamptzupdatedAtpf_updated_attimestamptzctsPrioritycts_priorityinteger
Derived fields we compute on insert/update:
ColumnTypeDerivationeffective_pricebigintCOALESCE(price_sale, price_yearly, price_monthly12, price_weekly52, price_daily*365)current_tiertextHighest active tier: featured > premium > standard > nonetier_expires_attimestamptzExpiry of current active tierdays_liveintegernow() - published_atprice_per_sqftnumericeffective_price / NULLIF(size_sqft, 0)last_synced_attimestamptzWhen we last pulled this from PF
4.2 Leads (GET /v1/leads)
Paginate with page + perPage=50 (max 50 per PF docs).
PF API FieldDB ColumnTypeNotesid (assumed)pf_lead_idtext PKlisting.referencelisting_referencetext FKMaps to listingscreatedAt (assumed)lead_created_attimestamptzWhen lead came inresponseLinkresponse_linktextFull payloadraw_payloadjsonbStore everything
Important: The leads endpoint recently added listing.reference in the response. We join leads to listings via reference.
4.3 Credits (GET /v1/credits/balance and GET /v1/credits/transactions)
Balance:
FieldDB ColumnTypebalancecredit_balancenumericsnapshot_atsnapshot_attimestamptz
Transactions (paginated):
FieldDB ColumnTypeidpf_transaction_idtext PKtypetransaction_typetextamountcredit_amountnumericlisting reference (if present)listing_referencetextcreated_attransaction_attimestamptzFull payloadraw_payloadjsonb
4.4 Agent Statistics (GET /v1/stats/public-profiles)
FieldDB ColumnTypepublicProfileIdagent_public_profile_idintegerFull stats payloadstats_payloadjsonbsnapshot_datesnapshot_datedate
4.5 Locations (GET /v1/locations)
Pull once and cache. Re-sync weekly.
FieldDB ColumnTypeidlocation_idinteger PKnamenametextcoordinates.latlatnumericcoordinates.lnglngnumericFull payloadraw_payloadjsonb[object Object]5. SUPABASE SCHEMA (RUN DIRECTLY)
-- ============================================================
-- PF EYE — COMPLETE SCHEMA
-- Run this in Supabase SQL Editor in one shot
-- Project ID: ynomeynlpfvtdopctsvg
-- ============================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- ============================================================
-- 1. LOCATIONS (reference table, synced weekly)
-- ============================================================
CREATE TABLE pf_locations (
  location_id     integer PRIMARY KEY,
  name            text NOT NULL,
  lat             numeric,
  lng             numeric,
  parent_id       integer REFERENCES pf_locations(location_id),
  raw_payload     jsonb,
  synced_at       timestamptz DEFAULT now()
);

CREATE INDEX idx_locations_parent ON pf_locations(parent_id);

-- ============================================================
-- 2. AGENTS (derived from /users endpoint)
-- ============================================================
CREATE TABLE pf_agents (
  public_profile_id   integer PRIMARY KEY,
  user_id             integer,
  first_name          text,
  last_name           text,
  email               text,
  phone               text,
  status              text,       -- active/inactive
  role_name           text,
  is_super_agent      boolean DEFAULT false,
  verification_status text,
  raw_payload         jsonb,
  synced_at           timestamptz DEFAULT now()
);

-- ============================================================
-- 3. LISTINGS (core table — every field from PF API)
-- ============================================================
CREATE TABLE pf_listings (
  pf_listing_id           text PRIMARY KEY,
  reference               text UNIQUE NOT NULL,
  
  -- Property attributes
  category                text,          -- residential/commercial
  property_type           text,          -- apartment/villa/land/etc
  bedrooms                text,          -- studio/1/2/.../30
  bathrooms               text,          -- none/1/2/.../20
  size_sqft               numeric,
  built_up_area_sqft      numeric,
  plot_size_sqft          numeric,
  property_age            integer,
  furnishing              text,          -- unfurnished/semi-furnished/furnished
  finishing               text,          -- fully-finished/semi-finished/unfinished
  amenities               text[],
  developer               text,
  project_status          text,          -- completed/off_plan/etc
  floor_number            text,
  num_floors              integer,
  parking_slots           integer,
  has_garden              boolean,
  has_kitchen             boolean,
  has_parking             boolean,
  street_direction        text,
  street_width            numeric,
  unit_number             text,
  
  -- Location
  location_id             integer REFERENCES pf_locations(location_id),
  
  -- Pricing (store ALL price types)
  price_type              text,          -- sale/yearly/monthly/weekly/daily
  price_sale              bigint,
  price_yearly            bigint,
  price_monthly           bigint,
  price_weekly            bigint,
  price_daily             bigint,
  downpayment             bigint,
  num_cheques             integer,
  price_on_request        boolean DEFAULT false,
  
  -- DERIVED price fields (computed on insert/update via trigger)
  effective_price         bigint,        -- normalized annual/sale price
  price_per_sqft          numeric,       -- effective_price / size
  
  -- Agent
  agent_public_profile_id integer REFERENCES pf_agents(public_profile_id),
  agent_name              text,
  created_by_profile_id   integer,
  
  -- Tier / Product
  tier_featured           jsonb,         -- {id, createdAt, expiresAt, renewalEnabled}
  tier_premium            jsonb,         -- same
  tier_standard           jsonb,         -- same
  current_tier            text,          -- derived: featured > premium > standard > none
  tier_expires_at         timestamptz,   -- derived
  
  -- Quality
  pf_quality_score        integer,       -- 0-100
  pf_quality_color        text,          -- red/yellow/green
  pf_quality_details      jsonb,         -- full breakdown
  
  -- State
  listing_stage           text,          -- draft/live/takendown/archived/etc
  listing_state_type      text,
  state_reasons           jsonb,
  is_live                 boolean DEFAULT false,
  published_at            timestamptz,
  
  -- Compliance & verification
  compliance              jsonb,
  rnpm                    jsonb,
  verification_status     text,
  
  -- Media
  image_count             integer DEFAULT 0,
  has_video               boolean DEFAULT false,
  
  -- CTS
  cts_priority            integer,
  
  -- Lifecycle
  days_live               integer,       -- derived: now() - published_at
  pf_created_at           timestamptz,
  pf_updated_at           timestamptz,
  last_synced_at          timestamptz DEFAULT now(),
  
  -- Tracking
  first_seen_at           timestamptz DEFAULT now(),
  is_deleted              boolean DEFAULT false,
  deleted_at              timestamptz
);

CREATE INDEX idx_listings_location ON pf_listings(location_id);
CREATE INDEX idx_listings_agent ON pf_listings(agent_public_profile_id);
CREATE INDEX idx_listings_tier ON pf_listings(current_tier);
CREATE INDEX idx_listings_type ON pf_listings(property_type);
CREATE INDEX idx_listings_category ON pf_listings(category);
CREATE INDEX idx_listings_bedrooms ON pf_listings(bedrooms);
CREATE INDEX idx_listings_is_live ON pf_listings(is_live);
CREATE INDEX idx_listings_reference ON pf_listings(reference);
CREATE INDEX idx_listings_stage ON pf_listings(listing_stage);
CREATE INDEX idx_listings_composite_segment ON pf_listings(location_id, category, property_type, bedrooms);

-- ============================================================
-- 4. LEADS
-- ============================================================
CREATE TABLE pf_leads (
  pf_lead_id          text PRIMARY KEY,
  listing_reference   text REFERENCES pf_listings(reference),
  lead_created_at     timestamptz,
  response_link       text,
  raw_payload         jsonb,
  synced_at           timestamptz DEFAULT now()
);

CREATE INDEX idx_leads_listing ON pf_leads(listing_reference);
CREATE INDEX idx_leads_created ON pf_leads(lead_created_at);

-- ============================================================
-- 5. CREDIT TRANSACTIONS (cost tracking)
-- ============================================================
CREATE TABLE pf_credit_transactions (
  pf_transaction_id   text PRIMARY KEY,
  transaction_type     text,
  credit_amount        numeric,
  listing_reference    text,        -- may be null for non-listing transactions
  transaction_at       timestamptz,
  raw_payload          jsonb,
  synced_at            timestamptz DEFAULT now()
);

CREATE INDEX idx_credits_listing ON pf_credit_transactions(listing_reference);
CREATE INDEX idx_credits_type ON pf_credit_transactions(transaction_type);
CREATE INDEX idx_credits_date ON pf_credit_transactions(transaction_at);

-- ============================================================
-- 6. CREDIT BALANCE SNAPSHOTS
-- ============================================================
CREATE TABLE pf_credit_snapshots (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  credit_balance  numeric,
  snapshot_at     timestamptz DEFAULT now()
);

-- ============================================================
-- 7. AGENT STATS SNAPSHOTS
-- ============================================================
CREATE TABLE pf_agent_stats (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  agent_public_profile_id integer REFERENCES pf_agents(public_profile_id),
  stats_payload           jsonb,
  snapshot_date           date DEFAULT CURRENT_DATE,
  synced_at               timestamptz DEFAULT now(),
  UNIQUE(agent_public_profile_id, snapshot_date)
);

-- ============================================================
-- 8. DAILY LISTING SNAPSHOTS (time-series for trend analysis)
-- ============================================================
CREATE TABLE listing_daily_snapshots (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pf_listing_id       text NOT NULL REFERENCES pf_listings(pf_listing_id),
  snapshot_date       date NOT NULL DEFAULT CURRENT_DATE,
  
  -- Snapshot of key metrics on this day
  total_leads         integer DEFAULT 0,       -- cumulative leads as of this date
  new_leads_today     integer DEFAULT 0,       -- leads received on this date
  pf_quality_score    integer,
  current_tier        text,
  effective_price     bigint,
  is_live             boolean,
  days_live           integer,
  
  -- Cumulative credit spend on this listing (sum of transactions)
  total_credits_spent numeric DEFAULT 0,
  
  -- Computed daily
  cpl                 numeric,                 -- total_credits_spent / NULLIF(total_leads, 0)
  
  created_at          timestamptz DEFAULT now(),
  UNIQUE(pf_listing_id, snapshot_date)
);

CREATE INDEX idx_snapshots_listing_date ON listing_daily_snapshots(pf_listing_id, snapshot_date);
CREATE INDEX idx_snapshots_date ON listing_daily_snapshots(snapshot_date);

-- ============================================================
-- 9. SEGMENT BENCHMARKS (precomputed nightly)
-- ============================================================
-- A "segment" = location + category + property_type + bedrooms
-- Fallback segments use fewer dimensions
CREATE TABLE segment_benchmarks (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  benchmark_date      date NOT NULL DEFAULT CURRENT_DATE,
  
  -- Segment definition (NULLs = wildcard/fallback level)
  location_id         integer,
  category            text,
  property_type       text,
  bedrooms            text,
  
  -- Segment level (for fallback hierarchy)
  -- 4 = full match, 3 = no bedrooms, 2 = no type, 1 = location+category only
  segment_level       integer NOT NULL DEFAULT 4,
  
  -- Stats
  listing_count       integer,
  
  -- Price benchmarks
  avg_price           numeric,
  median_price        numeric,
  min_price           numeric,
  max_price           numeric,
  avg_price_per_sqft  numeric,
  
  -- Lead benchmarks
  avg_leads           numeric,
  median_leads        numeric,
  p25_leads           numeric,
  p75_leads           numeric,
  avg_leads_per_day   numeric,
  
  -- CPL benchmarks
  avg_cpl             numeric,
  median_cpl          numeric,
  
  -- Quality benchmarks
  avg_quality_score   numeric,
  
  -- Tier distribution
  pct_featured        numeric,
  pct_premium         numeric,
  pct_standard        numeric,
  
  computed_at         timestamptz DEFAULT now(),
  UNIQUE(benchmark_date, location_id, category, property_type, bedrooms, segment_level)
);

CREATE INDEX idx_benchmarks_segment ON segment_benchmarks(location_id, category, property_type, bedrooms, segment_level);
CREATE INDEX idx_benchmarks_date ON segment_benchmarks(benchmark_date);

-- ============================================================
-- 10. SCORING CONFIG (versioned, adjustable)
-- ============================================================
CREATE TABLE scoring_config (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  version         integer NOT NULL DEFAULT 1,
  is_active       boolean DEFAULT true,
  
  -- Weight allocations (must sum to 100)
  w_lead_volume         numeric NOT NULL DEFAULT 20,
  w_lead_velocity       numeric NOT NULL DEFAULT 10,
  w_cost_efficiency     numeric NOT NULL DEFAULT 20,
  w_tier_roi            numeric NOT NULL DEFAULT 10,
  w_quality_score       numeric NOT NULL DEFAULT 10,
  w_price_position      numeric NOT NULL DEFAULT 10,
  w_listing_completeness numeric NOT NULL DEFAULT 5,
  w_freshness           numeric NOT NULL DEFAULT 5,
  w_competitive_position numeric NOT NULL DEFAULT 10,
  
  -- Thresholds
  zero_lead_days_threshold    integer DEFAULT 14,  -- days before zero-lead penalty kicks in
  zero_lead_penalty_pct       numeric DEFAULT 25,  -- percentage penalty
  min_segment_size            integer DEFAULT 3,   -- minimum peers for comparison
  freshness_decay_start_days  integer DEFAULT 30,  -- when freshness penalty begins
  freshness_decay_end_days    integer DEFAULT 180, -- when freshness hits 0
  
  -- Metadata
  created_at      timestamptz DEFAULT now(),
  created_by      text,
  notes           text,
  
  CONSTRAINT weights_sum_100 CHECK (
    w_lead_volume + w_lead_velocity + w_cost_efficiency + w_tier_roi +
    w_quality_score + w_price_position + w_listing_completeness +
    w_freshness + w_competitive_position = 100
  )
);

-- Insert default config
INSERT INTO scoring_config (
  version, is_active,
  w_lead_volume, w_lead_velocity, w_cost_efficiency, w_tier_roi,
  w_quality_score, w_price_position, w_listing_completeness,
  w_freshness, w_competitive_position,
  created_by, notes
) VALUES (
  1, true,
  20, 10, 20, 10, 10, 10, 5, 5, 10,
  'system', 'Initial default weights'
);

-- ============================================================
-- 11. LISTING SCORES (computed nightly)
-- ============================================================
CREATE TABLE listing_scores (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pf_listing_id           text NOT NULL REFERENCES pf_listings(pf_listing_id),
  score_date              date NOT NULL DEFAULT CURRENT_DATE,
  scoring_config_version  integer NOT NULL,
  
  -- Component scores (each 0-100)
  s_lead_volume           numeric,
  s_lead_velocity         numeric,
  s_cost_efficiency       numeric,
  s_tier_roi              numeric,
  s_quality_score         numeric,
  s_price_position        numeric,
  s_listing_completeness  numeric,
  s_freshness             numeric,
  s_competitive_position  numeric,
  
  -- Penalties applied
  zero_lead_penalty       numeric DEFAULT 0,
  
  -- Final weighted score (0-100)
  total_score             numeric NOT NULL,
  
  -- Which segment was used for peer comparison
  segment_level_used      integer,
  segment_listing_count   integer,
  
  -- Score band
  score_band              text,   -- S/A/B/C/D/F
  
  computed_at             timestamptz DEFAULT now(),
  UNIQUE(pf_listing_id, score_date)
);

CREATE INDEX idx_scores_listing ON listing_scores(pf_listing_id);
CREATE INDEX idx_scores_date ON listing_scores(score_date);
CREATE INDEX idx_scores_band ON listing_scores(score_band);
CREATE INDEX idx_scores_total ON listing_scores(total_score DESC);

-- ============================================================
-- 12. AGGREGATE SCORES (computed from listing scores)
-- ============================================================
CREATE TABLE aggregate_scores (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  score_date      date NOT NULL DEFAULT CURRENT_DATE,
  
  -- Dimension
  dimension_type  text NOT NULL,  -- 'agent' / 'location' / 'property_type' / 'developer' / 'tier'
  dimension_value text NOT NULL,  -- the ID or name
  
  -- Aggregation
  listing_count   integer,
  total_credits   numeric,
  total_leads     integer,
  avg_score       numeric,        -- cost-weighted average
  min_score       numeric,
  max_score       numeric,
  avg_cpl         numeric,
  
  -- Band distribution
  count_s         integer DEFAULT 0,
  count_a         integer DEFAULT 0,
  count_b         integer DEFAULT 0,
  count_c         integer DEFAULT 0,
  count_d         integer DEFAULT 0,
  count_f         integer DEFAULT 0,
  
  computed_at     timestamptz DEFAULT now(),
  UNIQUE(score_date, dimension_type, dimension_value)
);

CREATE INDEX idx_agg_dimension ON aggregate_scores(dimension_type, dimension_value);
CREATE INDEX idx_agg_date ON aggregate_scores(score_date);

-- ============================================================
-- 13. RECOMMENDATIONS (generated nightly)
-- ============================================================
CREATE TABLE recommendations (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pf_listing_id       text NOT NULL REFERENCES pf_listings(pf_listing_id),
  recommendation_date date NOT NULL DEFAULT CURRENT_DATE,
  
  -- Recommendation type
  action_type         text NOT NULL,  -- 'REMOVE' / 'DOWNGRADE' / 'UPGRADE' / 'WATCHLIST' / 'BOOST' / 'IMPROVE_QUALITY' / 'REPRICE'
  priority            text NOT NULL,  -- 'CRITICAL' / 'HIGH' / 'MEDIUM' / 'LOW'
  
  -- Reasoning (human-readable)
  reason_summary      text NOT NULL,
  reason_details      jsonb,          -- structured reasoning data
  
  -- Status
  status              text DEFAULT 'PENDING',  -- PENDING / APPROVED / REJECTED / EXECUTED
  reviewed_by         text,
  reviewed_at         timestamptz,
  notes               text,
  
  created_at          timestamptz DEFAULT now(),
  UNIQUE(pf_listing_id, recommendation_date, action_type)
);

CREATE INDEX idx_recs_listing ON recommendations(pf_listing_id);
CREATE INDEX idx_recs_status ON recommendations(status);
CREATE INDEX idx_recs_action ON recommendations(action_type);
CREATE INDEX idx_recs_priority ON recommendations(priority);

-- ============================================================
-- 14. SYNC LOG (audit trail)
-- ============================================================
CREATE TABLE sync_log (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sync_type       text NOT NULL,     -- 'listings' / 'leads' / 'credits' / 'agents' / 'locations' / 'scoring' / 'benchmarks'
  started_at      timestamptz DEFAULT now(),
  completed_at    timestamptz,
  status          text DEFAULT 'RUNNING',  -- RUNNING / SUCCESS / PARTIAL / FAILED
  records_synced  integer DEFAULT 0,
  records_created integer DEFAULT 0,
  records_updated integer DEFAULT 0,
  error_message   text,
  metadata        jsonb
);

CREATE INDEX idx_sync_type ON sync_log(sync_type);
CREATE INDEX idx_sync_status ON sync_log(status);

-- ============================================================
-- 15. TRIGGER: Auto-compute derived fields on listing upsert
-- ============================================================
CREATE OR REPLACE FUNCTION fn_listing_derived_fields()
RETURNS TRIGGER AS $$
BEGIN
  -- Effective price: normalize to comparable annual/sale figure
  NEW.effective_price := COALESCE(
    NEW.price_sale,
    NEW.price_yearly,
    NEW.price_monthly * 12,
    NEW.price_weekly * 52,
    NEW.price_daily * 365
  );
  
  -- Price per sqft
  IF NEW.size_sqft IS NOT NULL AND NEW.size_sqft > 0 AND NEW.effective_price IS NOT NULL THEN
    NEW.price_per_sqft := ROUND(NEW.effective_price::numeric / NEW.size_sqft, 2);
  ELSE
    NEW.price_per_sqft := NULL;
  END IF;
  
  -- Current tier (highest active)
  IF NEW.tier_featured IS NOT NULL 
     AND (NEW.tier_featured->>'expiresAt')::timestamptz > now() THEN
    NEW.current_tier := 'featured';
    NEW.tier_expires_at := (NEW.tier_featured->>'expiresAt')::timestamptz;
  ELSIF NEW.tier_premium IS NOT NULL 
     AND (NEW.tier_premium->>'expiresAt')::timestamptz > now() THEN
    NEW.current_tier := 'premium';
    NEW.tier_expires_at := (NEW.tier_premium->>'expiresAt')::timestamptz;
  ELSIF NEW.tier_standard IS NOT NULL 
     AND (NEW.tier_standard->>'expiresAt')::timestamptz > now() THEN
    NEW.current_tier := 'standard';
    NEW.tier_expires_at := (NEW.tier_standard->>'expiresAt')::timestamptz;
  ELSE
    NEW.current_tier := 'none';
    NEW.tier_expires_at := NULL;
  END IF;
  
  -- Days live
  IF NEW.published_at IS NOT NULL AND NEW.is_live THEN
    NEW.days_live := EXTRACT(DAY FROM now() - NEW.published_at)::integer;
  ELSE
    NEW.days_live := NULL;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_listing_derived
  BEFORE INSERT OR UPDATE ON pf_listings
  FOR EACH ROW EXECUTE FUNCTION fn_listing_derived_fields();

-- ============================================================
-- 16. VIEWS — Dashboard query acceleration
-- ============================================================

-- Active portfolio overview
CREATE OR REPLACE VIEW v_portfolio_overview AS
SELECT
  l.pf_listing_id,
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
  loc.name AS location_name,
  COALESCE(lead_counts.total_leads, 0) AS total_leads,
  COALESCE(lead_counts.leads_7d, 0) AS leads_7d,
  COALESCE(lead_counts.leads_30d, 0) AS leads_30d,
  COALESCE(credit_sums.total_credits, 0) AS total_credits_spent,
  CASE 
    WHEN COALESCE(lead_counts.total_leads, 0) > 0 
    THEN ROUND(COALESCE(credit_sums.total_credits, 0) / lead_counts.total_leads, 2)
    ELSE NULL 
  END AS cpl,
  ls.total_score,
  ls.score_band
FROM pf_listings l
LEFT JOIN pf_locations loc ON l.location_id = loc.location_id
LEFT JOIN LATERAL (
  SELECT 
    COUNT(*) AS total_leads,
    COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '7 days') AS leads_7d,
    COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '30 days') AS leads_30d
  FROM pf_leads 
  WHERE listing_reference = l.reference
) lead_counts ON true
LEFT JOIN LATERAL (
  SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
  FROM pf_credit_transactions
  WHERE listing_reference = l.reference
) credit_sums ON true
LEFT JOIN LATERAL (
  SELECT total_score, score_band
  FROM listing_scores
  WHERE pf_listing_id = l.pf_listing_id
  ORDER BY score_date DESC
  LIMIT 1
) ls ON true
WHERE l.is_deleted = false;

-- Agent leaderboard
CREATE OR REPLACE VIEW v_agent_leaderboard AS
SELECT
  a.public_profile_id,
  a.first_name || ' ' || a.last_name AS agent_name,
  a.status,
  a.is_super_agent,
  COUNT(l.pf_listing_id) FILTER (WHERE l.is_live) AS live_listings,
  COUNT(l.pf_listing_id) AS total_listings,
  AVG(l.pf_quality_score) FILTER (WHERE l.is_live) AS avg_quality_score,
  SUM(COALESCE(lc.lead_count, 0)) AS total_leads,
  SUM(COALESCE(cc.credit_total, 0)) AS total_credits_spent,
  CASE
    WHEN SUM(COALESCE(lc.lead_count, 0)) > 0
    THEN ROUND(SUM(COALESCE(cc.credit_total, 0)) / SUM(lc.lead_count), 2)
    ELSE NULL
  END AS avg_cpl
FROM pf_agents a
LEFT JOIN pf_listings l ON a.public_profile_id = l.agent_public_profile_id AND l.is_deleted = false
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS lead_count
  FROM pf_leads WHERE listing_reference = l.reference
) lc ON true
LEFT JOIN LATERAL (
  SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS credit_total
  FROM pf_credit_transactions WHERE listing_reference = l.reference
) cc ON true
GROUP BY a.public_profile_id, a.first_name, a.last_name, a.status, a.is_super_agent;

-- ============================================================
-- 17. ROW LEVEL SECURITY
-- ============================================================
ALTER TABLE pf_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE pf_leads ENABLE ROW LEVEL SECURITY;
ALTER TABLE pf_credit_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE listing_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE recommendations ENABLE ROW LEVEL SECURITY;
ALTER TABLE aggregate_scores ENABLE ROW LEVEL SECURITY;

-- Allow authenticated users to read all data (internal team only)
CREATE POLICY "Authenticated read all" ON pf_listings FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read all" ON pf_leads FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read all" ON pf_credit_transactions FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read all" ON listing_scores FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read all" ON recommendations FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated read all" ON aggregate_scores FOR SELECT TO authenticated USING (true);

-- Service role can do everything (for Edge Functions)
CREATE POLICY "Service full access" ON pf_listings FOR ALL TO service_role USING (true);
CREATE POLICY "Service full access" ON pf_leads FOR ALL TO service_role USING (true);
CREATE POLICY "Service full access" ON pf_credit_transactions FOR ALL TO service_role USING (true);
CREATE POLICY "Service full access" ON listing_scores FOR ALL TO service_role USING (true);
CREATE POLICY "Service full access" ON recommendations FOR ALL TO service_role USING (true);
CREATE POLICY "Service full access" ON aggregate_scores FOR ALL TO service_role USING (true);
[object Object]6. SYNC ENGINE (Edge Functions)
6.1 Sync Architecture
Five Edge Functions, orchestrated by pg_cron:
FunctionScheduleWhat it doessync-listingsEvery 4 hoursPaginate all listings, upsert into pf_listingssync-leadsEvery 2 hoursPaginate all leads, upsert into pf_leadssync-creditsEvery 6 hoursPull balance + transactions, upsertsync-agentsDaily 01:00 UTCPull all users, upsert agentsrun-scoring-pipelineDaily 03:00 UTCSnapshots → Benchmarks → Scores → Aggregates → Recommendations
6.2 Edge Function: sync-listings
Pseudocode:
1. GET JWT from Railway webhook
2. Log sync_log entry (type='listings', status='RUNNING')
3. page = 1, hasMore = true
4. WHILE hasMore:
   a. GET /v1/listings?page={page}&perPage=100&draft=false
   b. For each listing in response:
      - Map all fields per Section 4.1 mapping
      - UPSERT into pf_listings ON CONFLICT (pf_listing_id)
      - Track created/updated counts
   c. If results < 100: hasMore = false
   d. page++
   e. If page > 200: break (safety valve)
5. REPEAT for draft=true (to catch drafts)
6. Mark listings not seen in this sync as potentially deleted:
   - Any listing where last_synced_at < sync_start AND is_live = true
   - Set is_deleted = true, deleted_at = now()
7. Update sync_log: status='SUCCESS', records_synced, records_created, records_updated
Pagination safety: PF API max perPage is 100. At 10,000 listings that's 100 pages. Build in retry per page (3 attempts with backoff).
Token refresh: If any API call returns 401, refresh JWT from Railway webhook and retry.
6.3 Edge Function: sync-leads
Pseudocode:
1. GET JWT
2. Log sync_log
3. page = 1
4. WHILE hasMore:
   a. GET /v1/leads?page={page}&perPage=50
   b. For each lead:
      - Extract pf_lead_id (from response)
      - Extract listing.reference
      - UPSERT into pf_leads ON CONFLICT (pf_lead_id)
   c. If results < 50: hasMore = false
   d. page++
5. Update sync_log
6.4 Edge Function: sync-credits
Pseudocode:
1. GET JWT
2. GET /v1/credits/balance → INSERT into pf_credit_snapshots
3. Paginate GET /v1/credits/transactions:
   - UPSERT each transaction into pf_credit_transactions
   - Try to extract listing_reference from raw_payload if present
4. Update sync_log
6.5 Edge Function: run-scoring-pipeline
This is the brain. Runs as a single function that calls Postgres functions in sequence:
1. CALL fn_build_daily_snapshots()
2. CALL fn_build_segment_benchmarks()
3. CALL fn_score_all_listings()
4. CALL fn_build_aggregate_scores()
5. CALL fn_generate_recommendations()
6. Log completion
All five functions are defined in Section 7 and Section 8.
6.6 pg_cron Setup
-- Schedule sync functions via pg_net calling Edge Functions
-- (These call Supabase Edge Functions via HTTP)

SELECT cron.schedule(
  'sync-listings',
  '0 */4 * * *',  -- every 4 hours
  $$SELECT net.http_post(
    url := 'https://ynomeynlpfvtdopctsvg.supabase.co/functions/v1/sync-listings',
    headers := '{"Authorization": "Bearer SERVICE_ROLE_KEY", "Content-Type": "application/json"}'::jsonb
  )$$
);

SELECT cron.schedule(
  'sync-leads',
  '0 */2 * * *',  -- every 2 hours
  $$SELECT net.http_post(
    url := 'https://ynomeynlpfvtdopctsvg.supabase.co/functions/v1/sync-leads',
    headers := '{"Authorization": "Bearer SERVICE_ROLE_KEY", "Content-Type": "application/json"}'::jsonb
  )$$
);

SELECT cron.schedule(
  'sync-credits',
  '0 */6 * * *',  -- every 6 hours
  $$SELECT net.http_post(
    url := 'https://ynomeynlpfvtdopctsvg.supabase.co/functions/v1/sync-credits',
    headers := '{"Authorization": "Bearer SERVICE_ROLE_KEY", "Content-Type": "application/json"}'::jsonb
  )$$
);

SELECT cron.schedule(
  'sync-agents',
  '0 1 * * *',  -- daily at 01:00 UTC
  $$SELECT net.http_post(
    url := 'https://ynomeynlpfvtdopctsvg.supabase.co/functions/v1/sync-agents',
    headers := '{"Authorization": "Bearer SERVICE_ROLE_KEY", "Content-Type": "application/json"}'::jsonb
  )$$
);

SELECT cron.schedule(
  'run-scoring',
  '0 3 * * *',  -- daily at 03:00 UTC
  $$SELECT net.http_post(
    url := 'https://ynomeynlpfvtdopctsvg.supabase.co/functions/v1/run-scoring-pipeline',
    headers := '{"Authorization": "Bearer SERVICE_ROLE_KEY", "Content-Type": "application/json"}'::jsonb
  )$$
);
[object Object]7. SCORING ENGINE — THE BRAIN
7.1 Philosophy
Every listing gets a score from 0-100. The score answers ONE question: "How well is this listing performing relative to what it costs and what its peers are doing?"
This is NOT a quality score (PF already gives us that). This is a performance-efficiency score.
7.2 Score Components (9 Dimensions)
Component 1: Lead Volume (weight: 20)
Question: How many leads has this listing generated?
Metric: total_leads in last 30 days
Comparison: percentile rank within segment peers
Score: percentile * 100 (capped at 100)
If 0 leads and days_live >= threshold: apply zero_lead_penalty
Component 2: Lead Velocity (weight: 10)
Question: Is lead generation accelerating or decelerating?
Metric: leads_last_7d / leads_prior_7d (week-over-week)
Scoring:
  - velocity > 1.5: 100 (accelerating strongly)
  - velocity 1.0-1.5: 70-100 (linear interpolation)
  - velocity 0.5-1.0: 40-70
  - velocity 0.0-0.5: 10-40
  - velocity 0.0 (no leads): 0
  - If listing < 14 days old: neutral score of 50
Component 3: Cost Efficiency (weight: 20)
Question: Is the CPL competitive?
Metric: listing CPL vs segment median CPL
If listing has 0 leads:
  - If credits_spent > 0: score = 0 (burning money, no return)
  - If credits_spent = 0: score = 50 (neutral — no cost, no leads)
If listing has leads:
  - ratio = segment_median_cpl / listing_cpl
  - If ratio >= 2.0: 100 (CPL is half the median — excellent)
  - If ratio 1.0-2.0: 60-100 (linear)
  - If ratio 0.5-1.0: 30-60 (below average)
  - If ratio < 0.5: 0-30 (terrible CPL)
Component 4: Tier ROI (weight: 10)
Question: Is the tier upgrade justified by lead performance?
Tier cost multiplier (approximate):
  featured: 3x standard
  premium: 2x standard
  standard: 1x
  none: 0x (not on portal)

Expected lead multiplier for tier to be justified:
  featured: should generate >= 2.5x the leads of standard peers
  premium: should generate >= 1.8x the leads of standard peers
  standard: baseline

Metric: actual_lead_multiplier / expected_lead_multiplier
  - >= 1.0: the tier is justified, score 60-100
  - 0.5-1.0: questionable, score 30-60
  - < 0.5: tier is wasting money, score 0-30

If tier = 'none' or 'standard': score = 50 (neutral)
Component 5: PF Quality Score (weight: 10)
Question: Does PF think this listing is well-constructed?
Score: pf_quality_score (directly, it's already 0-100)
If NULL: score = 50 (neutral)
Component 6: Price Position (weight: 10)
Question: Is the listing priced competitively within its segment?
Metric: where does price_per_sqft sit relative to segment?
  - Between p25 and p75: 100 (well-positioned)
  - Between p10-p25 or p75-p90: 60 (slightly off)
  - Below p10 or above p90: 30 (outlier — suspiciously cheap or overpriced)
  - If price_on_request = true: 40 (hiding price is generally bad for leads)

Special case: if category = 'commercial' and price_type = 'sale', 
use effective_price directly since sqft pricing is less meaningful
Component 7: Listing Completeness (weight: 5)
Question: Is the listing well-filled-out?
Check these fields, each worth points:
  - Has >= 5 images: 15 pts
  - Has >= 10 images: +10 pts (bonus)
  - Has video: 15 pts
  - Has amenities (>= 3): 10 pts
  - Has floor number (if apartment): 10 pts
  - Has developer name: 5 pts
  - Has both AR and EN title: 10 pts
  - Has both AR and EN description: 10 pts
  - Has parking info: 5 pts
  - Has built-up area (if villa): 5 pts
  - Has furnished status: 5 pts
  
Total possible = 100, normalize to 0-100
Component 8: Freshness (weight: 5)
Question: How long has this listing been live without tier refresh?
If days_live <= freshness_decay_start_days (default 30):
  score = 100
If days_live >= freshness_decay_end_days (default 180):
  score = 0
Else:
  Linear decay from 100 to 0 between start and end days

Rationale: Stale listings get pushed down by PF's algorithm.
Old listings that are still generating leads will be saved by the 
lead volume component. This component just flags staleness.
Component 9: Competitive Position (weight: 10)
Question: How does this listing rank against its direct peers?
Peers = same location + category + property_type + bedrooms with active listings
If peer group < min_segment_size: fall back to broader segment

Metrics combined (equal sub-weight):
  a. Lead rank: percentile within peers by total_leads → 0-100
  b. Price rank: how close to median price → 0-100 (closest = best)
  c. Quality rank: percentile by pf_quality_score → 0-100

competitive_score = (lead_rank + price_rank + quality_rank) / 3
7.3 Final Score Calculation
raw_score = (
  s_lead_volume * w_lead_volume +
  s_lead_velocity * w_lead_velocity +
  s_cost_efficiency * w_cost_efficiency +
  s_tier_roi * w_tier_roi +
  s_quality_score * w_quality_score +
  s_price_position * w_price_position +
  s_listing_completeness * w_listing_completeness +
  s_freshness * w_freshness +
  s_competitive_position * w_competitive_position
) / 100

-- Apply zero-lead penalty
IF total_leads = 0 AND days_live >= zero_lead_days_threshold:
  final_score = raw_score * (1 - zero_lead_penalty_pct / 100)
ELSE:
  final_score = raw_score

-- Clamp
final_score = GREATEST(0, LEAST(100, ROUND(final_score, 1)))
7.4 Score Bands
BandRangeMeaningS85-100Star performer — protect and potentially boostA70-84Strong — maintain current strategyB55-69Average — room for optimizationC40-54Underperforming — needs interventionD25-39Poor — downgrade or restructure candidateF0-24Failing — remove candidate
7.5 Segment Benchmark Computation (Postgres Function)
CREATE OR REPLACE FUNCTION fn_build_segment_benchmarks()
RETURNS void AS $$
BEGIN
  -- Clear today's benchmarks
  DELETE FROM segment_benchmarks WHERE benchmark_date = CURRENT_DATE;
  
  -- Level 4: Full segment (location + category + type + bedrooms)
  INSERT INTO segment_benchmarks (
    benchmark_date, location_id, category, property_type, bedrooms, segment_level,
    listing_count, avg_price, median_price, min_price, max_price, avg_price_per_sqft,
    avg_leads, median_leads, p25_leads, p75_leads, avg_leads_per_day,
    avg_cpl, median_cpl, avg_quality_score,
    pct_featured, pct_premium, pct_standard
  )
  SELECT
    CURRENT_DATE,
    l.location_id,
    l.category,
    l.property_type,
    l.bedrooms,
    4,
    COUNT(*),
    AVG(l.effective_price),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY l.effective_price),
    MIN(l.effective_price),
    MAX(l.effective_price),
    AVG(l.price_per_sqft),
    AVG(lc.lead_count),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lc.lead_count),
    CASE WHEN AVG(l.days_live) > 0 THEN AVG(lc.lead_count::numeric / l.days_live) ELSE 0 END,
    AVG(CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END),
    PERCENTILE_CONT(0.5) WITHIN GROUP (
      ORDER BY CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END
    ),
    AVG(l.pf_quality_score),
    COUNT(*) FILTER (WHERE l.current_tier = 'featured')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'premium')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'standard')::numeric / NULLIF(COUNT(*), 0) * 100
  FROM pf_listings l
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS lead_count FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS credit_total
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_live = true AND l.is_deleted = false
  GROUP BY l.location_id, l.category, l.property_type, l.bedrooms
  HAVING COUNT(*) >= 1;
  
  -- Level 3: No bedrooms (location + category + type)
  INSERT INTO segment_benchmarks (
    benchmark_date, location_id, category, property_type, bedrooms, segment_level,
    listing_count, avg_price, median_price, min_price, max_price, avg_price_per_sqft,
    avg_leads, median_leads, p25_leads, p75_leads, avg_leads_per_day,
    avg_cpl, median_cpl, avg_quality_score,
    pct_featured, pct_premium, pct_standard
  )
  SELECT
    CURRENT_DATE, l.location_id, l.category, l.property_type, NULL, 3,
    COUNT(*),
    AVG(l.effective_price),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY l.effective_price),
    MIN(l.effective_price), MAX(l.effective_price),
    AVG(l.price_per_sqft),
    AVG(lc.lead_count),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lc.lead_count),
    CASE WHEN AVG(l.days_live) > 0 THEN AVG(lc.lead_count::numeric / l.days_live) ELSE 0 END,
    AVG(CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END),
    PERCENTILE_CONT(0.5) WITHIN GROUP (
      ORDER BY CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END
    ),
    AVG(l.pf_quality_score),
    COUNT(*) FILTER (WHERE l.current_tier = 'featured')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'premium')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'standard')::numeric / NULLIF(COUNT(*), 0) * 100
  FROM pf_listings l
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS lead_count FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS credit_total
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_live = true AND l.is_deleted = false
  GROUP BY l.location_id, l.category, l.property_type
  HAVING COUNT(*) >= 1;
  
  -- Level 2: location + category only
  INSERT INTO segment_benchmarks (
    benchmark_date, location_id, category, property_type, bedrooms, segment_level,
    listing_count, avg_price, median_price, min_price, max_price, avg_price_per_sqft,
    avg_leads, median_leads, p25_leads, p75_leads, avg_leads_per_day,
    avg_cpl, median_cpl, avg_quality_score,
    pct_featured, pct_premium, pct_standard
  )
  SELECT
    CURRENT_DATE, l.location_id, l.category, NULL, NULL, 2,
    COUNT(*),
    AVG(l.effective_price),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY l.effective_price),
    MIN(l.effective_price), MAX(l.effective_price),
    AVG(l.price_per_sqft),
    AVG(lc.lead_count),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY lc.lead_count),
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lc.lead_count),
    CASE WHEN AVG(l.days_live) > 0 THEN AVG(lc.lead_count::numeric / l.days_live) ELSE 0 END,
    AVG(CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END),
    PERCENTILE_CONT(0.5) WITHIN GROUP (
      ORDER BY CASE WHEN lc.lead_count > 0 THEN cc.credit_total / lc.lead_count ELSE NULL END
    ),
    AVG(l.pf_quality_score),
    COUNT(*) FILTER (WHERE l.current_tier = 'featured')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'premium')::numeric / NULLIF(COUNT(*), 0) * 100,
    COUNT(*) FILTER (WHERE l.current_tier = 'standard')::numeric / NULLIF(COUNT(*), 0) * 100
  FROM pf_listings l
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS lead_count FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS credit_total
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_live = true AND l.is_deleted = false
  GROUP BY l.location_id, l.category
  HAVING COUNT(*) >= 1;

END;
$$ LANGUAGE plpgsql;
7.6 Daily Snapshot Builder
CREATE OR REPLACE FUNCTION fn_build_daily_snapshots()
RETURNS void AS $$
BEGIN
  INSERT INTO listing_daily_snapshots (
    pf_listing_id, snapshot_date, total_leads, new_leads_today,
    pf_quality_score, current_tier, effective_price, is_live, days_live,
    total_credits_spent, cpl
  )
  SELECT
    l.pf_listing_id,
    CURRENT_DATE,
    COALESCE(lc.total_leads, 0),
    COALESCE(lc.new_today, 0),
    l.pf_quality_score,
    l.current_tier,
    l.effective_price,
    l.is_live,
    l.days_live,
    COALESCE(cc.total_credits, 0),
    CASE WHEN COALESCE(lc.total_leads, 0) > 0
      THEN ROUND(COALESCE(cc.total_credits, 0) / lc.total_leads, 2)
      ELSE NULL
    END
  FROM pf_listings l
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) AS total_leads,
      COUNT(*) FILTER (WHERE lead_created_at::date = CURRENT_DATE) AS new_today
    FROM pf_leads WHERE listing_reference = l.reference
  ) lc ON true
  LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
    FROM pf_credit_transactions WHERE listing_reference = l.reference
  ) cc ON true
  WHERE l.is_deleted = false AND l.is_live = true
  ON CONFLICT (pf_listing_id, snapshot_date) DO UPDATE SET
    total_leads = EXCLUDED.total_leads,
    new_leads_today = EXCLUDED.new_leads_today,
    pf_quality_score = EXCLUDED.pf_quality_score,
    current_tier = EXCLUDED.current_tier,
    effective_price = EXCLUDED.effective_price,
    is_live = EXCLUDED.is_live,
    days_live = EXCLUDED.days_live,
    total_credits_spent = EXCLUDED.total_credits_spent,
    cpl = EXCLUDED.cpl;
END;
$$ LANGUAGE plpgsql;
[object Object]8. RECOMMENDATION ENGINE (Rule-Based)
8.1 Rules
CREATE OR REPLACE FUNCTION fn_generate_recommendations()
RETURNS void AS $$
DECLARE
  cfg scoring_config;
  r RECORD;
BEGIN
  SELECT * INTO cfg FROM scoring_config WHERE is_active = true ORDER BY version DESC LIMIT 1;
  
  -- Clear today's recommendations
  DELETE FROM recommendations WHERE recommendation_date = CURRENT_DATE;
  
  FOR r IN
    SELECT
      l.pf_listing_id,
      l.reference,
      l.current_tier,
      l.days_live,
      l.pf_quality_score,
      l.pf_quality_color,
      l.effective_price,
      l.price_per_sqft,
      l.agent_name,
      l.location_id,
      l.property_type,
      l.bedrooms,
      l.image_count,
      ls.total_score,
      ls.score_band,
      ls.s_lead_volume,
      ls.s_cost_efficiency,
      ls.s_tier_roi,
      ls.s_quality_score,
      ls.s_freshness,
      COALESCE(lc.total_leads, 0) AS total_leads,
      COALESCE(lc.leads_30d, 0) AS leads_30d,
      COALESCE(cc.total_credits, 0) AS total_credits
    FROM pf_listings l
    LEFT JOIN LATERAL (
      SELECT total_score, score_band, s_lead_volume, s_cost_efficiency,
             s_tier_roi, s_quality_score, s_freshness
      FROM listing_scores WHERE pf_listing_id = l.pf_listing_id
      ORDER BY score_date DESC LIMIT 1
    ) ls ON true
    LEFT JOIN LATERAL (
      SELECT COUNT(*) AS total_leads,
        COUNT(*) FILTER (WHERE lead_created_at >= now() - interval '30 days') AS leads_30d
      FROM pf_leads WHERE listing_reference = l.reference
    ) lc ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(ABS(credit_amount)), 0) AS total_credits
      FROM pf_credit_transactions WHERE listing_reference = l.reference
    ) cc ON true
    WHERE l.is_live = true AND l.is_deleted = false
  LOOP
  
    -- RULE 1: REMOVE — F-band listings with high spend and zero leads
    IF r.score_band = 'F' AND r.total_leads = 0 AND r.total_credits > 0 AND r.days_live > 21 THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'REMOVE', 'CRITICAL',
        format('Score %s (F-band), %s days live, %s credits spent, 0 leads. Complete waste of budget.',
          r.total_score, r.days_live, r.total_credits),
        jsonb_build_object('score', r.total_score, 'days_live', r.days_live, 'credits', r.total_credits, 'leads', 0)
      ) ON CONFLICT DO NOTHING;
    END IF;
    
    -- RULE 2: DOWNGRADE — D-band listings on premium/featured tier
    IF r.score_band IN ('D', 'F') AND r.current_tier IN ('featured', 'premium') THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'DOWNGRADE', 'HIGH',
        format('Score %s (%s-band) but on %s tier. Tier ROI score: %s. Downgrade to save credits.',
          r.total_score, r.score_band, r.current_tier, r.s_tier_roi),
        jsonb_build_object('score', r.total_score, 'tier', r.current_tier, 'tier_roi', r.s_tier_roi)
      ) ON CONFLICT DO NOTHING;
    END IF;
    
    -- RULE 3: UPGRADE — S-band listings on standard tier
    IF r.score_band = 'S' AND r.current_tier = 'standard' THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'UPGRADE', 'HIGH',
        format('Score %s (S-band) on standard tier. %s leads in 30d. High performer — upgrade could amplify.',
          r.total_score, r.leads_30d),
        jsonb_build_object('score', r.total_score, 'leads_30d', r.leads_30d)
      ) ON CONFLICT DO NOTHING;
    END IF;
    
    -- RULE 4: BOOST — A-band with good velocity on standard
    IF r.score_band = 'A' AND r.current_tier = 'standard' AND r.leads_30d >= 3 THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'BOOST', 'MEDIUM',
        format('Score %s (A-band), %s leads in 30d on standard. Consider premium upgrade.',
          r.total_score, r.leads_30d),
        jsonb_build_object('score', r.total_score, 'leads_30d', r.leads_30d)
      ) ON CONFLICT DO NOTHING;
    END IF;
    
    -- RULE 5: WATCHLIST — C-band listings (not bad enough to remove but need attention)
    IF r.score_band = 'C' AND r.days_live > 14 THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'WATCHLIST', 'LOW',
        format('Score %s (C-band). Lead volume score: %s, cost efficiency: %s. Monitor for 7 days.',
          r.total_score, r.s_lead_volume, r.s_cost_efficiency),
        jsonb_build_object('score', r.total_score, 's_lead_volume', r.s_lead_volume, 's_cost_efficiency', r.s_cost_efficiency)
      ) ON CONFLICT DO NOTHING;
    END IF;
    
    -- RULE 6: IMPROVE_QUALITY — Low PF quality score
    IF r.pf_quality_score IS NOT NULL AND r.pf_quality_score < 40 THEN
      INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
      VALUES (r.pf_listing_id, CURRENT_DATE, 'IMPROVE_QUALITY', 'MEDIUM',
        format('PF Quality Score %s (%s). Low quality hurts ranking. Check images (%s), descriptions, and completeness.',
          r.pf_quality_score, r.pf_quality_color, r.image_count),
        jsonb_build_object('quality_score', r.pf_quality_score, 'image_count', r.image_count)
      ) ON CONFLICT DO NOTHING;
    END IF;
    
    -- RULE 7: REPRICE — Price is an outlier vs segment
    -- (Check if price_per_sqft is > 90th percentile or < 10th percentile in segment)
    IF r.price_per_sqft IS NOT NULL THEN
      DECLARE
        seg_avg numeric;
        seg_min numeric;
        seg_max numeric;
      BEGIN
        SELECT avg_price_per_sqft, min_price, max_price INTO seg_avg, seg_min, seg_max
        FROM segment_benchmarks
        WHERE benchmark_date = CURRENT_DATE
          AND location_id = r.location_id
          AND category IS NOT NULL
          AND property_type = r.property_type
          AND (bedrooms = r.bedrooms OR segment_level <= 3)
        ORDER BY segment_level DESC
        LIMIT 1;
        
        IF seg_avg IS NOT NULL AND r.price_per_sqft > seg_avg * 1.5 THEN
          INSERT INTO recommendations (pf_listing_id, recommendation_date, action_type, priority, reason_summary, reason_details)
          VALUES (r.pf_listing_id, CURRENT_DATE, 'REPRICE', 'MEDIUM',
            format('Price/sqft (%s) is >50%% above segment average (%s). Overpriced listings get fewer leads.',
              r.price_per_sqft, ROUND(seg_avg, 2)),
            jsonb_build_object('listing_ppsf', r.price_per_sqft, 'segment_avg_ppsf', seg_avg)
          ) ON CONFLICT DO NOTHING;
        END IF;
      END;
    END IF;
    
  END LOOP;
END;
$$ LANGUAGE plpgsql;
[object Object]9. DASHBOARD — UI SPEC
9.1 Tech
React + Vite + Tailwind CSS + Recharts + Supabase JS Client.
Deploy to Netlify (you already have Netlify connected).
9.2 Auth
Supabase Auth with email/password. Create accounts manually for team members.
No public signup.
9.3 Pages
Page 1: Portfolio Overview (Default Landing)
Top Stats Bar (4 cards):
Total Live Listings | Trend arrow (vs 7 days ago)
Total Leads (30d) | Trend arrow
Average CPL | Trend arrow
Credit Balance | Burn rate (credits/day)
Score Distribution Chart (horizontal stacked bar):
S / A / B / C / D / F bands with counts and percentages
Listings Table (sortable, filterable, searchable): Columns: Reference | Type | Bedrooms | Location | Price | Tier | Quality | Leads (30d) | CPL | Score | Band | Agent | Days Live
Filters: Location, Property Type, Bedrooms, Tier, Score Band, Agent
Sort: Any column
Search: By reference or location name
Click row → Listing Detail page
Page 2: Listing Detail
Header: Reference, address, type, bedrooms, bathrooms, size, price, tier badge, score badge
Score Breakdown Card: Spider/radar chart showing all 9 component scores. Below: table with component name, weight, raw score, weighted contribution.
Lead Timeline: Line chart of daily leads over time (from listing_daily_snapshots)
Cost Timeline: Line chart of cumulative credit spend over time
CPL Trend: CPL over time (line chart)
Segment Comparison Card: This listing vs segment averages (table):
Price vs avg/median
Leads vs avg/median
CPL vs avg/median
Quality vs avg
Days live vs avg
Active Recommendations: Cards for any pending recommendations on this listing
Peer Listings: Table of other listings in same segment, sorted by score
Page 3: Agent Leaderboard
Table: Agent Name | Live Listings | Total Leads | Avg CPL | Avg Score | Score Band Distribution (mini bar) | Total Credits Spent
Click agent → filtered portfolio view for that agent
Page 4: Area Analysis
Map view (optional V2) or Table: Location | Live Listings | Avg Score | Total Leads | Avg CPL | Best Performing Listing | Worst Performing Listing
Page 5: Tier Analysis
Comparison cards (Featured vs Premium vs Standard):
Listing count
Avg leads per listing
Avg CPL
Avg score
Lead multiplier vs standard (is Featured actually 3x better?)
Scatter plot: Credits spent (x) vs Leads generated (y), colored by tier
Page 6: Recommendations Hub
Tabs: Critical | High | Medium | Low | All
Cards: Each recommendation shows:
Listing reference + link to detail
Action type badge (REMOVE / DOWNGRADE / UPGRADE / etc)
Priority badge
Reason summary
Approve / Reject buttons (update status in DB)
Summary stats: Total pending, by type, estimated credit savings from downgrades/removals
Page 7: Cost Center
Credit burn chart: Daily credit spend over time (bar chart) Credit balance trend: Line chart from pf_credit_snapshotsTop spending listings: Table sorted by total credits spent Zero-lead high-spend: Listings with >X credits spent and 0 leads
Page 8: Sync Status (Admin)
Table: Each sync type, last run time, status, records synced, errors Manual trigger buttons: Force sync for each type
[object Object]10. EDGE CASES & RULES
10.1 New Listings (< 7 days live)
Freshness score = 100
Lead velocity = neutral (50)
Competitive position = neutral (50)
All other components scored normally
Do NOT generate REMOVE/DOWNGRADE recommendations for listings < 14 days old
10.2 Price On Request Listings
price_per_sqft = NULL
Price Position score = 40 (penalized but not killed)
Cannot be used in segment median price calculations
10.3 Commercial vs Residential
Commercial land: no bedrooms, no price_per_sqft
Score using effective_price directly for price comparisons
Segment = location + category only (no type/bedrooms)
10.4 Listings with No Credits Data
If no credit transactions found for a listing:
total_credits_spent = 0
CPL = NULL
Cost Efficiency score = 50 (neutral)
Tier ROI score = 50 (neutral)
10.5 Deleted/Unpublished Listings
Mark is_deleted = true
Keep historical scores
Exclude from benchmarks and active views
Keep in historical trends
10.6 Token Refresh
JWT from Railway webhook valid for 30 min
Each Edge Function gets fresh token at start
If 401 during pagination: refresh and retry that page
If 3 consecutive 401s: abort sync, log error
10.7 Rate Limiting
PF allows 650 req/min
At 100 listings/page: 100 pages = 100 requests for listings
At 50 leads/page: potentially 200+ pages
Implement 100ms delay between pages
On 429: exponential backoff starting at 2s, max 3 retries
[object Object]11. WEBHOOK SUBSCRIPTIONS (Real-time Layer)
Setup (one-time via API)
Subscribe to these events by calling POST /v1/webhooks:
[
  { "eventId": "lead.created", "url": "https://ynomeynlpfvtdopctsvg.supabase.co/functions/v1/webhook-lead" },
  { "eventId": "lead.updated", "url": "https://ynomeynlpfvtdopctsvg.supabase.co/functions/v1/webhook-lead" },
  { "eventId": "listing.published", "url": "https://ynomeynlpfvtdopctsvg.supabase.co/functions/v1/webhook-listing" },
  { "eventId": "listing.unpublished", "url": "https://ynomeynlpfvtdopctsvg.supabase.co/functions/v1/webhook-listing" },
  { "eventId": "listing.action", "url": "https://ynomeynlpfvtdopctsvg.supabase.co/functions/v1/webhook-listing" }
]
Webhook Edge Functions
webhook-lead:
Verify webhook signature (if PF provides one)
Upsert lead into pf_leads
Real-time: update listing's lead count in memory
webhook-listing:
On published: upsert listing, set is_live = true
On unpublished: set is_live = false
On action: store compliance/quality action in listing's state
[object Object]12. ENVIRONMENT VARIABLES
# Supabase
SUPABASE_URL=https://ynomeynlpfvtdopctsvg.supabase.co
SUPABASE_ANON_KEY=<from Supabase dashboard>
SUPABASE_SERVICE_ROLE_KEY=<from Supabase dashboard>

# PF API
PF_JWT_ENDPOINT=https://primary-production-e1a92.up.railway.app/webhook/99a74fd0-4d49-4ceb-8b69-9e696dbea679
PF_API_BASE=https://atlas.propertyfinder.com/v1

# Frontend
VITE_SUPABASE_URL=https://ynomeynlpfvtdopctsvg.supabase.co
VITE_SUPABASE_ANON_KEY=<anon key>
[object Object]13. BUILD ORDER (for the coding agent)
Phase 1: Foundation
1. Run the full SQL schema in Supabase SQL Editor
2. Create the sync-listings Edge Function — test with manual invocation
3. Create the sync-leads Edge Function
4. Create the sync-credits Edge Function
5. Create the sync-agents Edge Function
6. Verify data is flowing into all tables
Phase 2: Intelligence
7. Deploy fn_build_daily_snapshots (SQL function)
8. Deploy fn_build_segment_benchmarks (SQL function)
9. Build and deploy fn_score_all_listings (SQL function implementing Section 7)
10. Deploy fn_build_aggregate_scores (SQL function)
11. Deploy fn_generate_recommendations (SQL function)
12. Create run-scoring-pipeline Edge Function that calls all 5 in sequence
13. Set up pg_cron schedules
Phase 3: Dashboard
14. Scaffold React app (Vite + Tailwind + Supabase JS)
15. Build auth (login page)
16. Build Portfolio Overview page
17. Build Listing Detail page
18. Build Agent Leaderboard
19. Build Recommendations Hub
20. Build Tier Analysis
21. Build Cost Center
22. Build Sync Status page
Phase 4: Real-time
23. Subscribe to PF webhooks
24. Deploy webhook Edge Functions
25. Add real-time indicators to dashboard (Supabase Realtime on pf_leads)
[object Object]14. WHAT'S MISSING (V2 Roadmap — DO NOT BUILD YET)
CRM Integration: When available, add deal attribution, revenue tracking, monetary ROI
Bayut Portal: Second portal data source with cross-portal comparison
Impressions/Clicks: PF API doesn't expose these (might need scraping or PF Expert dashboard)
Predictive Scoring: ML model trained on historical lead patterns
Automated Actions: Score-triggered tier changes via PF API
Budget Optimizer: Given X credits, which listings should get upgraded
WhatsApp Alerts: Push critical recommendations to marketing manager via WhatsApp
Multi-tenant: Support multiple PF accounts/clients
[object Object]15. SUCCESS CRITERIA
The system is working when:
1. All live listings are synced and visible in the dashboard within 4 hours of any change
2. Every listing has a score that updates daily
3. The marketing manager can open the dashboard, sort by score, and immediately know which listings to kill, downgrade, or upgrade
4. CPL is visible per listing, per agent, per area, per tier
5. Recommendations are generated automatically and require one click to approve/reject
6. The system handles 10,000+ listings without timeout
7. Score computation completes in < 60 seconds for the full portfolio
8. Dashboard loads in < 3 seconds
