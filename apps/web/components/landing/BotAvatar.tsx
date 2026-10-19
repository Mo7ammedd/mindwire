/** The native app's bean, robot and sprout silhouettes, in its shared BotColor palette. */
export default function BotAvatar({ character = "bean", size = 48, className = "" }: {
  character?: "bean" | "robot" | "sprout";
  size?: number;
  className?: string;
}) {
  const color = { bean: "#EB9257", robot: "#6797F0", sprout: "#78BAA9" }[character];
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" fill="none" aria-hidden="true" className={className}>
      <g fill={color}>
        {character === "bean" && <path d="M61 5C88 8 98 34 93 56C90 84 79 98 58 94C31 91 3 87 7 65C9 35 32 2 61 5Z" />}
        {character === "sprout" && <path d="M26 8C42 1 51 3 62 16C77 33 98 40 93 58C92 78 51 95 30 94C7 98 3 87 8 68C10 44 10 16 26 8Z" />}
        {character === "robot" && <><rect x="12" y="23" width="76" height="64" rx="18" /><rect x="4" y="41" width="92" height="29" rx="8" /><rect x="46" y="9" width="8" height="21" rx="4" /><ellipse cx="50" cy="11.5" rx="10" ry="8.5" /></>}
      </g>
      <g stroke="#222629" strokeWidth="5" strokeLinecap="round">
        <path d={character === "sprout" ? "M33 46L36 51M62 46L59 51" : "M34 45V51M63 45V51"} />
        <path d={character === "robot" ? "M40 66H57" : "M40 64Q48 72 57 63"} strokeWidth="3.6" />
      </g>
      <ellipse cx="24" cy="60" rx="5" ry="3" fill="#fff" opacity=".18" />
      <ellipse cx="73" cy="59" rx="5" ry="3" fill="#fff" opacity=".18" />
    </svg>
  );
}
