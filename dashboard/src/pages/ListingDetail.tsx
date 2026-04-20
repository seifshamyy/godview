import { useEffect, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import type { ListingScore, Recommendation, DailySnapshot } from '../lib/types'
import ScoreBadge from '../components/ScoreBadge'
import TierBadge from '../components/TierBadge'
import { ArrowLeft, CheckCircle, XCircle } from 'lucide-react'
import {
  RadarChart, Radar, PolarGrid, PolarAngleAxis, ResponsiveContainer,
  LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid
} from 'recharts'

type Listing = Record<string, unknown>

function fmt(n: number | null | undefined) {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(n)
}

const PRIORITY_COLORS: Record<string, string> = {
  CRITICAL: 'text-red-400 bg-red-900/30 border-red-800',
  HIGH:     'text-orange-400 bg-orange-900/30 border-orange-800',
  MEDIUM:   'text-yellow-400 bg-yellow-900/30 border-yellow-800',
  LOW:      'text-blue-400 bg-blue-900/30 border-blue-800',
}

const ACTION_COLORS: Record<string, string> = {
  REMOVE:          'bg-red-900/40 text-red-300',
  DOWNGRADE:       'bg-orange-900/40 text-orange-300',
  UPGRADE:         'bg-green-900/40 text-green-300',
  BOOST:           'bg-teal-900/40 text-teal-300',
  WATCHLIST:       'bg-blue-900/40 text-blue-300',
  IMPROVE_QUALITY: 'bg-yellow-900/40 text-yellow-300',
  REPRICE:         'bg-purple-900/40 text-purple-300',
}

export default function ListingDetail() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const [listing, setListing] = useState<Listing | null>(null)
  const [score, setScore] = useState<ListingScore | null>(null)
  const [recs, setRecs] = useState<Recommendation[]>([])
  const [snapshots, setSnapshots] = useState<DailySnapshot[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!id) return
    Promise.all([
      supabase.from('v_portfolio_overview').select('*').eq('pf_listing_id', id).single(),
      supabase.from('listing_scores').select('*').eq('pf_listing_id', id).order('score_date', { ascending: false }).limit(1).single(),
      supabase.from('recommendations').select('*').eq('pf_listing_id', id).eq('status', 'PENDING').order('priority'),
      supabase.from('listing_daily_snapshots').select('*').eq('pf_listing_id', id).order('snapshot_date', { ascending: true }).limit(90),
    ]).then(([{ data: l }, { data: s }, { data: r }, { data: snaps }]) => {
      setListing(l as Listing)
      setScore(s as ListingScore)
      setRecs((r as Recommendation[]) ?? [])
      setSnapshots((snaps as DailySnapshot[]) ?? [])
      setLoading(false)
    })
  }, [id])

  const handleReview = async (recId: number, status: 'APPROVED' | 'REJECTED') => {
    await supabase.from('recommendations').update({ status, reviewed_at: new Date().toISOString() }).eq('id', recId)
    setRecs(prev => prev.filter(r => r.id !== recId))
  }

  if (loading) return <div className="flex items-center justify-center h-64"><div className="w-6 h-6 border-2 border-brand-500 border-t-transparent rounded-full animate-spin" /></div>
  if (!listing) return <div className="p-6 text-gray-500">Listing not found.</div>

  const scoreComponents = score ? [
    { subject: 'Lead Vol', value: score.s_lead_volume ?? 0 },
    { subject: 'Velocity', value: score.s_lead_velocity ?? 0 },
    { subject: 'Cost Eff', value: score.s_cost_efficiency ?? 0 },
    { subject: 'Tier ROI', value: score.s_tier_roi ?? 0 },
    { subject: 'Quality', value: score.s_quality_score ?? 0 },
    { subject: 'Price', value: score.s_price_position ?? 0 },
    { subject: 'Complete', value: score.s_listing_completeness ?? 0 },
    { subject: 'Fresh', value: score.s_freshness ?? 0 },
    { subject: 'Compete', value: score.s_competitive_position ?? 0 },
  ] : []

  return (
    <div className="p-6 space-y-6">
      <button onClick={() => navigate(-1)} className="btn-ghost flex items-center gap-1.5 -ml-1">
        <ArrowLeft className="w-4 h-4" /> Back
      </button>

      {/* Header */}
      <div className="card">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div className="flex items-center gap-3 mb-1">
              <span className="font-mono text-brand-400 text-lg font-bold">{listing.reference as string}</span>
              <TierBadge tier={listing.current_tier as string} />
              <ScoreBadge band={listing.score_band as string} score={listing.total_score as number} size="md" />
            </div>
            <p className="text-gray-400 text-sm">
              {[listing.property_type, listing.bedrooms ? `${listing.bedrooms} BR` : null, listing.location_name].filter(Boolean).join(' · ')}
            </p>
          </div>
          <div className="text-right">
            <div className="text-xl font-bold text-white">{fmt(listing.effective_price as number)}</div>
            <div className="text-xs text-gray-500 mt-0.5">{listing.price_type as string}</div>
          </div>
        </div>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4 mt-4 pt-4 border-t border-gray-800">
          <div><div className="text-xs text-gray-500">Total Leads</div><div className="text-white font-semibold mt-0.5">{listing.total_leads as number}</div></div>
          <div><div className="text-xs text-gray-500">Leads 30d</div><div className="text-white font-semibold mt-0.5">{listing.leads_30d as number}</div></div>
          <div><div className="text-xs text-gray-500">CPL</div><div className="text-white font-semibold mt-0.5">{fmt(listing.cpl as number)}</div></div>
          <div><div className="text-xs text-gray-500">Days Live</div><div className="text-white font-semibold mt-0.5">{listing.days_live as number ?? '—'}</div></div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Score breakdown radar */}
        {score && (
          <div className="card">
            <h2 className="text-xs text-gray-500 font-medium uppercase tracking-wider mb-4">Score Breakdown</h2>
            <div className="h-56">
              <ResponsiveContainer width="100%" height="100%">
                <RadarChart data={scoreComponents}>
                  <PolarGrid stroke="#374151" />
                  <PolarAngleAxis dataKey="subject" tick={{ fontSize: 10, fill: '#9ca3af' }} />
                  <Radar dataKey="value" stroke="#0ea5e9" fill="#0ea5e9" fillOpacity={0.15} />
                </RadarChart>
              </ResponsiveContainer>
            </div>
            <table className="w-full text-xs mt-2">
              <tbody className="divide-y divide-gray-800/40">
                {[
                  ['Lead Volume (20)', score.s_lead_volume],
                  ['Lead Velocity (10)', score.s_lead_velocity],
                  ['Cost Efficiency (20)', score.s_cost_efficiency],
                  ['Tier ROI (10)', score.s_tier_roi],
                  ['PF Quality (10)', score.s_quality_score],
                  ['Price Position (10)', score.s_price_position],
                  ['Completeness (5)', score.s_listing_completeness],
                  ['Freshness (5)', score.s_freshness],
                  ['Competitive (10)', score.s_competitive_position],
                ].map(([label, val]) => (
                  <tr key={label as string}>
                    <td className="py-1.5 text-gray-400">{label}</td>
                    <td className="py-1.5 text-right">
                      <div className="inline-flex items-center gap-2">
                        <div className="w-20 h-1.5 bg-gray-800 rounded-full overflow-hidden">
                          <div className="h-full bg-brand-500 rounded-full" style={{ width: `${val ?? 0}%` }} />
                        </div>
                        <span className="text-white font-mono w-8 text-right">{val ?? 0}</span>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {/* Lead timeline */}
        {snapshots.length > 0 && (
          <div className="card">
            <h2 className="text-xs text-gray-500 font-medium uppercase tracking-wider mb-4">Daily Leads</h2>
            <div className="h-56">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={snapshots}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#1f2937" />
                  <XAxis dataKey="snapshot_date" tick={{ fontSize: 10, fill: '#6b7280' }} tickFormatter={d => d.slice(5)} />
                  <YAxis tick={{ fontSize: 10, fill: '#6b7280' }} />
                  <Tooltip contentStyle={{ background: '#111827', border: '1px solid #374151', borderRadius: 8, fontSize: 12 }} />
                  <Line dataKey="new_leads_today" stroke="#4ade80" dot={false} strokeWidth={2} name="New Leads" />
                  <Line dataKey="total_leads" stroke="#60a5fa" dot={false} strokeWidth={1.5} strokeDasharray="4 2" name="Cumulative" />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </div>
        )}

        {/* CPL trend */}
        {snapshots.length > 0 && (
          <div className="card">
            <h2 className="text-xs text-gray-500 font-medium uppercase tracking-wider mb-4">CPL Trend</h2>
            <div className="h-56">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={snapshots.filter(s => s.cpl != null)}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#1f2937" />
                  <XAxis dataKey="snapshot_date" tick={{ fontSize: 10, fill: '#6b7280' }} tickFormatter={d => d.slice(5)} />
                  <YAxis tick={{ fontSize: 10, fill: '#6b7280' }} />
                  <Tooltip contentStyle={{ background: '#111827', border: '1px solid #374151', borderRadius: 8, fontSize: 12 }} />
                  <Line dataKey="cpl" stroke="#f59e0b" dot={false} strokeWidth={2} name="CPL" />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </div>
        )}

        {/* Recommendations */}
        <div className="card">
          <h2 className="text-xs text-gray-500 font-medium uppercase tracking-wider mb-4">Active Recommendations ({recs.length})</h2>
          {recs.length === 0 ? (
            <p className="text-gray-600 text-sm">No pending recommendations.</p>
          ) : (
            <div className="space-y-3">
              {recs.map(rec => (
                <div key={rec.id} className={`border rounded-lg p-3 ${PRIORITY_COLORS[rec.priority] ?? 'border-gray-800 bg-gray-800/30'}`}>
                  <div className="flex items-start justify-between gap-2">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className={`text-xs px-2 py-0.5 rounded font-medium ${ACTION_COLORS[rec.action_type] ?? 'bg-gray-700 text-gray-300'}`}>{rec.action_type}</span>
                      <span className="text-xs opacity-70">{rec.priority}</span>
                    </div>
                    <div className="flex gap-1.5 shrink-0">
                      <button onClick={() => handleReview(rec.id, 'APPROVED')} className="text-green-400 hover:text-green-300 transition-colors">
                        <CheckCircle className="w-4 h-4" />
                      </button>
                      <button onClick={() => handleReview(rec.id, 'REJECTED')} className="text-red-400 hover:text-red-300 transition-colors">
                        <XCircle className="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                  <p className="text-sm mt-2">{rec.reason_summary}</p>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
