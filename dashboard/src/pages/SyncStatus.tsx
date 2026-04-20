import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { SyncLogEntry } from '../lib/types'
import { RefreshCw, CheckCircle, XCircle, Clock, AlertCircle } from 'lucide-react'

const SYNC_TYPES = ['listings', 'leads', 'credits', 'agents', 'scoring']

const STATUS_ICONS: Record<string, React.ReactNode> = {
  SUCCESS: <CheckCircle className="w-4 h-4 text-green-400" />,
  FAILED:  <XCircle className="w-4 h-4 text-red-400" />,
  RUNNING: <Clock className="w-4 h-4 text-yellow-400 animate-pulse" />,
  PARTIAL: <AlertCircle className="w-4 h-4 text-orange-400" />,
}

const EDGE_FUNCTION_BASE = 'https://oidizmsasvtffjhhzsmg.supabase.co/functions/v1'
const SERVICE_ROLE = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9pZGl6bXNhc3Z0ZmZqaGh6c21nIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1NDE1MjMyMCwiZXhwIjoyMDY5NzI4MzIwfQ.ZLXQnuQwCs0QZ5_UoxAS9vG63Eyg7yuTvY4LJ_9nSLE'

function timeSince(dt: string) {
  const diff = Date.now() - new Date(dt).getTime()
  const m = Math.floor(diff / 60000)
  if (m < 60) return `${m}m ago`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h ago`
  return `${Math.floor(h / 24)}d ago`
}

export default function SyncStatus() {
  const [logs, setLogs] = useState<SyncLogEntry[]>([])
  const [all, setAll] = useState<SyncLogEntry[]>([])
  const [loading, setLoading] = useState(true)
  const [triggering, setTriggering] = useState<string | null>(null)

  const fetchLogs = () => {
    supabase.from('sync_log').select('*').order('started_at', { ascending: false }).limit(100)
      .then(({ data }) => {
        const entries = (data as SyncLogEntry[]) ?? []
        setAll(entries)
        const latest: Record<string, SyncLogEntry> = {}
        entries.forEach(e => { if (!latest[e.sync_type]) latest[e.sync_type] = e })
        setLogs(Object.values(latest))
        setLoading(false)
      })
  }

  useEffect(() => { fetchLogs() }, [])

  const triggerSync = async (type: string) => {
    setTriggering(type)
    try {
      const fnName = type === 'scoring' ? 'run-scoring-pipeline' : `sync-${type}`
      await fetch(`${EDGE_FUNCTION_BASE}/${fnName}`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${SERVICE_ROLE}`, 'Content-Type': 'application/json' },
        body: '{}',
      })
      setTimeout(fetchLogs, 2000)
    } catch (e) {
      console.error(e)
    } finally {
      setTriggering(null)
    }
  }

  if (loading) return <div className="flex items-center justify-center h-64"><div className="w-6 h-6 border-2 border-brand-500 border-t-transparent rounded-full animate-spin" /></div>

  return (
    <div className="p-6 space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-bold text-white">Sync Status</h1>
        <button onClick={fetchLogs} className="btn-ghost flex items-center gap-1.5">
          <RefreshCw className="w-3.5 h-3.5" /> Refresh
        </button>
      </div>

      {/* Latest status per type */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        {SYNC_TYPES.map(type => {
          const log = logs.find(l => l.sync_type === type)
          return (
            <div key={type} className="card">
              <div className="flex items-center justify-between mb-3">
                <div className="flex items-center gap-2">
                  {log ? STATUS_ICONS[log.status] ?? STATUS_ICONS.FAILED : <div className="w-4 h-4 rounded-full bg-gray-700" />}
                  <span className="text-sm font-semibold text-white capitalize">{type}</span>
                </div>
                <button
                  onClick={() => triggerSync(type)}
                  disabled={triggering === type}
                  className="text-xs text-brand-400 hover:text-brand-300 flex items-center gap-1 disabled:opacity-50"
                >
                  <RefreshCw className={`w-3 h-3 ${triggering === type ? 'animate-spin' : ''}`} />
                  Run now
                </button>
              </div>
              {log ? (
                <div className="space-y-1 text-xs text-gray-500">
                  <div className="flex justify-between"><span>Last run</span><span>{timeSince(log.started_at)}</span></div>
                  <div className="flex justify-between"><span>Status</span><span className={log.status === 'SUCCESS' ? 'text-green-400' : log.status === 'FAILED' ? 'text-red-400' : 'text-yellow-400'}>{log.status}</span></div>
                  <div className="flex justify-between"><span>Records synced</span><span>{log.records_synced}</span></div>
                  {log.error_message && <div className="text-red-400 mt-1 truncate">{log.error_message}</div>}
                </div>
              ) : (
                <div className="text-xs text-gray-600">Never run</div>
              )}
            </div>
          )
        })}
      </div>

      {/* Full log */}
      <div className="card p-0 overflow-hidden">
        <div className="px-4 py-3 border-b border-gray-800">
          <h2 className="text-xs text-gray-500 font-medium uppercase tracking-wider">Sync History</h2>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead className="border-b border-gray-800 bg-gray-900/50">
              <tr>
                {['Type', 'Started', 'Status', 'Synced', 'Created', 'Updated', 'Error'].map(h => (
                  <th key={h} className="px-3 py-2 text-left text-gray-500 font-medium">{h}</th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-800/60">
              {all.slice(0, 50).map(log => (
                <tr key={log.id}>
                  <td className="px-3 py-2 text-gray-300 capitalize font-medium">{log.sync_type}</td>
                  <td className="px-3 py-2 text-gray-500">{timeSince(log.started_at)}</td>
                  <td className="px-3 py-2">
                    <span className={`flex items-center gap-1 ${log.status === 'SUCCESS' ? 'text-green-400' : log.status === 'FAILED' ? 'text-red-400' : 'text-yellow-400'}`}>
                      {STATUS_ICONS[log.status]}
                      {log.status}
                    </span>
                  </td>
                  <td className="px-3 py-2 text-gray-400">{log.records_synced}</td>
                  <td className="px-3 py-2 text-gray-400">{log.records_created}</td>
                  <td className="px-3 py-2 text-gray-400">{log.records_updated}</td>
                  <td className="px-3 py-2 text-red-400 max-w-xs truncate">{log.error_message ?? ''}</td>
                </tr>
              ))}
              {all.length === 0 && <tr><td colSpan={7} className="text-center py-8 text-gray-600">No sync history yet</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
