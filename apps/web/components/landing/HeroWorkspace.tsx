"use client";

import { useState } from "react";
import { ArrowUpRight, BookOpen, Check, CheckCheck, ChevronRight, FileText, FolderOpen, Laptop, Lightbulb, Paperclip, SlidersHorizontal } from "lucide-react";
import AgentLogo from "../marketing/AgentLogo";
import BotAvatar from "./BotAvatar";
import { navigateTabs } from "./tabs";
import styles from "./landing.module.css";

const bots = [
  {
    id: "cleo", name: "Cleo", role: "Your everyday assistant", short: "Life, a little lighter", character: "bean", agent: "claude", engine: "Claude Code",
    prompt: "Turn my scattered notes into a plan for the week. Leave Friday afternoon free.",
    reply: "A little structure, a little breathing room. I grouped your notes into three priorities and kept Friday afternoon yours.",
    steps: ["Read your weekly notes", "Grouped tasks by priority", "Made room for the important things"],
    memory: ["You protect Friday afternoons", "You prefer a short daily list", "Your work week starts on Monday"],
    instructions: "Make everyday work feel lighter. Turn loose thoughts into practical next steps. Keep things short, warm, and useful.",
    file: "week-ahead.md", color: "peach",
  },
  {
    id: "kit", name: "Kit", role: "Your app builder", short: "Ideas into real things", character: "robot", agent: "codex", engine: "Codex",
    prompt: "Build a reading tracker. Somewhere for the books I love and the ones I’m getting to.",
    reply: "Meet your little reading corner. Your current books, a finished shelf, and a weekly goal. Try switching between the shelves.",
    steps: ["Created the reading app", "Added your books and shelves", "Prepared a working preview"],
    memory: ["You like quiet, simple interfaces", "Your weekly goal is 100 pages", "Your apps live in one workspace"],
    instructions: "Turn ideas into small, useful apps. Handle the technical details, explain the result clearly, and keep the user in control.",
    file: "reading-corner", color: "blue",
  },
  {
    id: "sage", name: "Sage", role: "Your research partner", short: "Clarity from the chaos", character: "sprout", agent: "claude", engine: "Claude Code",
    prompt: "Look through my project ideas. Which one could I actually finish this weekend?",
    reply: "The reading tracker is the clearest weekend project. I compared scope, setup, and what you could get working in two days.",
    steps: ["Reviewed your project notes", "Compared three possible directions", "Put the trade-offs in a short brief"],
    memory: ["You build on the weekends", "You prefer a useful first version", "You want sources with your research"],
    instructions: "Find the useful signal. Compare alternatives, call out uncertainty, and give a clear recommendation grounded in the supplied material.",
    file: "next-project.md", color: "mint",
  },
] as const;

export function ReadingCorner({ compact = false }: { compact?: boolean }) {
  const [shelf, setShelf] = useState<"reading" | "finished">("reading");
  return (
    <div className={`${styles.readingApp} ${compact ? styles.readingCompact : ""}`}>
      <div className={styles.readingTitle}><BookOpen size={20} /><span>Little reading corner</span></div>
      <p>A few pages. A little perspective.</p>
      <div className={styles.bookTabs} role="tablist" aria-label="Example reading shelves" onKeyDown={navigateTabs}>
        {(["reading", "finished"] as const).map(item => <button type="button" key={item} role="tab" aria-selected={shelf === item} tabIndex={shelf === item ? 0 : -1} aria-controls={compact ? "mode-reading-shelf" : "hero-reading-shelf"} id={`${compact ? "mode" : "hero"}-shelf-${item}`} onClick={() => setShelf(item)}>{item === "reading" ? "Reading now" : "Finished"}</button>)}
      </div>
      <div role="tabpanel" id={compact ? "mode-reading-shelf" : "hero-reading-shelf"} aria-labelledby={`${compact ? "mode" : "hero"}-shelf-${shelf}`} className={styles.bookShelf}>
        <div className={styles.bookCover} data-cover={shelf === "reading" ? "orange" : "green"}><small>{shelf === "reading" ? "A FIELD GUIDE" : "COLLECTED NOTES"}</small><strong>{shelf === "reading" ? <>The art<br />of noticing.</> : <>A quieter<br />kind of life.</>}</strong><i /><span>{shelf === "reading" ? "ESSAYS & OBSERVATIONS" : "ON THE EVERYDAY"}</span></div>
        <div className={styles.bookDetails}><span>{shelf === "reading" ? "ON YOUR NIGHTSTAND" : "BACK ON THE SHELF"}</span><h4>{shelf === "reading" ? "The art of noticing" : "A quieter kind of life"}</h4><p>{shelf === "reading" ? "Page 84 of 240" : "Finished on Sunday"}</p><div className={styles.bookProgress}><i style={{ width: shelf === "reading" ? "35%" : "100%" }} /></div><small>{shelf === "reading" ? "One chapter at a time." : "A little more perspective."}</small></div>
      </div>
      <div className={styles.readingGoal}><span>This week</span><strong>{shelf === "reading" ? "64" : "100"}<small> / 100 pages</small></strong><div className={styles.weekDots}>{["M", "T", "W", "T", "F", "S", "S"].map((day, index) => <span key={index} data-complete={index < (shelf === "reading" ? 4 : 7)}>{day}</span>)}</div></div>
    </div>
  );
}

