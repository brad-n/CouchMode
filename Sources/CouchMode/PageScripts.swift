// Owns: the JavaScript we inject into streaming sites. Two jobs only:
//  1. hide the page's own Gamepad API, so the controller is read once (by us);
//  2. on sites without a TV interface, a spatial-navigation layer: arrows move
//     a visible highlight between clickable things, Enter clicks it. While a
//     video fills the screen, arrows pass through to the site's player and
//     Enter asks the shell to press Space (play/pause).
// It never touches video data or the sites' DRM.

import Foundation

enum PageScripts {
    static let messageHandler = "shell"

    static let hideGamepads = """
    try { Object.defineProperty(navigator, 'getGamepads', { value: () => [], configurable: true }); } catch (e) {}
    """

    /// `skip`: a CSS selector for elements never to land on (Service.navigationSkip).
    static func spatialNavigation(skip: String?) -> String {
        // JSON-encoded, so the selector is a JS string literal whatever it holds.
        let skipLiteral = skip.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "null"
        return spatialNavigationBody.replacingOccurrences(of: "__SKIP__", with: skipLiteral)
    }

    private static let spatialNavigationBody = """
    (function () {
      if (window.__shellNav) return; window.__shellNav = true;
      const FOCUS_CLASS = '__shell-focus';
      const SKIP = __SKIP__;
      const SELECTOR = 'a[href],button,[role="button"],[role="link"],[role="tab"],[role="menuitem"],[tabindex]:not([tabindex="-1"])';
      const style = document.createElement('style');
      style.textContent = '.' + FOCUS_CLASS + '{outline:4px solid #f2b866 !important;outline-offset:3px !important;border-radius:6px}';
      document.documentElement.appendChild(style);
      let current = null;

      const viewport = () => ({ w: window.innerWidth, h: window.innerHeight });

      // Playback = a video filling (nearly) the whole window. Autoplaying
      // trailers on browse pages are large but not full-window; treating
      // them as playback would hand the arrows to the page (it just scrolls).
      const PLAYER_FILL = 0.9;
      function playerActive() {
        const { w, h } = viewport();
        return [...document.querySelectorAll('video')].some(v => {
          if (!v.videoWidth) return false;
          const r = v.getBoundingClientRect();
          return r.width >= PLAYER_FILL * w && r.height >= PLAYER_FILL * h;
        });
      }
      window.__shellPlayerActive = playerActive;

      // Something the viewer can actually see. Sites keep closed menus in the
      // page inside hidden or transparent containers, so the element's own
      // style isn't enough: no ancestor may hide it either. (A hit test at its
      // centre is not used: rows' scroll containers overlap the rows below.)
      function visible(el) {
        const r = el.getBoundingClientRect();
        const { h } = viewport();
        if (r.width < 8 || r.height < 8) return false;
        if (r.bottom < -h || r.top > 2 * h) return false;   // bounded: about three screens
        if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true,
                                                         checkOpacity: true, checkVisibilityCSS: true })) return false;
        const s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
      }

      function center(r) { return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }

      // While a pop-up (title details, menus) is open, navigation stays inside it.
      function scope() {
        const dialogs = [...document.querySelectorAll('[role="dialog"],[aria-modal="true"],dialog[open]')]
          .filter(d => { const r = d.getBoundingClientRect(); return r.width > 100 && r.height > 100; });
        return dialogs.length ? dialogs[dialogs.length - 1] : document;
      }

      // Left and right stay in the current row; at its end focus stops (as
      // on a TV) instead of jumping diagonally into the next row.
      function sameRow(a, b) {
        const overlap = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
        return overlap >= 0.5 * Math.min(a.height, b.height);
      }

      function next(dir) {
        const root = scope();
        const inScope = current && current.isConnected && (root === document || root.contains(current));
        const fromRect = inScope ? current.getBoundingClientRect() : null;
        const from = fromRect ? center(fromRect) : { x: 0, y: 0 };
        const horizontal = dir === 'ArrowRight' || dir === 'ArrowLeft';
        let best = null, bestScore = Infinity;
        for (const el of root.querySelectorAll(SELECTOR)) {
          if (el === current || (SKIP && el.matches(SKIP)) || !visible(el)) continue;
          const rect = el.getBoundingClientRect();
          if (horizontal && fromRect && !sameRow(fromRect, rect)) continue;
          const c = center(rect);
          const dx = c.x - from.x, dy = c.y - from.y;
          const primary = dir === 'ArrowRight' ? dx : dir === 'ArrowLeft' ? -dx : dir === 'ArrowDown' ? dy : -dy;
          const ortho = horizontal ? Math.abs(dy) : Math.abs(dx);
          if (primary <= 4) continue;
          const score = primary + 2 * ortho;
          if (score < bestScore) { bestScore = score; best = el; }
        }
        return best;
      }

      function setFocus(el) {
        if (current) current.classList.remove(FOCUS_CLASS);
        current = el;
        el.classList.add(FOCUS_CLASS);
        try { el.focus({ preventScroll: true }); } catch (e) {}
        el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' });
      }

      window.addEventListener('keydown', function (e) {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        if (playerActive()) {
          if (e.key === 'Enter') {
            e.preventDefault(); e.stopPropagation();
            window.webkit.messageHandlers.\(messageHandler).postMessage('playpause');
          }
          return;   // arrows, space, escape go to the site's player
        }
        if (e.key.startsWith('Arrow')) {
          const el = next(e.key);
          if (el) setFocus(el);
          e.preventDefault(); e.stopPropagation();
        } else if (e.key === 'Enter' && current && current.isConnected) {
          e.preventDefault(); e.stopPropagation();
          current.click();
        }
      }, true);
    })();
    """

    /// Plex Web only. (1) On the "Select User" screen, picks the profile the
    /// shell chose (localStorage shellPlexUser) or else the first one.
    /// (2) When the shell opened a title to resume (#...&shellAutoplay=1),
    /// presses the details page's Play once, then "Resume from …" if Plex
    /// asks. Profiles with a PIN still ask for it.
    static let plexHelper = """
    (function () {
      if (window.__shellPlexHelper) return; window.__shellPlexHelper = true;
      let pickedFor = null, playedFor = null, resumeUntil = 0;
      const visible = e => { const r = e.getBoundingClientRect(); return r.width > 20 && r.height > 20; };
      setInterval(function () {
        const picker = document.querySelector('.user-select-container');
        if (picker) {
          if (pickedFor === location.href) return;
          const want = localStorage.getItem('shellPlexUser');
          // Each profile is its own .user-select-container tile; the last is "Add User".
          const tiles = [...document.querySelectorAll('.user-select-container')].filter(visible).slice(0, -1);
          const tile = (want && tiles.find(t => (t.innerText || '').trim().split('\\n')[0] === want)) || tiles[0];
          if (tile) { pickedFor = location.href; tile.click(); }
          return;
        }
        if (location.hash.includes('shellAutoplay=1') && playedFor !== location.hash) {
          const play = document.querySelector('[data-testid="preplay-play"]');
          if (play && visible(play)) { playedFor = location.hash; resumeUntil = Date.now() + 10000; play.click(); }
        }
        // Plex then asks "Resume from 2:18" or "Start from the beginning": resume.
        if (Date.now() < resumeUntil) {
          const resume = [...document.querySelectorAll('button')].find(b => visible(b) && (b.innerText || '').trim().startsWith('Resume from'));
          if (resume) { resumeUntil = 0; resume.click(); }
        }
      }, 500);
    })();
    """

    static let pauseAllMedia = "document.querySelectorAll('video,audio').forEach(m => { try { m.pause(); } catch (e) {} });"
}
