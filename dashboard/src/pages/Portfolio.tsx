import { useEffect, useState, useMemo, useCallback, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import type { PortfolioRow } from '../lib/types'
import StatCard from '../components/StatCard'
import ScoreBadge from '../components/ScoreBadge'
import TierBadge from '../components/TierBadge'
import { Search, ChevronDown } from 'lucide-react'
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell } from 'recharts'

const PAGE_SIZE = 300

const BAND_COLORS: Record<string, string> = {
  S: '#a78bfa', A: '#4ade80', B: '#60a5fa', C: '#fbbf24', D: '#f97316', F: '#ef4444'
}

function fmt(n: number | null) {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(n)
}

interface Stats {
  total: number
  live: number
  leads_30d: number
  scored: number
  avg_cpl: number | null
  band_dist: { band: string; count: number }[]
  destinations: string[]
  types: string[]
  locations: { name: string; destination: string | null }[]
}

type SortCol = 'total_score' | 'effective_price' | 'leads_30d' | 'cpl' | 'days_live' | 'pf_quality_score'

export default function Portfolio() {
  const navigate = useNavigate()
  const [stats, setStats]           = useState<Stats | null>(null)
  const [rows, setRows]             = useState<PortfolioRow[]>([])
  const [total, setTotal]           = useState(0)
  const [loading, setLoading]       = useState(true)
  const [loadingMore, setLoadingMore] = useState(false)
  const [offset, setOffset]         = useState(0)

  const [search, setSearch]               = useState('')
  const [filterDest, setFilterDest]       = useState('')
  const [filterLocation, setFilterLocation] = useState('')
  const [filterTier, setFilterTier]       = useState('')
  const [filterBand, setFilterBand]       = useState('')
  const [filterType, setFilterType]       = useState('')
  const [sortCol, setSortCol]             = useState<SortCol>('total_score')
  const [sortAsc, setSortAsc]             = useState(false)
  const [debouncedSearch, setDebouncedSearch] = useState('')
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const onSearch = (v: string) => {
    setSearch(v)
    if (debounceRef.current) clearTimeout(debounceRef.current)
    debounceRef.current = setTimeout(() => setDebouncedSearch(v), 350)
  }

  useEffect(() => {
    supabase.rpc('get_portfolio_stats').then(({ data }) => {
      if (data) setStats(data as Stats)
    })
  }, [])

  const fetchPage = useCallback(async (newOffset: number, replace: boolean) => {
    if (newOffset === 0) setLoading(true)
    else setLoadingMore(true)

    const { data, error } = await supabase.rpc('get_portfolio_page', {
      p_search:   debouncedSearch || null,
      p_dest:     filterDest     || null,
      p_location: filterLocation || null,
      p_tier:     filterTier     || null,
      p_band:     filterBand     || null,
      p_type:     filterType     || null,
      p_sort:     sortCol,
      p_asc:      sortAsc,
      p_limit:    PAGE_SIZE,
      p_offset:   newOffset,
    })

    if (!error && data) {
      const result = data as { total: number; rows: PortfolioRow[] }
      setTotal(result.total)
      setRows(prev => replace ? result.rows : [...prev, ...result.rows])
      setOffset(newOffset + result.rows.length)
    }
    setLoading(false)
    setLoadingMore(false)
  }, [debouncedSearch, filterDest, filterLocation, filterTier, filterBand, filterType, sortCol, sortAsc])

  useEffect(() => { fetchPage(0, true) }, [fetchPage])

  const handleSort = (col: SortCol) => {
    if (sortCol === col) setSortAsc(a => !a)
    else { setSortCol(col); setSortAsc(false) }
  }

  const locations = useMemo(() => {
    if (!stats) return []
    const src = filterDest ? stats.locations.filter(l => l.destination === filterDest) : stats.locations
    return src.map(l => l.name)
  }, [stats, filterDest])

  const bandDist = stats?.band_dist ?? []
  const hasMore  = rows.length < total

  const Th = ({ col, label }: { col: SortCol; label: string }) => (
    <th
      className="px-3 py-2 text-left text-xs text-gray-500 font-medium cursor-pointer hover:text-gray-700 select-none whitespace-nowrap"
      onClick={() => handleSort(col)}
    >
      {label} {sortCol === col ? (sortAsc ? '↑' : '↓') : ''}
    </th>
  )

  return (
    <div className="p-6 space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-bold text-gray-900">Portfolio Overview</h1>
        {stats && <span className="text-xs text-gray-400">{stats.total.toLocaleString()} listings</span>}
      </div>

      {/* Stat cards */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard label="Live Listings" value={stats ? stats.live : '—'} />
        <StatCard label="Leads (30d)"   value={stats ? fmt(stats.leads_30d) : '—'} />
        <StatCard label="Avg CPL"       value={stats?.avg_cpl != null ? fmt(Math.round(stats.avg_cpl)) : '—'} />
        <StatCard label="Scored"        value={stats ? stats.scored : '—'} />
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
                <Tooltip contentStyle={{ background: '#ffffff', border: '1px solid #e5e7eb', borderRadius: 8, fontSize: 12 }} cursor={{ fill: 'rgba(0,0,0,0.04)' }} />
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
          <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-gray-400" />
          <input className="input pl-8 w-52" placeholder="Search ref or location…" value={search} onChange={e => onSearch(e.target.value)} />
        </div>
        <select className="input" value={filterDest} onChange={e => { setFilterDest(e.target.value); setFilterLocation('') }}>
          <option value="">All destinations</option>
          {stats?.destinations.map(d => <option key={d} value={d}>{d}</option>)}
        </select>
        <select className="input" value={filterLocation} onChange={e => setFilterLocation(e.target.value)}>
          <option value="">All locations</option>
          {locations.map(l => <option key={l} value={l}>{l}</option>)}
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
          {stats?.types.map(t => <option key={t} value={t}>{t}</option>)}
        </select>
        <span className="text-xs text-gray-400 ml-auto">
          {loading ? 'Loading…' : `${rows.length.toLocaleString()} / ${total.toLocaleString()}`}
        </span>
      </div>

      {/* Table */}
      <div className="card p-0 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-gray-200 bg-gray-50">
              <tr>
                <Th col="total_score"      label="Score" />
                <th className="px-3 py-2 text-left text-xs text-gray-500 font-medium">Ref</th>
                <th className="px-3 py-2 text-left text-xs text-gray-500 font-medium">Type</th>
                <th className="px-3 py-2 text-left text-xs text-gray-500 font-medium">Beds</th>
                <th className="px-3 py-2 text-left text-xs text-gray-500 font-medium">Destination</th>
                <th className="px-3 py-2 text-left text-xs text-gray-500 font-medium">Location</th>
                <Th col="effective_price"  label="Price" />
                <th className="px-3 py-2 text-left text-xs text-gray-500 font-medium">Tier</th>
                <Th col="pf_quality_score" label="Quality" />
                <Th col="leads_30d"        label="Leads 30d" />
                <Th col="cpl"              label="CPL" />
                <th className="px-3 py-2 text-left text-xs text-gray-500 font-medium">Agent</th>
                <Th col="days_live"        label="Days" />
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-200">
              {loading ? (
                <tr><td colSpan={13} className="text-center py-16">
                  <div className="w-6 h-6 border-2 border-brand-600 border-t-transparent rounded-full animate-spin mx-auto" />
                </td></tr>
              ) : rows.length === 0 ? (
                <tr><td colSpan={13} className="text-center py-12 text-gray-400">No listings found</td></tr>
              ) : rows.map(row => (
                <tr key={row.pf_listing_id} className="table-row-hover" onClick={() => navigate(`/listing/${row.pf_listing_id}`)}>
                  <td className="px-3 py-2"><ScoreBadge band={row.score_band} score={row.total_score} /></td>
                  <td className="px-3 py-2 font-mono text-xs text-brand-600">{row.reference}</td>
                  <td className="px-3 py-2 text-gray-700 capitalize">{row.property_type ?? '—'}</td>
                  <td className="px-3 py-2 text-gray-500">{row.bedrooms ?? '—'}</td>
                  <td className="px-3 py-2 text-gray-500 max-w-[110px] truncate">{row.destination ?? '—'}</td>
                  <td className="px-3 py-2 text-gray-500 max-w-[130px] truncate">{row.location_name ?? '—'}</td>
                  <td className="px-3 py-2 text-gray-700 whitespace-nowrap">{fmt(row.effective_price)}</td>
                  <td className="px-3 py-2"><TierBadge tier={row.current_tier} /></td>
                  <td className="px-3 py-2">
                    <span className={`text-xs font-medium ${
                      row.pf_quality_color === 'green' ? 'text-green-600' :
                      row.pf_quality_color === 'yellow' ? 'text-yellow-600' : 'text-red-500'
                    }`}>{row.pf_quality_score ?? '—'}</span>
                  </td>
                  <td className="px-3 py-2 text-gray-700">{row.leads_30d ?? 0}</td>
                  <td className="px-3 py-2 text-gray-500">{row.cpl != null ? fmt(Math.round(row.cpl)) : '—'}</td>
                  <td className="px-3 py-2 text-gray-400 text-xs max-w-[90px] truncate">{row.agent_name ?? '—'}</td>
                  <td className="px-3 py-2 text-gray-500">{row.days_live ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {hasMore && !loading && (
          <div className="border-t border-gray-200 px-4 py-3 flex items-center justify-between bg-gray-50">
            <span className="text-xs text-gray-500">Showing {rows.length.toLocaleString()} of {total.toLocaleString()}</span>
            <button
              onClick={() => fetchPage(offset, false)}
              disabled={loadingMore}
              className="flex items-center gap-1.5 text-xs text-brand-600 hover:text-brand-700 font-medium disabled:opacity-50"
            >
              {loadingMore
                ? <><div className="w-3.5 h-3.5 border-2 border-brand-600 border-t-transparent rounded-full animate-spin" /> Loading…</>
                : <><ChevronDown className="w-3.5 h-3.5" /> Load next {PAGE_SIZE}</>}
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
