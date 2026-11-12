// Owns: the debug-only JavaScript that records which media formats a
// service's player hands to the browser (codec strings and the audio/video
// parameters in each SourceBuffer's first init segment), plus the debug-only
// Netflix requested-formats experiment. Pure text; the app target decides
// when it is injected. It reads nothing else: no URLs, titles or tokens, and
// it never touches licenses, keys or the media itself beyond the init bytes.

import Foundation

public enum MediaProbeScript {
    /// Page global the probe keeps its capped record in.
    public static let globalName = "__cmProbe"

    /// JS expression that evaluates to the recorded list as a JSON string.
    public static let readExpression = "JSON.stringify(globalThis.\(globalName) ? globalThis.\(globalName).report() : null)"

    /// Document-start script: hooks MediaSource / SourceBuffer and records.
    public static let source = #"""
    (function () {
      if (globalThis.__cmProbe) return;
      var MAX_BUFFERS = 24, MAX_SIZES = 8, MAX_BYTES = 65536, MAX_TRIES = 4;
      var CONTAINERS = { moov: 1, trak: 1, mdia: 1, minf: 1, stbl: 1, edts: 1, mvex: 1, sinf: 1, schi: 1 };
      var AUDIO = { 'mp4a': 1, 'ec-3': 1, 'ac-3': 1, 'ac-4': 1, 'enca': 1, 'Opus': 1, 'fLaC': 1 };
      var VIDEO = { avc1: 1, avc3: 1, hvc1: 1, hev1: 1, dvh1: 1, dvhe: 1, av01: 1, vp09: 1, encv: 1 };
      var buffers = [], sizes = [];

      function u32(b, o) { return ((b[o] * 16777216) + (b[o + 1] << 16) + (b[o + 2] << 8) + b[o + 3]); }
      function u16(b, o) { return (b[o] << 8) | b[o + 1]; }
      function fourcc(b, o) { return String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]); }

      // Boxes in b[start, end): [{type, start, body, end}] (body = after the 8-byte header).
      function boxes(b, start, end) {
        var out = [], o = start;
        while (o + 8 <= end && out.length < 64) {
          var size = u32(b, o), type = fourcc(b, o + 4), hdr = 8;
          if (size === 1) { if (o + 16 > end) break; size = u32(b, o + 12); hdr = 16; }
          else if (size === 0) size = end - o;
          if (size < hdr || o + size > end) { size = Math.min(size, end - o); if (size < hdr) break; }
          out.push({ type: type, start: o, body: o + hdr, end: o + size });
          o += size;
        }
        return out;
      }

      // Every track sample entry under moov: [{trackStart, tkhd, entry}].
      function sampleEntries(b) {
        var found = [];
        function walk(start, end, track) {
          boxes(b, start, end).forEach(function (x) {
            if (x.type === 'trak') { var t = { tkhd: null }; walk(x.body, x.end, t); return; }
            if (x.type === 'tkhd' && track) { track.tkhd = x; return; }
            if (x.type === 'stsd') {
              var entries = boxes(b, x.body + 8, x.end);
              if (track && entries.length) found.push({ track: track, entry: entries[0] });
              return;
            }
            if (CONTAINERS[x.type]) walk(x.body, x.end, track);
          });
        }
        walk(0, b.length, null);
        return found;
      }

      function childBoxes(b, e) {
        var skip = AUDIO[e.type] ? 28 : VIDEO[e.type] ? 78 : -1;
        return skip < 0 ? [] : boxes(b, e.body + skip, e.end);
      }

      var ACMOD = [2, 1, 2, 3, 3, 4, 4, 5];

      function parseDec3(b, x) {
        var o = x.body, end = x.end;
        if (end - o < 5) return null;
        var numInd = (b[o + 1] & 7) + 1, bit = 0, p = o + 2, first = null;
        function bits(n) {
          var v = 0;
          for (var i = 0; i < n; i++) { v = (v << 1) | ((b[p + (bit >> 3)] >> (7 - (bit & 7))) & 1); bit++; }
          return v;
        }
        for (var i = 0; i < numInd; i++) {
          if (p + ((bit + 24) >> 3) > end) return null;
          bits(2); bits(5); bits(1); bits(1); bits(3);
          var acmod = bits(3), lfe = bits(1); bits(3);
          var dep = bits(4), extra = 0;
          if (dep > 0) {
            var loc = bits(9);
            extra = (loc & 1 ? 2 : 0) + (loc & 2 ? 2 : 0) + (loc & 4 ? 1 : 0) + (loc & 8 ? 1 : 0) + (loc & 16 ? 2 : 0) +
                    (loc & 32 ? 2 : 0) + (loc & 64 ? 2 : 0) + (loc & 128 ? 1 : 0) + (loc & 256 ? 1 : 0);
          } else bits(1);
          if (!first) first = { acmod: acmod, lfe: lfe, extra: extra };
        }
        var rest = p + ((bit + 7) >> 3);
        var joc = false, complexity = null;
        if (end - rest >= 2) { joc = (b[rest] & 1) === 1; if (joc) complexity = b[rest + 1]; }
        return { channels: ACMOD[first.acmod] + first.lfe + first.extra, joc: joc, jocComplexity: complexity };
      }

