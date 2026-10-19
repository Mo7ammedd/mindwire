import Link from "next/link";
import { ArrowUpRight } from "lucide-react";
import { type UseCase, useCaseTone } from "@/lib/use-cases";
import UseCaseArt from "./UseCaseArt";
import styles from "./use-cases.module.css";

export default function UseCaseCard({ item }: { item: UseCase }) {
  return <Link href={`/use-cases/${item.slug}`} className={styles.caseCard} data-tone={useCaseTone(item.category)}>
    <div className={styles.cardTop}><UseCaseArt kind={item.art} /><span>{item.category}</span></div>
    <h3>{item.title}</h3>
    <p>{item.summary}</p>
    <span className={styles.cardLink}>Explore this idea<ArrowUpRight size={16} /></span>
  </Link>;
}
