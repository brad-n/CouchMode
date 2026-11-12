// Netflix reader package (reader API 1). Runs only inside www.netflix.com's own page.
// It reads what the page already holds (its GraphQL cache, its details panel, its search cards, its
// "Who's watching?" tiles), makes no request of its own, never plays anything, never types anything
// (not a PIN either), and returns data in CouchMode's shared vocabulary as JSON text.
// The app validates every value again (ids, https addresses, bounds); this script only returns data.
// It does what NetflixSource and its Core parsers (NetflixHome, NetflixDetails, NetflixSearch, NetflixGate)
// do, and a parity test holds them to it. Netflix 5.1 is not here: the app installs that page script itself.
//
// Two layers, so the second can be tested against fixtures with no page:
//   extract.*  the page -> a "read": small JSON of just what the screens need (needs the page)
//   build.*    a read -> the shared vocabulary (pure: values in, values out)
// The reader object at the bottom is the API the app calls (see agents/add-a-streaming-service.md).
// "More in a row" is not offered on purpose: the page pages a row with a persisted GraphQL query that is
// not available to us, so there is no request this reader could make as the page makes it.
const reader = (() => {
  const ORIGIN = "https://www.netflix.com";
  const MAX_TEXT = 900000;
  const LIMITS = { rows: 20, titlesPerRow: 40, profiles: 10, seasons: 50, episodes: 100, search: 60, tiles: 30, sections: 200, edges: 200 };

  // ---- careful value readers (the same rules the app applies) ----
  const str = v => { if (typeof v !== "string") return null; const t = v.trim(); return t ? t : null; };
  const int = v => (typeof v === "number" && isFinite(v) && Math.abs(v) < 1e15 && Math.floor(v) === v) ? v : null;
  const numericID = v => {
    const n = int(v);
    if (n !== null) return n > 0 ? String(n) : null;
    return (typeof v === "string" && /^[0-9]{1,20}$/.test(v)) ? v : null;
  };
  const token = v => (typeof v === "string" && /^[A-Za-z0-9-]{1,64}$/.test(v)) ? v : null;
  const https = v => {
    if (typeof v !== "string") return null;
    const m = /^https:\/\/[^\/?#\s]+/i.exec(v);
    return m ? v : null;
  };
  const isObject = v => v !== null && typeof v === "object" && !Array.isArray(v);
  const refKey = v => (isObject(v) && typeof v.__ref === "string") ? v.__ref : null;
  const videoID = v => { const n = int(v); return n !== null && /^[0-9]{1,20}$/.test(String(n)) ? String(n) : null; };
  const playURL = id => /^[0-9]{1,20}$/.test(id || "") ? ORIGIN + "/watch/" + id : null;
  const pageURL = id => /^[0-9]{1,20}$/.test(id || "") ? ORIGIN + "/title/" + id : null;
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const text = value => {
    if (value === null || value === undefined) return "";
    const out = JSON.stringify(value);
    return out.length > MAX_TEXT ? "" : out;
  };

  // ---- the GraphQL cache -> the home (NetflixHome.parse) ----
  const build = {};

  build.home = cache => {
    if (!isObject(cache)) return null;
    const root = cache.ROOT_QUERY;
    if (!isObject(root)) return null;
    const pageRef = Object.keys(root).sort().filter(k => k.startsWith("pinotBrowsePage("))
      .map(k => refKey(root[k])).find(k => k !== null && k !== undefined);
    const page = pageRef ? cache[pageRef] : null;
    if (!isObject(page)) return null;

    const resolve = v => {
      if (!isObject(v)) return null;
      if (typeof v.__ref === "string") return isObject(cache[v.__ref]) ? cache[v.__ref] : null;
      return v;
    };
    // The url of the widest artwork(...) image in a record (widths are encoded in the key's params).
    const image = record => {
      if (!isObject(record)) return null;
      let best = null;
      for (const key of Object.keys(record).sort()) {
        if (!key.startsWith("artwork(")) continue;
        const img = record[key];
        if (!isObject(img) || typeof img.url !== "string" || !/^https?:\/\/[^\/?#\s]+/i.test(img.url)) continue;
        const m = /"width":(\d+)/.exec(key);
        const width = m ? parseInt(m[1], 10) : 0;
        if (best === null || width > best.width) best = { width, url: img.url };
      }
      if (best) return best.url;
      return (typeof record.url === "string" && https(record.url)) ? record.url : null;
    };
    const title = (entityRef, name) => {
      const type = entityRef.split(":")[0];
      if (type !== "Movie" && type !== "Show") return null;
      const entity = cache[entityRef];
      if (!isObject(entity)) return null;
      const id = videoID(entity.videoId);
      if (id === null) return null;
      const displayName = [name, entity.title].filter(s => typeof s === "string").find(s => s !== "");
      if (displayName === undefined) return null;
      // What Play starts: the movie itself, or a show's current episode.
      let playID = id, playable = entity;
      if (type === "Show") {
        const episode = resolve(entity.currentEpisode);
        const epID = episode ? videoID(episode.videoId) : null;
        if (epID !== null) { playID = epID; playable = episode; }
      }
      const play = playURL(playID);
      if (!play) return null;
      const advisory = resolve(entity.contentAdvisory);
      const bookmark = isObject(playable.bookmark) ? playable.bookmark : null;
      return {
        id, name: displayName, kind: type === "Show" ? "show" : "movie", play, page: pageURL(id),
        year: int(entity.releaseYear), rating: advisory && typeof advisory.certificationValue === "string" ? advisory.certificationValue : null,
        seasonsLabel: typeof entity.numSeasonsLabel === "string" ? entity.numSeasonsLabel : null,
        runtimeSeconds: int(playable.runtimeSec), resumeSeconds: bookmark ? int(bookmark.position) : null,
        tileArt: null, heroArt: null, synopsis: null
      };
    };
    const hero = section => {
      const treatment = resolve(section.entity);
      const entityRef = treatment ? refKey(treatment.promotedEntity) : null;
      if (!entityRef) return null;
      const t = title(entityRef, treatment.displayString);
      if (!t) return null;
      t.heroArt = image(resolve(treatment.contextualArtwork));
      const synopsis = resolve(treatment.contextualSynopsis);
      t.synopsis = synopsis && typeof synopsis.text === "string" ? synopsis.text : null;
      return t;
    };
    const row = (section, index) => {
      if (typeof section.displayString !== "string" || section.displayString === "" || !isObject(section.entities)) return null;
      const titles = [];
      let kind = "standard";
      for (const edge of (Array.isArray(section.entities.edges) ? section.entities.edges : []).slice(0, LIMITS.edges)) {
        const key = refKey(isObject(edge) ? edge.node : null);
        const treatment = key ? cache[key] : null;
        if (!isObject(treatment)) continue;
        const entityRef = refKey(treatment.unifiedEntity);
        const t = entityRef ? title(entityRef, treatment.displayString) : null;
        if (!t) continue;
        t.tileArt = image(resolve(treatment.contextualArtwork));
        titles.push(t);
        if (titles.length === 1) {
          const type = key.split(":")[0];
          if (type === "PinotContinueWatchingEntityTreatment") kind = "continueWatching";
          else if (type === "PinotRankedBoxshotEntityTreatment") kind = "ranked";
        }
        if (titles.length >= LIMITS.titlesPerRow) break;
      }
      return { id: "netflix-row-" + index, title: section.displayString, kind, titles,
               totalCount: int(section.entities.totalCount) };
    };

    const profiles = Object.keys(cache).filter(k => k.startsWith("Profile:")).map(k => {
      const p = cache[k];
      if (!isObject(p) || typeof p.guid !== "string" || p.guid === "" || typeof p.name !== "string") return null;
      return { id: p.guid, name: p.name, avatar: image(resolve(p.icon)), isKids: p.isKids === true, isLocked: p.isPinLocked === true };
    }).filter(Boolean).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

    const home = { profiles, currentProfileID: null, hero: null, rows: [], asksWhoIsWatching: false };
    const currentRef = refKey(root.currentProfile);
    home.currentProfileID = currentRef && isObject(cache[currentRef]) && typeof cache[currentRef].guid === "string" ? cache[currentRef].guid : null;

    const sectionsKey = Object.keys(page).sort().find(k => k.startsWith("sections("));
    const sections = sectionsKey && isObject(page[sectionsKey]) ? page[sectionsKey] : {};
    const edges = (Array.isArray(sections.edges) ? sections.edges : []).slice(0, LIMITS.sections);
    edges.forEach((edge, index) => {
      const key = refKey(isObject(edge) ? edge.node : null);
      const section = key ? cache[key] : null;
      if (!isObject(section)) return;
      const type = key.split(":")[0];
      if (type === "PinotSingleItemSection") {
        if (home.hero === null) { const h = hero(section); if (h) home.hero = h; }
      } else if (type === "PinotCarouselSection") {
        if (home.rows.length >= LIMITS.rows) return;
        const r = row(section, index);
        if (r && r.titles.length > 0) home.rows.push(r);
      }
    });
    return home;
  };

  // ---- the gate's read -> a home that asks who is watching (NetflixGate.parse) ----
  build.gate = read => {
    if (!isObject(read) || !Array.isArray(read.gate)) return null;
    const seen = {};
    const profiles = [];
    for (const entry of read.gate.slice(0, LIMITS.tiles)) {
      if (!isObject(entry)) continue;
      const id = token(entry.id), name = str(entry.name);
      if (id === null || name === null || seen[id]) continue;
      seen[id] = true;
      profiles.push({ id, name, avatar: https(entry.avatar), isKids: false, isLocked: entry.locked === true });
    }
    if (profiles.length === 0) return null;
    return { profiles, currentProfileID: null, hero: null, rows: [], asksWhoIsWatching: true };
  };

  // ---- the search cards -> titles (NetflixSearch.titles) ----
  build.search = cards => {
    const seen = {};
    const titles = [];
    for (const card of Array.isArray(cards) ? cards : []) {
      if (titles.length >= LIMITS.search || !isObject(card)) break;
      const id = card.id;
      if (typeof id !== "string" || !/^[0-9]+$/.test(id)) continue;
      const name = str(card.name), play = playURL(id);
      if (name === null || play === null || seen[id]) continue;
      seen[id] = true;
      titles.push({ id, name, kind: "other", play, page: pageURL(id), tileArt: https(card.art) });
    }
    return titles;
  };

  // ---- the details panel's read -> details / episodes (NetflixDetails) ----
  build.episodes = read => {
    const seen = {};
    const list = [];
    for (const entry of isObject(read) && Array.isArray(read.episodes) ? read.episodes : []) {
      if (list.length >= LIMITS.episodes || !isObject(entry)) break;
      const id = numericID(entry.id), play = playURL(id);
      if (id === null || play === null || seen[id]) continue;
      seen[id] = true;
      const number = int(entry.number), name = str(entry.name);
      list.push({
        id, name: name !== null ? name : number !== null ? "Episode " + number : "Episode", number,
        synopsis: typeof entry.synopsis === "string" ? entry.synopsis : null,
        runtimeSeconds: int(entry.runtime), resumeSeconds: int(entry.resume), play, art: https(entry.art)
      });
    }
    return list;
  };

  build.details = (read, title) => {
    if (!isObject(read) || !isObject(title)) return null;
    const filled = Object.assign({}, title);
    const synopsis = str(read.synopsis);
    if (synopsis !== null) filled.synopsis = synopsis;
    const shownID = numericID(read.currentSeasonId);
    const shownEpisodes = build.episodes(read);
    let seasons = [];
    const seen = {};
    for (const entry of Array.isArray(read.seasons) ? read.seasons : []) {
      if (!isObject(entry)) continue;
      const raw = entry.videoId !== undefined && entry.videoId !== null ? entry.videoId : entry.id;
      const id = numericID(raw), name = str(entry.name);
      if (id === null || name === null || seen[id]) continue;
      seen[id] = true;
      seasons.push({ id, name, episodes: id === shownID ? shownEpisodes : [] });
    }
    // A show without a picker (one season, or a limited series): its label names the one season.
    if (seasons.length === 0 && shownEpisodes.length > 0) {
      const label = str(read.seasonLabel);
      seasons = [{ id: shownID !== null ? shownID : title.id, name: label !== null ? label : "Episodes", episodes: shownEpisodes }];
    }
    seasons = seasons.slice(0, LIMITS.seasons);
    const shown = seasons.find(s => s.id === shownID);
    const current = shown ? shown.id : (seasons.length === 1 ? seasons[0].id : null);
    return { title: filled, seasons, currentSeasonID: current };
  };

  // ---- reading the page ----
  const extract = {};

  const graphql = () => {
    try { return window.netflix.reactContext.models.graphql; } catch (e) { return null; }
  };
  const pageDataReady = () => !!graphql();

  // The gate's tiles, in the page's order. Gate markers are required, because Netflix's top bar also
  // lists profile links on /browse and those must never read as the gate.
  const onGate = () => {
    const path = location.pathname.toLowerCase();
    return path.indexOf("profilesgate") >= 0 || !!document.querySelector('.profile-gate-label, .choose-profile, .profiles-gate-container, [data-uia="profile-gate-label"]');
  };
  const gateTiles = () => onGate()
    ? Array.from(document.querySelectorAll('.choose-profile a.profile-link, .profiles-gate-container a.profile-link, a[data-uia^="action-select-profile"], a[data-uia="profile-link"]'))
    : [];
  const tileToken = a => { const m = /[?&]tkn=([A-Za-z0-9-]{1,64})(?:&|$)/.exec(a.getAttribute("href") || ""); return m ? m[1] : null; };
  const tileLocked = a => !!a.querySelector('[class*="lock" i], [data-uia*="lock" i]') || /lock|pin/i.test(a.getAttribute("aria-label") || "") || !!a.closest('[class*="locked" i]');

  extract.home = () => {
    const data = graphql() && graphql().data;
    return data ? data : null;
  };

  extract.gate = () => {
    const found = gateTiles().slice(0, LIMITS.tiles);
    if (found.length === 0) return null;
    return {
      gate: found.map((a, i) => {
        const nameEl = a.querySelector(".profile-name");
        const name = ((nameEl && nameEl.textContent) || a.getAttribute("aria-label") || a.textContent || "").trim().slice(0, 64);
        const icon = a.querySelector(".profile-icon") || a.querySelector('[class*="avatar" i]');
        const bg = icon ? (getComputedStyle(icon).backgroundImage || "") : "";
        const m = /url\(["']?([^"')]+)["']?\)/.exec(bg);
        const isLocked = tileLocked(a);
        return { id: tileToken(a) || (isLocked ? "locked-" + (i + 1) : ""), name, avatar: m ? m[1] : "", locked: isLocked };
      })
    };
  };

  extract.search = () =>
    Array.from(document.querySelectorAll('[data-uia="standard-card"]')).slice(0, LIMITS.search).map(card => {
      const match = (card.getAttribute("href") || "").match(/[?&]jbv=([0-9]+)/);
      const image = card.querySelector("img");
      return { id: match ? match[1] : null, name: card.getAttribute("aria-label") || "", art: image ? image.getAttribute("src") : null };
    });

  // React props of the element's fiber (or an ancestor's), as the page's own components hold them.
  const fiberOf = el => el && el[Object.keys(el).find(k => k.startsWith("__reactFiber"))];
  const propUp = (el, name, depth) => {
    for (let p = fiberOf(el), d = 0; p && d < depth; p = p.return, d++) {
      if (p.memoizedProps && p.memoizedProps[name] !== undefined) return p.memoizedProps[name];
    }
    return undefined;
  };
  const CARD = '[data-uia="titleCard--container"]';
  const episodeCards = () => Array.from(document.querySelectorAll(CARD)).filter(c => propUp(c, "episode", 6));
  const picker = () => document.querySelector('[data-uia="episode-selector"]');

  // The panel: its synopsis, season picker and the shown season's episode cards, expanding a long
  // season's list first. The episode list draws a moment after the panel, so for a show it is waited
  // for; a movie has none; a title of unknown kind (a search result) waits briefly for a picker.
  extract.panel = async kind => {
    const expect = kind === "show" || kind === "episode" ? "episodes" : kind === "movie" ? "none" : "unknown";
    if (expect === "unknown") for (let i = 0; i < 5 && !picker(); i++) await sleep(200);
    if (expect === "episodes" || (expect === "unknown" && picker())) {
      for (let i = 0; i < 15 && episodeCards().length === 0; i++) await sleep(200);
    }
    const before = episodeCards().length;
    let expanded = false;
    for (const button of before ? document.querySelectorAll('[data-uia="section-expand"]') : []) {
      let box = button.parentElement;
      for (let up = 0; box && up < 6 && !box.querySelector(CARD); up++) box = box.parentElement;
      if (box && Array.from(box.querySelectorAll(CARD)).some(c => propUp(c, "episode", 6))) { button.click(); expanded = true; break; }
    }
    for (let i = 0; expanded && i < 15 && episodeCards().length === before; i++) await sleep(200);
    const cards = episodeCards().slice(0, LIMITS.episodes);
    const toggle = document.querySelector('[data-uia="dropdown-toggle"]');
    const options = (toggle && propUp(toggle, "options", 8)) || [];
    const synopsis = document.querySelector('[data-uia="preview-modal-synopsis"]');
    return {
      synopsis: synopsis ? synopsis.textContent.trim() : null,
      currentSeasonId: cards.length ? (propUp(cards[0], "seasonId", 8) || null) : null,
      seasonLabel: toggle ? toggle.textContent.trim() : null,
      seasons: options.slice(0, LIMITS.seasons).map(s => ({ id: s && s.videoId, name: s && s.title })),
      episodes: cards.map(c => {
        const e = propUp(c, "episode", 6);
        return { id: e.videoId, number: e.number, name: e.title, synopsis: e.contextualSynopsis && e.contextualSynopsis.text,
                 runtime: e.runtimeSec, resume: e.bookmark && e.bookmark.position, art: e.artwork && e.artwork.url };
      })
    };
  };

  // Netflix separates an item's name from its count with non-breaking spaces: compare words, not bytes.
  const norm = value => (value || "").replace(/\s+/g, " ").trim();

  // Picks a season in Netflix's own season picker (by its name); true when picked or already shown.
  const chooseSeason = async seasonName => {
    const name = norm(seasonName);
    const toggle = document.querySelector('[data-uia="dropdown-toggle"]');
    if (!toggle) return false;
    if (norm(toggle.textContent) === name) return true;
    const findItem = () => Array.from(document.querySelectorAll('[data-uia="dropdown-menu-item"]'))
      .find(e => { const t = norm(e.textContent); return t === name || t.startsWith(name + " "); });
    // The menu may already be open: clicking the toggle then would close it.
    let item = findItem();
    if (!item) {
      toggle.click();
      for (let i = 0; i < 20 && !(item = findItem()); i++) await sleep(150);
    }
    if (!item) return false;
    item.click();
    return true;
  };

  // True when the shown episode cards belong to this season.
  const seasonShown = seasonID => {
    for (const card of document.querySelectorAll(CARD)) {
      let episode = false, season = null;
      for (let p = fiberOf(card), d = 0; p && d < 8; p = p.return, d++) {
        const props = p.memoizedProps || {};
        if (props.episode) episode = true;
        if (props.seasonId !== undefined && season === null) season = props.seasonId;
      }
      if (episode) return String(season) === seasonID;
    }
    return false;
  };

  extract.season = async seasonID => {
    const toggle = document.querySelector('[data-uia="dropdown-toggle"]');
    const options = (toggle && propUp(toggle, "options", 8)) || [];
    const option = options.find(o => o && numericID(o.videoId) === seasonID);
    const name = option ? str(option.title) : null;
    if (name === null || !(await chooseSeason(name))) return null;
    let shown = false;
    for (let i = 0; i < 40 && !(shown = seasonShown(seasonID)); i++) await sleep(200);
    return shown ? await extract.panel("show") : null;
  };

  // ---- profiles ----
  const currentProfileID = () => {
    const g = graphql(), data = g && g.data;
    const ref = data && data.ROOT_QUERY ? refKey(data.ROOT_QUERY.currentProfile) : null;
    const profile = ref && data ? data[ref] : null;
    return isObject(profile) && typeof profile.guid === "string" ? profile.guid : null;
  };

  // ---- the API the app calls ----
  return {
    api: 1, build, extract,
    // The home page's data is there, or the "Who's watching?" gate has drawn its tiles (/browse may land on it).
    homeReady: () => { try { return pageDataReady() || gateTiles().length > 0; } catch (e) { return false; } },
    detailsReady: () => {
      try { return !!(document.querySelector('[data-uia="preview-modal-synopsis"]') || document.querySelector('[data-uia="episode-selector"]')); }
      catch (e) { return false; }
    },
    searchReady: () => { try { return document.querySelectorAll('[data-uia="standard-card"]').length > 0; } catch (e) { return false; } },
    home: async () => {
      try {
        // On the gate the home is its profiles with no rows; else the page data. One read.
        const gate = extract.gate();
        if (gate) { const g = build.gate(gate); if (g) return text(g); }
        const cache = extract.home();
        return cache ? text(build.home(cache)) : "";
      } catch (e) { return ""; }
    },
    details: async args => {
      try {
        const title = args.title;
        return text(build.details(await extract.panel(title.kind), title));
      } catch (e) { return ""; }
    },
    season: async args => {
      try {
        const id = numericID(args.seasonID);
        const read = id ? await extract.season(id) : null;
        return read ? text(build.episodes(read)) : "";
      } catch (e) { return ""; }
    },
    search: async () => { try { return text(build.search(extract.search())); } catch (e) { return ""; } },
    // On the gate: follow the unlocked tile's own link (Netflix ignores scripted clicks), a tile without
    // one is clicked. Elsewhere: Netflix's own profile switch address. Never types anything.
    chooseProfile: async args => {
      try {
        const id = args.profileID;
        if (token(id) === null) return false;
        if (!onGate() && currentProfileID() === id) return true;
        const hits = gateTiles().filter(a => tileToken(a) === id && !tileLocked(a));
        if (hits.length === 1) {
          const link = hits[0].href ? new URL(hits[0].href, location.href) : null;
          if (link && link.origin === location.origin && link.pathname.toLowerCase() === "/switchprofile") location.assign(link.href);
          else hits[0].click();
          return true;
        }
        if (!/^[A-Za-z0-9]{1,64}$/.test(id)) return false;
        location.assign(ORIGIN + "/SwitchProfile?tkn=" + id);
        return true;
      } catch (e) { return false; }
    },
    // True once the page has left the gate and the chosen profile is the current one.
    profileIsCurrent: args => { try { return !onGate() && currentProfileID() === args.profileID; } catch (e) { return false; } }
  };
})();
