import { create } from 'zustand';

type Theme = 'light' | 'dark';

interface ThemeStore {
  theme: Theme;
  setTheme: (theme: Theme) => void;
  toggleTheme: () => void;
}

const themeStorageKey = 'theme';

const getStoredTheme = (): Theme => {
  if (typeof window === 'undefined') return 'light';

  try {
    return window.localStorage.getItem(themeStorageKey) === 'dark' ? 'dark' : 'light';
  } catch {
    return 'light';
  }
};

const applyTheme = (theme: Theme) => {
  if (typeof document === 'undefined') return;

  document.documentElement.classList.toggle('dark', theme === 'dark');
};

const initialTheme = getStoredTheme();
applyTheme(initialTheme);

export const useThemeStore = create<ThemeStore>((set) => ({
  theme: initialTheme,

  setTheme: (theme: Theme) => {
    set({ theme });
    applyTheme(theme);

    try {
      window.localStorage.setItem(themeStorageKey, theme);
    } catch {
      // Keep UI state even when localStorage is unavailable.
    }
  },

  toggleTheme: () => {
    const nextTheme = useThemeStore.getState().theme === 'dark' ? 'light' : 'dark';
    useThemeStore.getState().setTheme(nextTheme);
  },
}));

if (typeof window !== 'undefined') {
  window.addEventListener('storage', (event) => {
    if (event.key !== themeStorageKey) return;

    const theme = event.newValue === 'dark' ? 'dark' : 'light';
    applyTheme(theme);
    useThemeStore.setState({ theme });
  });
}
