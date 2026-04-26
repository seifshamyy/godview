import { useEffect, useState, useMemo } from 'react'
import { supabase } from '../lib/supabase'
import { ChevronUp, ChevronDown, ChevronsUpDown } from 'lucide-react'

interface AreaRow {
  dimension_value: string
  listing_count: number
  total_leads: number
  total_credits: number
  avg_score: number | null
  min_score: number | null
  max_score: number | null
  avg_cpl: number | null
  count_s: number; count_a: number; count_b: number
  count_c: number; count_d: number; count_f: number
}

type SortKey = 'avg_score' | 'total_leads' | 'listing_count' | 'avg_cpl' | 'good_pct' | 'total_credits'

function fmt(n: number | null | undefined, prefix = '') {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${prefix}${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${prefix}${(n / 1_000).toFixed(1)}k`
  return `${prefix}${Math.round(n)}`
}

function scoreColor(score: number | null) {
  if (score == null) return 'text-gray-400'
  if (score >= 70) return 'text-green-600'
  if (score >= 55) return 'text-blue-600'
  if (score >= 40) return 'text-yellow-600'
  return 'text-red-500'
}

function scoreBg(score: number | null) {
  if (score == null) return 'bg-gray-100'
  if (score >= 70) return 'bg-green-50'
  if (score >= 55) return 'bg-blue-50'
  if (score >= 40) return 'bg-yellow-50'
  return 'bg-red-50'
}

const BAND_COLORS: Record<string, string> = {
  count_s: '#a855f7',
  count_a: '#22c55e',
  count_b: '#3b82f6',
  count_c: '#f59e0b',
  count_d: '#f97316',
  count_f: '#ef4444',
}

function SortIcon({ col, sort, asc }: { col: SortKey; sort: SortKey; asc: boolean }) {
  if (sort !== col) return <ChevronsUpDown className="w-3 h-3 opacity-30" />
  return asc ? <ChevronUp className="w-3 h-3" /> : <ChevronDown className="w-3 h-3" />
}

export default function AreaAnalysis() {
  const [areas, setAreas] = useState<AreaRow[]>([])
  const [loading, setLoading] = useState(true)
  const [sort, setSort] = useState<SortKey>('avg_score')
  const [asc, setAsc] = useState(false)

  useEffect(() => {
    supabase.from('aggregate_scores')
      .select('*')
      .eq('dimension_type', 'location')
      .limit(300)
      .then(({ data }) => { setAreas((data as AreaRow[]) ?? []); setLoading(false) })
  }, [])

  const ranked = useMemo(() => {
    return [...areas]
      .map(a => ({
        ...a,
        good_pct: (a.count_s + a.count_a) / Math.max(a.listing_count, 1) * 100,
      }))
      .sort((a, b) => {
        const av = a[sort] as number | null ?? (asc ? Infinity : -Infinity)
        const bv = b[sort] as number | null ?? (asc ? Infinity : -Infinity)
        return asc ? av - bv : bv - av
      })
  }, [areas, sort, asc])

  function toggleSort(col: SortKey) {
    if (sort === col) setAsc(p => !p)
    else { setSort(col); setAsc(false) }
  }

  const thCls = (col: SortKey) =>
    `px-3 py-2.5 text-left text-xs font-medium select-none cursor-pointer whitespace-nowrap transition-colors ${
      sort === col ? 'text-brand-600' : 'text-gray-500 hover:text-gray-900'
    }`

  if (loading) return (
    <div className="flex items-center justify-center h-64">
      <div className="w-6 h-6 border-2 border-brand-600 border-t-transparent rounded-full animate-spin" />
    </div>
  )

  const totalListings = areas.reduce((s, a) => s + a.listing_count, 0)
  const totalLeads    = areas.reduce((s, a) => s + a.total_leads, 0)

  return (
    <div className="p-6 space-y-5">
      {/* Header */}
      <div className="flex items-end justify-between">
        <div>
          <h1 className="text-lg font-bold text-gray-900">Area Analysis</h1>
          <p className="text-xs text-gray-500 mt-0.5">{ranked.length} areas · {totalListings.toLocaleString()} listings · {totalLeads.toLocaleString()} total leads</p>
        </div>
        <span className="text-xs text-gray-400">Ranked by: <span className="text-gray-700 font-medium">{sort.replace('_', ' ')}</span></span>
      </div>

      {/* Summary cards — top 3 */}
      {ranked.length > 0 && (
        <div className="grid grid-cols-3 gap-3">
          {ranked.slice(0, 3).map((area, i) => {
            const total = area.count_s + area.count_a + area.count_b + area.count_c + area.count_d + area.count_f
            const medals = ['🥇', '🥈', '🥉']
            return (
              <div key={area.dimension_value} className={`card border ${i === 0 ? 'border-brand-200 bg-brand-50/30' : ''}`}>
                <div className="flex items-start justify-between">
                  <span className="text-lg">{medals[i]}</span>
                  <span className={`text-xl font-bold ${scoreColor(area.avg_score)}`}>
                    {area.avg_score != null ? Math.round(area.avg_score) : '—'}
                  </span>
                </div>
                <div className="mt-1.5 font-semibold text-gray-900 text-sm truncate">{area.dimension_value}</div>
                <div className="text-xs text-gray-500 mt-0.5">{area.listing_count} listings · {area.total_leads} leads</div>
                <div className="flex rounded overflow-hidden h-1.5 mt-2 gap-px">
                  {(['count_s','count_a','count_b','count_c','count_d','count_f'] as const).map(k => {
                    const v = area[k] as number
                    const pct = total > 0 ? v / total * 100 : 0
                    return pct > 0 ? <div key={k} style={{ width: `${pct}%`, background: BAND_COLORS[k] }} /> : null
                  })}
                </div>
              </div>
            )
          })}
        </div>
      )}

      {/* Full table */}
      <div className="card p-0 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-gray-200 bg-gray-50/80">
              <tr>
                <th className="px-3 py-2.5 text-left text-xs font-medium text-gray-400 w-10">#</th>
                <th className="px-3 py-2.5 text-left text-xs font-medium text-gray-500">Area</th>
                <th className={thCls('listing_count')} onClick={() => toggleSort('listing_count')}>
                  <span className="flex items-center gap-1">Listings <SortIcon col="listing_count" sort={sort} asc={asc} /></span>
                </th>
                <th className={thCls('avg_score')} onClick={() => toggleSort('avg_score')}>
                  <span className="flex items-center gap-1">Avg Score <SortIcon col="avg_score" sort={sort} asc={asc} /></span>
                </th>
                <th className={thCls('good_pct')} onClick={() => toggleSort('good_pct')}>
                  <span className="flex items-center gap-1">S+A% <SortIcon col="good_pct" sort={sort} asc={asc} /></span>
                </th>
                <th className={thCls('total_leads')} onClick={() => toggleSort('total_leads')}>
                  <span className="flex items-center gap-1">Total Leads <SortIcon col="total_leads" sort={sort} asc={asc} /></span>
                </th>
                <th className={thCls('avg_cpl')} onClick={() => toggleSort('avg_cpl')}>
                  <span className="flex items-center gap-1">Avg CPL <SortIcon col="avg_cpl" sort={sort} asc={asc} /></span>
                </th>
                <th className={thCls('total_credits')} onClick={() => toggleSort('total_credits')}>
                  <span className="flex items-center gap-1">Credits Spent <SortIcon col="total_credits" sort={sort} asc={asc} /></span>
                </th>
                <th className="px-3 py-2.5 text-left text-xs font-medium text-gray-500">Band Distribution</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {ranked.map((area, i) => {
                const total = area.count_s + area.count_a + area.count_b + area.count_c + area.count_d + area.count_f
                const goodPct = area.good_pct
                return (
                  <tr key={area.dimension_value} className="hover:bg-gray-50 transition-colors">
                    <td className="px-3 py-2.5 text-xs text-gray-400 font-mono">{i + 1}</td>
                    <td className="px-3 py-2.5 font-medium text-gray-900">{area.dimension_value}</td>
                    <td className="px-3 py-2.5 text-gray-500">{area.listing_count}</td>
                    <td className="px-3 py-2.5">
                      {area.avg_score != null ? (
                        <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-bold ${scoreBg(area.avg_score)} ${scoreColor(area.avg_score)}`}>
                          {Math.round(area.avg_score)}
                        </span>
                      ) : '—'}
                    </td>
                    <td className="px-3 py-2.5">
                      <div className="flex items-center gap-2">
                        <div className="w-16 h-1.5 bg-gray-200 rounded-full overflow-hidden">
                          <div
                            className="h-full bg-green-500 rounded-full"
                            style={{ width: `${goodPct}%` }}
                          />
                        </div>
                        <span className="text-xs text-gray-600">{Math.round(goodPct)}%</span>
                      </div>
                    </td>
                    <td className="px-3 py-2.5 text-gray-600 font-medium">{fmt(area.total_leads)}</td>
                    <td className="px-3 py-2.5 text-gray-500">{area.avg_cpl != null ? `${Math.round(area.avg_cpl)} AED` : '—'}</td>
                    <td className="px-3 py-2.5 text-gray-500">{fmt(area.total_credits)}</td>
                    <td className="px-3 py-2.5">
                      {total > 0 ? (
                        <div className="flex items-center gap-2">
                          <div className="flex rounded overflow-hidden h-2 w-28 gap-px">
                            {(['count_s','count_a','count_b','count_c','count_d','count_f'] as const).map(k => {
                              const v = area[k] as number
                              const pct = v / total * 100
                              return pct > 0 ? (
                                <div
                                  key={k}
                                  style={{ width: `${pct}%`, background: BAND_COLORS[k] }}
                                  title={`${k.slice(-1).toUpperCase()}: ${v}`}
                                />
                              ) : null
                            })}
                          </div>
                          <span className="text-xs text-gray-400">
                            {area.count_s + area.count_a}/{total}
                          </span>
                        </div>
                      ) : null}
                    </td>
                  </tr>
                )
              })}
              {ranked.length === 0 && (
                <tr>
                  <td colSpan={9} className="text-center py-16 text-gray-500">
                    No area data yet — run scoring pipeline first
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
