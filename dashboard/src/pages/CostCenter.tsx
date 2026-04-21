import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { CreditSnapshot, PortfolioRow } from '../lib/types'
import { BarChart, Bar, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, ResponsiveContainer } from 'recharts'

function fmt(n: number | null | undefined) {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(Math.round(n))
}

export default function CostCenter() {
  const [snapshots, setSnapshots] = useState<CreditSnapshot[]>([])
  const [topSpend, setTopSpend] = useState<PortfolioRow[]>([])
  const [zeroLead, setZeroLead] = useState<PortfolioRow[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    Promise.all([
      supabase.from('pf_credit_snapshots').select('*').order('snapshot_at', { ascending: true }).limit(90),
      supabase.from('v_portfolio_overview').select('*').order('total_credits_spent', { ascending: false }).limit(20),
      supabase.from('v_portfolio_overview').select('*').eq('total_leads', 0).gt('total_credits_spent', 0).order('total_credits_spent', { ascending: false }).limit(20),
    ]).then(([{ data: snaps }, { data: top }, { data: zero }]) => {
      setSnapshots((snaps as CreditSnapshot[]) ?? [])
      setTopSpend((top as PortfolioRow[]) ?? [])
      setZeroLead((zero as PortfolioRow[]) ?? [])
      setLoading(false)
    })
  }, [])

  const latestBalance = snapshots[snapshots.length - 1]?.credit_balance

  if (loading) return <div className="flex items-center justify-center h-64"><div className="w-6 h-6 border-2 border-brand-600 border-t-transparent rounded-full animate-spin" /></div>

  return (
    <div className="p-6 space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-bold text-gray-900">Cost Center</h1>
        {latestBalance != null && (
          <div className="card py-2 px-4">
            <span className="text-xs text-gray-500">Credit Balance</span>
            <span className="ml-3 text-lg font-bold text-gray-900">{fmt(latestBalance)}</span>
          </div>
        )}
      </div>

      {/* Balance trend */}
      {snapshots.length > 0 && (
        <div className="card">
          <h2 className="text-xs text-gray-500 font-medium uppercase tracking-wider mb-4">Credit Balance Trend</h2>
          <div className="h-56">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={snapshots}>
                <CartesianGrid strokeDasharray="3 3" stroke="#e5e7eb" />
                <XAxis dataKey="snapshot_at" tick={{ fontSize: 10, fill: '#6b7280' }} tickFormatter={d => d.slice(5, 10)} />
                <YAxis tick={{ fontSize: 10, fill: '#6b7280' }} />
                <Tooltip contentStyle={{ background: '#ffffff', border: '1px solid #e5e7eb', borderRadius: 8, fontSize: 12 }} />
                <Line dataKey="credit_balance" stroke="#e11d48" dot={false} strokeWidth={2} name="Balance" />
              </LineChart>
            </ResponsiveContainer>
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Top spenders */}
        <div className="card">
          <h2 className="text-xs text-gray-500 font-medium uppercase tracking-wider mb-3">Top Credit Spenders</h2>
          <div className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={topSpend.slice(0, 10)} layout="vertical" margin={{ left: 0, right: 20 }}>
                <XAxis type="number" tick={{ fontSize: 10, fill: '#6b7280' }} />
                <YAxis dataKey="reference" type="category" tick={{ fontSize: 9, fill: '#9ca3af' }} width={70} />
                <Tooltip contentStyle={{ background: '#ffffff', border: '1px solid #e5e7eb', borderRadius: 8, fontSize: 12 }} />
                <Bar dataKey="total_credits_spent" fill="#e11d48" name="Credits" radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>

        {/* Zero-lead high-spend */}
        <div className="card">
          <h2 className="text-xs text-gray-500 font-medium uppercase tracking-wider mb-3">
            Zero Leads, Non-Zero Spend
            {zeroLead.length > 0 && <span className="ml-2 text-red-400">({zeroLead.length})</span>}
          </h2>
          {zeroLead.length === 0 ? (
            <p className="text-gray-600 text-sm py-8 text-center">None — great!</p>
          ) : (
            <div className="overflow-y-auto max-h-64">
              <table className="w-full text-xs">
                <thead className="border-b border-gray-200">
                  <tr>
                    <th className="px-2 py-1.5 text-left text-gray-500">Ref</th>
                    <th className="px-2 py-1.5 text-left text-gray-500">Tier</th>
                    <th className="px-2 py-1.5 text-right text-gray-500">Credits</th>
                    <th className="px-2 py-1.5 text-right text-gray-500">Days Live</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-200/40">
                  {zeroLead.map(row => (
                    <tr key={row.pf_listing_id} className="hover:bg-gray-100/40">
                      <td className="px-2 py-1.5 font-mono text-brand-600">{row.reference}</td>
                      <td className="px-2 py-1.5 text-gray-400 capitalize">{row.current_tier}</td>
                      <td className="px-2 py-1.5 text-right text-red-400 font-medium">{fmt(row.total_credits_spent)}</td>
                      <td className="px-2 py-1.5 text-right text-gray-500">{row.days_live ?? '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
