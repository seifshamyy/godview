import { createSupabaseClient, getJWT, pfFetch, corsHeaders } from '../_shared/helpers.ts'

function mapListing(raw: Record<string, unknown>, syncedAt: string) {
  const price      = (raw.price      ?? {}) as Record<string, unknown>
  const amounts    = (price.amounts  ?? {}) as Record<string, unknown>
  const products   = (raw.products   ?? {}) as Record<string, unknown>
  const quality    = (raw.qualityScore ?? {}) as Record<string, unknown>
  const state      = (raw.state      ?? {}) as Record<string, unknown>
  const portals    = (raw.portals    ?? {}) as Record<string, unknown>
  const pf         = (portals.propertyfinder ?? {}) as Record<string, unknown>
  const media      = (raw.media      ?? {}) as Record<string, unknown>
  const location   = (raw.location   ?? {}) as Record<string, unknown>
  const assignedTo = (raw.assignedTo ?? {}) as Record<string, unknown>
  const createdBy  = (raw.createdBy  ?? {}) as Record<string, unknown>
  const street     = (raw.street     ?? {}) as Record<string, unknown>
  const images     = (media.images   ?? []) as unknown[]
  const videos     = (media.videos   ?? []) as unknown[]
  const mapTier    = (t: unknown) => {
    if (!t || typeof t !== 'object') return null
    const tier = t as Record<string, unknown>
    return { id: tier.id, createdAt: tier.createdAt, expiresAt: tier.expiresAt, renewalEnabled: tier.renewalEnabled }
  }
  return {
    pf_listing_id:           String(raw.id ?? ''),
    reference:               String(raw.reference ?? ''),
    category:                raw.category as string ?? null,
    property_type:           raw.type as string ?? null,
    bedrooms:                raw.bedrooms != null ? String(raw.bedrooms) : null,
    bathrooms:               raw.bathrooms != null ? String(raw.bathrooms) : null,
    size_sqft:               raw.size != null ? Number(raw.size) : null,
    built_up_area_sqft:      raw.builtUpArea != null ? Number(raw.builtUpArea) : null,
    plot_size_sqft:          raw.plotSize != null ? Number(raw.plotSize) : null,
    property_age:            raw.age != null ? Number(raw.age) : null,
    furnishing:              raw.furnishingType as string ?? null,
    finishing:               raw.finishingType as string ?? null,
    amenities:               Array.isArray(raw.amenities) ? raw.amenities : [],
    developer:               raw.developer as string ?? null,
    project_status:          raw.projectStatus as string ?? null,
    floor_number:            raw.floorNumber != null ? String(raw.floorNumber) : null,
    num_floors:              raw.numberOfFloors != null ? Number(raw.numberOfFloors) : null,
    parking_slots:           raw.parkingSlots != null ? Number(raw.parkingSlots) : null,
    has_garden:              raw.hasGarden as boolean ?? null,
    has_kitchen:             raw.hasKitchen as boolean ?? null,
    has_parking:             raw.hasParkingOnSite as boolean ?? null,
    street_direction:        street.direction as string ?? null,
    street_width:            street.width != null ? Number(street.width) : null,
    unit_number:             raw.unitNumber as string ?? null,
    location_id:             location.id != null ? Number(location.id) : null,
    price_type:              price.type as string ?? null,
    price_sale:              amounts.sale != null ? Number(amounts.sale) : null,
    price_yearly:            amounts.yearly != null ? Number(amounts.yearly) : null,
    price_monthly:           amounts.monthly != null ? Number(amounts.monthly) : null,
    price_weekly:            amounts.weekly != null ? Number(amounts.weekly) : null,
    price_daily:             amounts.daily != null ? Number(amounts.daily) : null,
    downpayment:             price.downpayment != null ? Number(price.downpayment) : null,
    num_cheques:             price.numberOfCheques != null ? Number(price.numberOfCheques) : null,
    price_on_request:        Boolean(price.onRequest),
    agent_public_profile_id: assignedTo.id != null ? Number(assignedTo.id) : null,
    agent_name:              assignedTo.name as string ?? null,
    created_by_profile_id:   createdBy.id != null ? Number(createdBy.id) : null,
    tier_featured:           mapTier(products.featured),
    tier_premium:            mapTier(products.premium),
    tier_standard:           mapTier(products.standard),
    pf_quality_score:        quality.value != null ? Number(quality.value) : null,
    pf_quality_color:        quality.color as string ?? null,
    pf_quality_details:      quality.details ?? null,
    listing_stage:           state.stage as string ?? null,
    listing_state_type:      state.type as string ?? null,
    state_reasons:           state.reasons ?? null,
    is_live:                 Boolean(pf.isLive),
    published_at:            pf.publishedAt as string ?? null,
    compliance:              raw.compliance ?? null,
    rnpm:                    raw.rnpm ?? null,
    verification_status:     raw.verificationStatus as string ?? null,
    image_count:             images.length,
    has_video:               videos.length > 0,
    cts_priority:            raw.ctsPriority != null ? Number(raw.ctsPriority) : null,
    pf_created_at:           raw.createdAt as string ?? null,
    pf_updated_at:           raw.updatedAt as string ?? null,
    last_synced_at:          syncedAt,
  }
}

