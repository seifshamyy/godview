import { useEffect, useState } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { supabase } from './lib/supabase'
import type { Session } from '@supabase/supabase-js'
import Layout from './components/Layout'
import Login from './pages/Login'
import Portfolio from './pages/Portfolio'
import ListingDetail from './pages/ListingDetail'
import AgentLeaderboard from './pages/AgentLeaderboard'
import AreaAnalysis from './pages/AreaAnalysis'
import TierAnalysis from './pages/TierAnalysis'
import Recommendations from './pages/Recommendations'
import CostCenter from './pages/CostCenter'
import SyncStatus from './pages/SyncStatus'

export default function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => subscription.unsubscribe()
  }, [])

  if (session === undefined) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="w-8 h-8 border-2 border-brand-600 border-t-transparent rounded-full animate-spin" />
      </div>
    )
  }

  if (!session) {
    return (
      <BrowserRouter>
        <Routes>
          <Route path="*" element={<Login />} />
        </Routes>
      </BrowserRouter>
    )
  }

  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Layout />}>
          <Route path="/" element={<Navigate to="/portfolio" replace />} />
          <Route path="/portfolio" element={<Portfolio />} />
          <Route path="/listing/:id" element={<ListingDetail />} />
          <Route path="/agents" element={<AgentLeaderboard />} />
          <Route path="/areas" element={<AreaAnalysis />} />
          <Route path="/tiers" element={<TierAnalysis />} />
          <Route path="/recommendations" element={<Recommendations />} />
          <Route path="/costs" element={<CostCenter />} />
          <Route path="/sync" element={<SyncStatus />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
