// Runs before the page paints so the chosen theme never flashes. An explicit choice is
// stored in this browser; without one the site follows the system setting.
(() => {
  const KEY = 'asenaizer.theme';
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  const stored = () => { try { return localStorage.getItem(KEY); } catch { return null; } };
  const apply = (theme) => { document.documentElement.dataset.theme = theme; };
  apply(stored() || (media.matches ? 'dark' : 'light'));
  media.addEventListener('change', (event) => { if (!stored()) apply(event.matches ? 'dark' : 'light'); });
  document.addEventListener('DOMContentLoaded', () => {
    const toggle = document.getElementById('theme-toggle');
    if (!toggle) return;
    const label = () => {
      const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
      toggle.setAttribute('aria-label', `Switch to ${next} theme`);
      toggle.title = `Switch to ${next} theme`;
    };
    label();
    toggle.addEventListener('click', () => {
      const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
      apply(next);
      try { localStorage.setItem(KEY, next); } catch { /* the choice lasts for this page only */ }
      label();
    });
  });
})();
