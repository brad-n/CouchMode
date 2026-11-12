// Disney+ reader package (reader API 1). Runs only inside www.disneyplus.com's own page.
// Disney+ is a single-page app whose views all come from its explore API, so every read works from one
// quiet Disney page (the search page, which plays nothing) and makes the same request the site makes for
// that view, signed in with the page's own session. The bearer token is read from the page's
// localStorage inside the request helper and never leaves it: it is not returned, logged or stored.
// The script never plays anything and returns data in CouchMode's shared vocabulary as JSON text.
// The app validates every value again (ids, https addresses, bounds); this script only returns data.
//
// Two layers, so the second can be tested against fixtures with no page:
//   extract.*  the page and its explore requests -> a "read": small JSON of just what the screens need
//   build.*    a read -> the shared vocabulary (pure: values in, values out)
// The reader object at the bottom is the API the app calls (see agents/add-a-streaming-service.md).
const reader = (() => {
  const SERVICE = "disney";
  const SITE = "https://www.disneyplus.com";
  const API = "https://disney.api.edge.bamgrid.com/explore/v1.21/";
  const TOKEN_KEY = "DTCI-DISNEYPLUS.WEB-PROD.token";
  const MAX_TEXT = 900000;
  const MAX_CONTAINERS = 16, MAX_ITEMS = 30, MAX_OFFSET = 5000, MAX_QUERY = 800;
  const LIMITS = { rows: 20, rowsRead: 24, titlesPerRow: 40, profiles: 10, seasons: 50, episodes: 100, search: 60 };
  const PROFILE_FORMS = ["update-profile"];
  const AVATAR_DOMAINS = ["disney-plus.net", "bamgrid.com", "example.invalid"];

  // ---- careful value readers (the same rules the app applies) ----
  const str = v => { if (typeof v !== "string") return null; const t = v.trim(); return t ? t : null; };
  const int = v => (typeof v === "number" && isFinite(v) && Math.abs(v) < 1e15 && Math.floor(v) === v) ? v : null;
  const token = v => (typeof v === "string" && /^[A-Za-z0-9-]{1,64}$/.test(v)) ? v : null;
  const numericID = v => {
    const n = int(v);
    if (n !== null) return n > 0 ? String(n) : null;
    return (typeof v === "string" && /^[0-9]{1,20}$/.test(v)) ? v : null;
  };
  const isUUID = v => typeof v === "string" && /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(v);
  const year = v => {
    const text = typeof v === "string" ? v : (int(v) !== null ? String(int(v)) : null);
    if (text === null) return null;
    const head = text.slice(0, 4);
    if (!/^[0-9]{1,4}$/.test(head)) return null;
    const n = parseInt(head, 10);
    return n >= 1900 && n <= 2100 ? n : null;
  };
  const hostOf = address => {
    const m = /^https:\/\/([^\/?#:@\s]+)(?::[0-9]+)?(?:[\/?#]|$)/i.exec(typeof address === "string" ? address : "");
    return m ? m[1].toLowerCase() : null;
  };
  const avatarURL = address => {
    const h = hostOf(address);
    return h && AVATAR_DOMAINS.some(d => h === d || h.endsWith("." + d)) ? address : null;
  };
  const playURL = id => { const t = token(id); return t ? SITE + "/play/" + t : null; };
  const pageURL = id => { const t = token(id); return t ? SITE + "/browse/entity-" + t : null; };
  // A 16:9 artwork address at a width: ripcut's compose with an image id.
  const imageURL = (imageID, width) => {
    const t = token(imageID);
    return t ? "https://disney.images.edge.bamgrid.com/ripcut-delivery/v2/variant/disney/" + t + "/compose?format=jpeg&width=" + width : null;
  };
  // Where playback resumes, in seconds: the percent watched when partway (1 to 99), else the seconds left.
  const resumeSeconds = (runtimeMs, percent, left) => {
    if (runtimeMs === null || runtimeMs <= 0) return null;
    const total = Math.floor(runtimeMs / 1000);
    if (percent !== null && percent !== 0) return (percent >= 1 && percent <= 99) ? Math.floor(total * percent / 100) : null;
    if (left !== null && left > 0 && left < total) return total - left;
    return null;
  };
  const validQuery = q => typeof q === "string" && q.length > 0 && q.length <= MAX_QUERY && /^[A-Za-z0-9=&_.-]+$/.test(q);
  const validCursor = c => !!c && typeof c === "object" && token(c.setID) !== null && validQuery(c.query) && int(c.next) !== null && c.next >= 0 && c.next <= MAX_OFFSET;

  // ---- build: reads -> shared vocabulary ----
  const build = {};

  // A title from a card; null without a plain id and a name.
  build.title = card => {
    if (!card || typeof card !== "object") return null;
    const id = token(card.id), name = str(card.name), page = id ? pageURL(id) : null;
    if (!id || !name || !page) return null;
    const season = numericID(card.season), episode = numericID(card.episode);
    const runtimeMs = int(card.runtimeMs);
    const kind = season !== null ? "show" : (runtimeMs !== null ? "movie" : "show");
    return {
      id, name, kind, play: playURL(typeof card.playId === "string" ? card.playId : "") || page, page,
      episodeLabel: season !== null && episode !== null ? "S" + season + " · E" + episode : null,
      synopsis: str(card.desc), year: year(card.year), rating: str(card.rating), seasonsLabel: null,
      runtimeSeconds: runtimeMs !== null && runtimeMs > 0 ? Math.floor(runtimeMs / 1000) : null,
      resumeSeconds: resumeSeconds(runtimeMs, int(card.pct), int(card.left)),
      tileArt: imageURL(card.tile, 640), heroArt: imageURL(card.wide, 1920)
    };
  };

  const moreTotal = (container, loaded) => {
    const more = container && container.more;
    if (!more || typeof more !== "object") return null;
    const total = int(more.total);
    return total !== null && total > loaded ? total : null;
  };

  const rowKind = style => style === "continue_watching" ? "continueWatching" : style === "top_ranked" ? "ranked" : "standard";

  // Profiles by name; a name that is empty, too long or shared is left out.
  const profilesOf = entries => {
    const names = entries.map(e => str(e && e.name)).filter(n => n !== null);
    const profiles = [];
    let currentID = null;
    for (const e of entries) {
      const name = str(e && e.name);
      if (name === null || name.length > 64 || names.filter(n => n === name).length !== 1) continue;
      profiles.push({ id: name, name, avatar: avatarURL(e.avatar), isKids: false, isLocked: false });
      if (e.current === true) currentID = name;
    }
    return { profiles, currentID };
  };

  // The home from the home read; null when it has nothing to show. A row the site holds more of carries an
  // opaque "cursor" (what more() needs to ask for the row's next batch).
  build.home = read => {
    if (!read || !Array.isArray(read.rows)) return null;
    let hero = null;
    const rows = [];
    for (const c of read.rows) {
      if (!c || typeof c !== "object") continue;
      const items = Array.isArray(c.items) ? c.items.filter(i => i && typeof i === "object") : [];
      const titles = items.map(build.title).filter(Boolean);
      const style = typeof c.style === "string" ? c.style : "";
      if (style === "hero_immersive") { if (!hero) hero = titles[0] || null; continue; }
      const id = token(c.id);
      if (titles.length === 0 || id === null) continue;
      const row = { id: "disney-row-" + id, title: str(c.name) || "", kind: rowKind(style), titles, totalCount: moreTotal(c, titles.length), cursor: null };
      // The cursor needs the total measured against the raw items, as the page counted them.
      const more = c.more;
      if (moreTotal(c, items.length) !== null) {
        const cursor = { setID: id, query: more.q, next: int(more.next) };
        if (validCursor(cursor)) row.cursor = cursor;
      }
      rows.push(row);
    }
    const { profiles, currentID } = profilesOf(Array.isArray(read.profiles) ? read.profiles.filter(p => p && typeof p === "object") : []);
    const home = {
      serviceID: SERVICE, profiles: profiles.slice(0, LIMITS.profiles), currentProfileID: currentID, hero,
      rows: rows.slice(0, LIMITS.rows).map(r => Object.assign({}, r, { titles: r.titles.slice(0, LIMITS.titlesPerRow) })),
      asksWhoIsWatching: false
    };
    return home.rows.length === 0 && !home.hero ? null : home;
  };

  // Cards with a plain id and a name, each once, at most LIMITS.search. Their player address is found when their details are read.
  build.search = cards => {
    if (!Array.isArray(cards)) return [];
    const seen = new Set(), titles = [];
    for (const card of cards) {
      if (titles.length >= LIMITS.search) break;
      const t = build.title(card);
      if (!t || seen.has(t.id)) continue;
      seen.add(t.id);
      titles.push(t);
    }
    return titles;
  };

  // The batch and the cursor for the one after it (null when the site has no more, or sent nothing); null when unreadable.
  build.more = (read, cursor) => {
    if (!read || typeof read !== "object" || !Array.isArray(read.items) || !validCursor(cursor)) return null;
    const titles = read.items.map(build.title).filter(Boolean);
    const sent = int(read.count) !== null ? int(read.count) : read.items.length;
    const hasMore = read.hasMore === true && sent > 0;
    const next = cursor.next + sent;
    return { titles, cursor: hasMore && next <= MAX_OFFSET ? { setID: cursor.setID, query: cursor.query, next } : null };
  };

  // The title filled in from its page: what it is (a movie or a show), synopsis, year, rating, a movie's length and
  // place, a show's season count, the address Play uses, and the seasons (their episodes arrive when one is opened).
  build.details = (read, title) => {
    if (!read || typeof read !== "object" || !title || typeof title !== "object") return null;
    const isSeries = typeof read.series === "boolean" ? read.series : title.kind === "show";
    const filled = Object.assign({}, title, { kind: isSeries ? "show" : "movie", play: playURL(typeof read.playId === "string" ? read.playId : "") || title.play });
    if (str(read.desc)) filled.synopsis = str(read.desc);
    if (str(read.rating)) filled.rating = str(read.rating);
    if (year(read.year) !== null) filled.year = year(read.year);
    const wide = imageURL(read.wide, 1920);
    if (wide) filled.heroArt = wide;
    if (!filled.tileArt) { const tile = imageURL(read.tile, 640); if (tile) filled.tileArt = tile; }
    const seasons = [], seen = new Set();
    for (const entry of Array.isArray(read.seasons) ? read.seasons : []) {
      const id = token(entry && entry.id), name = str(entry && entry.name);
      if (id === null || name === null || seen.has(id)) continue;
      seen.add(id);
      seasons.push({ id, name, episodes: [] });
    }
    if (isSeries) {
      filled.seasonsLabel = str(read.seasonsLabel) || (seasons.length === 0 ? null : seasons.length === 1 ? "1 Season" : seasons.length + " Seasons");
    } else {
      filled.seasonsLabel = null;
      const runtimeMs = int(read.runtimeMs);
      if (runtimeMs !== null && runtimeMs > 0) filled.runtimeSeconds = Math.floor(runtimeMs / 1000);
      filled.resumeSeconds = resumeSeconds(runtimeMs, int(read.pct), null);
    }
    const focus = token(read.currentSeasonId);
    const focused = seasons.find(s => s.id === focus);
    const current = focused ? focused.id : (seasons.length === 1 ? seasons[0].id : null);
    return { title: filled, seasons: isSeries ? seasons : [], currentSeasonID: isSeries ? current : null };
  };

  // The episodes of a season's read: each with a plain id and a player address, once, at most LIMITS.episodes.
  build.episodes = read => {
    const out = [], seen = new Set();
    for (const e of (read && Array.isArray(read.episodes)) ? read.episodes : []) {
      if (out.length >= LIMITS.episodes || !e || typeof e !== "object") continue;
      const id = token(e.id), play = playURL(typeof e.playId === "string" ? e.playId : "");
      if (id === null || play === null || seen.has(id)) continue;
      seen.add(id);
      const number = numericID(e.number);
      const runtimeMs = int(e.durationMs);
      out.push({
        id, name: str(e.name) || (number !== null ? "Episode " + number : "Episode"), number: number === null ? null : parseInt(number, 10),
        synopsis: str(e.desc), runtimeSeconds: runtimeMs !== null && runtimeMs > 0 ? Math.floor(runtimeMs / 1000) : null,
        resumeSeconds: resumeSeconds(runtimeMs, int(e.pct), int(e.left)), play, art: imageURL(e.art, 640)
      });
    }
    return out;
  };

  // ---- extract: the page's own explore requests -> reads ----
  const extract = {};

  // A signed-in explore request. The token is read here and used here; it throws without a session.
  const get = async path => {
    let session = null;
    try { session = JSON.parse(localStorage.getItem(TOKEN_KEY) || "null"); } catch (e) { session = null; }
    if (!session || typeof session.access_token !== "string") throw new Error("no session");
    const response = await fetch(API + path, { headers: { authorization: "Bearer " + session.access_token, accept: "application/json" } });
    if (!response.ok) throw new Error(String(response.status));
    return response.json();
  };

  // A row, search or season item squeezed into a card; null for anything that isn't a title with a page.
  const image = o => (o && o["1.78"] && o["1.78"].imageId) || null;
  const card = item => {
    const v = item.visuals || {}, acts = item.actions || [], art = v.artwork || {}, std = art.standard || {}, m = v.metastringParts || {};
    const browse = acts.find(a => a.type === "browse" && /^entity-[0-9a-f-]{36}$/i.test(a.pageId || ""));
    if (!browse) return null;
    const play = acts.find(a => a.type === "playback");
    const progress = (item.personalization && item.personalization.userState && item.personalization.userState.progress) || {};
    const description = v.description || {};
    return {
      id: browse.pageId.slice(7), name: v.title || null,
      desc: String(description.medium || description.brief || description.full || "").slice(0, 400) || null,
      year: (m.releaseYearRange && m.releaseYearRange.startYear) || null,
      rating: (m.ratingInfo && m.ratingInfo.rating && m.ratingInfo.rating.text) || null,
      runtimeMs: v.durationMs || (m.runtime && m.runtime.runtimeMs) || null,
      season: v.seasonNumber || null, episode: v.episodeNumber || null,
      pct: progress.progressPercentage == null ? null : progress.progressPercentage,
      left: progress.secondsRemaining == null ? null : progress.secondsRemaining,
      playId: play ? play.deeplinkId || null : null,
      tile: image(std.tile) || image(std.thumbnail) || image(std.background),
      wide: image((art.hero || {}).background) || image(std.background) || image(std.tile)
    };
  };

  // The profile menu in the top bar: menuOpen() opens it the way a hover does and waits (bounded) for its
  // entries, menuClose() lets it go, currentName() is the current profile's name.
  const active = () => document.querySelector('[data-testid="dropdown-active-profile"]');
  const fire = (el, types) => types.forEach(t => el.dispatchEvent(new MouseEvent(t, { bubbles: true, view: window })));
  const currentName = () => {
    const button = active();
    const m = button && (button.getAttribute("aria-label") || "").match(/^(.+?)['’]s profile\./);
    return m ? m[1].trim() : null;
  };
  const menuOpen = async () => {
    const button = active();
    if (!button) return false;
    fire(button, ["pointerover", "mouseover", "pointerenter", "mouseenter", "mousemove"]);
    button.focus();
    for (let i = 0; i < 15; i++) {
      if (document.querySelector('[data-testid^="dropdown-option-"]')) return true;
      await new Promise(r => setTimeout(r, 100));
    }
    return false;
  };
  const menuClose = () => {
    const button = active();
    if (!button) return;
    const list = document.querySelector('[data-testid="account-dropdown-list"]');
    fire(button, ["pointerout", "mouseout", "pointerleave", "mouseleave"]);
    if (list) fire(list, ["pointerout", "mouseout", "pointerleave", "mouseleave"]);
    button.blur();
  };
  const click = el => { for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window })); };

  // What a container the site holds more of notes for the paging request: its total, the next offset and the
  // params query (the params the page's own set request carries).
  const moreNote = c => {
    const p = c.pagination || {}, params = c.params || {}, q = new URLSearchParams();
    for (const k of Object.keys(params).slice(0, 12)) if (typeof params[k] === "string") q.set(k, params[k]);
    return { total: p.totalCount, next: (p.currentOffset || 0) + (c.items || []).slice(0, MAX_ITEMS).length, q: q.toString() };
  };

  extract.home = async () => {
    const findHome = (node, depth) => {
      if (!node || depth > 6) return null;
      const a = node.action;
      if (a && a.deeplinkId === "home" && /^page-[0-9a-f-]{36}$/i.test(a.pageId || "")) return a.pageId;
      for (const child of node.children || []) { const found = findHome(child, depth + 1); if (found) return found; }
      return null;
    };
    const pageId = findHome((await get("globalNav")).data.nav, 0);
    if (!pageId) return null;
    const page = (await get("page/" + pageId + "?disableSmartFocus=true&enhancedContainersLimit=" + MAX_CONTAINERS + "&limit=" + MAX_ITEMS)).data.page;
    const rows = (page.containers || []).filter(c => c.type === "set" && c.style && c.items && c.items.length)
      .map(c => ({ id: c.id || null, name: (c.visuals && c.visuals.name) || "", style: c.style.name || "",
                   items: c.items.slice(0, MAX_ITEMS).map(card).filter(Boolean),
                   more: c.pagination && c.pagination.hasMore ? moreNote(c) : null }))
      .filter(r => r.items.length).slice(0, LIMITS.rowsRead);
    const profiles = [];
    const current = currentName();
    if (current && await menuOpen()) {
      const avatar = el => { const img = el && el.querySelector("img"); return img ? img.getAttribute("src") : null; };
      profiles.push({ name: current, avatar: avatar(active()), current: true });
      for (const b of Array.from(document.querySelectorAll('[data-testid^="dropdown-profile-"]')).slice(0, LIMITS.profiles)) {
        profiles.push({ name: b.textContent.trim(), avatar: avatar(b), current: false });
      }
      menuClose();
    }
    return { rows, profiles };
  };

  extract.search = async query => {
    const page = (await get("search?query=" + encodeURIComponent(query))).data.page;
    const items = (page.containers || []).flatMap(c => c.items || []);
    return items.slice(0, LIMITS.search * 2).map(card).filter(Boolean).slice(0, LIMITS.search);
  };

  extract.details = async entityID => {
    if (!isUUID(entityID)) return null;
    const page = (await get("page/entity-" + entityID + "?disableSmartFocus=true&enhancedContainersLimit=0&limit=1")).data.page;
    const v = page.visuals || {}, m = v.metastringParts || {}, std = (v.artwork || {}).standard || {}, description = v.description || {};
    const plays = (page.actions || []).filter(a => a.type === "playback");
    const kindOf = a => ((a.options || [])[0] || {}).type;
    const play = plays.find(a => kindOf(a) === "resume") || plays[0] || null;
    const episodes = (page.containers || []).find(c => c.type === "episodes");
    const progress = (page.personalization && page.personalization.userState && page.personalization.userState.progress) || {};
    return {
      id: entityID, name: v.title || null,
      desc: String(description.full || description.medium || description.brief || "").slice(0, 1200) || null,
      year: (m.releaseYearRange && m.releaseYearRange.startYear) || null,
      rating: (m.ratingInfo && m.ratingInfo.rating && m.ratingInfo.rating.text) || null,
      series: !!episodes, runtimeMs: (m.runtime && m.runtime.runtimeMs) || null,
      pct: progress.progressPercentage == null ? null : progress.progressPercentage,
      seasonsLabel: m.seasonsAvailable || null,
      playId: play ? play.deeplinkId || null : null, resumes: !!play && kindOf(play) === "resume",
      tile: image(std.tile) || image(std.background), wide: image(std.background) || image(std.tile),
      currentSeasonId: (episodes && episodes.focus && episodes.focus.seasonId) || null,
      seasons: ((episodes && episodes.seasons) || []).slice(0, LIMITS.seasons).map(s => ({
        id: s.id || null, name: (s.visuals && s.visuals.name) || null, count: (s.visuals && s.visuals.episodeCountDisplayText) || null
      }))
    };
  };

  extract.season = async seasonID => {
    if (!isUUID(seasonID)) return null;
    const season = (await get("season/" + seasonID + "?limit=" + LIMITS.episodes)).data.season;
    const episodes = (season.items || []).slice(0, LIMITS.episodes).map(item => {
      const v = item.visuals || {}, std = (v.artwork || {}).standard || {}, description = v.description || {};
      const play = (item.actions || []).find(a => a.type === "playback");
      const progress = (item.personalization && item.personalization.userState && item.personalization.userState.progress) || {};
      return {
        id: item.id || null, playId: play ? play.deeplinkId || null : null, name: v.episodeTitle || v.title || null,
        number: v.episodeNumber || null, desc: String(description.medium || description.brief || "").slice(0, 400) || null,
        durationMs: v.durationMs || (v.metastringParts && v.metastringParts.runtime && v.metastringParts.runtime.runtimeMs) || null,
        pct: progress.progressPercentage == null ? null : progress.progressPercentage,
        left: progress.secondsRemaining == null ? null : progress.secondsRemaining,
        art: image(std.thumbnail) || image(std.tile)
      };
    });
    return { episodes };
  };

  // The one set request the page itself makes for the rest of a row, at the cursor.
  extract.more = async cursor => {
    const set = (await get("set/" + cursor.setID + "?limit=" + MAX_ITEMS + "&offset=" + cursor.next + "&" + cursor.query)).data.set;
    const sent = (set.items || []).slice(0, MAX_ITEMS);
    return { items: sent.map(card).filter(Boolean), count: sent.length, hasMore: !!(set.pagination && set.pagination.hasMore) };
  };

  // ---- page checks ----
  const onForm = () => PROFILE_FORMS.includes(location.pathname.split("/").filter(Boolean)[0]);
  // True once the page is signed in (a session is kept) and has drawn its profile menu (so no "who's watching" screen is in the way).
  const pageReady = () => {
    try {
      const session = JSON.parse(localStorage.getItem(TOKEN_KEY) || "null");
      return !!session && typeof session.access_token === "string" && !!active();
    } catch (e) { return false; }
  };
  const pickerTiles = () => Array.from(document.querySelectorAll('[data-testid^="profile-avatar-"]'));

  // ---- the API the app calls ----
  const text = value => {
    if (value === null || value === undefined) return "";
    const out = JSON.stringify(value);
    return out.length > MAX_TEXT ? "" : out;
  };

  return {
    api: 1, build, extract,
    // Ready, or on a profile form (which never gets ready), so a read waiting on this ends at once on the form.
    homeReady: () => { try { return onForm() || pageReady(); } catch (e) { return false; } },
    pageReady: () => { try { return pageReady(); } catch (e) { return false; } },
    home: async () => {
      try { const read = await extract.home(); return read ? text(build.home(read)) : ""; } catch (e) { return ""; }
    },
    details: async args => {
      try { const read = await extract.details(args.title.id); return read ? text(build.details(read, args.title)) : ""; } catch (e) { return ""; }
    },
    season: async args => {
      try { const read = await extract.season(args.seasonID); return read ? text(build.episodes(read)) : ""; } catch (e) { return ""; }
    },
    search: async args => {
      try { return typeof args.query === "string" && args.query ? text(build.search(await extract.search(args.query))) : ""; } catch (e) { return ""; }
    },
    more: async args => {
      try {
        const cursor = args.cursor;
        if (!validCursor(cursor)) return "";
        return text(build.more(await extract.more(cursor), cursor));
      } catch (e) { return ""; }
    },
    // Presses the profile in the top bar's menu, nothing more; true when chosen (or already current).
    chooseProfile: async args => {
      const name = args.profileID;
      if (currentName() === name) return true;
      if (!(await menuOpen())) return false;
      const matches = Array.from(document.querySelectorAll('[data-testid^="dropdown-profile-"]')).filter(b => b.textContent.trim() === name);
      if (matches.length !== 1) { menuClose(); return false; }
      click(matches[0]);
      return true;
    },
    // True once a profile switch has settled: the page is on a profile form, or its current profile is the chosen one.
    profileSettled: args => { try { return onForm() || currentName() === args.profileID; } catch (e) { return false; } },
    profileIsCurrent: args => currentName() === args.profileID,
    // Disney's own "who's watching" page: ready once it has drawn its tiles; a tile is labelled with its profile's name.
    pickerReady: () => { try { return pickerTiles().length > 0; } catch (e) { return false; } },
    restoreProfile: args => {
      const tiles = pickerTiles().filter(e => e.getAttribute("aria-label") === args.profileID);
      if (tiles.length !== 1) return false;
      click(tiles[0]);
      return true;
    },
    leftPicker: () => !location.pathname.split("/").includes("select-profile")
  };
})();
