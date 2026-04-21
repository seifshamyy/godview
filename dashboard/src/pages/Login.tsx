import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { Eye } from 'lucide-react'

export default function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setLoading(true)
    setError('')
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) setError(error.message)
    setLoading(false)
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50 px-4">
      <div className="w-full max-w-sm">
        <div className="flex items-center gap-3 mb-8 justify-center">
          <div className="w-10 h-10 bg-brand-600 rounded-xl flex items-center justify-center">
            <Eye className="w-5 h-5 text-gray-900" />
          </div>
          <div>
            <h1 className="text-xl font-bold text-gray-900 leading-none">PF Eye</h1>
            <p className="text-xs text-gray-500 mt-0.5">Performance Engine</p>
          </div>
        </div>

        <div className="card">
          <h2 className="text-sm font-semibold text-gray-600 mb-4">Sign in to your account</h2>
          <form onSubmit={handleSubmit} className="space-y-3">
            <div>
              <label className="block text-xs text-gray-500 mb-1">Email</label>
              <input
                type="email"
                value={email}
                onChange={e => setEmail(e.target.value)}
                className="input w-full"
                placeholder="you@company.com"
                required
              />
            </div>
            <div>
              <label className="block text-xs text-gray-500 mb-1">Password</label>
              <input
                type="password"
                value={password}
                onChange={e => setPassword(e.target.value)}
                className="input w-full"
                required
              />
            </div>
            {error && <p className="text-xs text-red-400">{error}</p>}
            <button type="submit" disabled={loading} className="btn-primary w-full mt-2">
              {loading ? 'Signing in…' : 'Sign in'}
            </button>
          </form>
        </div>
      </div>
    </div>
  )
}
