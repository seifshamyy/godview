interface Props {
  band: string | null
  score?: number | null
  size?: 'sm' | 'md' | 'lg'
}

const bandColors: Record<string, string> = {
  S: 'bg-purple-500/20 text-purple-300 border-purple-500/40',
  A: 'bg-green-500/20 text-green-300 border-green-500/40',
  B: 'bg-blue-500/20 text-blue-300 border-blue-500/40',
  C: 'bg-yellow-500/20 text-yellow-300 border-yellow-500/40',
  D: 'bg-orange-500/20 text-orange-300 border-orange-500/40',
  F: 'bg-red-500/20 text-red-300 border-red-500/40',
}

export default function ScoreBadge({ band, score, size = 'sm' }: Props) {
  if (!band) return <span className="text-gray-500 text-xs">—</span>
  const colors = bandColors[band] ?? 'bg-gray-700 text-gray-300 border-gray-600'
  const sizeClass = size === 'lg' ? 'text-base px-3 py-1.5' : size === 'md' ? 'text-sm px-2.5 py-1' : 'text-xs px-2 py-0.5'
  return (
    <span className={`inline-flex items-center gap-1 border rounded-md font-mono font-bold ${colors} ${sizeClass}`}>
      {band}{score != null && <span className="opacity-70 font-normal text-[10px]">{score}</span>}
    </span>
  )
}
