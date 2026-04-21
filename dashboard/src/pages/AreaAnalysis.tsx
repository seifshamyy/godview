import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

interface AreaRow {
  dimension_value: string
  listing_count: number
  avg_score: number | null
  total_leads: number
  avg_cpl: number | null
  count_s: number; count_a: number; count_b: number
  count_c: number; count_d: number; count_f: number
}

function fmt(n: number | null | undefined) {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(Math.round(n))
}

export default function AreaAnalysis() {
  const [areas, setAreas] = useState<AreaRow[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.from('aggregate_scores')
      .select('*')
      .eq('dimension_type', 'location')
      .order('total_leads', { ascending: false })
      .limit(100)
      .then(({ data }) => { setAreas((data as AreaRow[]) ?? []); setLoading(false) })
  }, [])

  if (loading) return <div className="flex items-center justify-center h-64"><div className="w-6 h-6 border-2 border-brand-600 border-t-transparent rounded-full animate-spin" /></div>

  return (
    <div className="p-6 space-y-4">
      <h1 className="text-lg font-bold text-gray-900">Area Analysis</h1>
      <div className="card p-0 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-gray-200 bg-white/80">
              <tr>
                {['Location', 'Listings', 'Total Leads', 'Avg CPL', 'Avg Score', 'Distribution'].map(h => (
                  <th key={h} className="px-3 py-2 text-left text-xs text-gray-500 font-medium">{h}</th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-200">
              {areas.map(area => {
                const total = area.count_s + area.count_a + area.count_b + area.count_c + area.count_d + area.count_f
                return (
                  <tr key={area.dimension_value}>
                    <td className="px-3 py-2 text-gray-900 font-medium">{area.dimension_value}</td>
                    <td className="px-3 py-2 text-gray-400">{area.listing_count}</td>
                    <td className="px-3 py-2 text-gray-600">{area.total_leads}</td>
                    <td className="px-3 py-2 text-gray-400">{fmt(area.avg_cpl)}</td>
                    <td className="px-3 py-2 text-gray-600">{area.avg_score != null ? Math.round(area.avg_score) : '—'}</td>
                    <td className="px-3 py-2">
                      {total > 0 && (
                        <div className="flex rounded-full overflow-hidden h-3 w-32 gap-px">
                          {[['count_s','#a78bfa'], ['count_a','#4ade80'], ['count_b','#60a5fa'], ['count_c','#fbbf24'], ['count_d','#f97316'], ['count_f','#ef4444']].map(([k, color]) => {
                            const v = area[k as keyof AreaRow] as number
                            const pct = v / total * 100
                            return pct > 0 ? <div key={k} style={{ width: `${pct}%`, background: color }} title={`${k.slice(-1)}: ${v}`} /> : null
                          })}
                        </div>
                      )}
                    </td>
                  </tr>
                )
              })}
              {areas.length === 0 && (
                <tr><td colSpan={6} className="text-center py-12 text-gray-600">No area data yet — run scoring pipeline first</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
