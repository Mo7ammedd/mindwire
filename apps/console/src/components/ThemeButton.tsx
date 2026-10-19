import { Moon, Sun } from "lucide-react";
import { useTheme } from "@/lib/theme";
import { Button } from "./ui/button";

export function ThemeButton() {
  const { theme, toggle } = useTheme();
  return <Button type="button" size="icon" variant="ghost" aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`} onClick={toggle}>
    {theme === "dark" ? <Sun /> : <Moon />}
  </Button>;
}
