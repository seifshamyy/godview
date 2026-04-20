import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

export function todayUTC(): string {
  return new Date().toISOString().slice(0, 10) // "YYYY-MM-DD"
}

export function isToday(dateStr: string | null | undefined): boolean {
  if (!dateStr) return false
  return dateStr.slice(0, 10) === todayUTC()
}

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

export const SUPABASE_URL = 'https://oidizmsasvtffjhhzsmg.supabase.co'
export const SERVICE_ROLE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9pZGl6bXNhc3Z0ZmZqaGh6c21nIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1NDE1MjMyMCwiZXhwIjoyMDY5NzI4MzIwfQ.ZLXQnuQwCs0QZ5_UoxAS9vG63Eyg7yuTvY4LJ_9nSLE'
export const PF_JWT_ENDPOINT = 'https://primary-production-e1a92.up.railway.app/webhook/99a74fd0-4d49-4ceb-8b69-9e696dbea679'
export const PF_API_BASE = 'https://atlas.propertyfinder.com/v1'

let jwtCache: { token: string; expiresAt: number } | null = null

export async function getJWT(): Promise<string> {
  const now = Date.now()
  if (jwtCache && jwtCache.expiresAt - now > 5 * 60 * 1000) {
    return jwtCache.token
  }
  const res = await fetch(PF_JWT_ENDPOINT)
  if (!res.ok) throw new Error(`JWT endpoint failed: ${res.status}`)
  const data = await res.json()
  const token = data.accessToken ?? data.access_token ?? data.token
  const expiresIn = data.expiresIn ?? data.expires_in ?? 1800
  jwtCache = { token, expiresAt: now + expiresIn * 1000 }
  return token
}

export async function refreshJWT(): Promise<string> {
  jwtCache = null
  return getJWT()
}

export function createSupabaseClient() {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY)
}

export async function sleep(ms: number) {
  await new Promise(resolve => setTimeout(resolve, ms))
}

export async function pfFetch(
  path: string,
  jwt: string,
  params?: Record<string, string | number>,
  retryCount = 0
): Promise<{ data: unknown; jwt: string }> {
  const url = new URL(`${PF_API_BASE}${path}`)
  if (params) {
    for (const [k, v] of Object.entries(params)) {
      url.searchParams.set(k, String(v))
    }
  }

  const res = await fetch(url.toString(), {
    headers: {
      Authorization: `Bearer ${jwt}`,
      'Content-Type': 'application/json',
    },
  })

  if (res.status === 401) {
    if (retryCount >= 3) throw new Error('3 consecutive 401s — aborting sync')
    const newJwt = await refreshJWT()
    return pfFetch(path, newJwt, params, retryCount + 1)
  }

  if (res.status === 429) {
    if (retryCount >= 3) throw new Error('Rate limit retries exhausted')
    const backoff = Math.pow(2, retryCount) * 2000 + Math.random() * 1000
    await sleep(backoff)
    return pfFetch(path, jwt, params, retryCount + 1)
  }

  if (!res.ok) {
    throw new Error(`PF API ${path} failed: ${res.status} ${await res.text()}`)
  }

  return { data: await res.json(), jwt }
}

export class CancelledError extends Error {
  constructor() { super('Sync cancelled by user') }
}

export async function checkCancelled(
  supabase: ReturnType<typeof createSupabaseClient>,
  logId: number
): Promise<void> {
  const { data } = await supabase.from('sync_log').select('status').eq('id', logId).single()
  if (data?.status === 'CANCELLED') throw new CancelledError()
}

export async function emitProgress(
  supabase: ReturnType<typeof createSupabaseClient>,
  logId: number,
  synced: number
): Promise<void> {
  await supabase.from('sync_log').update({ records_synced: synced }).eq('id', logId)
}

export async function withSyncLog(
  supabase: ReturnType<typeof createSupabaseClient>,
  syncType: string,
  fn: (logId: number) => Promise<{ created: number; updated: number; synced: number }>
) {
  const { data: log } = await supabase
    .from('sync_log')
    .insert({ sync_type: syncType, status: 'RUNNING' })
    .select('id')
    .single()

  const logId = log?.id
  try {
    const result = await fn(logId)
    await supabase
      .from('sync_log')
      .update({
        status: 'SUCCESS',
        completed_at: new Date().toISOString(),
        records_synced: result.synced,
        records_created: result.created,
        records_updated: result.updated,
      })
      .eq('id', logId)
    return result
  } catch (err) {
    const status = err instanceof CancelledError ? 'CANCELLED' : 'FAILED'
    await supabase
      .from('sync_log')
      .update({
        status,
        completed_at: new Date().toISOString(),
        error_message: status === 'FAILED' ? String(err) : null,
      })
      .eq('id', logId)
    throw err
  }
}
