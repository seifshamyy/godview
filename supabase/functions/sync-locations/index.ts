import { createSupabaseClient, getJWT, pfFetch, withSyncLog, corsHeaders } from '../_shared/helpers.ts'

function displayName(loc: Record<string, unknown>): string {
  const tree = (loc.tree ?? []) as Record<string, unknown>[]
  if (!tree.length) return String(loc.name ?? '')
  if (String(tree[0]?.name ?? '').toLowerCase() === 'north coast') return 'North Coast'
  return String(tree[1]?.name ?? tree[0]?.name ?? loc.name ?? '')
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  const supabase = createSupabaseClient()
  try {
    await withSyncLog(supabase, 'locations', async (logId) => {
      // Collect all unique location_ids from our listings
      const { data: rows } = await supabase
        .from('pf_listings')
        .select('location_id')
        .not('location_id', 'is', null)

      const uniqueIds = [...new Set((rows ?? []).map((r: Record<string, unknown>) => r.location_id as number))]
      let synced = 0

      // Batch-fetch from PF API (comma-separated filter, 50 per call)
      const BATCH = 50
      let jwt = await getJWT()
      for (let i = 0; i < uniqueIds.length; i += BATCH) {
        const batch = uniqueIds.slice(i, i + BATCH)
        const result = await pfFetch('/locations', jwt, {
          'filter[id]': batch.join(','),
          perPage: BATCH,
        })
        jwt = result.jwt
        const body = result.data as Record<string, unknown>
        const locations = (body.data ?? []) as Record<string, unknown>[]

        const mapped = locations.map(loc => {
          const coords = (loc.coordinates ?? {}) as Record<string, unknown>
          return {
            location_id: Number(loc.id),
            name:        displayName(loc),
            lat:         coords.lat  != null ? Number(coords.lat)  : null,
            lng:         coords.lng  != null ? Number(coords.lng)  : null,
            parent_id:   null, // skip self-ref FK to avoid ordering issues
            raw_payload: loc,
            synced_at:   new Date().toISOString(),
          }
        })

        if (mapped.length) {
          const { error } = await supabase.from('pf_locations').upsert(mapped, { onConflict: 'location_id' })
          if (error) console.error('Location upsert error:', error)
          else synced += mapped.length
          await supabase.from('sync_log').update({ records_synced: synced }).eq('id', logId)
        }

        await new Promise(r => setTimeout(r, 50))
      }

      return { created: synced, updated: 0, synced }
    })

    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
