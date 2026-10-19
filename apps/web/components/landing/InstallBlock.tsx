import { Terminal } from "lucide-react";
import CopyButton from "./CopyButton";
import styles from "./product.module.css";

export default function InstallBlock({ sdk = false }: { sdk?: boolean }) {
  const command = sdk ? "npm install mindwire" : "npm install -g mindwire\nmindwire connect";
  return <div className={styles.installBlock}>
    <div><span><Terminal size={15} /> {sdk ? "Install the SDK" : "On your computer"}</span><CopyButton value={command} label={sdk ? "Copy SDK install command" : "Copy install and connect commands"} /></div>
    <pre><code>{command}</code></pre>
  </div>;
}
