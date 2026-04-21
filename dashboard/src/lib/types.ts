export interface PortfolioRow {
  pf_listing_id: string
  reference: string
  category: string | null
  property_type: string | null
  bedrooms: string | null
  bathrooms: string | null
  size_sqft: number | null
  effective_price: number | null
  price_per_sqft: number | null
  price_type: string | null
  current_tier: string | null
  tier_expires_at: string | null
  agent_name: string | null
  agent_public_profile_id: number | null
  pf_quality_score: number | null
  pf_quality_color: string | null
  is_live: boolean
  published_at: string | null
  days_live: number | null
  image_count: number | null
  has_video: boolean | null
  furnishing: string | null
  developer: string | null
  project_status: string | null
  location_id: number | null
  location_name: string | null
  destination: string | null
  total_leads: number
  leads_7d: number
  leads_30d: number
  total_credits_spent: number
  cpl: number | null
  total_score: number | null
  score_band: string | null
}

export interface ListingScore {
  id: number
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
  zero_lead_penalty: number
  total_score: number
  score_band: string | null
}

export interface Recommendation {
  id: number
  pf_listing_id: string
  recommendation_date: string
  action_type: string
  priority: string
  reason_summary: string
  reason_details: Record<string, unknown> | null
  status: string
  reviewed_by: string | null
  reviewed_at: string | null
  notes: string | null
  created_at: string
}

export interface AgentLeaderboard {
  public_profile_id: number
  agent_name: string
  status: string | null
  is_super_agent: boolean | null
  live_listings: number
  total_listings: number
  avg_quality_score: number | null
  total_leads: number
  total_credits_spent: number
  avg_cpl: number | null
}

export interface SyncLogEntry {
  id: number
  sync_type: string
  started_at: string
  completed_at: string | null
  status: string
  records_synced: number
  records_created: number
  records_updated: number
  error_message: string | null
  metadata: Record<string, unknown> | null
}

export interface CreditSnapshot {
  id: number
  credit_balance: number
  snapshot_at: string
}

export interface DailySnapshot {
  id: number
  pf_listing_id: string
  snapshot_date: string
  total_leads: number
  new_leads_today: number
  pf_quality_score: number | null
  current_tier: string | null
  effective_price: number | null
  is_live: boolean
  days_live: number | null
  total_credits_spent: number
  cpl: number | null
}