function WeekPlan() {
  const [done, setDone] = useState<number[]>([0]);
  const tasks = [{ day: "MON", text: "Make a start", detail: "Outline the weekend project" }, { day: "TUE", text: "Clear some space", detail: "Sort the notes and loose ends" }, { day: "FRI", text: "Wrap it up", detail: "A short review, then log off" }];
  return <div className={styles.weekPlan}><span className={styles.paperEyebrow}>A LITTLE ROOM TO THINK</span><h3>Your week,<br />with intention.</h3><div className={styles.planTasks}>{tasks.map((task, index) => <button type="button" key={task.day} aria-pressed={done.includes(index)} onClick={() => setDone(previous => previous.includes(index) ? previous.filter(i => i !== index) : [...previous, index])}><span className={styles.taskDay}>{task.day}</span><span><strong>{task.text}</strong><small>{task.detail}</small></span><i>{done.includes(index) && <Check size={13} />}</i></button>)}</div><div className={styles.freeFriday}><span>Friday, after 12</span><strong>Yours to enjoy.</strong><svg viewBox="0 0 60 50" width="50" height="42" fill="none" aria-hidden="true"><path d="M18 28a12 12 0 0 1 24 0M10 33h40M30 4v6M9 13l5 5M51 13l-5 5M6 26h6M48 26h6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></svg></div></div>;
}

function ResearchBrief() {
  const [idea, setIdea] = useState(0);
  const ideas = [{ title: "Reading tracker", scope: "A weekend", note: "A focused first version: two shelves, a reading goal, and your own books." }, { title: "Personal newsletter", scope: "A few weekends", note: "A bigger project: writing, subscriptions, email delivery, and an archive." }, { title: "Habit companion", scope: "A weekend", note: "A good alternative: start with one daily check-in and a simple streak." }];
  return <div className={styles.researchBrief}><Lightbulb size={25} /><span className={styles.paperEyebrow}>YOUR NEXT SIDE PROJECT</span><h3>Start small.<br />Make it useful.</h3><div className={styles.ideaList}>{ideas.map((item, index) => <button key={item.title} type="button" aria-pressed={idea === index} onClick={() => setIdea(index)}><span>0{index + 1}</span><strong>{item.title}</strong><ChevronRight size={15} /></button>)}</div><div className={styles.ideaDetail}><strong>{ideas[idea].scope}</strong><p>{ideas[idea].note}</p></div></div>;
}

