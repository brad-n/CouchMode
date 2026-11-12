// Apple TV reader package (reader API 1). Runs only inside tv.apple.com's own page. tv.apple.com is a web
// app whose views all come from its own same-origin API (/api/uts/v3/...), so every action works from one
// quiet page (the search page, which plays nothing) and makes the same request the site makes for that view,
// signed in with the page's own MusicKit session. The developer and user tokens are only used as request
// headers inside this script: they are never returned, logged or stored. Nothing here plays anything: a
// title carries the address of its own page with action=play (or just its page, when this account can't
// play it with Apple's own player), which the app hands to the service's player.
//
// Two layers, so the second can be tested against fixtures with no page:
//   extract.*  the page -> a "read": small JSON of just what the screens need (needs the page)
//   build.*    a read -> the shared vocabulary (pure: values in, values out)
// The reads have the same shapes as the built-in Swift reader's (AppleTVHome, AppleTVDetails, AppleTVSearch,
// AppleTVSite): a "card" is
//   {id, kind, name, page, episodeURL, year, rating, desc, runtime, season, episode, resume, canPlay, tile, wide}
const reader = (() => {
  const CHANNEL = "tvs.sbd.4000";
  const MAX_TEXT = 900000;
  const MAX_ROWS = 20 + 4, MAX_ITEMS = 40, MAX_SEARCH = 60, MAX_SEASONS = 50, MAX_EPISODES = 100, MAX_WINDOWS = 6;
  const IMAGE_DOMAINS = ["mzstatic.com", "example.invalid"];
  const PROFILE_ID = "main";

  // ---- careful value readers (the same rules the app applies) ----
  const str = v => { if (typeof v !== "string") return null; const t = v.trim(); return t ? t : null; };
  const int = v => (typeof v === "number" && isFinite(v) && Math.abs(v) < 1e15 && Math.floor(v) === v) ? v : null;
  const numericID = v => {
    const n = int(v);
    if (n !== null) return n > 0 ? String(n) : null;
    return (typeof v === "string" && /^[0-9]{1,20}$/.test(v)) ? v : null;
  };
  const isID = v => typeof v === "string" && /^[A-Za-z0-9.\-]{4,64}$/.test(v);
  const year = v => { const n = int(v); return n !== null && n >= 1900 && n <= 2100 ? n : null; };
  const positive = v => { const n = int(v); return n !== null && n > 0 ? n : null; };
  const resumeSeconds = (runtime, cursor) => (runtime && runtime > 0 && cursor !== null && cursor > 0 && cursor < runtime) ? cursor : null;

  // ---- addresses ----
  // An Apple TV page address: https on tv.apple.com exactly (no user, no port).
  const pageURL = v => {
    if (typeof v !== "string" || v.length >= 400) return null;
    const m = v.match(/^https:\/\/([^\/?#]*)([\/?#].*)?$/is);
    return m && m[1].toLowerCase() === "tv.apple.com" ? v : null;
  };
  // The page with action=play, which opens the service's player as a dialog over it.
  const playURL = page => {
    const m = typeof page === "string" ? page.match(/^([^?#]*)(?:\?([^#]*))?(#.*)?$/s) : null;
    if (!m) return null;
    const pairs = (m[2] || "").split("&").filter(p => p !== "" && decodeURIComponent_(p.split("=")[0]) !== "action");
    pairs.push("action=play");
    return m[1] + "?" + pairs.join("&") + (m[3] || "");
  };
  const decodeURIComponent_ = t => { try { return decodeURIComponent(t); } catch (e) { return t; } };
  // A 16:9 image from the API's template ({w}, {h}, {f}, {c} filled in): https on Apple's image host only.
  const imageURL = (template, width) => {
    if (typeof template !== "string" || !(width > 0 && width <= 4096)) return null;
    const height = Math.floor(width * 9 / 16);
    const filled = template.split("{w}").join(String(width)).split("{h}").join(String(height)).split("{f}").join("jpg").split("{c}").join("sr");
    if (filled.indexOf("{") >= 0 || filled.length >= 400) return null;
    const m = filled.match(/^https:\/\/([^\/?#]*)/i);
    if (!m) return null;
    const host = m[1].replace(/^.*@/, "").replace(/:[0-9]*$/, "").toLowerCase();
    return host && IMAGE_DOMAINS.some(d => host === d || host.endsWith("." + d)) ? filled : null;
  };
  const art = (o, width) => (o && typeof o === "object") ? imageURL(o.u, width) : null;

  // ---- pure: a read -> the shared vocabulary ----
  const build = {};

  const rowKind = type => type === "upNextLockup" ? "continueWatching" : type === "chart" ? "ranked" : "standard";

  // A title from a card; null without a plain id, a name and a page on tv.apple.com. Play starts what the
  // card says it can (the episode being continued, else the title); anything else plays by opening its page.
  const cardTitle = card => {
    if (!card || typeof card !== "object") return null;
    const name = str(card.name), page = pageURL(card.page);
    if (!isID(card.id) || !name || !page) return null;
    const playPage = pageURL(card.episodeURL) || page;
    const runtime = positive(card.runtime);
    const season = numericID(card.season), episode = numericID(card.episode);
    return {
      id: card.id, name, kind: card.kind === "movie" ? "movie" : "show",
      play: (card.canPlay === true ? playURL(playPage) : null) || page, page,
      episodeLabel: season !== null && episode !== null ? "S" + season + " · E" + episode : null,
      synopsis: str(card.desc), year: year(card.year), rating: str(card.rating), seasonsLabel: null,
      runtimeSeconds: runtime, resumeSeconds: resumeSeconds(runtime, int(card.resume)),
      tileArt: art(card.tile, 640), heroArt: art(card.wide, 1920)
    };
  };

  build.home = read => {
    if (!read || typeof read !== "object" || !Array.isArray(read.rows)) return null;
    let hero = null;
    const rows = [], seen = new Set();
    for (const shelf of read.rows) {
      if (!shelf || typeof shelf !== "object") continue;
      const titles = (Array.isArray(shelf.items) ? shelf.items : []).map(cardTitle).filter(Boolean);
      const type = typeof shelf.type === "string" ? shelf.type : "";
      if (type === "epicStage") { if (!hero) hero = titles[0] || null; continue; }
      const name = str(shelf.name);
      if (!titles.length || typeof shelf.id !== "string" || shelf.id.length < 1 || shelf.id.length > 120 || seen.has(shelf.id) || !name) continue;
      seen.add(shelf.id);
      rows.push({ id: "appletv-row-" + shelf.id, title: name, kind: rowKind(type), titles });
    }
    if (!rows.length && !hero) return null;
    return { profiles: [{ id: PROFILE_ID, name: "Apple TV" }], currentProfileID: PROFILE_ID, hero, asksWhoIsWatching: false, rows };
  };

  build.search = read => {
    const out = [], seen = new Set();
    for (const card of Array.isArray(read) ? read : []) {
      const title = out.length < MAX_SEARCH ? cardTitle(card) : null;
      if (title && !seen.has(title.id)) { seen.add(title.id); out.push(title); }
    }
    return out;
  };

  // The row's title filled in from the page (row: the title as the app sent it).
  build.details = (read, row) => {
    if (!read || typeof read !== "object" || !row || typeof row !== "object" || read.id !== row.id) return null;
    const isShow = read.kind !== "movie";
    const page = pageURL(read.page) || row.page || null;
    const playPage = pageURL(read.episodeURL) || page;
    const play = read.canPlay === true && playPage ? playURL(playPage) : null;
    const filled = {
      id: row.id, name: row.name, kind: isShow ? "show" : "movie", play: play || page || row.play, page,
      episodeLabel: null, synopsis: row.synopsis || null, year: row.year || null, rating: row.rating || null, seasonsLabel: null,
      runtimeSeconds: row.runtimeSeconds || null, resumeSeconds: row.resumeSeconds || null,
      tileArt: row.tileArt || null, heroArt: row.heroArt || null
    };
    const synopsis = str(read.desc); if (synopsis) filled.synopsis = synopsis;
    const rating = str(read.rating); if (rating) filled.rating = rating;
    const y = year(read.year); if (y) filled.year = y;
    const wide = art(read.wide, 1920); if (wide) filled.heroArt = wide;
    if (!filled.tileArt) filled.tileArt = art(read.tile, 640);
    const runtime = positive(read.runtime);
    filled.runtimeSeconds = runtime || row.runtimeSeconds || null;
    filled.resumeSeconds = resumeSeconds(filled.runtimeSeconds, int(read.resume));
    const seasons = [], seen = new Set();
    for (const entry of Array.isArray(read.seasons) ? read.seasons : []) {
      if (!entry || typeof entry !== "object" || !isID(entry.id) || seen.has(entry.id)) continue;
      seen.add(entry.id);
      seasons.push({ id: entry.id, name: str(entry.name) || "Season " + (seasons.length + 1) });
    }
    if (isShow) {
      const season = numericID(read.season), episode = numericID(read.episode);
      filled.episodeLabel = season !== null && episode !== null ? "S" + season + " · E" + episode : (row.episodeLabel || null);
      filled.seasonsLabel = seasons.length === 0 ? null : seasons.length === 1 ? "1 Season" : seasons.length + " Seasons";
    }
    const current = (seasons.find(s => s.id === read.currentSeasonId) || (seasons.length === 1 ? seasons[0] : null));
    return { title: filled, seasons: isShow ? seasons : [], currentSeasonID: isShow && current ? current.id : null };
  };

  // The episodes of one season: each with a plain id and a play address, once. An episode this account can't
  // play carries its page as the address.
  build.season = read => {
    const out = [], seen = new Set();
    for (const e of (read && typeof read === "object" && Array.isArray(read.episodes)) ? read.episodes : []) {
      if (!e || typeof e !== "object" || out.length >= MAX_EPISODES || !isID(e.id) || seen.has(e.id)) continue;
      const page = pageURL(e.url);
      if (!page) continue;
      seen.add(e.id);
      const n = numericID(e.number), number = n === null ? null : parseInt(n, 10);
      const runtime = positive(e.runtime);
      out.push({
        id: e.id, name: str(e.name) || (number !== null ? "Episode " + number : "Episode"), number, synopsis: str(e.desc),
        runtimeSeconds: runtime, resumeSeconds: resumeSeconds(runtime, int(e.resume)),
        play: (e.canPlay === true ? playURL(page) : null) || page, art: art(e.art, 640)
      });
    }
    return out;
  };

  // ---- the page: a signed-in UTS request, made the way the page makes it ----
  const extract = {};

  // Also false on a page with an action in its address (the player dialog's ?action=play): not a page to read from.
  extract.ready = () => {
    try {
      if (location.hostname !== "tv.apple.com" || /[?&]action=/.test(location.search || "")) return false;
      const kit = MusicKit.getInstance();
      const user = kit.musicUserToken || (document.cookie.match(/(?:^|; )media-user-token=([^;]+)/) || [])[1];
      return typeof kit.developerToken === "string" && kit.developerToken.length > 0 && typeof user === "string" && user.length > 0;
    } catch (e) { return false; }
  };

  // get(path, extra): throws without a session or on an error status.
  const session = () => {
    const kit = MusicKit.getInstance();
    const userToken = kit.musicUserToken || (document.cookie.match(/(?:^|; )media-user-token=([^;]+)/) || [])[1];
    if (typeof kit.developerToken !== "string" || !kit.developerToken || typeof userToken !== "string" || !userToken) throw new Error("no session");
    return async (path, extra) => {
      const query = new URLSearchParams({ caller: "web", locale: "en-US", pfm: "web", sf: "143441", v: "101",
        utscf: "OjAAAAEAAAAAAAMAEAAAACMAKwAtADgA", utsk: "6e3013c6d6fae3c2::::::228b20cf2959f76f" });
      for (const key of Object.keys(extra || {})) query.set(key, extra[key]);
      const response = await fetch("/api/uts/v3/" + path + "?" + query, {
        credentials: "include",
        headers: { authorization: "Bearer " + kit.developerToken, "media-user-token": userToken, accept: "application/json" }
      });
      if (!response.ok) throw new Error(String(response.status));
      return response.json();
    };
  };

  const landscape = (images, keys) => {
    for (const key of keys) {
      const o = images && images[key];
      if (o && typeof o.url === "string" && o.width > o.height * 1.3) return { u: o.url, w: o.width, h: o.height };
    }
    return null;
  };
  const tileKeys = ["shelfItemImage", "shelfImageBackground", "contentImage16X9", "coverArt16X9", "posterArt", "transitionImage", "contentImage"];
  const wideKeys = ["shelfImageBackground", "contentImage16X9", "transitionImage", "contentImage", "posterArt", "shelfItemImage"];
  // True when Apple's own player can play it for this account (on Apple's channel, entitled, not a hand-off to another app).
  const entitled = p => !!p && p.isEntitledToPlay === true && p.channelId === CHANNEL && !p.punchoutUrls;

  // A shelf or search item squeezed into a card; null for anything that isn't a movie, a show or an episode of one.
  const card = item => {
    let kind = null, id = null, page = null, name = null, episodeURL = null;
    if (item.type === "Movie" || item.type === "Show") { kind = item.type === "Movie" ? "movie" : "show"; id = item.id; page = item.url; name = item.title; }
    else if (item.type === "Episode" && item.showId) { kind = "show"; id = item.showId; page = item.showUrl; name = item.showTitle || item.title; episodeURL = item.url; }
    else return null;
    const p = item.playable || null, event = p && p.playEvent && p.playEvent.isDone !== true ? p.playEvent : null;
    const total = event ? event.contentMediaLengthInSeconds : null;
    return {
      id, kind, name, page, episodeURL,
      year: typeof item.releaseDate === "number" ? new Date(item.releaseDate).getUTCFullYear() : null,
      rating: (item.rating && item.rating.displayName) || null,
      desc: String(item.description || item.heroDescription || "").slice(0, 400) || null,
      runtime: total || item.duration || null,
      season: item.type === "Episode" ? item.seasonNumber || null : null, episode: item.type === "Episode" ? item.episodeNumber || null : null,
      resume: event ? event.contentPlayCursorInSeconds : null,
      canPlay: entitled(p),
      tile: landscape(item.images, tileKeys), wide: landscape(item.images, wideKeys)
    };
  };

  // Home: the channel canvas's shelves, one request.
  extract.home = async () => {
    const get = session();
    const canvas = (await get("canvases/channels/" + CHANNEL)).data.canvas;
    return { rows: (canvas.shelves || []).filter(s => Array.isArray(s.items) && s.items.length)
      .map(s => ({ id: s.id || null, name: (s.header && s.header.title) || "", type: s.displayType || "", items: s.items.slice(0, MAX_ITEMS).map(card).filter(Boolean) }))
      .filter(r => r.items.length).slice(0, MAX_ROWS) };
  };

  // Search: the request the search page makes.
  extract.search = async query => {
    if (typeof query !== "string" || !query) throw new Error("no query");
    const get = session();
    const canvas = (await get("search", { searchTerm: query, userTerm: query })).data.canvas;
    const items = (canvas.shelves || []).flatMap(s => s.items || []);
    return items.slice(0, MAX_SEARCH * 2).map(card).filter(Boolean).slice(0, MAX_SEARCH);
  };

  // A title's page data: the request a title's page makes.
  extract.details = async title => {
    if (!title || !isID(title.id) || (title.kind !== "movie" && title.kind !== "show")) throw new Error("no title");
    const get = session();
    const data = (await get((title.kind === "movie" ? "movies/" : "shows/") + title.id)).data;
    const c = data.content || {}, smart = data.smartEpisode || null;
    const playables = Object.values(data.playables || {}).filter(p => p && p.contentType !== "Extra");
    const event = playables.map(p => p.playEvent).find(e => e && e.isDone !== true && e.contentPlayCursorInSeconds > 0) || null;
    const seasons = Object.values(data.seasons || {}).filter(s => s && typeof s.id === "string")
      .sort((a, b) => (a.seasonNumber || 0) - (b.seasonNumber || 0)).slice(0, MAX_SEASONS)
      .map(s => ({ id: s.id, name: s.title || (s.seasonNumber ? "Season " + s.seasonNumber : null) }));
    return {
      id: title.id, kind: title.kind, name: c.title || null,
      desc: String(c.description || c.heroDescription || "").slice(0, 1200) || null,
      year: typeof c.releaseDate === "number" ? new Date(c.releaseDate).getUTCFullYear() : null,
      rating: (c.rating && c.rating.displayName) || null,
      runtime: c.duration || (event && event.contentMediaLengthInSeconds) || (smart && smart.duration) || null,
      resume: event ? event.contentPlayCursorInSeconds : null,
      canPlay: playables.some(entitled),
      page: c.url || null, episodeURL: smart ? smart.url || null : null,
      season: smart ? smart.seasonNumber || null : null, episode: smart ? smart.episodeNumber || null : null,
      tile: landscape(c.images, tileKeys), wide: landscape(c.images, wideKeys),
      currentSeasonId: smart ? smart.seasonId || null : null, seasons
    };
  };

  // A season's episodes: the season picker's request, then the episode shelf's next windows until the
  // season ends, at most MAX_WINDOWS requests.
  extract.season = async (seasonID, title) => {
    if (!title || !isID(title.id) || !isID(seasonID)) throw new Error("no season");
    const get = session();
    const base = "shows/" + title.id + "/episodes", season = seasonID;
    const list = [], seen = new Set();
    let extra = { selectedSeasonId: season };
    for (let n = 0; n < MAX_WINDOWS; n++) {
      const data = (await get(base, extra)).data, episodes = data.episodes || [];
      let added = 0;
      for (const e of episodes) {
        if (e.seasonId !== season || seen.has(e.id) || list.length >= MAX_EPISODES) continue;
        seen.add(e.id); added++;
        const p = ((data.episodesPlayables || {})[e.id] || [])[0] || null, event = p && p.playEvent && p.playEvent.isDone !== true ? p.playEvent : null;
        list.push({
          id: e.id, name: e.title || null, number: e.episodeNumber || null, desc: String(e.description || "").slice(0, 400) || null,
          runtime: (event && event.contentMediaLengthInSeconds) || e.duration || null, resume: event ? event.contentPlayCursorInSeconds : null,
          url: e.url || null, canPlay: entitled(p), art: landscape(e.images, tileKeys)
        });
      }
      const last = episodes[episodes.length - 1];
      if (!last || last.seasonId !== season || added === 0 || list.length >= MAX_EPISODES || last.episodeIndex >= data.totalEpisodeCount - 1) break;
      extra = { selectedEpisodeId: last.id };
    }
    list.sort((a, b) => (a.number || 0) - (b.number || 0));
    return { episodes: list };
  };

  // Apple's player is a dialog (dialog.playback-view) opened over the title's page; the address doesn't change.
  extract.playerShown = () => {
    const dialog = document.querySelector("dialog.playback-view");
    return !!dialog && dialog.open === true;
  };

  // ---- the API the app calls ----
  const text = value => {
    if (value === null || value === undefined) return "";
    const out = JSON.stringify(value);
    return out.length > MAX_TEXT ? "" : out;
  };
  const safe = f => { try { return f() === true; } catch (e) { return false; } };

  return {
    api: 1, build, extract,
    ready: () => safe(extract.ready),
    homeReady: () => safe(extract.ready), detailsReady: () => safe(extract.ready), searchReady: () => safe(extract.ready),
    home: async () => { try { return text(build.home(await extract.home())); } catch (e) { return ""; } },
    details: async args => { try { return text(build.details(await extract.details(args.title), args.title)); } catch (e) { return ""; } },
    season: async args => {
      try {
        const episodes = build.season(await extract.season(args.seasonID, args.title));
        return episodes.length ? text(episodes) : "";
      } catch (e) { return ""; }
    },
    search: async args => { try { return text(build.search(await extract.search(args.query))); } catch (e) { return ""; } },
    chooseProfile: args => !!args && args.profileID === PROFILE_ID,
    profileIsCurrent: args => !!args && args.profileID === PROFILE_ID,
    playerShown: () => safe(extract.playerShown)
  };
})();
