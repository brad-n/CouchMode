// Hulu reader package (reader API 1). Runs only inside www.hulu.com's own page. It makes the
// requests the page itself makes for the action (the home's one discover request, a title's hub and
// season requests), types into the page's own search box, reads profile id, name and kids flag from
// the page's store (nothing else from it), never plays anything, and returns data in CouchMode's
// shared vocabulary as JSON text. The app validates every value again (ids, https addresses, bounds).
//
// Two layers, so the second can be tested against fixtures with no page:
//   extract.*  the page -> a "read": small JSON of just what the screens need (needs the page)
//   build.*    a read -> the shared vocabulary (pure: values in, values out)
// The reads have the same shapes as the built-in Swift reader's (HuluHome, HuluDetails, HuluSearch).
const reader = (() => {
  const ORIGIN = "https://www.hulu.com";
  const DISCOVER = "https://discover.hulu.com/content/v5/";
  const MAX_TEXT = 900000;
  const MAX_COMPONENTS = 30, MAX_ITEMS = 40, MAX_EPISODES = 100, MAX_SEASONS = 50, MAX_SEARCH = 60;
  const SEARCH_WAIT_MS = 8000;
  const IMAGE_DOMAINS = ["hulu.com", "hulustream.com", "huluim.com", "hulu.invalid"];

  // ---- careful value readers (the same rules the app applies) ----
  const str = v => { if (typeof v !== "string") return null; const t = v.trim(); return t ? t : null; };
  const int = v => (typeof v === "number" && isFinite(v) && Math.abs(v) < 1e15 && Math.floor(v) === v) ? v : null;
  const token = (v, max = 64) => (typeof v === "string" && v.length >= 1 && v.length <= max && /^[A-Za-z0-9-]+$/.test(v)) ? v : null;
  const intText = v => (typeof v === "string" && /^[+-]?[0-9]{1,15}$/.test(v)) ? parseInt(v, 10) : null;
  const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

  // ---- addresses ----
  const playURL = id => { const t = token(id); return t ? ORIGIN + "/watch/" + t : null; };
  const pageURL = (kind, id) => {
    const t = token(id);
    if (!t) return null;
    return kind === "show" ? ORIGIN + "/series/" + t : kind === "movie" ? ORIGIN + "/movie/" + t : null;
  };

  // An artwork address at a size: https and a Hulu host only; the size is the `operations` parameter
  // Hulu's own pages use (an existing one is replaced). Every value is encoded fully.
  const encodeValue = text => Array.from(text).map(c => /[A-Za-z0-9:,\-_.~]/.test(c) ? c :
    encodeURIComponent(c).replace(/[!'()*]/g, ch => "%" + ch.charCodeAt(0).toString(16).toUpperCase())).join("");
  const decodeValue = text => { try { return decodeURIComponent(text); } catch (e) { return null; } };
  const imageURL = (address, width, height) => {
    if (typeof address !== "string") return null;
    const m = address.match(/^https:\/\/([^\/?#:@]+)(:[0-9]+)?([^?#]*)(?:\?([^#]*))?(#.*)?$/i);
    if (!m) return null;
    const host = m[1].toLowerCase();
    if (!IMAGE_DOMAINS.some(d => host === d || host.endsWith("." + d))) return null;
    const pairs = [];
    for (const part of (m[4] || "").split("&")) {
      if (part === "") continue;
      const i = part.indexOf("=");
      const name = decodeValue(i < 0 ? part : part.slice(0, i)), value = i < 0 ? "" : decodeValue(part.slice(i + 1));
      if (name === null || value === null) return null;
      if (name !== "operations") pairs.push([name, value]);
    }
    pairs.push(["operations", '[{"resize":"' + width + "x" + height + '|max"},{"format":"jpeg"}]']);
    return "https://" + m[1] + (m[2] || "") + m[3] + "?" + pairs.map(([n, v]) => n + "=" + encodeValue(v)).join("&") + (m[5] || "");
  };

  // ---- pure: a read -> the shared vocabulary ----
  const build = {};

  const rowKind = name => name.startsWith("Continue Watching") ? "continueWatching" : /^Top [0-9]+/.test(name) ? "ranked" : "standard";

  // "S1 · E7" from a subtitle starting "S1 E7".
  const episodeLabel = subtitle => {
    const m = typeof subtitle === "string" ? subtitle.match(/^S([0-9]+) E([0-9]+)/) : null;
    return m ? "S" + m[1] + " · E" + m[2] : null;
  };

  // The uuid an "EAB::<uuid>::..." names, which is what Hulu's player plays.
  const playableID = eab => {
    if (typeof eab !== "string") return null;
    const parts = eab.split("::");
    return parts.length >= 2 && parts[0] === "EAB" && UUID.test(parts[1]) ? parts[1] : null;
  };

  const homeTitle = item => {
    if (!item || typeof item !== "object") return null;
    const kind = item.type === "series" ? "show" : item.type === "movie" ? "movie" : item.type === "episode" ? "episode" : null;
    if (!kind) return null;
    const id = token(item.id), name = str(item.name), playID = playableID(item.eab), play = playID && playURL(playID);
    if (!id || !name || !play) return null;
    // The label marks the episode you're on: an episode tile is that episode; a show has one only when
    // Hulu offers to resume it (a recommendation's "S1 E1" is just where it starts).
    const resumes = (str(item.action) || "").toLowerCase().startsWith("resume");
    return {
      id, name, kind, play, page: pageURL(kind, id),
      episodeLabel: kind === "episode" || resumes ? episodeLabel(item.subtitle) : null,
      synopsis: str(item.body), tileArt: imageURL(item.tile, 640, 360), heroArt: imageURL(item.wide, 1920, 1080)
    };
  };

  build.home = read => {
    if (!read || typeof read !== "object" || !Array.isArray(read.rows)) return null;
    let hero = null;
    const rows = [];
    for (const component of read.rows) {
      if (!component || typeof component !== "object") continue;
      const name = str(component.name) || "";
      const titles = (Array.isArray(component.items) ? component.items : []).map(homeTitle).filter(Boolean);
      if (name === "Spotlight") { if (!hero) hero = titles[0] || null; continue; }
      const id = token(component.id);
      if (titles.length === 0 || !id) continue;
      rows.push({ id: "hulu-row-" + id, title: name, kind: rowKind(name), titles });
    }
    const profiles = (Array.isArray(read.profiles) ? read.profiles : []).map(p => {
      const id = p && token(p.id), name = p && str(p.name);
      return id && name ? { id, name, isKids: p.kids === true } : null;
    }).filter(Boolean);
    return { profiles, currentProfileID: token(read.currentProfileId), hero, rows };
  };

  const episodeList = list => {
    const seen = new Set(), out = [];
    for (const e of Array.isArray(list) ? list : []) {
      if (out.length >= MAX_EPISODES) break;
      if (!e || typeof e !== "object") continue;
      const id = token(e.id), play = id && playURL(id);
      if (!play || seen.has(id)) continue;
      seen.add(id);
      const number = int(e.number) !== null ? int(e.number) : intText(e.number);
      const runtime = int(e.duration);
      const progress = int(e.progress);
      const resume = runtime !== null && runtime > 0 && progress !== null && progress >= 1 && progress <= 100 ? Math.floor(runtime * progress / 100) : null;
      out.push({
        id, name: str(e.name) || (number !== null ? "Episode " + number : "Episode"), number, synopsis: str(e.synopsis),
        runtimeSeconds: runtime, resumeSeconds: resume, play, art: imageURL(e.art, 640, 360)
      });
    }
    return out;
  };

  build.details = (read, row) => {
    if (!read || typeof read !== "object" || Array.isArray(read)) return null;
    const title = Object.assign({}, row);
    // What Play continues: a show from search only knew its own id, which isn't something to play.
    const playID = title.kind === "show" ? token(read.playId) : null;
    if (playID) {
      const season = str(read.playSeason), number = str(read.playNumber);
      title.play = playURL(playID);
      title.episodeLabel = season && number ? season + " · E" + number : (title.episodeLabel === undefined ? null : title.episodeLabel);
    }
    if (str(read.description)) title.synopsis = str(read.description);
    if (str(read.rating)) title.rating = str(read.rating);
    const premiere = str(read.premiere);
    const year = premiere ? parseInt(premiere.slice(0, 4), 10) : NaN;
    if (premiere && /^[+-]?[0-9]+$/.test(premiere.slice(0, 4)) && year >= 1900 && year <= 2100) title.year = year;
    const shownID = str(read.currentSeasonId);
    const seasons = [], seen = new Set();
    for (const entry of Array.isArray(read.seasons) ? read.seasons : []) {
      const id = entry && str(entry.id), name = entry && str(entry.name);
      if (!id || !name || seen.has(id)) continue;
      seen.add(id);
      seasons.push({ id, name, episodes: id === shownID ? episodeList(read.shownEpisodes) : [] });
    }
    if (title.kind !== "movie") {
      title.seasonsLabel = seasons.length === 0 ? null : seasons.length === 1 ? "1 Season" : seasons.length + " Seasons";
    } else if (int(read.duration) !== null && int(read.duration) > 0) {
      title.runtimeSeconds = int(read.duration);
    }
    const shown = seasons.find(s => s.id === shownID);
    const current = shown ? shown.id : (seasons.length === 1 ? seasons[0].id : null);
    return { title, seasons: seasons.slice(0, MAX_SEASONS), currentSeasonID: current };
  };

  build.season = read => (read && typeof read === "object" && !Array.isArray(read)) ? episodeList(read.episodes) : [];

  build.search = read => {
    const out = [], seen = new Set();
    for (const card of Array.isArray(read) ? read : []) {
      if (out.length >= MAX_SEARCH) break;
      const parts = card && typeof card.href === "string" ? card.href.split("/").filter(p => p !== "") : [];
      if (parts.length !== 2) continue;
      const id = token(parts[1]), kind = parts[0] === "series" ? "show" : parts[0] === "movie" ? "movie" : null;
      const name = str(card.name), play = id && playURL(id);
      if (!kind || !id || !name || !play || seen.has(id)) continue;
      seen.add(id);
      out.push({ id, name, kind, play, page: pageURL(kind, id), tileArt: imageURL(card.art, 640, 360) });
    }
    return out;
  };

  // ---- the page -> a read (needs the page) ----
  const extract = {};

  const profileStore = () => { try { return (window.store && window.store.getState().profile_manager) || null; } catch (e) { return null; } };

  extract.homeReady = () => !!document.getElementById("__NEXT_DATA__") && !!profileStore();

  // The one discover request the page makes for its home (the address is in the page's own data).
  extract.home = async () => {
    const next = document.getElementById("__NEXT_DATA__");
    if (!next) return null;
    const props = JSON.parse(next.textContent).props.pageProps;
    const navQuery = (props.dehydratedState.queries || []).find(q => q.queryKey && q.queryKey[0] === "GlobalNav");
    const href = navQuery && navQuery.state.data.nav.defaultNavItem.discoverHref;
    if (!href || !/^https:\/\/discover\.hulu\.com\//.test(href)) return null;
    const response = await fetch(href, { credentials: "include" });
    if (!response.ok) return null;
    const hub = await response.json();
    const path = art => (art && art.image && art.image.path) || null;
    const pick = item => {
      const v = item.visuals || {}, art = v.artwork || {}, m = item.metrics_info || {}, p = item.personalization || {};
      return { id: item.id || null, type: m.target_type || null, name: v.headline || m.target_name || null,
               subtitle: v.subtitle || null, body: v.body || null, action: v.action_text || null, eab: p.eab || null,
               tile: path(art.horizontal_tile) || path(art.horizontal), wide: path(art.horizontal) || path(art.horizontal_tile) };
    };
    const rows = (hub.components || []).slice(0, MAX_COMPONENTS).map(c => ({
      id: c.id || null, name: c.name || null, items: (c.items || []).slice(0, MAX_ITEMS).map(pick)
    }));
    // Only id, name and is_kids are read from the page's store, and the current profile's id.
    const manager = profileStore() || {};
    return {
      rows,
      profiles: (manager.profiles || []).map(p => ({ id: String(p.id), name: p.name || "", kids: !!p.is_kids })),
      currentProfileId: manager.currentProfileId ? String(manager.currentProfileId) : null
    };
  };

  extract.detailsReady = () => document.readyState === "complete" && /^\/(series|movie)\/[0-9a-f-]{36}$/i.test(location.pathname);

  const get = async url => {
    if (!url.startsWith(DISCOVER)) throw new Error("not discover");
    const response = await fetch(url, { credentials: "include" });
    if (!response.ok) throw new Error(String(response.status));
    return response.json();
  };
  const episodesOf = async grouping => {
    const items = (grouping.items || []).slice(0, MAX_EPISODES);
    const state = {};
    if (items.length && grouping.p13n_href) {
      for (const s of (await get(grouping.p13n_href)).items || []) state[s.entity_id] = s;
    }
    return items.map(e => {
      const s = state[e.id] || {}, art = e.artwork && (e.artwork["video.horizontal.hero"] || Object.values(e.artwork)[0]);
      return { id: e.id || null, number: e.number || null, name: e.name || null, synopsis: e.description || null,
               duration: (e.bundle && e.bundle.duration) || null, progress: s.is_completed ? null : (s.progress_percentage || null),
               art: (art && art.path) || null };
    });
  };

  // The shown title page's own hub request (and the episodes' progress request it names).
  extract.details = async () => {
    const m = location.pathname.match(/^\/(series|movie)\/([0-9a-f-]{36})$/i);
    if (!m) return null;
    const hub = await get(DISCOVER + "hubs/" + m[1] + "/" + m[2] + "?schema=3&limit=1999");
    const entity = (hub.details && hub.details.entity) || {};
    const groups = ((hub.components || []).find(c => c.theme === "collection_theme_groupings") || {}).items || [];
    const focus = (hub.components || []).map(c => c.focus_navigation && c.focus_navigation.collection_id).find(Boolean);
    const shown = groups.find(g => g.id === focus && (g.items || []).length) || groups.find(g => (g.items || []).length);
    const vod = hub.details && hub.details.vod_items && hub.details.vod_items.focus;
    const bundle = entity.bundle || (vod && vod.entity && vod.entity.bundle) || {};
    const playing = vod && vod.entity && vod.entity._type === "episode" ? vod.entity : null;
    return {
      playId: playing ? playing.id || null : null,
      playSeason: playing ? playing.season_short_display_name || null : null, playNumber: playing ? playing.number || null : null,
      name: entity.name || null, description: entity.description || null, rating: entity.rating && entity.rating.code || null,
      premiere: entity.premiere_date || null, duration: bundle.duration || null, genres: entity.genre_names || [],
      currentSeasonId: shown ? shown.id : null,
      seasons: groups.slice(0, MAX_SEASONS).map(g => ({
        id: g.id || null, name: g.name || null, count: g.pagination && g.pagination.total_count || null, episodes: null
      })),
      shownEpisodes: shown ? await episodesOf(shown) : []
    };
  };

  // The season request the title page's season picker makes. `seasonID` is "<series>::<n>".
  extract.season = async seasonID => {
    const m = typeof seasonID === "string" ? seasonID.match(/^([0-9a-f-]{36})::([0-9]{1,3})$/i) : null;
    if (!m) return null;
    const grouping = await get(DISCOVER + "hubs/series/" + m[1] + "/season/" + m[2] + "?schema=3&limit=" + MAX_EPISODES);
    return { episodes: await episodesOf(grouping) };
  };

  const searchBox = () => document.querySelector('[data-testid="search-bar-input"]');
  extract.searchReady = () => { const box = searchBox(); return !!box && Object.keys(box).some(k => k.startsWith("__reactProps")); };

  // Types the query into the page's own search box the way a keyboard would (the page's own handlers run).
  extract.type = query => {
    const box = searchBox();
    if (!box || typeof query !== "string") return false;
    box.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(box, query);
    box.dispatchEvent(new Event("input", { bubbles: true }));
    return true;
  };
  const resultLinks = () => Array.from(document.querySelectorAll('[data-testid="instant-search-item-link"]'))
    .filter(a => /^\/(series|movie)\//.test(a.getAttribute("href") || ""));
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  // Waits (bounded) for series or movies to be listed; null when none came.
  extract.search = async () => {
    const deadline = Date.now() + SEARCH_WAIT_MS;
    while (resultLinks().length === 0) {
      if (Date.now() >= deadline) return null;
      await sleep(200);
    }
    // The page fills the list in as answers arrive: read once it has stopped growing.
    let count = -1;
    for (let i = 0; i < 6 && resultLinks().length !== count; i++) { count = resultLinks().length; await sleep(300); }
    return resultLinks().slice(0, MAX_SEARCH).map(a => {
      const name = a.querySelector('[data-testid="list-item-content-title"]');
      const image = a.querySelector("img.ListItem__artwork__image");
      return { href: a.getAttribute("href"), name: name ? name.textContent : "", art: image ? image.getAttribute("src") : null };
    });
  };

  extract.profileListReady = () => document.querySelectorAll("a.ProfileList__profile-item").length > 0 && !!profileStore();

  // ---- the API the app calls ----
  const text = value => {
    if (value === null || value === undefined) return "";
    const out = JSON.stringify(value);
    return out.length > MAX_TEXT ? "" : out;
  };
  const safe = fn => { try { return fn(); } catch (e) { return false; } };

  return {
    api: 1, build, extract,
    homeReady: () => safe(extract.homeReady),
    detailsReady: () => safe(extract.detailsReady),
    searchReady: () => safe(extract.searchReady),
    profileListReady: () => safe(extract.profileListReady),
    home: async () => { try { return text(build.home(await extract.home())); } catch (e) { return ""; } },
    details: async args => { try { return text(build.details(await extract.details(), args.title)); } catch (e) { return ""; } },
    season: async args => { try { const read = await extract.season(args.seasonID); return read ? text(build.season(read)) : ""; } catch (e) { return ""; } },
    // One search: type the query into the page's own box, then read what the page lists. Nothing listed
    // by the deadline is an answer ([]); a box that can't be typed into is not.
    search: async args => {
      try {
        if (!extract.type(args.query)) return "";
        const found = await extract.search();
        return found ? text(build.search(found)) : "[]";
      } catch (e) { return ""; }
    },
    // Chooses the profile in the top bar's own list (names, not ids; a name two profiles share is refused).
    chooseProfile: args => {
      try {
        const manager = profileStore() || {};
        const id = String(args.profileID);
        if (String(manager.currentProfileId) === id) return true;
        const profiles = manager.profiles || [];
        const profile = profiles.find(p => String(p.id) === id);
        if (!profile || !profile.name || profiles.filter(p => p.name === profile.name).length !== 1) return false;
        const item = Array.from(document.querySelectorAll("a.ProfileList__profile-item"))
          .find(a => a.getAttribute("aria-label") === "Switch profile to " + profile.name);
        if (!item) return false;
        for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
          item.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
        }
        return true;
      } catch (e) { return false; }
    },
    profileIsCurrent: args => { try { return String((profileStore() || {}).currentProfileId) === String(args.profileID); } catch (e) { return false; } }
  };
})();
