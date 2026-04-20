import { createSupabaseClient, corsHeaders } from '../_shared/helpers.ts'

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  const supabase = createSupabaseClient()
  const steps = ['fn_build_daily_snapshots', 'fn_build_segment_benchmarks', 'fn_score_all_listings', 'fn_build_aggregate_scores', 'fn_generate_recommendations']
  const timings: Record<string, number> = {}

  const { data: log } = await supabase
    .from('sync_log')
    .insert({ sync_type: 'scoring', status: 'RUNNING' })
    .select('id')
    .single()

  const logId = log?.id

  try {
    for (const fn of steps) {
      const t0 = Date.now()
      const { error } = await supabase.rpc(fn)
      if (error) throw new Error(`${fn} failed: ${error.message}`)
      timings[fn] = Date.now() - t0
      console.log(`${fn} completed in ${timings[fn]}ms`)
    }

    await supabase.from('sync_log').update({
      status: 'SUCCESS',
      completed_at: new Date().toISOString(),
      records_synced: 0,
      metadata: { timings },
    }).eq('id', logId)

    return new Response(JSON.stringify({ ok: true, timings }), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (err) {
    await supabase.from('sync_log').update({
      status: 'FAILED',
      completed_at: new Date().toISOString(),
      error_message: String(err),
    }).eq('id', logId)
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
