import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { PortfolioRow } from '../lib/types'
import { ScatterChart, Scatter, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from 'recharts'

interface TierRow {
  dimension_value: string
  listing_count: number
  total_leads: number
  avg_cpl: number | null
  avg_score: number | null
}

const TIER_COLORS: Record<string, string> = {
  featured: '#f59e0b', premium: '#8b5cf6', standard: '#6b7280', none: '#6b7280'
}

function fmt(n: number | null | undefined) {
  if (n == null) return '—'
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(Math.round(n))
}

export default function TierAnalysis() {
  const [tiers, setTiers] = useState<TierRow[]>([])
  const [scatter, setScatter] = useState<PortfolioRow[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    Promise.all([
      supabase.from('aggregate_scores').select('*').eq('dimension_type', 'tier'),
      supabase.from('v_portfolio_overview').select('pf_listing_id,current_tier,total_credits_spent,total_leads').limit(1000),
    ]).then(([{ data: t }, { data: s }]) => {
      setTiers((t as TierRow[]) ?? [])
      setScatter((s as PortfolioRow[]) ?? [])
      setLoading(false)
    })
  }, [])

  const standardAvgLeads = tiers.find(t => t.dimension_value === 'standard')?.total_leads
    ? (tiers.find(t => t.dimension_value === 'standard')!.total_leads / Math.max(tiers.find(t => t.dimension_value === 'standard')!.listing_count, 1))
    : null

  if (loading) return <div className="flex items-center justify-center h-64"><div className="w-6 h-6 border-2 border-brand-600 border-t-transparent rounded-full animate-spin" /></div>

  return (
    <div className="p-6 space-y-6">
      <h1 className="text-lg font-bold text-gray-900">Tier Analysis</h1>

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        {['featured', 'premium', 'standard', 'none'].map(tier => {
          const t = tiers.find(r => r.dimension_value === tier)
          const avgLeads = t ? (t.total_leads / Math.max(t.listing_count, 1)) : null
          const mult = standardAvgLeads && avgLeads ? (avgLeads / standardAvgLeads).toFixed(1) : null
          return (
            <div key={tier} className="card">
              <div className="flex items-center gap-2 mb-3">
                <div className="w-2 h-2 rounded-full" style={{ background: TIER_COLORS[tier] }} />
                <span className="text-sm font-semibold text-gray-900 capitalize">{tier}</span>
              </div>
              <div className="space-y-1.5 text-xs">
                <div className="flex justify-between"><span className="text-gray-500">Listings</span><span className="text-gray-600">{t?.listing_count ?? 0}</span></div>
                <div className="flex justify-between"><span className="text-gray-500">Avg leads/listing</span><span className="text-gray-600">{avgLeads != null ? avgLeads.toFixed(1) : '—'}</span></div>
                <div className="flex justify-between"><span className="text-gray-500">Avg CPL</span><span className="text-gray-600">{fmt(t?.avg_cpl)}</span></div>
                <div className="flex justify-between"><span className="text-gray-500">Avg score</span><span className="text-gray-600">{t?.avg_score != null ? Math.round(t.avg_score) : '—'}</span></div>
                {mult && tier !== 'standard' && <div className="flex justify-between"><span className="text-gray-500">Lead mult vs std</span><span className={`font-bold ${Number(mult) >= 1.8 ? 'text-green-400' : 'text-orange-400'}`}>{mult}x</span></div>}
              </div>
            </div>
          )
        })}
      </div>

      {/* Scatter plot */}
      <div className="card">
        <h2 className="text-xs text-gray-500 font-medium uppercase tracking-wider mb-4">Credits Spent vs Leads Generated</h2>
        <div className="h-72">
          <ResponsiveContainer width="100%" height="100%">
            <ScatterChart margin={{ top: 10, right: 30, bottom: 10, left: 0 }}>
              <CartesianGrid strokeDasharray="3 3" stroke="#e5e7eb" />
              <XAxis dataKey="total_credits_spent" name="Credits" tick={{ fontSize: 10, fill: '#6b7280' }} />
              <YAxis dataKey="total_leads" name="Leads" tick={{ fontSize: 10, fill: '#6b7280' }} />
              <Tooltip
                cursor={{ strokeDasharray: '3 3' }}
                contentStyle={{ background: '#ffffff', border: '1px solid #e5e7eb', borderRadius: 8, fontSize: 12 }}
              />
              {['featured', 'premium', 'standard', 'none'].map(tier => (
                <Scatter
                  key={tier}
                  name={tier}
                  data={scatter.filter(r => r.current_tier === tier).map(r => ({
                    total_credits_spent: r.total_credits_spent,
                    total_leads: r.total_leads,
                  }))}
                  fill={TIER_COLORS[tier]}
                  fillOpacity={0.7}
                />
              ))}
            </ScatterChart>
          </ResponsiveContainer>
        </div>
      </div>
    </div>
  )
}
