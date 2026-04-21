import { Outlet, NavLink, useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import {
  LayoutDashboard, Users, MapPin, Layers, Lightbulb,
  CreditCard, RefreshCw, LogOut
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
    <div className="flex min-h-screen bg-gray-50">
      {/* Sidebar */}
      <aside className="w-56 bg-white border-r border-gray-200 flex flex-col shrink-0 shadow-sm">
        <div className="flex items-center gap-2.5 px-4 py-4 border-b border-gray-100">
          <img src="/logo.png" alt="EBP Slash" className="h-8 w-auto" />
          <span className="font-bold text-gray-900 tracking-tight">EBP Slash</span>
        </div>
        <nav className="flex-1 px-2 py-3 space-y-0.5">
          {navItems.map(({ to, icon: Icon, label }) => (
            <NavLink
              key={to}
              to={to}
              className={({ isActive }) =>
                `flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm transition-colors ${
                  isActive
                    ? 'bg-brand-50 text-brand-600 font-medium'
                    : 'text-gray-500 hover:text-gray-900 hover:bg-gray-100'
                }`
              }
            >
              <Icon className="w-4 h-4" />
              {label}
            </NavLink>
          ))}
        </nav>
        <div className="p-2 border-t border-gray-100">
          <button onClick={handleSignOut} className="btn-ghost w-full flex items-center gap-2 text-gray-500">
            <LogOut className="w-4 h-4" />
            Sign out
          </button>
        </div>
      </aside>

      {/* Main content */}
      <main className="flex-1 overflow-auto bg-gray-50">
        <Outlet />
      </main>
    </div>
  )
}
