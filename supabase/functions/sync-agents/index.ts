import { createSupabaseClient, getJWT, pfFetch, withSyncLog, corsHeaders } from '../_shared/helpers.ts'

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  const supabase = createSupabaseClient()
  try {
    await withSyncLog(supabase, 'agents', async (logId) => {
      // Source of truth: agent_public_profile_id on listings.
      // The /users API returns internal user IDs (106788+) which don't match
      // the public profile IDs (5543, 57515, etc.) that listings reference.
      // Build pf_agents directly from listing data so the join always works.
      const { error } = await supabase.rpc('upsert_agents_from_listings')
      if (error) throw new Error(`Agent upsert failed: ${error.message}`)

      const { count } = await supabase
        .from('pf_agents')
        .select('*', { count: 'exact', head: true })
      const synced = count ?? 0
      await supabase.from('sync_log').update({ records_synced: synced }).eq('id', logId)

      // Agent stats — non-fatal, endpoint occasionally 502s
      try {
        const jwt = await getJWT()
        const statsResult = await pfFetch('/stats/public-profiles', jwt)
        const statsBody = statsResult.data as Record<string, unknown>
        const profiles = (statsBody.data ?? statsBody.profiles ?? []) as Record<string, unknown>[]
        if (Array.isArray(profiles) && profiles.length > 0) {
          const statsRows = profiles.map(p => ({
            agent_public_profile_id: Number((p as Record<string, unknown>).publicProfileId ?? (p as Record<string, unknown>).id),
            stats_payload:           p,
            snapshot_date:           new Date().toISOString().split('T')[0],
          })).filter(s => s.agent_public_profile_id)
          await supabase.from('pf_agent_stats').upsert(statsRows, { onConflict: 'agent_public_profile_id,snapshot_date' })
        }
      } catch (e) {
        console.error('Agent stats sync failed (non-fatal):', e)
      }

      return { created: synced, updated: 0, synced }
    })

    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
