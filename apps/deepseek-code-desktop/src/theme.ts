export type ThemePreference = "system" | "light" | "dark"

const STORAGE_KEY = "deepseek-code.theme"

export function loadThemePreference(): ThemePreference {
  try {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (stored === "light" || stored === "dark" || stored === "system") return stored
  } catch { /* Restricted webviews may block localStorage; fall back to system. */ }
  return "system"
}

export function saveThemePreference(preference: ThemePreference) {
  try { localStorage.setItem(STORAGE_KEY, preference) } catch { /* Optional persistence. */ }
}

export function resolveTheme(preference: ThemePreference): "light" | "dark" {
  if (preference !== "system") return preference
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
}

export function applyTheme(preference: ThemePreference) {
  document.documentElement.dataset.theme = resolveTheme(preference)
}

export function watchSystemTheme(onChange: () => void): () => void {
  const media = window.matchMedia("(prefers-color-scheme: dark)")
  media.addEventListener("change", onChange)
  return () => media.removeEventListener("change", onChange)
}
