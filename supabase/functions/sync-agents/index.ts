import { createSupabaseClient, getJWT, pfFetch, withSyncLog, corsHeaders } from '../_shared/helpers.ts'

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  const supabase = createSupabaseClient()
  try {
    await withSyncLog(supabase, 'agents', async () => {
      let jwt = await getJWT()
      let page = 1
      let hasMore = true
      let synced = 0

      // Sync users/agents
      while (hasMore && page <= 50) {
        const result = await pfFetch('/users', jwt, { page, perPage: 100 })
        jwt = result.jwt
        const body = result.data as Record<string, unknown>
        const users = (body.data ?? body.users ?? body ?? []) as Record<string, unknown>[]

        if (!Array.isArray(users) || users.length === 0) { hasMore = false; break }

        const mapped = users.map(u => {
          const raw = u as Record<string, unknown>
          return {
            public_profile_id:  raw.publicProfileId != null ? Number(raw.publicProfileId) : Number(raw.id),
            user_id:            raw.id != null ? Number(raw.id) : null,
            first_name:         raw.firstName as string ?? null,
            last_name:          raw.lastName as string ?? null,
            email:              raw.email as string ?? null,
            phone:              raw.phone as string ?? null,
            status:             raw.status as string ?? null,
            role_name:          raw.roleName as string ?? raw.role as string ?? null,
            is_super_agent:     Boolean(raw.isSuperAgent),
            verification_status: raw.verificationStatus as string ?? null,
            raw_payload:        raw,
          }
        }).filter(u => u.public_profile_id)

        const { error } = await supabase.from('pf_agents').upsert(mapped, { onConflict: 'public_profile_id' })
        if (error) console.error('Agents upsert error:', error)
        else synced += mapped.length

        if (users.length < 100) hasMore = false
        page++
        await new Promise(r => setTimeout(r, 100))
      }

      // Sync agent stats
      const statsResult = await pfFetch('/stats/public-profiles', jwt)
      jwt = statsResult.jwt
      const statsBody = statsResult.data as Record<string, unknown>
      const profiles = (statsBody.data ?? statsBody.profiles ?? statsBody ?? []) as Record<string, unknown>[]

      if (Array.isArray(profiles) && profiles.length > 0) {
        const statsRows = profiles.map(p => ({
          agent_public_profile_id: Number((p as Record<string, unknown>).publicProfileId ?? (p as Record<string, unknown>).id),
          stats_payload:           p,
          snapshot_date:           new Date().toISOString().split('T')[0],
        })).filter(s => s.agent_public_profile_id)

        await supabase.from('pf_agent_stats').upsert(statsRows, { onConflict: 'agent_public_profile_id,snapshot_date' })
      }

      return { created: synced, updated: 0, synced }
    })

    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
