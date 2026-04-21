import { useEffect, useState, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import type { Recommendation } from '../lib/types'
import { CheckCircle, XCircle, ExternalLink, RefreshCw } from 'lucide-react'

const PRIORITY_ORDER = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']

const PRIORITY_COLORS: Record<string, string> = {
  CRITICAL: 'bg-red-50 text-red-700 border-red-200',
  HIGH:     'bg-orange-50 text-orange-700 border-orange-200',
  MEDIUM:   'bg-yellow-50 text-yellow-700 border-yellow-200',
  LOW:      'bg-blue-50 text-blue-700 border-blue-200',
}

const ACTION_COLORS: Record<string, string> = {
  REMOVE:          'bg-red-100 text-red-700',
  DOWNGRADE:       'bg-orange-100 text-orange-700',
  UPGRADE:         'bg-green-100 text-green-700',
  BOOST:           'bg-teal-100 text-teal-700',
  WATCHLIST:       'bg-blue-100 text-blue-700',
  IMPROVE_QUALITY: 'bg-yellow-100 text-yellow-700',
  REPRICE:         'bg-purple-100 text-purple-700',
}

function fmt(n: number | null | undefined) {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(n)
}

/** Render key supporting metrics from reason_details as compact chips */
function DetailChips({ action, details }: { action: string; details: Record<string, unknown> | null }) {
  if (!details) return null

  const chip = (label: string, value: string | number, color = 'text-gray-400') => (
    <span key={label} className="inline-flex items-center gap-1 text-[11px] bg-gray-100 border border-gray-200 rounded px-2 py-0.5">
      <span className="text-gray-500">{label}</span>
      <span className={`font-medium ${color}`}>{value}</span>
    </span>
  )

  const d = details as Record<string, number | string | boolean | null>

  switch (action) {
    case 'REMOVE':
    case 'DOWNGRADE':
      return (
        <div className="flex flex-wrap gap-1.5 mt-2">
          {chip('Band', String(d.score_band ?? '—'), d.score_band === 'F' ? 'text-red-400' : 'text-orange-400')}
          {chip('Score', `${d.total_score ?? '—'}/100`)}
          {chip('Days live', String(d.days_live ?? '—'))}
          {chip('Total leads', String(d.total_leads ?? 0), d.total_leads === 0 ? 'text-red-400' : 'text-gray-600')}
          {d.total_credits != null && chip('Credits spent', fmt(Number(d.total_credits)), Number(d.total_credits) > 0 ? 'text-orange-300' : 'text-gray-400')}
          {d.s_tier_roi != null && chip('Tier ROI', `${Math.round(Number(d.s_tier_roi))}/100`, Number(d.s_tier_roi) < 25 ? 'text-red-400' : 'text-yellow-400')}
        </div>
      )
    case 'REPRICE':
      return (
        <div className="flex flex-wrap gap-1.5 mt-2">
          {d.effective_price != null && chip('Listed price', fmt(Number(d.effective_price)) + ' AED')}
          {d.seg_median_price != null && chip('Segment median', fmt(Number(d.seg_median_price)) + ' AED', 'text-green-400')}
          {d.pct_above_median != null && chip('Above median', `+${d.pct_above_median}%`, 'text-red-400')}
          {d.s_lead_volume != null && chip('Lead volume', `${Math.round(Number(d.s_lead_volume))}/100`)}
          {d.days_live != null && chip('Days live', String(d.days_live))}
          {d.price_on_request && chip('POR', 'Yes', 'text-yellow-400')}
        </div>
      )
    case 'UPGRADE':
      return (
        <div className="flex flex-wrap gap-1.5 mt-2">
          {chip('Band', String(d.score_band ?? '—'), d.score_band === 'A' ? 'text-green-400' : 'text-blue-400')}
          {chip('Score', `${d.total_score ?? '—'}/100`, 'text-green-300')}
          {d.s_lead_volume != null && chip('Lead volume', `${Math.round(Number(d.s_lead_volume))}/100`, 'text-green-400')}
          {d.leads_30d != null && chip('Leads 30d', String(d.leads_30d), 'text-green-300')}
          {d.seg_avg_leads != null && chip('Seg avg', String(Math.round(Number(d.seg_avg_leads))))}
          {d.s_competitive_position != null && chip('Competitive', `${Math.round(Number(d.s_competitive_position))}/100`)}
          {chip('Days live', String(d.days_live ?? '—'))}
        </div>
      )
    case 'BOOST':
      return (
        <div className="flex flex-wrap gap-1.5 mt-2">
          {chip('Leads 7d', String(d.leads_7d ?? 0))}
          {chip('Prev 7d', String(d.leads_prior_7d ?? 0), 'text-orange-300')}
          {d.s_lead_velocity != null && chip('Velocity', `${Math.round(Number(d.s_lead_velocity))}/100`, 'text-yellow-400')}
          {d.s_competitive_position != null && chip('Competitive', `${Math.round(Number(d.s_competitive_position))}/100`, 'text-green-400')}
          {chip('Days live', String(d.days_live ?? '—'))}
        </div>
      )
    case 'WATCHLIST':
      return (
        <div className="flex flex-wrap gap-1.5 mt-2">
          {chip('Band', String(d.score_band ?? '—'), 'text-red-400')}
          {chip('Score', `${d.total_score ?? '—'}/100`)}
          {chip('Total leads', String(d.total_leads ?? 0), 'text-red-400')}
          {chip('Days live', String(d.days_live ?? '—'), 'text-orange-300')}
          {d.seg_avg_leads != null && chip('Seg avg leads', String(Math.round(Number(d.seg_avg_leads))))}
          {d.s_price_position != null && chip('Price pos', `${Math.round(Number(d.s_price_position))}/100`)}
        </div>
      )
    case 'IMPROVE_QUALITY':
      return (
        <div className="flex flex-wrap gap-1.5 mt-2">
          {d.s_listing_completeness != null && chip('Completeness', `${Math.round(Number(d.s_listing_completeness))}/100`, Number(d.s_listing_completeness) < 40 ? 'text-red-400' : 'text-yellow-400')}
          {d.has_video != null && chip('Video', d.has_video ? 'Yes' : 'No', d.has_video ? 'text-green-400' : 'text-red-400')}
          {d.image_count != null && chip('Images', String(d.image_count), Number(d.image_count) < 10 ? 'text-yellow-400' : 'text-gray-600')}
          {chip('Band', String(d.score_band ?? '—'), 'text-yellow-400')}
          {chip('Score', `${d.total_score ?? '—'}/100`)}
        </div>
      )
    default:
      return null
  }
}

export default function Recommendations() {
  const navigate = useNavigate()
  const [recs, setRecs] = useState<(Recommendation & { reference?: string })[]>([])
  const [loading, setLoading] = useState(true)
  const [regenerating, setRegenerating] = useState(false)
  const [tab, setTab] = useState<string>('CRITICAL')

  const loadRecs = () => {
    setLoading(true)
    supabase
      .from('recommendations')
      .select('*, pf_listings(reference)')
      .eq('status', 'PENDING')
      .order('priority')
      .order('created_at', { ascending: false })
      .limit(1000)
      .then(({ data }) => {
        const mapped = ((data as (Recommendation & { pf_listings?: { reference: string } })[]) ?? []).map(r => ({
          ...r,
          reference: r.pf_listings?.reference,
        }))
        setRecs(mapped)
        setLoading(false)
      })
  }

  useEffect(loadRecs, [])

  const handleRegenerate = async () => {
    setRegenerating(true)
    await supabase.rpc('fn_generate_recommendations')
    loadRecs()
    setRegenerating(false)
  }

  const handleReview = async (id: number, status: 'APPROVED' | 'REJECTED') => {
    await supabase.from('recommendations').update({ status, reviewed_at: new Date().toISOString() }).eq('id', id)
    setRecs(prev => prev.filter(r => r.id !== id))
  }

  const filtered = useMemo(() => tab === 'ALL' ? recs : recs.filter(r => r.priority === tab), [recs, tab])

  const counts = useMemo(() => {
    const c: Record<string, number> = { ALL: recs.length }
    PRIORITY_ORDER.forEach(p => { c[p] = recs.filter(r => r.priority === p).length })
    return c
  }, [recs])

  if (loading) return (
    <div className="flex items-center justify-center h-64">
      <div className="w-6 h-6 border-2 border-brand-600 border-t-transparent rounded-full animate-spin" />
    </div>
  )

  return (
    <div className="p-6 space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-bold text-gray-900">Recommendations Hub</h1>
        <div className="flex items-center gap-3">
          <span className="text-xs text-gray-500">{recs.length} pending</span>
          <button
            onClick={handleRegenerate}
            disabled={regenerating}
            className="flex items-center gap-1.5 text-xs text-gray-400 hover:text-gray-900 border border-gray-300 hover:border-gray-500 px-3 py-1.5 rounded-lg transition-colors disabled:opacity-50"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${regenerating ? 'animate-spin' : ''}`} />
            {regenerating ? 'Regenerating…' : 'Regenerate'}
          </button>
        </div>
      </div>

      {/* Priority summary cards */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        {PRIORITY_ORDER.map(p => (
          <div
            key={p}
            className={`card border cursor-pointer transition-all ${tab === p ? 'ring-1 ring-brand-600' : ''}`}
            onClick={() => setTab(p)}
          >
            <div className="text-2xl font-bold text-gray-900">{counts[p] ?? 0}</div>
            <div className={`text-xs mt-1 font-medium ${
              p === 'CRITICAL' ? 'text-red-400' :
              p === 'HIGH'     ? 'text-orange-400' :
              p === 'MEDIUM'   ? 'text-yellow-400' : 'text-blue-400'
            }`}>{p}</div>
          </div>
        ))}
      </div>

      {/* Action type breakdown */}
      <div className="flex flex-wrap gap-2">
        {Object.entries(
          recs.reduce((acc, r) => { acc[r.action_type] = (acc[r.action_type] ?? 0) + 1; return acc }, {} as Record<string, number>)
        ).sort((a,b) => b[1] - a[1]).map(([type, count]) => (
          <span key={type} className={`text-xs px-2.5 py-1 rounded-md font-medium ${ACTION_COLORS[type] ?? 'bg-gray-700 text-gray-600'}`}>
            {type} <span className="opacity-60 ml-1">{count}</span>
          </span>
        ))}
      </div>

      {/* Priority tabs */}
      <div className="flex gap-1 border-b border-gray-200 pb-1">
        {[...PRIORITY_ORDER, 'ALL'].map(t => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`px-3 py-1.5 text-xs font-medium rounded-md transition-colors ${tab === t ? 'bg-brand-600/20 text-brand-600' : 'text-gray-500 hover:text-gray-600'}`}
          >
            {t} {(counts[t] ?? 0) > 0 && <span className="ml-1 opacity-60">{counts[t]}</span>}
          </button>
        ))}
      </div>

      {/* Recommendation cards */}
      <div className="space-y-3">
        {filtered.map(rec => (
          <div key={rec.id} className={`border rounded-xl p-4 ${PRIORITY_COLORS[rec.priority] ?? 'border-gray-200 bg-white'}`}>
            <div className="flex items-start justify-between gap-3">
              <div className="flex flex-wrap items-center gap-2 min-w-0">
                <span className={`text-xs px-2 py-0.5 rounded-md font-semibold ${ACTION_COLORS[rec.action_type] ?? 'bg-gray-700 text-gray-600'}`}>
                  {rec.action_type}
                </span>
                {rec.reference && (
                  <button
                    onClick={() => navigate(`/listing/${rec.pf_listing_id}`)}
                    className="text-xs font-mono text-brand-600 hover:text-brand-300 flex items-center gap-1"
                  >
                    {rec.reference} <ExternalLink className="w-3 h-3" />
                  </button>
                )}
              </div>
              <div className="flex gap-2 shrink-0">
                <button
                  onClick={() => handleReview(rec.id, 'APPROVED')}
                  className="text-green-400 hover:text-green-300 transition-colors flex items-center gap-1 text-xs"
                >
                  <CheckCircle className="w-4 h-4" /> Approve
                </button>
                <button
                  onClick={() => handleReview(rec.id, 'REJECTED')}
                  className="text-red-400 hover:text-red-300 transition-colors flex items-center gap-1 text-xs"
                >
                  <XCircle className="w-4 h-4" /> Reject
                </button>
              </div>
            </div>

            <p className="text-sm text-gray-700 mt-2">{rec.reason_summary}</p>

            <DetailChips
              action={rec.action_type}
              details={rec.reason_details as Record<string, unknown> | null}
            />
          </div>
        ))}
        {filtered.length === 0 && (
          <div className="text-center py-16 text-gray-600">
            No {tab === 'ALL' ? '' : tab.toLowerCase()} recommendations pending
          </div>
        )}
      </div>
    </div>
  )
}
