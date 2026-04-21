import { createSupabaseClient, getJWT, pfFetch, corsHeaders } from '../_shared/helpers.ts'

const PAGES_PER_CHUNK = 15
const SELF_URL    = `${Deno.env.get('SUPABASE_URL')}/functions/v1/sync-leads`
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

function fireNextChunk(payload: Record<string, unknown>) {
  const p = fetch(SELF_URL, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  }).catch(e => console.error('Next chunk fire failed:', e))
  // @ts-ignore
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(p)
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  let reqBody: Record<string, unknown> = {}
  try { reqBody = await req.json() } catch { /* no body */ }

  const resumeLogId = reqBody.logId  as number | undefined
  const startPage   = Number(reqBody.page   ?? 1)
  const totalSoFar  = Number(reqBody.synced ?? 0)

  const supabase = createSupabaseClient()

  let logId = resumeLogId
  if (!logId) {
    const { data } = await supabase
      .from('sync_log')
      .insert({ sync_type: 'leads', status: 'RUNNING' })
      .select('id').single()
    logId = data?.id
  }

  try {
    let jwt    = await getJWT()
    let synced = 0
    let page   = startPage
    let hasMore = true

    while (hasMore && page < startPage + PAGES_PER_CHUNK) {
      const { data: logRow } = await supabase.from('sync_log').select('status').eq('id', logId).single()
      if (logRow?.status === 'CANCELLED') {
        return new Response(JSON.stringify({ ok: true, cancelled: true }), {
          status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      const result = await pfFetch('/leads', jwt, {
        page, perPage: 50,
        orderBy: 'createdAt', 'sort[createdAt]': 'desc',
      })
      jwt = result.jwt
      const body  = result.data as Record<string, unknown>
      const leads = (body.data ?? []) as Record<string, unknown>[]

      if (!Array.isArray(leads) || leads.length === 0) { hasMore = false; break }

      const mapped = leads.map(lead => {
        const listing = (lead.listing ?? {}) as Record<string, unknown>
        return {
          pf_lead_id:        String(lead.id ?? ''),
          listing_reference: (listing.reference ?? listing.id) as string ?? null,
          lead_created_at:   lead.createdAt as string ?? null,
          response_link:     lead.responseLink as string ?? null,
          raw_payload:       lead,
        }
      }).filter(l => l.pf_lead_id)

      const { error } = await supabase.from('pf_leads').upsert(mapped, { onConflict: 'pf_lead_id' })
      if (error) console.error('Lead upsert error:', error)
      else synced += mapped.length

      await supabase.from('sync_log').update({ records_synced: totalSoFar + synced }).eq('id', logId)

      const pagination = body.pagination as Record<string, unknown> | undefined
      if (!pagination?.nextPage) { hasMore = false; break }
      page++
      await new Promise(r => setTimeout(r, 50))
    }

    const totalNow = totalSoFar + synced

    if (!hasMore) {
      await supabase.from('sync_log').update({
        status: 'SUCCESS',
        completed_at: new Date().toISOString(),
        records_synced: totalNow,
        records_created: totalNow,
      }).eq('id', logId)
    } else {
      fireNextChunk({ logId, page, synced: totalNow })
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
