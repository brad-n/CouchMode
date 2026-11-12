// Prime Video reader package (reader API 1). Runs only inside www.primevideo.com's own page.
// It reads the page's own data (the hydration script tag), never requests anything the page
// would not (except the one paginateCollection call the page itself makes at the end of a row),
// never plays anything, and returns data in CouchMode's shared vocabulary as JSON text.
// The app validates every value again (ids, https addresses, bounds); this script only returns data.
//
// Two layers, so the second can be tested against fixtures with no page:
//   extract.*  the page -> a "read": small JSON of just what the screens need (needs the page)
//   build.*    a read -> the shared vocabulary (pure: values in, values out)
// The reader object at the bottom is the API the app calls (see agents/add-a-streaming-service.md).
const reader = (() => {
  const SERVICE = "prime";
  const ORIGIN = "https://www.primevideo.com";
  const MAX_TEXT = 900000;
  const LIMITS = { rows: 20, titlesPerRow: 40, profiles: 10, seasons: 50, episodes: 100, search: 60 };
  const IMAGE_DOMAINS = ["media-amazon.com", "ssl-images-amazon.com", "example.invalid"];

  // ---- careful value readers (the same rules the app applies) ----
  const str = v => { if (typeof v !== "string") return null; const t = v.trim(); return t ? t : null; };
  const int = v => (typeof v === "number" && isFinite(v) && Math.abs(v) < 1e15 && Math.floor(v) === v) ? v : null;
  const numericID = v => {
    const n = int(v);
    if (n !== null) return n > 0 ? String(n) : null;
    return (typeof v === "string" && /^[0-9]{1,20}$/.test(v)) ? v : null;
  };
  const positive = v => { const n = int(v); return n !== null && n > 0 ? n : null; };
  const isPageID = id => typeof id === "string" && /^[A-Za-z0-9_-]{4,64}$/.test(id);
  const year = v => { const n = int(v); return n !== null && n >= 1900 && n <= 2100 ? n : null; };
  const percent = v => (typeof v === "number" && isFinite(v)) ? v : int(v);
  const hostOf = address => {
    const m = /^https:\/\/([^\/?#:@\s]+)(?::[0-9]+)?(?:[\/?#]|$)/i.exec(typeof address === "string" ? address : "");
    return m ? m[1].toLowerCase() : null;
  };
  const imageHost = address => { const h = hostOf(address); return !!h && IMAGE_DOMAINS.some(d => h === d || h.endsWith("." + d)); };

  const pageURL = id => isPageID(id) ? ORIGIN + "/detail/" + id : null;
  const playURL = (id, resume) => {
    if (!isPageID(id)) return null;
    const at = (typeof resume === "number" && resume > 0 && resume < 1000000) ? "&t=" + resume : "";
    return ORIGIN + "/detail/" + id + "?autoplay=1" + at;
  };
  // <stem>._SX<width>_.<ext>: a clean image of that width (a row's own cover has a badge composed into it).
  const imageURL = (address, width) => {
    if (typeof address !== "string" || !imageHost(address)) return null;
    const at = address.indexOf("/images/");
    if (at < 0) return null;
    const head = address.slice(0, at + 8), rest = address.slice(at + 8);
    const dot = rest.lastIndexOf(".");
    if (dot < 0) return null;
    const ext = rest.slice(dot + 1).toLowerCase();
    if (!["jpg", "jpeg", "png"].includes(ext)) return null;
    const mod = rest.indexOf("._");
    const stem = mod >= 0 ? rest.slice(0, mod) : rest.slice(0, dot);
    if (!stem || stem.includes("?") || stem.endsWith("/")) return null;
    return head + stem + "._SX" + width + "_." + ext;
  };
  const avatarURL = address => (typeof address === "string" && imageHost(address)) ? address : null;
  const seasonLabel = title => { const m = /^[\s\S]* - Season ([0-9]{1,3})$/.exec(typeof title === "string" ? title : ""); return m ? "S" + m[1] : null; };
  const pathOf = address => { const m = /^https:\/\/[^\/?#]+([^?#]*)/.exec(address || ""); return m ? m[1] : ""; };

  // ---- build: reads -> shared vocabulary ----
  const build = {};

  build.title = card => {
    if (!card || typeof card !== "object") return null;
    const id = card.id, page = typeof id === "string" ? pageURL(id) : null, name = str(card.name);
    if (!page || !name) return null;
    const resume = positive(card.resume);
    const play = (typeof card.playId === "string" ? playURL(card.playId, resume) : null) || page;
    let runtime = null;
    const pct = percent(card.pct);
    if (resume && pct !== null && pct > 0 && pct < 100) runtime = Math.round(resume * 100 / pct);
    const kind = card.type === "Movie" ? "movie" : card.type === "TV Show" ? "show" : "other";
    return {
      id, name, kind, play, page, episodeLabel: seasonLabel(card.title), synopsis: str(card.desc), year: year(card.year),
      rating: str(card.rating), seasonsLabel: null, runtimeSeconds: runtime, resumeSeconds: runtime === null ? null : resume,
      tileArt: imageURL(card.art, 640), heroArt: imageURL(card.art, 1920)
    };
  };

  const moreTotal = (container, loaded) => {
    const more = container.more;
    if (!more || typeof more !== "object") return null;
    const total = int(more.total);
    return total !== null && total > loaded ? total : null;
  };
  const plain = (text, max) => typeof text === "string" && text.length > 0 && text.length <= max && /^[A-Za-z0-9_=-]+$/.test(text);
  const validCursor = c => !!c && plain(c.target, 512) && plain(c.token, 4096) && int(c.start) !== null && c.start >= 0 && c.start <= 5000;
  const rowID = id => { const s = str(id); return s !== null && /^[0-9]{1,3}$/.test(s) ? s : null; };

  const rowKind = (name, continueWatching) => continueWatching ? "continueWatching" : /^top\s*10\b/i.test(name) ? "ranked" : "standard";

  const profilesOf = entries => {
    const names = entries.map(e => str(e && e.name)).filter(n => n !== null);
    const profiles = [];
    let currentID = null;
    for (const e of entries) {
      const name = str(e && e.name);
      if (name === null || name.length > 64 || names.filter(n => n === name).length !== 1) continue;
      profiles.push({ id: name, name, avatar: avatarURL(e.avatar), isKids: e.kids === true, isLocked: false });
      if (e.current === true) currentID = name;
    }
    return { profiles, currentID };
  };

  // The home from the home read; null when it has nothing to show. Each row may carry an opaque
  // "cursor" (what more() needs to fetch the row's next batch).
  build.home = read => {
    if (!read || !Array.isArray(read.rows)) return null;
    const rows = [];
    for (const c of read.rows) {
      if (!c || typeof c !== "object") continue;
      const items = Array.isArray(c.items) ? c.items.filter(i => i && typeof i === "object") : [];
      const titles = items.map(build.title).filter(Boolean);
      const id = rowID(c.id);
      if (c.type === "StandardHero" || titles.length === 0 || id === null) continue;
      const name = str(c.name) || "";
      const row = { id: "prime-row-" + id, title: name, kind: rowKind(name, c.cw === true), titles, totalCount: moreTotal(c, titles.length), cursor: null };
      // The cursor needs the total measured against the raw items, as the page counted them.
      if (moreTotal(c, items.length) !== null) {
        const cursor = { target: c.more.target, token: c.more.token, start: c.more.start };
        if (validCursor(cursor)) row.cursor = cursor;
      }
      rows.push(row);
    }
    const hero = build.title(read.hero);
    const { profiles, currentID } = profilesOf(Array.isArray(read.profiles) ? read.profiles : []);
    const home = {
      serviceID: SERVICE, profiles: profiles.slice(0, LIMITS.profiles), currentProfileID: currentID, hero,
      rows: rows.slice(0, LIMITS.rows).map(r => Object.assign({}, r, { titles: r.titles.slice(0, LIMITS.titlesPerRow) })),
      asksWhoIsWatching: false
    };
    return home.rows.length === 0 && !home.hero ? null : home;
  };

  build.search = cards => {
    if (!Array.isArray(cards)) return [];
    const seen = new Set(), titles = [];
    for (const card of cards) {
      if (titles.length >= LIMITS.search) break;
      const t = build.title(card);
      if (t && !seen.has(t.id)) { seen.add(t.id); titles.push(t); }
    }
    return titles;
  };

  // The next batch and cursor from a more read; null when unreadable.
  build.more = (read, cursor) => {
    if (!read || !Array.isArray(read.items)) return null;
    const titles = read.items.map(build.title).filter(Boolean);
    let next = null;
    if (read.hasMore === true && typeof read.token === "string" && int(read.start) !== null && read.start > cursor.start) {
      const c = { target: cursor.target, token: read.token, start: read.start };
      if (validCursor(c)) next = c;
    }
    return { titles, cursor: next };
  };

  const secondsFromRuntimeText = text => {
    const unit = u => { const m = new RegExp("([0-9]{1,3})\\s*" + u).exec(text); return m ? parseInt(m[1], 10) : null; };
    const h = unit("h"), m = unit("min");
    return h === null && m === null ? null : (h || 0) * 3600 + (m || 0) * 60;
  };

  build.episodes = read => {
    const seen = new Set(), list = [];
    const entries = read && Array.isArray(read.episodes) ? read.episodes : [];
    for (const e of entries) {
      if (!e || typeof e !== "object") continue;
      const resume = positive(e.resume);
      const page = typeof e.id === "string" ? pageURL(e.id) : null;
      if (list.length >= LIMITS.episodes || !page || seen.has(e.id)) continue;
      seen.add(e.id);
      const play = (typeof e.playId === "string" ? playURL(e.playId, resume) : null) || page;
      const n = numericID(e.number), number = n === null ? null : parseInt(n, 10);
      const run = positive(e.run);
      list.push({
        id: e.id, name: str(e.name) || (number !== null ? "Episode " + number : "Episode"), number, synopsis: str(e.desc),
        runtimeSeconds: run, resumeSeconds: run !== null && resume !== null && resume < run ? resume : null,
        play, art: imageURL(e.art, 640)
      });
    }
    return list;
  };

  const episodeLabel = (label, playID, episodes, season) => {
    let m = typeof label === "string" ? /S([0-9]{1,3})\s*E([0-9]{1,4})/.exec(label) : null;
    if (m) return "S" + m[1] + " · E" + m[2];
    const suffix = "/" + (playID || "-");
    const hit = episodes.find(e => { const p = pathOf(e.play); return p.length >= suffix.length && p.endsWith(suffix); });
    let number = hit ? hit.number : null;
    if (number === null && typeof label === "string") { m = /Episode ([0-9]{1,4})/.exec(label); if (m) number = parseInt(m[1], 10); }
    return number === null ? null : "S" + (season || 1) + " · E" + number;
  };

  // The details: the row's own title filled in from the page's read; null when it isn't one.
  build.details = (read, title) => {
    if (!read || typeof read !== "object" || Array.isArray(read) || (read.name === undefined && read.title === undefined)) return null;
    const episodes = build.episodes(read);
    const isSeries = read.titleType === "season" || (Array.isArray(read.episodes) && read.episodes.length > 0);
    const play = read.play && typeof read.play === "object" ? read.play : null;
    const resume = play ? positive(play.resume) : null;
    const run = (play ? positive(play.run) : null) || secondsFromRuntimeText(typeof read.runtimeText === "string" ? read.runtimeText : "");
    let seasons = [], seen = new Set();
    for (const s of (Array.isArray(read.seasons) ? read.seasons : [])) {
      if (!s || typeof s.id !== "string" || !pageURL(s.id) || seen.has(s.id)) continue;
      seen.add(s.id);
      const n = numericID(s.number);
      seasons.push({ id: s.id, name: str(s.name) || (n !== null ? "Season " + n : "Season"), episodes: [] });
    }
    const wanted = str(read.currentSeasonId);
    let currentSeason = wanted !== null && seasons.some(s => s.id === wanted) ? wanted : null;
    const sn = numericID(read.seasonNumber), seasonNumber = sn === null ? null : parseInt(sn, 10);
    if (seasons.length === 0 && isSeries && typeof read.id === "string" && pageURL(read.id)) {
      seasons = [{ id: read.id, name: seasonNumber !== null ? "Season " + seasonNumber : "Season 1", episodes: [] }];
      currentSeason = read.id;
    }
    const current = seasons.find(s => s.id === currentSeason);
    if (current) current.episodes = episodes;
    const filled = Object.assign({}, title);
    filled.name = str(read.name) || title.name;
    filled.kind = isSeries ? "show" : "movie";
    filled.play = (play && typeof play.id === "string" ? playURL(play.id, resume) : null) || title.page || title.play;
    filled.episodeLabel = null;
    filled.seasonsLabel = null;
    filled.resumeSeconds = null;
    const synopsis = str(read.desc); if (synopsis) filled.synopsis = synopsis;
    const rating = str(read.rating); if (rating) filled.rating = rating;
    const y = year(read.year); if (y) filled.year = y;
    const wide = imageURL(read.art, 1920); if (wide) filled.heroArt = wide;
    if (!filled.tileArt) filled.tileArt = imageURL(read.art, 640);
    filled.runtimeSeconds = run;
    if (play) filled.resumeSeconds = resume;
    if (isSeries) {
      filled.seasonsLabel = seasons.length === 0 ? null : seasons.length === 1 ? "1 Season" : seasons.length + " Seasons";
      if (play) filled.episodeLabel = episodeLabel(play.label, play.id, episodes, seasonNumber);
    }
    return {
      title: filled, seasons: isSeries ? seasons.slice(0, LIMITS.seasons) : [], currentSeasonID: isSeries ? currentSeason : null
    };
  };

  // ---- extract: the page -> a read ----
  const extract = {};
  const hydration = () => {
    const el = document.getElementById("dv-web-page-hydration-data");
    return el ? JSON.parse(el.textContent) : null;
  };
  const bodyOf = () => { const d = hydration(); return d && d.init && d.init.preparations && d.init.preparations.body; };
  const pathID = u => { const m = /^\/detail\/([A-Za-z0-9_-]{4,64})(?:[\/?#]|$)/.exec(typeof u === "string" ? u : ""); return m ? m[1] : null; };
  // A row, search or detail item squeezed into a card (null for anything that isn't a /detail/ title).
  const card = e => {
    const id = pathID(e.link && e.link.url);
    if (!id) return null;
    const pb = (e.playbackActions && e.playbackActions[0]) || null;
    const images = e.images || {};
    return {
      id, name: e.displayTitle || e.title || null, title: e.title || null, type: e.entityType || null,
      year: Number(e.releaseYear) || null,
      rating: (e.maturityRatingBadge && e.maturityRatingBadge.displayText) || null,
      desc: String(e.synopsis || "").slice(0, 400) || null,
      art: (images.cover && images.cover.url) || (images.hero && images.hero.url) || null,
      pct: e.progress && typeof e.progress.percentage === "number" ? e.progress.percentage : null,
      resume: pb && typeof pb.resumeTime === "number" ? pb.resumeTime : null,
      playId: pb ? pathID(pb.fallbackUrl) : null
    };
  };
  const moreNote = (c, loaded) => {
    if (typeof c.paginationServiceToken !== "string" || typeof c.paginationTargetId !== "string") return null;
    if (!(c.estimatedTotal > loaded) || typeof c.paginationStartIndex !== "number") return null;
    return { total: c.estimatedTotal, target: c.paginationTargetId, token: c.paginationServiceToken, start: c.paginationStartIndex };
  };

  extract.homeReady = () => {
    const body = bodyOf();
    return !!body && Array.isArray(body.containers) && body.containers.length > 0 && !!document.querySelector('[data-testid^="active-profile-"]');
  };

  extract.home = () => {
    const body = bodyOf();
    if (!body || !Array.isArray(body.containers)) return null;
    const containers = body.containers.slice(0, LIMITS.rows + 4);
    const heroContainer = containers.find(c => c.containerType === "StandardHero");
    const hero = heroContainer ? ((heroContainer.entities || []).map(card).find(Boolean) || null) : null;
    const rows = containers.map((c, i) => {
      const items = (c.entities || []).slice(0, LIMITS.titlesPerRow).map(card).filter(Boolean);
      return { id: String(i), name: c.text || "", type: c.containerType || "", cw: !!c.isContinueWatching, items, more: moreNote(c, (c.entities || []).length) };
    }).filter(r => r.items.length);
    const avatarOf = el => {
      if (!el) return null;
      const m = /url\("([^"]+)"\)/.exec(getComputedStyle(el).backgroundImage || "");
      return m ? m[1] : null;
    };
    const profiles = [];
    const active = document.querySelector('[data-testid^="active-profile-"]');
    if (active) profiles.push({ name: active.getAttribute("data-testid").slice("active-profile-".length), avatar: avatarOf(active), current: true, kids: false });
    const seen = new Set(profiles.map(p => p.name));
    for (const form of Array.from(document.querySelectorAll('form[action="/profiles/switch"]')).slice(0, 40)) {
      const name = ((form.querySelector("button") || {}).textContent || "").trim();
      if (!name || seen.has(name)) continue;
      seen.add(name);
      const avatar = avatarOf(form.querySelector('[data-testid^="pv-nav-profile-icon-"]'));
      profiles.push({ name, avatar, current: false, kids: !!avatar && /\/kid-[0-9]+\.png$/.test(avatar) });
      if (profiles.length >= LIMITS.profiles) break;
    }
    return { hero, rows, profiles };
  };

  extract.searchReady = () => {
    const d = hydration();
    return !!d && d.init.route.name === "search" && Array.isArray(d.init.preparations.body.containers);
  };
  extract.search = () => {
    const body = bodyOf();
    if (!body || !Array.isArray(body.containers)) return null;
    const items = body.containers.filter(c => c.containerType === "Grid").flatMap(c => c.entities || []);
    return items.slice(0, LIMITS.search * 2).map(card).filter(Boolean).slice(0, LIMITS.search);
  };

  extract.detailsReady = () => {
    const d = hydration();
    const state = d && d.init && d.init.route && d.init.route.name === "detail" && d.init.preparations.body.atf.state;
    return !!state && !!state.pageTitleId && !!state.detail && !!state.detail.headerDetail && !!state.detail.headerDetail[state.pageTitleId];
  };
  extract.details = () => {
    const body = bodyOf();
    const A = body.atf.state, B = (body.btf && body.btf.state) || {};
    const gti = A.pageTitleId, h = A.detail.headerDetail[gti];
    const playOf = action => {
      const p = ((action && action.primaryActions) || []).find(a => a.actionType === "PLAY" && a.payload && a.payload.playback && !a.payload.playback.isTrailer);
      return p ? p.payload.playback : null;
    };
    const pb = playOf((A.action && A.action.atf && A.action.atf[gti]) || null);
    const play = pb && pathID(pb.playbackURL) ? { id: pathID(pb.playbackURL), resume: pb.resumeTime || 0, run: pb.runTime || null, label: pb.label || "" } : null;
    const seasonLists = Object.values(A.seasons || {}).filter(Array.isArray);
    const seasons = (seasonLists[0] || []).slice(0, LIMITS.seasons).map(s => ({
      id: pathID(s.seasonLink), name: s.displayName || null, number: s.sequenceNumber || null, selected: !!s.isSelected
    }));
    const selected = seasons.find(s => s.selected);
    const ids = ((B.episodeList && B.episodeList.cardTitleIds) || []).slice(0, LIMITS.episodes);
    const episodes = ids.map(id => {
      const d = (B.detail && B.detail.detail && B.detail.detail[id]) || {};
      const self = (B.self && B.self[id]) || {};
      const epPlay = playOf((B.action && B.action.btf && B.action.btf[id]) || null);
      const images = d.images || {};
      return {
        id: pathID(self.link), number: d.episodeNumber || null, name: d.title || null, desc: String(d.synopsis || "").slice(0, 400) || null,
        run: (epPlay && epPlay.runTime) || d.duration || null, resume: (epPlay && epPlay.resumeTime) || 0,
        art: images.covershot || images.packshot || null, playId: epPlay ? pathID(epPlay.playbackURL) : null
      };
    });
    const images = h.images || {};
    return {
      id: pathID(location.pathname), name: h.parentTitle || h.title || null, title: h.title || null, type: h.entityType || null,
      titleType: h.titleType || null, seasonNumber: h.seasonNumber || null, year: Number(h.releaseYear) || null,
      rating: (h.ratingBadge && h.ratingBadge.displayText) || null, desc: String(h.synopsis || "").slice(0, 1200) || null,
      art: images.heroshot || images.titleshot || images.packshot || null, runtimeText: h.runtime || "", play,
      currentSeasonId: selected ? selected.id : null,
      seasons: seasons.map(s => ({ id: s.id, name: s.name, number: s.number })), episodes
    };
  };

  // The one request the page itself makes at the end of a carousel (same origin, the page's own session).
  extract.more = async cursor => {
    const body = bodyOf();
    const q = body && body.pagination && body.pagination.queryParameters, sp = body && body.swiftPageParameters;
    if (!q || !sp || !Array.isArray(q.dynamicFeatures)) return null;
    const p = new URLSearchParams();
    p.set("pageType", sp.pageType); p.set("pageId", sp.pageId); p.set("collectionType", "Container");
    p.set("paginationTargetId", cursor.target); p.set("serviceToken", cursor.token);
    p.set("startIndex", String(cursor.start));
    p.set("actionScheme", q.actionScheme); p.set("payloadScheme", "default");
    p.set("decorationScheme", q.decorationScheme); p.set("featureScheme", q.featureScheme);
    for (const f of q.dynamicFeatures.slice(0, 40)) p.append("dynamicFeatures", f);
    p.set("widgetScheme", q.widgetScheme); p.set("variant", "desktopOSX");
    const response = await fetch("/api/paginateCollection", {
      method: "POST", credentials: "same-origin",
      headers: { "x-requested-with": "XMLHttpRequest", "Content-Type": "application/x-www-form-urlencoded", "X-Amzn-Client-TTL-Seconds": "15" },
      body: p.toString()
    });
    if (!response.ok) return null;
    const page = await response.json();
    const next = page.pagination || {};
    return {
      items: (page.entities || []).slice(0, LIMITS.titlesPerRow).map(card).filter(Boolean), hasMore: page.hasMoreItems === true,
      token: typeof next.serviceToken === "string" ? next.serviceToken : null, start: typeof page.startIndex === "number" ? page.startIndex : null
    };
  };

  // ---- the API the app calls ----
  const text = value => {
    if (value === null || value === undefined) return "";
    const out = JSON.stringify(value);
    return out.length > MAX_TEXT ? "" : out;
  };
  const profileButtons = name => Array.from(document.querySelectorAll('form[action="/profiles/switch"] button')).filter(b => b.textContent.trim() === name);
  const activeProfile = () => document.querySelector('[data-testid^="active-profile-"]');

  return {
    api: 1, build, extract,
    homeReady: () => { try { return extract.homeReady(); } catch (e) { return false; } },
    detailsReady: () => { try { return extract.detailsReady(); } catch (e) { return false; } },
    searchReady: () => { try { return extract.searchReady(); } catch (e) { return false; } },
    home: () => { try { return text(build.home(extract.home())); } catch (e) { return ""; } },
    details: args => { try { return text(build.details(extract.details(), args.title)); } catch (e) { return ""; } },
    season: () => { try { return text(build.episodes(extract.details())); } catch (e) { return ""; } },
    search: () => { try { const found = extract.search(); return found ? text(build.search(found)) : ""; } catch (e) { return ""; } },
    more: async args => {
      try {
        const cursor = args.cursor;
        if (!validCursor(cursor)) return "";
        const batch = build.more(await extract.more(cursor), cursor);
        return text(batch);
      } catch (e) { return ""; }
    },
    chooseProfile: args => {
      const name = args.profileID, active = activeProfile();
      if (active && active.getAttribute("data-testid") === "active-profile-" + name) return true;
      const buttons = profileButtons(name);
      if (buttons.length === 0) return false;
      buttons[0].click();
      return true;
    },
    profileIsCurrent: args => { const a = activeProfile(); return !!a && a.getAttribute("data-testid") === "active-profile-" + args.profileID; },
    // True while Prime's player is open: an element on the title's page (#dv-web-player) that the page marks
    // full-screen (class dv-player-fullscreen) while open and unmarks when it closes.
    playerShown: () => { const p = document.getElementById("dv-web-player"); return !!p && p.classList.contains("dv-player-fullscreen"); }
  };
})();
