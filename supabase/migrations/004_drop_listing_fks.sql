-- Drop FK constraints that block listings upserts when referenced tables are empty
ALTER TABLE pf_listings DROP CONSTRAINT IF EXISTS pf_listings_location_id_fkey;
ALTER TABLE pf_listings DROP CONSTRAINT IF EXISTS pf_listings_agent_public_profile_id_fkey;
