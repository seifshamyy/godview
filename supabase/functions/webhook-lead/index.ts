import { createSupabaseClient } from '../_shared/helpers.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 })

  const supabase = createSupabaseClient()
  try {
    const payload = await req.json() as Record<string, unknown>
    const events = Array.isArray(payload) ? payload : [payload]

    for (const event of events) {
      const lead = (event.data ?? event) as Record<string, unknown>
      const listing = (lead.listing ?? {}) as Record<string, unknown>

      const row = {
        pf_lead_id:        String(lead.id ?? ''),
        listing_reference: listing.reference as string ?? null,
        lead_created_at:   lead.createdAt as string ?? new Date().toISOString(),
        response_link:     lead.responseLink as string ?? null,
        raw_payload:       event,
      }

      if (row.pf_lead_id) {
        const { error } = await supabase.from('pf_leads').upsert(row, { onConflict: 'pf_lead_id' })
        if (error) console.error('Webhook lead upsert error:', error)
      }
    }

    return new Response(JSON.stringify({ ok: true }), { status: 200 })
  } catch (err) {
    console.error('Webhook lead error:', err)
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 })
  }
})
