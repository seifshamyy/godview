import { createSupabaseClient, getJWT, pfFetch, sleep, withSyncLog, corsHeaders, checkCancelled, emitProgress } from '../_shared/helpers.ts'

function mapListing(raw: Record<string, unknown>, syncedAt: string) {
  const price = (raw.price ?? {}) as Record<string, unknown>
  const amounts = (price.amounts ?? {}) as Record<string, unknown>
  const products = (raw.products ?? {}) as Record<string, unknown>
  const quality = (raw.qualityScore ?? {}) as Record<string, unknown>
  const state = (raw.state ?? {}) as Record<string, unknown>
  const portals = (raw.portals ?? {}) as Record<string, unknown>
  const pf = (portals.propertyfinder ?? {}) as Record<string, unknown>
  const media = (raw.media ?? {}) as Record<string, unknown>
  const location = (raw.location ?? {}) as Record<string, unknown>
  const assignedTo = (raw.assignedTo ?? {}) as Record<string, unknown>
  const createdBy = (raw.createdBy ?? {}) as Record<string, unknown>
  const street = (raw.street ?? {}) as Record<string, unknown>

  const images = (media.images ?? []) as unknown[]
  const videos = (media.videos ?? []) as unknown[]

  const mapTier = (t: unknown) => {
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

const PAGES_PER_RUN = 30 // ~3000 listings per invocation — safe for memory/CPU limits

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  // Accept { startPage, draft } to resume a previous run
  let body: Record<string, unknown> = {}
  try { body = await req.json() } catch { /* empty body is fine */ }
  const startPage = Number(body.startPage ?? 1)
  const draft = body.draft === true || body.draft === 'true'

  const supabase = createSupabaseClient()
  try {
    await withSyncLog(supabase, 'listings', async (logId) => {
      let jwt = await getJWT()
      const syncStart = new Date().toISOString()
      let created = 0
      let page = startPage

      while (page < startPage + PAGES_PER_RUN) {
        const result = await pfFetch('/listings', jwt, { page, perPage: 100, draft: String(draft) })
        jwt = result.jwt
        const respBody = result.data as Record<string, unknown>
        const listings = (respBody.results ?? respBody.data ?? []) as Record<string, unknown>[]

        if (!Array.isArray(listings) || listings.length === 0) break

        const mapped = listings.map(l => mapListing(l, syncStart))
        const { error } = await supabase.from('pf_listings').upsert(mapped, { onConflict: 'pf_listing_id' })
        if (error) console.error('Upsert error:', error)
        else created += mapped.length

        await emitProgress(supabase, logId, (page - startPage + 1) * 100)
        await checkCancelled(supabase, logId)

        const pagination = respBody.pagination as Record<string, unknown> | undefined
        if (!pagination?.nextPage) break
        page++
        await new Promise(r => setTimeout(r, 50))
      }

      return { created, updated: 0, synced: created }
    })

    const nextPage = startPage + PAGES_PER_RUN
    return new Response(JSON.stringify({ ok: true, nextPage, draft }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
