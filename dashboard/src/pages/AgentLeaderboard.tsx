import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import type { AgentLeaderboard } from '../lib/types'

function fmt(n: number | null | undefined) {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(Math.round(n))
}

export default function AgentLeaderboardPage() {
  const navigate = useNavigate()
  const [agents, setAgents] = useState<AgentLeaderboard[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.from('v_agent_leaderboard').select('*').order('total_leads', { ascending: false })
      .then(({ data }) => { setAgents((data as AgentLeaderboard[]) ?? []); setLoading(false) })
  }, [])

  if (loading) return <div className="flex items-center justify-center h-64"><div className="w-6 h-6 border-2 border-brand-600 border-t-transparent rounded-full animate-spin" /></div>

  return (
    <div className="p-6 space-y-4">
      <h1 className="text-lg font-bold text-gray-900">Agent Leaderboard</h1>
      <div className="card p-0 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-gray-200 bg-white/80">
              <tr>
                {['Agent', 'Live', 'Total Listings', 'Total Leads', 'Avg CPL', 'Avg Quality', 'Credits Spent'].map(h => (
                  <th key={h} className="px-3 py-2 text-left text-xs text-gray-500 font-medium">{h}</th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-200">
              {agents.map(agent => (
                <tr
                  key={agent.public_profile_id}
                  className="table-row-hover"
                  onClick={() => navigate(`/portfolio?agent=${encodeURIComponent(agent.agent_name)}`)}
                >
                  <td className="px-3 py-2">
                    <div className="flex items-center gap-2">
                      <span className="text-gray-900 font-medium">{agent.agent_name}</span>
                      {agent.is_super_agent && <span className="text-[10px] px-1.5 py-0.5 bg-amber-500/20 text-amber-300 rounded">Super</span>}
                    </div>
                    <div className="text-xs text-gray-500 mt-0.5">{agent.status}</div>
                  </td>
                  <td className="px-3 py-2 text-gray-600">{agent.live_listings}</td>
                  <td className="px-3 py-2 text-gray-400">{agent.total_listings}</td>
                  <td className="px-3 py-2 text-gray-600 font-medium">{agent.total_leads}</td>
                  <td className="px-3 py-2 text-gray-400">{fmt(agent.avg_cpl)}</td>
                  <td className="px-3 py-2 text-gray-400">{agent.avg_quality_score != null ? Math.round(agent.avg_quality_score) : '—'}</td>
                  <td className="px-3 py-2 text-gray-400">{fmt(agent.total_credits_spent)}</td>
                </tr>
              ))}
              {agents.length === 0 && (
                <tr><td colSpan={7} className="text-center py-12 text-gray-600">No agent data yet</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
