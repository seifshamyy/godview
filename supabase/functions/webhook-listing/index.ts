import { createSupabaseClient } from '../_shared/helpers.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 })

  const supabase = createSupabaseClient()
  try {
    const payload = await req.json() as Record<string, unknown>
    const eventType = payload.eventId as string ?? payload.event as string ?? ''
    const listing = (payload.data ?? payload.listing ?? payload) as Record<string, unknown>
    const listingId = String(listing.id ?? listing.pf_listing_id ?? '')
    const reference = listing.reference as string ?? null

    if (!listingId && !reference) {
      return new Response(JSON.stringify({ ok: true, skipped: true }), { status: 200 })
    }

    if (eventType.includes('published') || eventType.includes('listing.published')) {
      const updates: Record<string, unknown> = {
        is_live: true,
        listing_stage: 'live',
        last_synced_at: new Date().toISOString(),
      }
      if (listing.portals?.propertyfinder?.publishedAt) {
        updates.published_at = listing.portals.propertyfinder.publishedAt
      }
      const query = listingId
        ? supabase.from('pf_listings').update(updates).eq('pf_listing_id', listingId)
        : supabase.from('pf_listings').update(updates).eq('reference', reference)
      const { error } = await query
      if (error) console.error('Webhook listing published error:', error)
    } else if (eventType.includes('unpublished') || eventType.includes('listing.unpublished')) {
      const query = listingId
        ? supabase.from('pf_listings').update({ is_live: false, last_synced_at: new Date().toISOString() }).eq('pf_listing_id', listingId)
        : supabase.from('pf_listings').update({ is_live: false, last_synced_at: new Date().toISOString() }).eq('reference', reference)
      const { error } = await query
      if (error) console.error('Webhook listing unpublished error:', error)
    } else if (eventType.includes('listing.action')) {
      const updates: Record<string, unknown> = {
        last_synced_at: new Date().toISOString(),
      }
      if (listing.state) updates.listing_stage = (listing.state as Record<string, unknown>).stage
      if (listing.compliance) updates.compliance = listing.compliance
      const query = listingId
        ? supabase.from('pf_listings').update(updates).eq('pf_listing_id', listingId)
        : supabase.from('pf_listings').update(updates).eq('reference', reference)
      const { error } = await query
      if (error) console.error('Webhook listing action error:', error)
    }

    return new Response(JSON.stringify({ ok: true }), { status: 200 })
  } catch (err) {
    console.error('Webhook listing error:', err)
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 })
  }
})