      function parseDac3(b, x) {
        if (x.end - x.body < 3) return null;
        // fscod2 bsid5 bsmod3 | acmod3 lfeon1 bit_rate_code5 reserved5
        var acmod = (b[x.body + 1] >> 3) & 7, lfe = (b[x.body + 1] >> 2) & 1;
        return { channels: ACMOD[acmod] + lfe };
      }

      var AAC_CH = [null, 1, 2, 3, 4, 5, 6, 8];

      function parseEsds(b, x) {
        var o = x.body + 4, end = x.end;
        function tagLen() { // returns length, advances o past the length bytes
          var n = 0;
          for (var i = 0; i < 4 && o < end; i++) { var c = b[o++]; n = (n << 7) | (c & 127); if (!(c & 128)) break; }
          return n;
        }
        if (o >= end || b[o++] !== 3) return null;
        tagLen();
        var flags = b[o + 2]; o += 3;
        if (flags & 0x80) o += 2;
        if (flags & 0x40) o += 1 + b[o];
        if (flags & 0x20) o += 2;
        if (o >= end || b[o++] !== 4) return null;
        tagLen(); o += 13;
        if (o >= end || b[o++] !== 5) return null;
        var len = tagLen();
        if (len < 2 || o + 2 > end) return null;
        var bit = 0, p = o;
        function bits(n) {
          var v = 0;
          for (var i = 0; i < n; i++) { v = (v * 2) + ((b[p + (bit >> 3)] >> (7 - (bit & 7))) & 1); bit++; }
          return v;
        }
        var aot = bits(5); if (aot === 31) aot = 32 + bits(6);
        var sf = bits(4); if (sf === 15) bits(24);
        var cc = bits(4);
        return { channels: AAC_CH[cc] || null, aot: aot };
      }

      // Parses an fMP4 init segment: [{kind, codec, channels?, joc?, width?, height?}].
      function parseInit(bytes) {
        var b = bytes, out = [];
        sampleEntries(b).forEach(function (s) {
          var e = s.entry, rec = { codec: e.type };
          if (AUDIO[e.type]) {
            rec.kind = 'audio';
            childBoxes(b, e).forEach(function (c) {
              var r = c.type === 'dec3' ? parseDec3(b, c) : c.type === 'dac3' ? parseDac3(b, c) : c.type === 'esds' ? parseEsds(b, c) : null;
              if (r) for (var k in r) rec[k] = r[k];
              if (c.type === 'dec3' && r) rec.config = 'dec3';
              if (c.type === 'dac3' && r) rec.config = 'dac3';
              if (c.type === 'esds' && r) rec.config = 'esds';
            });
            if (rec.channels === undefined) rec.channels = null;
          } else if (VIDEO[e.type]) {
            rec.kind = 'video';
            var t = s.track.tkhd;
            if (t) {
              var v = b[t.body], w = t.body + (v === 1 ? 88 : 76);
              if (w + 8 <= t.end) { rec.width = u16(b, w); rec.height = u16(b, w + 4); }
            }
            childBoxes(b, e).forEach(function (c) {
              if (c.type === 'dvcC' || c.type === 'dvvC') rec.dolbyVision = true;
              if (c.type === 'hvcC' || c.type === 'avcC' || c.type === 'av1C') rec.config = c.type;
              if (c.type === 'colr' && fourcc(b, c.body) === 'nclx') { rec.transfer = u16(b, c.body + 6); }
            });
          } else return;
          out.push(rec);
        });
        return out;
      }

