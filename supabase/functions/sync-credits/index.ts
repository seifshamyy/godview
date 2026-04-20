import { createSupabaseClient, getJWT, pfFetch, withSyncLog, corsHeaders } from '../_shared/helpers.ts'

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  const supabase = createSupabaseClient()
  try {
    await withSyncLog(supabase, 'credits', async () => {
      let jwt = await getJWT()
      let synced = 0

      // Balance snapshot
      const balResult = await pfFetch('/credits/balance', jwt)
      jwt = balResult.jwt
      const balBody = balResult.data as Record<string, unknown>
      const balance = balBody.balance ?? balBody.credit_balance ?? balBody.credits ?? 0
      await supabase.from('pf_credit_snapshots').insert({ credit_balance: Number(balance) })

      // Transactions
      let page = 1
      let hasMore = true

      while (hasMore && page <= 500) {
        const result = await pfFetch('/credits/transactions', jwt, { page, perPage: 100 })
        jwt = result.jwt
        const body = result.data as Record<string, unknown>
        const txns = (body.data ?? body.transactions ?? body ?? []) as Record<string, unknown>[]

        if (!Array.isArray(txns) || txns.length === 0) { hasMore = false; break }

        const mapped = txns.map(t => {
          const raw = t as Record<string, unknown>
          const ref = raw.listing?.reference ?? raw.listingReference ?? raw.listing_reference ?? null
          return {
            pf_transaction_id: String(raw.id ?? ''),
            transaction_type:  raw.type as string ?? null,
            credit_amount:     raw.amount != null ? Number(raw.amount) : null,
            listing_reference: ref as string ?? null,
            transaction_at:    raw.createdAt as string ?? raw.created_at as string ?? null,
            raw_payload:       raw,
          }
        }).filter(t => t.pf_transaction_id)

        const { error } = await supabase.from('pf_credit_transactions').upsert(mapped, { onConflict: 'pf_transaction_id' })
        if (error) console.error('Credits upsert error:', error)
        else synced += mapped.length

        if (txns.length < 100) hasMore = false
        page++
        await new Promise(r => setTimeout(r, 100))
      }

      return { created: synced, updated: 0, synced }
    })

    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
