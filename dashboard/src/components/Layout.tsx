import { Outlet, NavLink, useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import {
  LayoutDashboard, Users, MapPin, Layers, Lightbulb,
  CreditCard, RefreshCw, LogOut, Eye
} from 'lucide-react'

const navItems = [
  { to: '/portfolio',        icon: LayoutDashboard, label: 'Portfolio' },
  { to: '/agents',           icon: Users,           label: 'Agents' },
  { to: '/areas',            icon: MapPin,          label: 'Areas' },
  { to: '/tiers',            icon: Layers,          label: 'Tiers' },
  { to: '/recommendations',  icon: Lightbulb,       label: 'Actions' },
  { to: '/costs',            icon: CreditCard,      label: 'Cost Center' },
  { to: '/sync',             icon: RefreshCw,       label: 'Sync' },
]

export default function Layout() {
  const navigate = useNavigate()

  const handleSignOut = async () => {
    await supabase.auth.signOut()
    navigate('/')
  }

  return (
    <div className="flex min-h-screen">
      {/* Sidebar */}
      <aside className="w-56 bg-gray-900 border-r border-gray-800 flex flex-col shrink-0">
        <div className="flex items-center gap-2 px-4 py-5 border-b border-gray-800">
          <Eye className="w-6 h-6 text-brand-500" />
          <span className="font-bold text-white tracking-tight">PF Eye</span>
        </div>
        <nav className="flex-1 px-2 py-3 space-y-0.5">
          {navItems.map(({ to, icon: Icon, label }) => (
            <NavLink
              key={to}
              to={to}
              className={({ isActive }) =>
                `flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm transition-colors ${
                  isActive
                    ? 'bg-brand-600/20 text-brand-400'
                    : 'text-gray-400 hover:text-white hover:bg-gray-800'
                }`
              }
            >
              <Icon className="w-4 h-4" />
              {label}
            </NavLink>
          ))}
        </nav>
        <div className="p-2 border-t border-gray-800">
          <button onClick={handleSignOut} className="btn-ghost w-full flex items-center gap-2">
            <LogOut className="w-4 h-4" />
            Sign out
          </button>
        </div>
      </aside>

      {/* Main content */}
      <main className="flex-1 overflow-auto bg-gray-950">
        <Outlet />
      </main>
    </div>
  )
}
