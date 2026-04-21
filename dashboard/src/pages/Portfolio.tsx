import { useEffect, useState, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import type { PortfolioRow } from '../lib/types'
import StatCard from '../components/StatCard'
import ScoreBadge from '../components/ScoreBadge'
import TierBadge from '../components/TierBadge'
import { Search, SlidersHorizontal } from 'lucide-react'
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell } from 'recharts'

const BAND_COLORS: Record<string, string> = {
  S: '#a78bfa', A: '#4ade80', B: '#60a5fa', C: '#fbbf24', D: '#f97316', F: '#ef4444'
}

function fmt(n: number | null) {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(n)
}

export default function Portfolio() {
  const navigate = useNavigate()
  const [rows, setRows] = useState<PortfolioRow[]>([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [filterTier, setFilterTier] = useState('')
  const [filterBand, setFilterBand] = useState('')
  const [filterType, setFilterType] = useState('')
  const [filterDest, setFilterDest] = useState('')
  const [filterLocation, setFilterLocation] = useState('')
  const [sortCol, setSortCol] = useState<keyof PortfolioRow>('total_score')
  const [sortAsc, setSortAsc] = useState(false)

  useEffect(() => {
    supabase
      .rpc('get_portfolio_overview')
      .then(({ data, error }) => {
        if (error) console.error('Portfolio fetch error:', error)
        // RPC returns json — Supabase wraps scalar json in an array, unwrap it
        const rows = Array.isArray(data) ? data : (data ?? [])
        setRows(rows as PortfolioRow[])
        setLoading(false)
      })
  }, [])

  const destinations = useMemo(() => [...new Set(rows.map(r => r.destination).filter(Boolean))].sort(), [rows])
  const locations    = useMemo(() => {
    const src = filterDest ? rows.filter(r => r.destination === filterDest) : rows
    return [...new Set(src.map(r => r.location_name).filter(Boolean))].sort()
  }, [rows, filterDest])

  const filtered = useMemo(() => {
    let r = rows
    if (search) r = r.filter(x =>
      x.reference?.toLowerCase().includes(search.toLowerCase()) ||
      x.location_name?.toLowerCase().includes(search.toLowerCase()) ||
      x.destination?.toLowerCase().includes(search.toLowerCase())
    )
    if (filterDest) r = r.filter(x => x.destination === filterDest)
    if (filterLocation) r = r.filter(x => x.location_name === filterLocation)
    if (filterTier) r = r.filter(x => x.current_tier === filterTier)
    if (filterBand) r = r.filter(x => x.score_band === filterBand)
    if (filterType) r = r.filter(x => x.property_type === filterType)
    return [...r].sort((a, b) => {
      const av = a[sortCol] ?? 0
      const bv = b[sortCol] ?? 0
      return sortAsc ? (av > bv ? 1 : -1) : (av < bv ? 1 : -1)
    })
  }, [rows, search, filterTier, filterBand, filterType, sortCol, sortAsc])

  const stats = useMemo(() => {
    const live = rows.filter(r => r.is_live)
    const leads30 = rows.reduce((s, r) => s + r.leads_30d, 0)
    const withLeads = rows.filter(r => r.total_leads > 0 && r.cpl != null)
    const avgCpl = withLeads.length ? withLeads.reduce((s, r) => s + (r.cpl ?? 0), 0) / withLeads.length : null
    return { live: live.length, leads30, avgCpl }
  }, [rows])

  const bandDist = useMemo(() => {
    const counts: Record<string, number> = { S: 0, A: 0, B: 0, C: 0, D: 0, F: 0 }
    rows.forEach(r => { if (r.score_band) counts[r.score_band] = (counts[r.score_band] ?? 0) + 1 })
    return Object.entries(counts).map(([band, count]) => ({ band, count }))
  }, [rows])

  const types = useMemo(() => [...new Set(rows.map(r => r.property_type).filter(Boolean))], [rows])

  const handleSort = (col: keyof PortfolioRow) => {
    if (sortCol === col) setSortAsc(!sortAsc)
    else { setSortCol(col); setSortAsc(false) }
  }

  const Th = ({ col, label }: { col: keyof PortfolioRow; label: string }) => (
    <th
      className="px-3 py-2 text-left text-xs text-gray-500 font-medium cursor-pointer hover:text-gray-300 select-none whitespace-nowrap"
      onClick={() => handleSort(col)}
    >
      {label} {sortCol === col ? (sortAsc ? '↑' : '↓') : ''}
    </th>
  )

  if (loading) return <div className="flex items-center justify-center h-64"><div className="w-6 h-6 border-2 border-brand-500 border-t-transparent rounded-full animate-spin" /></div>

  return (
    <div className="p-6 space-y-6">
      <h1 className="text-lg font-bold text-white">Portfolio Overview</h1>

      {/* Stat cards */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard label="Live Listings" value={stats.live} />
        <StatCard label="Leads (30d)" value={fmt(stats.leads30)} />
        <StatCard label="Avg CPL" value={stats.avgCpl != null ? fmt(Math.round(stats.avgCpl)) : '—'} />
        <StatCard label="Scored" value={rows.filter(r => r.score_band).length} />
      </div>

      {/* Score distribution */}
      {bandDist.some(b => b.count > 0) && (
        <div className="card">
          <h2 className="text-xs text-gray-500 font-medium uppercase tracking-wider mb-3">Score Distribution</h2>
          <div className="h-32">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={bandDist} layout="vertical" margin={{ left: 0, right: 20 }}>
                <XAxis type="number" tick={{ fontSize: 11, fill: '#6b7280' }} />
                <YAxis dataKey="band" type="category" tick={{ fontSize: 12, fill: '#9ca3af' }} width={20} />
                <Tooltip
                  contentStyle={{ background: '#111827', border: '1px solid #374151', borderRadius: 8, fontSize: 12 }}
                  cursor={{ fill: 'rgba(255,255,255,0.04)' }}
                />
                <Bar dataKey="count" radius={[0, 4, 4, 0]}>
                  {bandDist.map(({ band }) => <Cell key={band} fill={BAND_COLORS[band] ?? '#6b7280'} />)}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>
      )}

      {/* Filters */}
      <div className="flex flex-wrap gap-2 items-center">
        <div className="relative">
          <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-gray-500" />
          <input
            className="input pl-8 w-52"
            placeholder="Search ref or location…"
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <select className="input" value={filterDest} onChange={e => { setFilterDest(e.target.value); setFilterLocation('') }}>
          <option value="">All destinations</option>
          {destinations.map(d => <option key={d!} value={d!}>{d}</option>)}
        </select>
        <select className="input" value={filterLocation} onChange={e => setFilterLocation(e.target.value)}>
          <option value="">All locations</option>
          {locations.map(l => <option key={l!} value={l!}>{l}</option>)}
        </select>
        <select className="input" value={filterTier} onChange={e => setFilterTier(e.target.value)}>
          <option value="">All tiers</option>
          {['featured', 'premium', 'standard', 'none'].map(t => <option key={t} value={t}>{t}</option>)}
        </select>
        <select className="input" value={filterBand} onChange={e => setFilterBand(e.target.value)}>
          <option value="">All bands</option>
          {['S', 'A', 'B', 'C', 'D', 'F'].map(b => <option key={b} value={b}>Band {b}</option>)}
        </select>
        <select className="input" value={filterType} onChange={e => setFilterType(e.target.value)}>
          <option value="">All types</option>
          {types.map(t => <option key={t!} value={t!}>{t}</option>)}
        </select>
        <span className="text-xs text-gray-500 ml-auto">{filtered.length} listings</span>
      </div>

      {/* Table */}
      <div className="card p-0 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-gray-800 bg-gray-900/50">
              <tr>
                <Th col="reference" label="Ref" />
                <Th col="property_type" label="Type" />
                <Th col="bedrooms" label="Beds" />
                <Th col="destination" label="Destination" />
                <Th col="location_name" label="Location" />
                <Th col="effective_price" label="Price" />
                <th className="px-3 py-2 text-left text-xs text-gray-500 font-medium">Tier</th>
                <Th col="pf_quality_score" label="Quality" />
                <Th col="leads_30d" label="Leads 30d" />
                <Th col="cpl" label="CPL" />
                <Th col="total_score" label="Score" />
                <Th col="agent_name" label="Agent" />
                <Th col="days_live" label="Days Live" />
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-800/60">
              {filtered.map(row => (
                <tr
                  key={row.pf_listing_id}
                  className="table-row-hover"
                  onClick={() => navigate(`/listing/${row.pf_listing_id}`)}
                >
                  <td className="px-3 py-2 font-mono text-xs text-brand-400">{row.reference}</td>
                  <td className="px-3 py-2 text-gray-300 capitalize">{row.property_type ?? '—'}</td>
                  <td className="px-3 py-2 text-gray-400">{row.bedrooms ?? '—'}</td>
                  <td className="px-3 py-2 text-gray-400 max-w-[120px] truncate">{row.destination ?? '—'}</td>
                  <td className="px-3 py-2 text-gray-400 max-w-[140px] truncate">{row.location_name ?? '—'}</td>
                  <td className="px-3 py-2 text-gray-300 whitespace-nowrap">{fmt(row.effective_price)}</td>
                  <td className="px-3 py-2"><TierBadge tier={row.current_tier} /></td>
                  <td className="px-3 py-2">
                    <span className={`text-xs font-medium ${row.pf_quality_color === 'green' ? 'text-green-400' : row.pf_quality_color === 'yellow' ? 'text-yellow-400' : 'text-red-400'}`}>
                      {row.pf_quality_score ?? '—'}
                    </span>
                  </td>
                  <td className="px-3 py-2 text-gray-300">{row.leads_30d}</td>
                  <td className="px-3 py-2 text-gray-400">{row.cpl != null ? fmt(Math.round(row.cpl)) : '—'}</td>
                  <td className="px-3 py-2"><ScoreBadge band={row.score_band} score={row.total_score} /></td>
                  <td className="px-3 py-2 text-gray-500 text-xs max-w-[100px] truncate">{row.agent_name ?? '—'}</td>
                  <td className="px-3 py-2 text-gray-400">{row.days_live ?? '—'}</td>
                </tr>
              ))}
              {filtered.length === 0 && (
                <tr><td colSpan={12} className="text-center py-12 text-gray-600">No listings found</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
