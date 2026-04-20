#!/usr/bin/env node
// Run schema against Supabase via Management API
// Requires: SUPABASE_ACCESS_TOKEN env var (personal access token from app.supabase.com)
// Usage: SUPABASE_ACCESS_TOKEN=sbp_xxx node scripts/run-schema.js

import { readFileSync } from 'fs'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const PROJECT_REF = 'oidizmsasvtffjhhzsmg'
const TOKEN = process.env.SUPABASE_ACCESS_TOKEN

if (!TOKEN) {
  console.error('ERROR: Set SUPABASE_ACCESS_TOKEN to your Supabase personal access token')
  console.error('Get one at: https://app.supabase.com/account/tokens')
  process.exit(1)
}

async function runSQL(sql, label) {
  console.log(`\nRunning: ${label}...`)
  const res = await fetch(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ query: sql }),
  })

  const text = await res.text()
  let data
  try { data = JSON.parse(text) } catch { data = text }

  if (!res.ok) {
    console.error(`FAILED (${res.status}):`, data)
    process.exit(1)
  }

  console.log(`OK — ${label}`)
  return data
}

const migrations = ['001_schema.sql', '002_scoring_functions.sql']
for (const file of migrations) {
  const sql = readFileSync(join(__dirname, '..', 'supabase', 'migrations', file), 'utf8')
  await runSQL(sql, file)
}

console.log('\n✓ Schema setup complete')