const PAGES_PER_CHUNK = 15
const SELF_URL = `${Deno.env.get('SUPABASE_URL')}/functions/v1/sync-listings`
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

function fireNextChunk(logId: number, page: number, synced: number) {
  const p = fetch(SELF_URL, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ logId, page, synced }),
  }).catch(e => console.error('Next chunk fire failed:', e))
  // Keep the runtime alive long enough to dispatch the request
  // @ts-ignore
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(p)
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  let reqBody: Record<string, unknown> = {}
  try { reqBody = await req.json() } catch { /* no body */ }

  const resumeLogId = reqBody.logId as number | undefined
  const startPage   = Number(reqBody.page   ?? 1)
  const totalSoFar  = Number(reqBody.synced ?? 0)

  const supabase  = createSupabaseClient()
  const syncStart = new Date().toISOString()

  let logId = resumeLogId
  if (!logId) {
    const { data } = await supabase
      .from('sync_log')
      .insert({ sync_type: 'listings', status: 'RUNNING' })
      .select('id')
      .single()
    logId = data?.id
  }

  try {
    let jwt     = await getJWT()
    let created = 0
    let page    = startPage
    let hasMore = true

    while (hasMore && page < startPage + PAGES_PER_CHUNK) {
      const { data: logRow } = await supabase.from('sync_log').select('status').eq('id', logId).single()
      if (logRow?.status === 'CANCELLED') {
        return new Response(JSON.stringify({ ok: true, cancelled: true }), {
          status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      const result = await pfFetch('/listings', jwt, { page, perPage: 100, 'filter[state]': 'live' })
      jwt = result.jwt
      const body     = result.data as Record<string, unknown>
      const listings = (body.results ?? body.data ?? []) as Record<string, unknown>[]

      if (!Array.isArray(listings) || listings.length === 0) { hasMore = false; break }

      const mapped = listings.map(l => mapListing(l as Record<string, unknown>, syncStart))
      const { error } = await supabase.from('pf_listings').upsert(mapped, { onConflict: 'pf_listing_id' })
      if (error) console.error('Upsert error:', error)
      else created += mapped.length

      await supabase.from('sync_log').update({ records_synced: totalSoFar + created }).eq('id', logId)

      const pagination = body.pagination as Record<string, unknown> | undefined
      if (!pagination?.nextPage) { hasMore = false; break }
      page++
      await new Promise(r => setTimeout(r, 50))
    }

    const totalNow = totalSoFar + created

    if (!hasMore) {
      await supabase.from('sync_log').update({
        status: 'SUCCESS',
        completed_at: new Date().toISOString(),
        records_synced: totalNow,
        records_created: totalNow,
      }).eq('id', logId)
    } else {
      // Server fires the next chunk itself — dashboard is not involved
      fireNextChunk(logId!, page, totalNow)
    }

    return new Response(JSON.stringify({ ok: true, logId }), {
      status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    await supabase.from('sync_log').update({
      status: 'FAILED',
      completed_at: new Date().toISOString(),
      error_message: String(err),
    }).eq('id', logId)
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
