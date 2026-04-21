import { createSupabaseClient, getJWT, pfFetch, withSyncLog, corsHeaders } from '../_shared/helpers.ts'

function getNames(loc: Record<string, unknown>): { name: string; destination: string } {
  const tree = (loc.tree ?? []) as Record<string, unknown>[]
  const leaf = String(loc.name ?? '')
  if (!tree.length) return { name: leaf, destination: leaf }

  const t = (node: unknown) => node as Record<string, unknown>

  // North Coast: destination = "North Coast", granular = the leaf
  if (String(tree[0]?.name ?? '').toLowerCase() === 'north coast') {
    return { name: leaf, destination: 'North Coast' }
  }

  // Destination = TOWN level (tree[1]) if it exists, else CITY (tree[0])
  const destination = String(tree[1]?.name ?? tree[0]?.name ?? leaf)

  return { name: leaf, destination }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  const supabase = createSupabaseClient()
  try {
    await withSyncLog(supabase, 'locations', async (logId) => {
      // Paginate through ALL listings to collect unique location_ids
      // (can't do SELECT DISTINCT via client — PostgREST caps at 1000 rows)
      const allIds: Set<number> = new Set()
      let from = 0
      while (true) {
        const { data } = await supabase
          .from('pf_listings')
          .select('location_id')
          .not('location_id', 'is', null)
          .range(from, from + 999)
        if (!data || data.length === 0) break
        data.forEach((r: Record<string, unknown>) => allIds.add(r.location_id as number))
        if (data.length < 1000) break
        from += 1000
      }

      const uniqueIds = [...allIds]
      let synced = 0
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
          const { name, destination } = getNames(loc)
          return {
            location_id: Number(loc.id),
            name,
            destination,
            lat:         coords.lat != null ? Number(coords.lat) : null,
            lng:         coords.lng != null ? Number(coords.lng) : null,
            parent_id:   null,
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