export default function HeroWorkspace() {
  const [selected, setSelected] = useState(0);
  const [inspector, setInspector] = useState<"result" | "bot">("result");
  const bot = bots[selected];

  return (
    <div className={styles.workspaceScene}>
      <svg className={styles.workspaceWires} viewBox="0 0 1400 540" fill="none" aria-hidden="true"><path d="M0 70h68q22 0 22 22v130q0 22 22 22h65M0 460h55q35 0 35-35v-70q0-24 24-24h65M1400 80h-68q-22 0-22 22v70q0 22-22 22h-60M1400 470h-60q-30 0-30-30v-70q0-22-22-22h-50" /><circle cx="0" cy="70" r="4" /><circle cx="0" cy="460" r="4" /><circle cx="1400" cy="80" r="4" /><circle cx="1400" cy="470" r="4" /></svg>
      <div className={styles.workspace} data-accent={bot.color}>
        <aside className={styles.botSidebar}>
          <div className={styles.spaceLabel}><span className={styles.spaceMonogram}>m.</span>My space</div>
          <span className={styles.sidebarLabel}>YOUR LITTLE TEAM</span>
          <div role="tablist" aria-label="Explore personal bots" aria-orientation="vertical" onKeyDown={navigateTabs} className={styles.botList}>
            {bots.map((item, index) => <button type="button" role="tab" key={item.id} id={`bot-${item.id}`} aria-selected={selected === index} aria-controls="bot-conversation" tabIndex={selected === index ? 0 : -1} onClick={() => { setSelected(index); setInspector("result"); }}><BotAvatar character={item.character} size={43} /><span><strong>{item.name}</strong><small>{item.short}</small></span><ChevronRight size={13} /></button>)}
          </div>
          <div className={styles.sidebarNote}><span>Different talents.<br />A shared place to work.</span><div className={styles.botMiniatures}><BotAvatar size={26} /><BotAvatar character="robot" size={26} /><BotAvatar character="sprout" size={26} /></div></div>
          <div className={styles.computerLink}><Laptop size={18} /><span>Your computer<small>Files, apps, and possibilities</small></span></div>
        </aside>
        <div className={styles.conversation} id="bot-conversation" role="tabpanel" aria-labelledby={`bot-${bot.id}`}>
          <div className={styles.conversationHeader}><span>{bot.name}<small>{bot.role}</small></span><span className={styles.exampleLabel}>Example</span></div>
          <div key={bot.id} className={styles.chatBody}>
            <div className={styles.userBubble}>{bot.prompt}</div>
            <div className={styles.botResponse}><BotAvatar character={bot.character} size={34} /><span>{bot.name}<small>Made for you</small></span></div>
            <p className={styles.reply}>{bot.reply}</p>
            <div className={styles.completedSteps}>{bot.steps.map(step => <div key={step}><Check size={14} /><span>{step}</span></div>)}</div>
            <button type="button" className={styles.resultLink} onClick={() => setInspector("result")}><span><FileText size={18} />{bot.file}</span><ArrowUpRight size={16} /></button>
          </div>
          <div className={styles.conversationBottom}><span><AgentLogo agent={bot.agent} size={16} />Powered by {bot.engine}</span><button type="button" aria-label={`About ${bot.name}: instructions and memory`} onClick={() => setInspector(inspector === "bot" ? "result" : "bot")} aria-pressed={inspector === "bot"}><SlidersHorizontal size={17} /></button></div>
        </div>
        <div className={styles.inspector}>
          <div className={styles.inspectorTabs} role="tablist" aria-label="Bot preview details" onKeyDown={navigateTabs}>
            {(["result", "bot"] as const).map(item => <button type="button" key={item} role="tab" id={`inspector-${item}`} aria-selected={inspector === item} aria-controls="bot-inspector-panel" tabIndex={inspector === item ? 0 : -1} onClick={() => setInspector(item)}>{item === "result" ? "The result" : "Behind the bot"}</button>)}
          </div>
          <div id="bot-inspector-panel" role="tabpanel" aria-labelledby={`inspector-${inspector}`} className={styles.inspectorBody} key={`${bot.id}-${inspector}`}>
            {inspector === "result" ? selected === 0 ? <WeekPlan /> : selected === 1 ? <ReadingCorner /> : <ResearchBrief /> : <div className={styles.botProfile}>
              <div className={styles.profileIdentity}><BotAvatar character={bot.character} size={62} /><div><h3>{bot.name}</h3><span>{bot.role}</span></div></div>
              <h4><SlidersHorizontal size={14} />Instructions</h4><p>{bot.instructions}</p>
              <h4><CheckCheck size={15} />Personal memory</h4><ul>{bot.memory.map(memory => <li key={memory}>{memory}</li>)}</ul>
              <div className={styles.knowledgeLink}><FolderOpen size={16} /><span>Your knowledge & files</span><Paperclip size={14} /></div>
            </div>}
          </div>
        </div>
      </div>
    </div>
  );
}
