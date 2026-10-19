import type { UseCaseArtKind } from "@/lib/use-cases";

/** Small, mixed-color illustrations of the things a bot can help make. */
export default function UseCaseArt({ kind, className }: { kind: UseCaseArtKind; className?: string }) {
  const peach = "var(--mw-peach)", blue = "var(--mw-blue)", mint = "var(--mw-mint)";
  const paper = "var(--mw-surface)", line = "var(--mw-line)";
  return <svg viewBox="0 0 104 88" fill="none" className={className} aria-hidden="true">
    {kind === "calendar" && <>
      <rect x="21" y="15" width="69" height="59" rx="12" fill="var(--mw-blue-soft)" transform="rotate(8 21 15)" />
      <rect x="13" y="13" width="68" height="61" rx="11" fill={paper} stroke={line} />
      <path d="M13 34h68" stroke={line} /><path d="M31 9v10m32-10v10" stroke={peach} strokeWidth="4" strokeLinecap="round" />
      {[26, 44, 62].map((x, i) => <g key={x}><rect x={x} y="43" width="10" height="8" rx="3" fill={i === 1 ? peach : "var(--mw-inset)"} /><rect x={x} y="57" width="10" height="8" rx="3" fill="var(--mw-inset)" /></g>)}
      <circle cx="82" cy="65" r="13" fill={mint} /><path d="m76 65 4 4 7-8" stroke={paper} strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
    </>}
    {kind === "notes" && <>
      <rect x="28" y="12" width="52" height="67" rx="8" fill="var(--mw-mint-soft)" transform="rotate(10 28 12)" />
      <rect x="19" y="7" width="52" height="67" rx="8" fill={paper} stroke={line} />
      <path d="M29 24h19" stroke={blue} strokeWidth="4" strokeLinecap="round" /><path d="M29 36h31m-31 9h31m-31 9h19" stroke={line} strokeWidth="3" strokeLinecap="round" />
      <path d="m63 63 18-30 8 5-18 30-10 6Z" fill={peach} /><path d="m81 33 3-5q3-4 7-1t2 6l-4 5" fill="var(--mw-peach-soft)" /><path d="m63 63 8 5-10 6Z" fill="var(--mw-ink)" opacity=".65" />
    </>}
    {kind === "plan" && <>
      <rect x="14" y="15" width="76" height="60" rx="12" fill="var(--mw-peach-soft)" />
      <rect x="24" y="8" width="58" height="66" rx="9" fill={paper} stroke={line} />
      <rect x="40" y="4" width="26" height="10" rx="5" fill={peach} />
      {[28, 44, 60].map((y, i) => <g key={y}><rect x="34" y={y-4} width="9" height="9" rx="3" fill={i === 2 ? "var(--mw-blue-soft)" : "var(--mw-mint-soft)"} />{i < 2 && <path d={`m36 ${y} 2 2 4-4`} stroke={mint} strokeWidth="1.6" strokeLinecap="round" />}<path d={`M50 ${y}h${i === 1 ? 14 : 21}`} stroke={i === 2 ? blue : line} strokeWidth="3" strokeLinecap="round" /></g>)}
    </>}
    {kind === "map" && <>
      <path d="m10 24 27-9 29 9 28-9v55l-28 8-29-9-27 9Z" fill="var(--mw-mint-soft)" />
      <path d="m37 15 29 9v54l-29-9Z" fill={paper} /><path d="m37 15 0 54m29-45v54" stroke={line} />
      <path d="M24 61c21-31 25 16 49-19" stroke={mint} strokeWidth="2" strokeDasharray="4 4" strokeLinecap="round" />
      <circle cx="24" cy="61" r="4" fill={blue} />
      <path d="M63 29a13 13 0 1 1 26 0c0 10-13 23-13 23S63 39 63 29Z" fill={peach} /><circle cx="76" cy="28" r="4" fill={paper} />
    </>}
    {kind === "chart" && <>
      <rect x="11" y="17" width="78" height="58" rx="11" fill={paper} stroke={line} /><path d="M24 62h51" stroke={line} />
      <rect x="26" y="42" width="10" height="20" rx="3" fill={mint} /><rect x="43" y="32" width="10" height="30" rx="3" fill={blue} /><rect x="60" y="46" width="10" height="16" rx="3" fill={peach} />
      <circle cx="80" cy="24" r="17" fill="var(--mw-peach-soft)" /><path d="M80 12v12h12a12 12 0 0 0-12-12Z" fill={peach} /><path d="M76 14a12 12 0 1 0 14 14H76Z" fill={blue} />
    </>}
    {kind === "folders" && <>
      <path d="M13 26a8 8 0 0 1 8-8h21l8 8h33a8 8 0 0 1 8 8v35H13Z" fill={blue} />
      <rect x="29" y="13" width="45" height="47" rx="5" fill={paper} stroke={line} transform="rotate(7 29 13)" /><path d="m40 27 23 3m-24 8 18 2" stroke={line} strokeWidth="3" strokeLinecap="round" />
      <path d="M13 39h78l-6 33a7 7 0 0 1-7 6H24a7 7 0 0 1-7-6Z" fill="var(--mw-blue-soft)" /><rect x="33" y="52" width="31" height="8" rx="4" fill={blue} opacity=".7" /><circle cx="84" cy="66" r="11" fill={peach} /><path d="M79 66h10m-5-5v10" stroke={paper} strokeWidth="2" strokeLinecap="round" />
    </>}
    {kind === "book" && <>
      <path d="M12 21q20-8 40 1 20-9 40-1v51q-20-8-40 0-20-8-40 0Z" fill="var(--mw-mint-soft)" /><path d="M17 15q19-6 35 3 16-9 35-3v50q-19-6-35 3-16-9-35-3Z" fill={paper} stroke={line} /><path d="M52 18v50" stroke={line} />
      <path d="M26 31q8-2 17 1m-17 9q8-2 17 1m-17 9q8-2 12 0m22-19q8-3 17-1m-17 11q8-3 17-1m-17 11q8-3 11-2" stroke={line} strokeWidth="2.5" strokeLinecap="round" />
      <path d="M67 11h12v20l-6-4-6 4Z" fill={peach} /><circle cx="19" cy="70" r="9" fill={blue} /><path d="M15 70h8m-4-4v8" stroke={paper} strokeWidth="1.8" strokeLinecap="round" />
    </>}
    {kind === "app" && <>
      <rect x="10" y="14" width="84" height="60" rx="10" fill={paper} stroke={line} /><path d="M10 29h84" stroke={line} /><circle cx="20" cy="22" r="2" fill={peach} /><circle cx="27" cy="22" r="2" fill={mint} /><circle cx="34" cy="22" r="2" fill={blue} />
      <rect x="18" y="36" width="18" height="30" rx="4" fill="var(--mw-blue-soft)" /><path d="M24 43h6m-6 8h6m-6 8h4" stroke={blue} strokeWidth="2" strokeLinecap="round" />
      <rect x="43" y="36" width="42" height="14" rx="4" fill="var(--mw-peach-soft)" /><rect x="43" y="55" width="19" height="11" rx="3" fill="var(--mw-mint-soft)" /><rect x="67" y="55" width="18" height="11" rx="3" fill="var(--mw-blue-soft)" /><path d="m80 62 5 20 4-8 8-4Z" fill={blue} stroke={paper} strokeWidth="2" strokeLinejoin="round" />
    </>}
  </svg>;
}