      function safeText(s) {
        s = String(s);
        return /^[\w\/.,;=+\- "']{1,200}$/.test(s) ? s : '?';
      }

      function toBytes(data) {
        try {
          var u8;
          if (data instanceof ArrayBuffer) u8 = new Uint8Array(data, 0, Math.min(data.byteLength, MAX_BYTES));
          else if (data && data.buffer) u8 = new Uint8Array(data.buffer, data.byteOffset, Math.min(data.byteLength, MAX_BYTES));
          else return null;
          return u8;
        } catch (e) { return null; }
      }

      var probe = globalThis.__cmProbe = {
        parse: parseInit,
        buffers: buffers,
        report: function () { return { buffers: buffers, videoSizes: sizes }; }
      };

      // A prototype is wrapped only if it defines the method itself: an
      // inherited one (ManagedMediaSource from MediaSource) is already wrapped,
      // and a second wrapper would record twice.
      function ownFn(proto, name) {
        return proto && Object.prototype.hasOwnProperty.call(proto, name) && typeof proto[name] === 'function' ? proto[name] : null;
      }

      function hookAdd(proto) {
        var origAdd = ownFn(proto, 'addSourceBuffer');
        if (!origAdd || origAdd.__cmWrapped) return;
        var wrapped = function (mime) {
          var sb = origAdd.apply(this, arguments);
          try {
            if (buffers.length < MAX_BUFFERS && !sb.__cm) {
              var rec = { mime: safeText(mime), parsed: [] };
              buffers.push(rec);
              Object.defineProperty(sb, '__cm', { value: { rec: rec, tries: 0, done: false }, enumerable: false });
              share();
            }
          } catch (e) {}
          return sb;
        };
        wrapped.__cmWrapped = true;
        proto.addSourceBuffer = wrapped;
      }

      function hookAppend(proto) {
        var origAppend = ownFn(proto, 'appendBuffer');
        if (!origAppend || origAppend.__cmWrapped) return;
        var wrapped = function (data) {
          try {
            var st = this.__cm;
            if (st && !st.done && st.tries < MAX_TRIES) {
              st.tries++;
              var u8 = toBytes(data);
              if (u8) {
                var recs = parseInit(u8);
                if (recs.length) { st.rec.parsed = recs.slice(0, 4); st.done = true; share(); }
                else if (st.tries >= MAX_TRIES) st.done = true;
              }
            }
          } catch (e) {}
          return origAppend.apply(this, arguments);
        };
        wrapped.__cmWrapped = true;
        proto.appendBuffer = wrapped;
      }

      // Frames other than the top one hand their record to the top frame
      // (the debug route reads only the top frame). Records hold codec
      // strings and numbers only.
      var isTop = true;
      try { isTop = globalThis.top === globalThis; } catch (e) { isTop = false; }
      var frames = [];
      function share() {
        if (isTop) return;
        try { globalThis.top.postMessage({ __cmProbeFrame: { buffers: buffers, videoSizes: sizes } }, '*'); } catch (e) {}
      }
      if (isTop && globalThis.addEventListener) {
        globalThis.addEventListener('message', function (ev) {
          try {
            var d = ev.data && ev.data.__cmProbeFrame;
            if (!d || !Array.isArray(d.buffers) || !Array.isArray(d.videoSizes)) return;
            var rec = { buffers: d.buffers.slice(0, MAX_BUFFERS), videoSizes: d.videoSizes.slice(0, MAX_SIZES) };
            var i = frames.findIndex(function (f) { return f.src === ev.source; });
            if (i >= 0) frames[i].rec = rec;
            else if (frames.length < 4) frames.push({ src: ev.source, rec: rec });
          } catch (e) {}
        });
      }
      probe.report = function () {
        return { buffers: buffers, videoSizes: sizes, frames: frames.map(function (f) { return f.rec; }) };
      };

      hookAdd(globalThis.MediaSource && MediaSource.prototype);
      hookAdd(globalThis.ManagedMediaSource && ManagedMediaSource.prototype);
      hookAppend(globalThis.SourceBuffer && SourceBuffer.prototype);
      hookAppend(globalThis.ManagedSourceBuffer && ManagedSourceBuffer.prototype);

      function noteSize(ev) {
        try {
          var v = ev.target;
          if (!v || v.tagName !== 'VIDEO' || !v.videoWidth) return;
          var key = v.videoWidth + 'x' + v.videoHeight;
          if (sizes.indexOf(key) < 0 && sizes.length < MAX_SIZES) { sizes.push(key); share(); }
        } catch (e) {}
      }
      document.addEventListener('playing', noteSize, true);
      document.addEventListener('resize', noteSize, true);
      document.addEventListener('loadedmetadata', noteSize, true);
      // Sizes can settle without a later event; sample while time advances (cheap: one property read).
      document.addEventListener('timeupdate', noteSize, true);
    })();
    """#
}
