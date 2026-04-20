import { createSupabaseClient, getJWT, pfFetch, withSyncLog } from '../_shared/helpers.ts'

Deno.serve(async () => {
  const supabase = createSupabaseClient()
  try {
    await withSyncLog(supabase, 'leads', async () => {
      let jwt = await getJWT()
      let page = 1
      let hasMore = true
      let created = 0

      while (hasMore && page <= 500) {
        const result = await pfFetch('/leads', jwt, { page, perPage: 50 })
        jwt = result.jwt
        const body = result.data as Record<string, unknown>
        const leads = (body.data ?? body.leads ?? body ?? []) as Record<string, unknown>[]

        if (!Array.isArray(leads) || leads.length === 0) { hasMore = false; break }

        const mapped = leads.map(lead => {
          const listing = (lead.listing ?? {}) as Record<string, unknown>
          return {
            pf_lead_id:        String(lead.id ?? lead.pf_lead_id ?? ''),
            listing_reference: listing.reference as string ?? null,
            lead_created_at:   lead.createdAt as string ?? null,
            response_link:     lead.responseLink as string ?? null,
            raw_payload:       lead,
          }
        }).filter(l => l.pf_lead_id)

        const { error } = await supabase.from('pf_leads').upsert(mapped, { onConflict: 'pf_lead_id' })
        if (error) console.error('Lead upsert error:', error)
        else created += mapped.length

        if (leads.length < 50) hasMore = false
        page++
        await new Promise(r => setTimeout(r, 100))
      }

      return { created, updated: 0, synced: created }
    })

    return new Response(JSON.stringify({ ok: true }), { status: 200 })
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 })
  }
})
