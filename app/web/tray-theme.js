// Applies the tray theme before the first paint. The choice ("system", "light" or "dark") is
// kept in the tray's persistent webview profile; "system" follows the desktop setting.
(() => {
  const KEY = 'asenaizer.tray.theme';
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  const choice = () => {
    try { return localStorage.getItem(KEY) || 'system'; } catch { return 'system'; }
  };
  const apply = () => {
    const c = choice();
    document.documentElement.dataset.theme = c === 'system' ? (media.matches ? 'dark' : 'light') : c;
    document.documentElement.dataset.themeChoice = c;
  };
  apply();
  media.addEventListener('change', apply);
  window.asenaizerSetTheme = (c) => {
    try { localStorage.setItem(KEY, c); } catch { /* lasts until the tray restarts */ }
    apply();
  };
})();
