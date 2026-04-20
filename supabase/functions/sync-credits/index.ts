import { createSupabaseClient, getJWT, pfFetch, withSyncLog, corsHeaders, checkCancelled, emitProgress, isToday } from '../_shared/helpers.ts'

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  const supabase = createSupabaseClient()
  try {
    await withSyncLog(supabase, 'credits', async (logId) => {
      let jwt = await getJWT()
      let synced = 0

      // Balance snapshot
      const balResult = await pfFetch('/credits/balance', jwt)
      jwt = balResult.jwt
      const balBody = balResult.data as Record<string, unknown>
      const balance = balBody.remaining ?? balBody.total ?? balBody.balance ?? 0
      await supabase.from('pf_credit_snapshots').insert({ credit_balance: Number(balance) })

      // Transactions — newest-first, stop when past today
      let page = 1
      while (page <= 500) {
        const result = await pfFetch('/credits/transactions', jwt, { page, perPage: 100 })
        jwt = result.jwt
        const body = result.data as Record<string, unknown>
        const txns = (body.data ?? []) as Record<string, unknown>[]

        if (!Array.isArray(txns) || txns.length === 0) break

        const todayTxns = txns.filter(t => isToday((t as Record<string, unknown>).createdAt as string))

        if (todayTxns.length > 0) {
          const mapped = todayTxns.map(t => {
            const raw = t as Record<string, unknown>
            const txInfo = (raw.transactionInfo ?? {}) as Record<string, unknown>
            const listInfo = (raw.listingInfo ?? {}) as Record<string, unknown>
            const compositeId = `${raw.createdAt}_${listInfo.id ?? ''}_${txInfo.amount ?? ''}`
            return {
              pf_transaction_id: compositeId,
              transaction_type:  txInfo.type as string ?? txInfo.action as string ?? null,
              credit_amount:     txInfo.amount != null ? Number(txInfo.amount) : null,
              listing_reference: listInfo.reference as string ?? null,
              transaction_at:    raw.createdAt as string ?? null,
              raw_payload:       raw,
            }
          }).filter(t => t.pf_transaction_id)

          const { error } = await supabase.from('pf_credit_transactions').upsert(mapped, { onConflict: 'pf_transaction_id' })
          if (error) console.error('Credits upsert error:', error)
          else synced += mapped.length
          await emitProgress(supabase, logId, synced)
          await checkCancelled(supabase, logId)
        }

        // All records on this page are from before today — stop
        if (txns.every(t => !isToday((t as Record<string, unknown>).createdAt as string))) break

        const pagination = body.pagination as Record<string, unknown> | undefined
        if (!pagination?.nextPage) break
        page++
        await new Promise(r => setTimeout(r, 50))
      }

      return { created: synced, updated: 0, synced }
    })

    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
