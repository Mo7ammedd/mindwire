"use client";

import { useId, useState } from "react";
import { ArrowLeft, Check, FileText, MoreHorizontal } from "lucide-react";
import BotAvatar from "./BotAvatar";
import { navigateTabs } from "./tabs";
import styles from "./secretary.module.css";

const tasks = [
  { time: "09:00", title: "Prepare the studio catch-up", detail: "A short brief, ready to review" },
  { time: "11:30", title: "Get back to Maya", detail: "A reply draft in your voice" },
  { time: "15:00", title: "A little uninterrupted time", detail: "Room for the project that matters" },
];

export default function SecretaryPreview({ framed = false, density = "compact" }: { framed?: boolean; density?: "compact" | "comfortable" }) {
  const id = useId();
  const [tab, setTab] = useState<"day" | "meeting">("day");
  const [done, setDone] = useState<number[]>([]);
  const [notice, setNotice] = useState("");

  return <div className={`${styles.secretary} ${framed ? styles.framed : density === "comfortable" ? styles.comfortable : styles.compact}`}>
    {framed && <div className={styles.header}><BotAvatar size={37} /><span>Cleo<small>Your personal secretary</small></span><MoreHorizontal size={19} /></div>}
    <div className={styles.body}>
      <span className={styles.eyebrow}>A LITTLE ORDER. A LOT MORE SPACE.</span>
      <h3>A little head start.</h3>
      <p className={styles.intro}>Three priorities. A little breathing room.</p>
      <div className={styles.tabs} role="tablist" aria-label="Personal secretary example" onKeyDown={navigateTabs}>
        {(["day", "meeting"] as const).map(value => <button key={value} type="button" role="tab" id={`${id}-${value}`} aria-selected={tab === value} aria-controls={`${id}-content`} tabIndex={tab === value ? 0 : -1} onClick={() => setTab(value)}>{value === "day" ? "My day" : "Meeting prep"}</button>)}
      </div>
      <div id={`${id}-content`} role="tabpanel" aria-labelledby={`${id}-${tab}`} className={styles.content}>
        {tab === "day" ? <><div className={styles.tasks}>{tasks.map((task, i) => <label key={task.time} className={styles.task} data-done={done.includes(i)}><input type="checkbox" checked={done.includes(i)} onChange={() => { const next = done.includes(i) ? done.filter(value => value !== i) : [...done, i]; setDone(next); setNotice(`${task.title} marked ${next.includes(i) ? "done" : "not done"}. ${next.length} of three example priorities complete.`); }} /><span className={styles.checkbox} aria-hidden="true">{done.includes(i) && <Check size={12} />}</span><span className={styles.taskCopy}><strong>{task.title}</strong><small>{task.detail}</small></span><time>{task.time}</time></label>)}</div><div className={styles.dayFooter}><span>{done.length === 3 ? "A little more room in your day." : `${done.length} of 3 priorities complete`}</span><button type="button" onClick={() => setTab("meeting")}>Open the brief<FileText size={13} /></button></div></> : <div className={styles.meeting}><div className={styles.meetingHeading}><strong>Studio catch-up</strong><span>09:00 · 30 min</span></div><p>From the notes you shared:</p><ul><li>Review the first website draft.</li><li>Agree on the two changes that matter.</li><li>Confirm who owns the next step.</li></ul><div className={styles.briefFile}><FileText size={15} /><span>meeting-brief.md</span><Check size={13} /></div><button type="button" className={styles.backToDay} onClick={() => setTab("day")}><ArrowLeft size={13} />Back to my day</button></div>}
      </div>
    </div>
    <span className="sr-only" role="status">{notice}</span>
  </div>;
}
