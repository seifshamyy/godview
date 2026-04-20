interface Props { tier: string | null }

const tierColors: Record<string, string> = {
  featured: 'bg-amber-500/20 text-amber-300 border-amber-500/40',
  premium:  'bg-violet-500/20 text-violet-300 border-violet-500/40',
  standard: 'bg-sky-500/20 text-sky-300 border-sky-500/40',
  none:     'bg-gray-700/40 text-gray-500 border-gray-700',
}

export default function TierBadge({ tier }: Props) {
  if (!tier) return <span className="text-gray-500 text-xs">—</span>
  const colors = tierColors[tier.toLowerCase()] ?? tierColors.none
  return (
    <span className={`inline-flex items-center border rounded-md text-xs px-2 py-0.5 font-medium capitalize ${colors}`}>
      {tier}
    </span>
  )
}
