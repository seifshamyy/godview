import { useEffect, useState, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import type { Recommendation } from '../lib/types'
import { CheckCircle, XCircle, ExternalLink } from 'lucide-react'

const PRIORITY_ORDER = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']

const PRIORITY_COLORS: Record<string, string> = {
  CRITICAL: 'bg-red-500/20 text-red-300 border-red-500/30',
  HIGH:     'bg-orange-500/20 text-orange-300 border-orange-500/30',
  MEDIUM:   'bg-yellow-500/20 text-yellow-300 border-yellow-500/30',
  LOW:      'bg-blue-500/20 text-blue-300 border-blue-500/30',
}

const ACTION_COLORS: Record<string, string> = {
  REMOVE:          'bg-red-900/50 text-red-200',
  DOWNGRADE:       'bg-orange-900/50 text-orange-200',
  UPGRADE:         'bg-green-900/50 text-green-200',
  BOOST:           'bg-teal-900/50 text-teal-200',
  WATCHLIST:       'bg-blue-900/50 text-blue-200',
  IMPROVE_QUALITY: 'bg-yellow-900/50 text-yellow-200',
  REPRICE:         'bg-purple-900/50 text-purple-200',
}

export default function Recommendations() {
  const navigate = useNavigate()
  const [recs, setRecs] = useState<(Recommendation & { reference?: string })[]>([])
  const [loading, setLoading] = useState(true)
  const [tab, setTab] = useState<string>('CRITICAL')

  useEffect(() => {
    supabase
      .from('recommendations')
      .select('*, pf_listings(reference)')
      .eq('status', 'PENDING')
      .order('priority')
      .order('created_at', { ascending: false })
      .limit(500)
      .then(({ data }) => {
        const mapped = ((data as (Recommendation & { pf_listings?: { reference: string } })[]) ?? []).map(r => ({
          ...r,
          reference: r.pf_listings?.reference,
        }))
        setRecs(mapped)
        setLoading(false)
      })
  }, [])

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

  if (loading) return <div className="flex items-center justify-center h-64"><div className="w-6 h-6 border-2 border-brand-500 border-t-transparent rounded-full animate-spin" /></div>

  return (
    <div className="p-6 space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-bold text-white">Recommendations Hub</h1>
        <span className="text-xs text-gray-500">{recs.length} pending</span>
      </div>

      {/* Summary stats */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        {PRIORITY_ORDER.map(p => (
          <div key={p} className={`card border cursor-pointer transition-all ${tab === p ? 'ring-1 ring-brand-500' : ''}`} onClick={() => setTab(p)}>
            <div className="text-2xl font-bold text-white">{counts[p] ?? 0}</div>
            <div className={`text-xs mt-1 font-medium ${p === 'CRITICAL' ? 'text-red-400' : p === 'HIGH' ? 'text-orange-400' : p === 'MEDIUM' ? 'text-yellow-400' : 'text-blue-400'}`}>{p}</div>
          </div>
        ))}
      </div>

      {/* Tabs */}
      <div className="flex gap-1 border-b border-gray-800 pb-1">
        {[...PRIORITY_ORDER, 'ALL'].map(t => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`px-3 py-1.5 text-xs font-medium rounded-md transition-colors ${tab === t ? 'bg-brand-600/20 text-brand-400' : 'text-gray-500 hover:text-gray-300'}`}
          >
            {t} {counts[t] > 0 && <span className="ml-1 opacity-60">{counts[t]}</span>}
          </button>
        ))}
      </div>

      {/* Cards */}
      <div className="space-y-3">
        {filtered.map(rec => (
          <div key={rec.id} className={`border rounded-xl p-4 ${PRIORITY_COLORS[rec.priority] ?? 'border-gray-800 bg-gray-900'}`}>
            <div className="flex items-start justify-between gap-3">
              <div className="flex flex-wrap items-center gap-2 min-w-0">
                <span className={`text-xs px-2 py-0.5 rounded-md font-semibold ${ACTION_COLORS[rec.action_type] ?? 'bg-gray-700 text-gray-300'}`}>{rec.action_type}</span>
                {rec.reference && (
                  <button
                    onClick={() => navigate(`/listing/${rec.pf_listing_id}`)}
                    className="text-xs font-mono text-brand-400 hover:text-brand-300 flex items-center gap-1"
                  >
                    {rec.reference} <ExternalLink className="w-3 h-3" />
                  </button>
                )}
              </div>
              <div className="flex gap-2 shrink-0">
                <button onClick={() => handleReview(rec.id, 'APPROVED')} className="text-green-400 hover:text-green-300 transition-colors flex items-center gap-1 text-xs">
                  <CheckCircle className="w-4 h-4" /> Approve
                </button>
                <button onClick={() => handleReview(rec.id, 'REJECTED')} className="text-red-400 hover:text-red-300 transition-colors flex items-center gap-1 text-xs">
                  <XCircle className="w-4 h-4" /> Reject
                </button>
              </div>
            </div>
            <p className="text-sm text-gray-200 mt-2">{rec.reason_summary}</p>
          </div>
        ))}
        {filtered.length === 0 && (
          <div className="text-center py-16 text-gray-600">No {tab === 'ALL' ? '' : tab.toLowerCase()} recommendations pending</div>
        )}
      </div>
    </div>
  )
}
