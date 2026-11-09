-- Dōga chrome: transport bar, seek bar, track menu, playlist, OSD, info, start screen.
-- Drawn into mpv's own OSD layer so it composites in the same present as the video.

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local OPT = {
  datadir = mp.get_opt('doga-datadir') or '',
  uidir = mp.get_opt('doga-uidir') or '',
  ui = mp.get_opt('doga-uifont') or 'Segoe UI',
  mono = mp.get_opt('doga-monofont') or 'Consolas',
  hasfile = mp.get_opt('doga-hasfile') == 'yes',
}
package.path = OPT.uidir .. '/?.lua;' .. package.path
local K = require 'kit'
local SCRIPT_T0 = mp.get_time()

---------------------------------------------------------------------------
-- Themes (tokens.json). Hex is RRGGBB; ASS wants BBGGRR.
---------------------------------------------------------------------------
local THEMES = {
  { id = 'nightshade', name = 'Nightshade', c = {
    surface0 = '0b0912', surface1 = '13101d', surface2 = '1c1729', scrim = '07050c', line = '2e2642',
    lineStrong = '4a3d6b', ink = 'ece8f6', muted = 'a69cc0', faint = '6f6689', accent = 'b57bff',
    accentStrong = '8a3dff', accentBright = 'd4b3ff', onAccent = '0b0912', signal = '3ee6ff', danger = 'ff5c7a' } },
  { id = 'glacier', name = 'Glacier', c = {
    surface0 = '05090c', surface1 = '0b141a', surface2 = '122029', scrim = '020609', line = '1e3340',
    lineStrong = '2f5163', ink = 'e3f4fa', muted = '8fb3c2', faint = '557583', accent = '3ee0ff',
    accentStrong = '0fb5d9', accentBright = 'a8f1ff', onAccent = '05090c', signal = 'c38bff', danger = 'ff6b6b' } },
  { id = 'redline', name = 'Redline', c = {
    surface0 = '0c0608', surface1 = '170c10', surface2 = '221218', scrim = '080305', line = '3a1d27',
    lineStrong = '5e2f3f', ink = 'f8e9ee', muted = 'c49aa8', faint = '7e5b66', accent = 'ff3d7f',
    accentStrong = 'e01e63', accentBright = 'ffb3cc', onAccent = '0c0608', signal = 'ffb547', danger = 'ffd23f' } },
  { id = 'carbon', name = 'Carbon', c = {
    surface0 = '000000', surface1 = '0a0a0a', surface2 = '161616', scrim = '000000', line = '2a2a2a',
    lineStrong = '444444', ink = 'ffffff', muted = 'b3b3b3', faint = '6b6b6b', accent = 'e6e6e6',
    accentStrong = 'bfbfbf', accentBright = 'ffffff', onAccent = '000000', signal = 'b57bff', danger = 'ff5c7a' } },
}
local SCRIM_A = 0x38 -- 78% opaque
local T, theme_i = {}, 1
local function set_theme(i)
  theme_i = ((i - 1) % #THEMES) + 1
  T = {}
  for k, v in pairs(THEMES[theme_i].c) do T[k] = v:sub(5, 6) .. v:sub(3, 4) .. v:sub(1, 2) end
end
set_theme(1)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local st = {
  w = 0, h = 0, s = 1, mx = -1, my = -1, inside = false, last_move = 0,
  idle = true, paused = false, pos = 0, dur = 0, cache = 0, volume = 100, mute = false, fs = false,
  title = '', path = nil, tracks = {}, chapters = {}, playlist = {},
  menu = nil, panel = false, scroll = 0, info = false,
  drag = nil, osd = nil, osd_until = 0, series = nil,
  last_click = { t = 0, id = nil },
}
local settings_path = OPT.datadir ~= '' and utils.join_path(OPT.datadir, 'settings.json') or nil
local recent_path = OPT.datadir ~= '' and utils.join_path(OPT.datadir, 'recent.json') or nil
local recent = {}
local function recent_for(path)
  for _, r0 in ipairs(recent) do if r0.path == path then return r0 end end
end

local function read_json(p)
  if not p then return nil end
  local f = io.open(p, 'rb'); if not f then return nil end
  local s = f:read('*a'); f:close()
  return utils.parse_json(s)
end
local function write_json(p, t)
  if not p then return end
  local s = utils.format_json(t); if not s then return end
  local f = io.open(p .. '.tmp', 'wb'); if not f then return end
  f:write(s); f:close(); os.remove(p); os.rename(p .. '.tmp', p)
end
local function save_settings()
  write_json(settings_path, { theme = THEMES[theme_i].id, panel = st.panel, volume = st.volume, maximized = st.maximized and true or false,
    alang = st.alang or '', slang = st.slang or '' })
end

---------------------------------------------------------------------------
-- Text helpers
---------------------------------------------------------------------------
local function r(x) return math.floor(x + 0.5) end
local function esc(s)
  s = tostring(s or '')
  return (s:gsub('\\', '\\\239\187\191'):gsub('{', '\\{'):gsub('\n', ' '))
end
local function utf8_chars(s)
  local out = {}
  for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do out[#out + 1] = ch end
  return out
end
-- rough advance width (px) — good enough for layout and ellipsis
local function text_w(s, px, mono)
  local w = 0
  for _, ch in ipairs(utf8_chars(s)) do
    -- calibrated against Chakra Petch / JetBrains Mono as rendered by libass
    if #ch >= 3 then w = w + px * (ch == '—' and 0.62 or ch == '·' and 0.3 or 1.0) -- CJK / wide
    elseif mono then w = w + px * 0.6
    elseif ch:match('[ilI%.,:;|!\' ]') then w = w + px * 0.25
    elseif ch:match('[mwMW]') then w = w + px * 0.72
    elseif ch:match('[A-Z]') then w = w + px * 0.56
    else w = w + px * 0.47 end
  end
  return w
end
local function fit(s, maxw, px, mono)
  if text_w(s, px, mono) <= maxw then return s end
  local chars, acc = utf8_chars(s), {}
  local ell = text_w('…', px, mono)
  for _, ch in ipairs(chars) do
    acc[#acc + 1] = ch
    if text_w(table.concat(acc), px, mono) + ell > maxw then acc[#acc] = nil; break end
  end
  return table.concat(acc) .. '…'
end
local function fmt_time(t)
  t = math.max(0, math.floor(t or 0))
  return string.format('%02d:%02d:%02d', math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
end
local function short_time(t)
  t = math.max(0, math.floor(t or 0))
  if t >= 3600 then return fmt_time(t) end
  return string.format('%02d:%02d', math.floor(t / 60), t % 60)
end

---------------------------------------------------------------------------
-- Drawing (ASS). \p3 → coordinates are in quarter pixels for crisp small icons.
---------------------------------------------------------------------------
local out, zones = {}, {}
local function P(v) return r(v * 4) end
local function A(a) return string.format('%02X', a or 0) end
local function poly(pts)
  local t = { 'm', P(pts[1]), P(pts[2]) }
  for i = 3, #pts, 2 do t[#t + 1] = (i == 3) and 'l' or ''; t[#t + 1] = P(pts[i]); t[#t + 1] = P(pts[i + 1]) end
  return table.concat(t, ' ') .. ' '
end
local function fill(cmds, color, alpha, extra)
  out[#out + 1] = '{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H' .. color .. '&\\1a&H' .. A(alpha) .. '&' .. (extra or '') .. '\\p3}' .. cmds .. '{\\p0}'
end
local function stroke(cmds, color, width, alpha, extra)
  out[#out + 1] = string.format('{\\an7\\pos(0,0)\\bord%.2f\\shad0\\1a&HFF&\\3c&H%s&\\3a&H%s&%s\\p3}%s{\\p0}',
    width / 2, color, A(alpha), extra or '', cmds)
end
local function rect(x, y, w, h) return poly({ x, y, x + w, y, x + w, y + h, x, y + h }) end
local function cut(x, y, w, h, c)
  return poly({ x + c, y, x + w, y, x + w, y + h - c, x + w - c, y + h, x, y + h, x, y + c })
end
local function circle(cx, cy, rad)
  local k = rad * 0.5523
  return string.format('m %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d ',
    P(cx - rad), P(cy),
    P(cx - rad), P(cy - k), P(cx - k), P(cy - rad), P(cx), P(cy - rad),
    P(cx + k), P(cy - rad), P(cx + rad), P(cy - k), P(cx + rad), P(cy),
    P(cx + rad), P(cy + k), P(cx + k), P(cy + rad), P(cx), P(cy + rad),
    P(cx - k), P(cy + rad), P(cx - rad), P(cy + k), P(cx - rad), P(cy))
end
local function diamond(cx, cy, rad) return poly({ cx, cy - rad, cx + rad, cy, cx, cy + rad, cx - rad, cy }) end

-- CSS px → ASS \fs (libass sizes by full line height)
-- (measured: Chakra Petch needs ~1.6, JetBrains Mono ~1.2 to match CSS px)
local FSK_UI, FSK_MONO = 1.6, 1.2
local function txt(x, y, s, o)
  o = o or {}
  local px = (o.size or 14) * st.s
  out[#out + 1] = string.format('{\\an%d\\pos(%d,%d)\\bord0\\shad0\\fn%s\\fs%d\\b%d\\1c&H%s&\\1a&H%s&\\q2%s}%s',
    o.an or 4, r(x), r(y), o.mono and OPT.mono or OPT.ui, r(px * (o.mono and FSK_MONO or FSK_UI)), o.weight or 400,
    o.color or T.ink, A(o.alpha), o.extra or '', o.raw and s or esc(s))
end

-- Icons on a 24 grid: 'f' filled polygon, 's' open stroke, 'c' closed stroke.
local ICONS = {
  play = { { 'f', { 7, 4.5, 19, 12, 7, 19.5 } } },
  pause = { { 'f', { 6, 4.5, 10, 4.5, 10, 19.5, 6, 19.5 } }, { 'f', { 14, 4.5, 18, 4.5, 18, 19.5, 14, 19.5 } } },
  back = { { 'f', { 11.5, 6, 4, 12, 11.5, 18 } }, { 'f', { 20, 6, 12.5, 12, 20, 18 } } },
  fwd = { { 'f', { 4, 6, 11.5, 12, 4, 18 } }, { 'f', { 12.5, 6, 20, 12, 12.5, 18 } } },
  vol = { { 'f', { 4, 9, 8, 9, 13, 5, 13, 19, 8, 15, 4, 15 } },
    { 's', { 16.5, 9, 17.7, 10.4, 18.1, 12, 17.7, 13.6, 16.5, 15 } },
    { 's', { 19, 6.5, 20.9, 9, 21.6, 12, 20.9, 15, 19, 17.5 } } },
  mute = { { 'f', { 4, 9, 8, 9, 13, 5, 13, 19, 8, 15, 4, 15 } }, { 's', { 16.5, 9.5, 20.5, 14.5 } }, { 's', { 20.5, 9.5, 16.5, 14.5 } } },
  subs = { { 'c', { 3.5, 5.5, 20.5, 5.5, 20.5, 18.5, 3.5, 18.5 } }, { 's', { 7, 15, 11, 15 } }, { 's', { 13.5, 15, 17, 15 } }, { 's', { 7, 11.5, 17, 11.5 } } },
  audio = { { 's', { 4, 10.5, 4, 13.5 } }, { 's', { 8, 7.5, 8, 16.5 } }, { 's', { 12, 4.5, 12, 19.5 } }, { 's', { 16, 8.5, 16, 15.5 } }, { 's', { 20, 11, 20, 13 } } },
  full = { { 's', { 4, 9, 4, 4, 9, 4 } }, { 's', { 15, 4, 20, 4, 20, 9 } }, { 's', { 20, 15, 20, 20, 15, 20 } }, { 's', { 9, 20, 4, 20, 4, 15 } } },
  exitfull = { { 's', { 9, 4, 9, 9, 4, 9 } }, { 's', { 20, 9, 15, 9, 15, 4 } }, { 's', { 15, 20, 15, 15, 20, 15 } }, { 's', { 4, 15, 9, 15, 9, 20 } } },
  open = { { 'c', { 3.5, 5.5, 10, 5.5, 12, 8, 20.5, 8, 20.5, 18.5, 3.5, 18.5 } } },
  info = { { 'c', { 12, 3.5, 20.5, 12, 12, 20.5, 3.5, 12 } }, { 's', { 12, 11, 12, 16 } }, { 'f', { 11.1, 7.3, 12.9, 7.3, 12.9, 9.1, 11.1, 9.1 } } },
  close = { { 's', { 6, 6, 18, 18 } }, { 's', { 18, 6, 6, 18 } } },
  chev = { { 's', { 9, 5.5, 15.5, 12, 9, 18.5 } } },
  list = { { 's', { 4, 6.5, 20, 6.5 } }, { 's', { 4, 12, 14, 12 } }, { 's', { 4, 17.5, 14, 17.5 } }, { 'f', { 17, 14.5, 21.5, 17.5, 17, 20.5 } } },
}
local function icon(name, x, y, size, color)
  local k = size / 24
  for _, part in ipairs(ICONS[name] or {}) do
    local kind, src = part[1], part[2]
    local pts = {}
    for i = 1, #src, 2 do pts[#pts + 1] = x + src[i] * k; pts[#pts + 1] = y + src[i + 1] * k end
    if kind == 'f' then
      fill(poly(pts), color)
    else
      if kind == 's' and #pts > 4 then -- retrace so the implicit close adds nothing
        for i = #src - 3, 1, -2 do pts[#pts + 1] = x + src[i] * k; pts[#pts + 1] = y + src[i + 1] * k end
      end
      stroke(poly(pts), color, 1.75 * k)
    end
  end
end

local function zone(id, x, y, w, h, data) zones[#zones + 1] = { id = id, x = x, y = y, w = w, h = h, data = data } end
local function within(x, y, w, h) return st.mx >= x and st.mx < x + w and st.my >= y and st.my < y + h end
local function hit()
  for i = #zones, 1, -1 do
    local z = zones[i]
    if st.mx >= z.x and st.mx < z.x + z.w and st.my >= z.y and st.my < z.y + z.h then return z end
  end
end

---------------------------------------------------------------------------
-- Tracks
---------------------------------------------------------------------------
local LANGS = { jpn = 'Japanese', ja = 'Japanese', jp = 'Japanese', eng = 'English', en = 'English', spa = 'Spanish', es = 'Spanish',
  fre = 'French', fra = 'French', fr = 'French', ger = 'German', deu = 'German', de = 'German', ita = 'Italian', it = 'Italian',
  por = 'Portuguese', pt = 'Portuguese', rus = 'Russian', ru = 'Russian', chi = 'Chinese', zho = 'Chinese', zh = 'Chinese',
  kor = 'Korean', ko = 'Korean', ara = 'Arabic', ar = 'Arabic', hin = 'Hindi', tha = 'Thai', vie = 'Vietnamese',
  ind = 'Indonesian', may = 'Malay', msa = 'Malay', pol = 'Polish', tur = 'Turkish', nld = 'Dutch', dut = 'Dutch',
  swe = 'Swedish', nor = 'Norwegian', dan = 'Danish', fin = 'Finnish', und = nil }
local CODECS = { flac = 'FLAC', aac = 'AAC', ac3 = 'AC-3', eac3 = 'E-AC-3', truehd = 'TrueHD', dts = 'DTS', opus = 'Opus',
  vorbis = 'Vorbis', mp3 = 'MP3', alac = 'ALAC', pcm_s16le = 'PCM', pcm_s24le = 'PCM', pcm_bluray = 'PCM',
  ass = 'ASS', ssa = 'SSA', subrip = 'SRT', webvtt = 'VTT', hdmv_pgs_subtitle = 'PGS', dvd_subtitle = 'VobSub',
  mov_text = 'Text', dvb_subtitle = 'DVB', text = 'Text' }
local CHANNELS = { [1] = '1.0', [2] = '2.0', [3] = '2.1', [6] = '5.1', [7] = '6.1', [8] = '7.1' }

local function lang_name(l) if not l or l == '' then return nil end return LANGS[l:lower()] or l:upper() end
local function track_name(t)
  local l, title = lang_name(t.lang), t.title
  if title == '' then title = nil end
  if l and title and title:lower() ~= l:lower() then return l .. ' — ' .. title end
  return l or title or ((t.type == 'sub' and 'Subtitles ' or 'Audio ') .. t.id)
end
local function track_meta(t)
  local p = {}
  local c = t.codec and (CODECS[t.codec] or t.codec:upper())
  if c then p[#p + 1] = c end
  if t.type == 'audio' then
    local ch = t['demux-channel-count']
    if ch then p[#p + 1] = CHANNELS[ch] or (ch .. 'ch') end
    if t['demux-samplerate'] then p[#p + 1] = string.format('%g kHz', t['demux-samplerate'] / 1000) end
  else
    if t.codec == 'ass' or t.codec == 'ssa' then p[#p + 1] = 'styled' elseif t.image then p[#p + 1] = 'image' end
    if t.forced then p[#p + 1] = 'forced' end
  end
  if t.external then p[#p + 1] = 'external' end
  return table.concat(p, ' · ')
end
local function tracks_of(kind)
  local res = {}
  for _, t in ipairs(st.tracks) do if t.type == kind then res[#res + 1] = t end end
  return res
end
local function selected(kind)
  for _, t in ipairs(st.tracks) do if t.type == kind and t.selected then return t end end
end
local function chip_label(kind)
  local t = selected(kind)
  if not t then return kind == 'sub' and 'Off' or '—' end
  local code = (t.lang and t.lang ~= '' and t.lang:sub(1, 3):upper()) or ((kind == 'audio' and 'A' or 'S') .. t.id)
  if kind == 'audio' then
    local ch = t['demux-channel-count']
    if ch and #tracks_of('audio') > 0 then return code .. ' ' .. (CHANNELS[ch] or ch .. 'ch') end
  end
  return code
end

---------------------------------------------------------------------------
-- OSD message
---------------------------------------------------------------------------
local render -- forward
local function osd(icon_name, lead, value, meta, opts)
  st.osd = { icon = icon_name, lead = lead, value = value, meta = meta, bar = opts and opts.bar, off = opts and opts.off }
  st.osd_until = mp.get_time() + 1.2
  render()
end

local function show_track_osd(kind, t)
  if kind == 'audio' then
    local only = #tracks_of('audio') == 1 and ' · only track' or ''
    osd('audio', 'Audio', track_name(t), track_meta(t) .. only)
  elseif t then
    osd('subs', 'Subtitles', track_name(t), track_meta(t))
  else
    osd('subs', nil, 'Subtitles off', nil, { off = true })
  end
end

local function cycle(kind, dir)
  local list = tracks_of(kind)
  local cur
  for i, t in ipairs(list) do if t.selected then cur = i end end
  if kind == 'audio' then
    if #list == 0 then osd('audio', 'Audio', 'none in this file', nil, { off = true }); return end
    local n = (((cur or 1) - 1 + dir) % #list) + 1
    mp.set_property_number('aid', list[n].id)
    show_track_osd('audio', list[n])
  else
    if #list == 0 then osd('subs', 'Subtitles', 'none in this file', nil, { off = true }); return end
    local total = #list + 1 -- the extra slot is Off
    local n = ((((cur or total) - 1 + dir) % total) + 1)
    if n == total then
      mp.set_property('sid', 'no'); show_track_osd('sub', nil)
    else
      mp.set_property_number('sid', list[n].id); show_track_osd('sub', list[n])
    end
  end
end

---------------------------------------------------------------------------
-- Playlist helpers (index token + clean title, mirrors src/series.rs)
---------------------------------------------------------------------------
local TAGS = {}
for _, t in ipairs({ '2160p', '1440p', '1080p', '1080i', '720p', '576p', '480p', '360p', '4k', 'uhd', 'hdr', 'hdr10', 'hdr10+', 'dovi',
  'x264', 'x265', 'h264', 'h265', 'h.264', 'h.265', 'hevc', 'avc', 'av1', 'vp9', 'xvid', 'aac', 'flac', 'opus', 'ac3', 'eac3',
  'ddp5.1', 'dd5.1', 'truehd', 'atmos', '10bit', '10-bit', '8bit', '8-bit', 'hi10p', 'web-dl', 'webdl', 'webrip', 'bluray',
  'blu-ray', 'bdrip', 'brrip', 'remux', 'hdtv', 'dvdrip', 'repack', 'proper' }) do TAGS[t] = true end

local function basename(p) return (p or ''):match('([^/\\]+)$') or p or '' end
local function trim_seps(s)
  local changed = true
  while changed do
    changed = false
    for _, sep in ipairs({ ' ', '-', '_', '.', '—', '–', '·', ':', '~', '|' }) do
      if s:sub(1, #sep) == sep then s = s:sub(#sep + 1); changed = true end
      if #s >= #sep and s:sub(-#sep) == sep then s = s:sub(1, -#sep - 1); changed = true end
    end
  end
  return s
end
local function clean_title(name)
  local s = basename(name):gsub('%.%w%w?%w?%w?%w?$', '')
  s = s:gsub('%b[]', ' '):gsub('%b()', ' '):gsub('%b{}', ' '):gsub('【.-】', ' ')
  s = s:gsub('_', ' '):gsub('(%d)%.(%d%d?)%f[^%w]', '%1\1%2'):gsub('%.', ' '):gsub('\1', '.')
  local words = {}
  for w in s:gmatch('%S+') do
    local lw = w:lower()
    if TAGS[lw] or (lw:find('-', 1, true) and TAGS[lw:match('^[^-]+')]) then break end
    words[#words + 1] = w
  end
  local t = trim_seps(table.concat(words, ' '))
  return t ~= '' and t or basename(name)
end
local function guess_token(title)
  local s, e = title:match('[Ss](%d+)[Ee](%d+)')
  if s then
    s, e = tonumber(s), tonumber(e)
    return s <= 1 and string.format('E%02d', e) or string.format('S%02dE%02d', s, e)
  end
  local last
  for num in title:gmatch('%f[%w]%a*(%d+%.?%d*)%f[^%w.]') do last = num end
  if last then return last end
  local letter = title:match('[%s%-](%a)$')
  return letter and letter:upper() or nil
end
local function entry_info(e)
  local path = e.filename
  local title = clean_title(path)
  local token = st.series and st.series.entries and st.series.entries[path]
  if token == nil or token == '' then token = guess_token(title) end
  return title, token
end

---------------------------------------------------------------------------
-- Layout constants (CSS px, multiplied by st.s)
---------------------------------------------------------------------------
local BAR_H, TOP_H, PANEL_W, ROW_H = 80, 48, 320, 48

local function panel_w() return st.panel and r(PANEL_W * st.s) or 0 end
local function apply_margin()
  local ratio = (st.panel and st.w > 0) and (panel_w() / st.w) or 0
  mp.set_property_number('video-margin-ratio-right', ratio)
end

local function controls_visible(now)
  if st.idle then return false end
  if st.drag or st.menu or st.cm or st.paused or st.info then return true end
  if not st.inside then return false end
  if now - st.last_move < 1.5 then return true end
  local vw = st.w - panel_w()
  return st.mx < vw and (st.my > st.h - BAR_H * st.s or st.my < TOP_H * st.s)
end

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------
local function ibtn(id, x, y, name, o)
  o = o or {}
  local s = st.s
  local size = 40 * s
  local hov = within(x, y, size, size)
  if o.primary then
    if hov then
      stroke(cut(x, y, size, size, 8 * s), T.accent, 10 * s, 0x90, '\\blur6')
    end
    fill(cut(x, y, size, size, 8 * s), (st.drag and st.drag.id == id) and T.accentStrong or T.accent)
    icon(name, x + 10 * s, y + 10 * s, 20 * s, T.onAccent)
  else
    if hov then fill(rect(x, y, size, size), 'FFFFFF', 0xEB) end
    icon(name, x + 10 * s, y + 10 * s, 20 * s, o.on and T.accent or (hov and T.ink or T.muted))
  end
  zone(id, x, y, size, size, o.data)
end

local function chip(id, right_x, cy, icon_name, label, key)
  local s = st.s
  local tw = text_w(label, 12 * s)
  local w = 8 * s + 16 * s + 4 * s + tw + 6 * s + 14 * s + 8 * s
  local x, y, h = right_x - w, cy - 14 * s, 28 * s
  local hov = within(x, y, w, h) or st.menu == id
  fill(cut(x, y, w, h, 4 * s), hov and T.line or T.surface2)
  icon(icon_name, x + 8 * s, cy - 8 * s, 16 * s, T.muted)
  txt(x + 28 * s, cy, label, { size = 12, weight = 600, color = label == 'Off' and T.muted or T.ink })
  local kx = x + 28 * s + tw + 6 * s
  stroke(rect(kx, cy - 7 * s, 14 * s, 14 * s), T.lineStrong, 1 * s)
  txt(kx + 7 * s, cy + 0.5 * s, key, { size = 10, mono = true, an = 5, color = T.muted })
  zone(id, x, y, w, h)
  return w
end

local function draw_top(vw)
  local s = st.s
  fill(rect(0, 0, vw, TOP_H * s), T.scrim, SCRIM_A)
  zone('topbar', 0, 0, vw, TOP_H * s)
  txt(16 * s, 24 * s, fit(st.title, vw - 32 * s, 18 * s), { size = 18, weight = 600 })
end

local function seek_time_at(sx, sw)
  return math.max(0, math.min(1, (st.mx - sx) / sw)) * st.dur
end

---------------------------------------------------------------------------
-- Scrub thumbnails (generated by the host's hidden decoder, shown with overlay-add)
---------------------------------------------------------------------------
local THUMB_ID = 7
local thumbs = { path = nil, map = {}, requested = nil, shown = nil }

local function thumb_step() return math.max(1, st.dur / 300) end

function thumb_geometry()
  if not st.video or st.dur <= 0 then return nil end
  local w = r(192 * st.s / 2) * 2
  local h = r(w / st.video.aspect / 2) * 2
  if h > w then h = w; w = r(h * st.video.aspect / 2) * 2 end
  return { w = w, h = h }
end

local function thumb_reset()
  thumbs.map, thumbs.requested = {}, nil
  if thumbs.shown then mp.command_native({ 'overlay-remove', THUMB_ID }); thumbs.shown = nil end
end

-- after each render: show the right thumbnail (or none), ask the host for missing ones
local function thumb_sync()
  local want = st.thumb_want
  st.thumb_want = nil
  if not want or not st.path then
    if thumbs.shown then mp.command_native({ 'overlay-remove', THUMB_ID }); thumbs.shown = nil end
    return
  end
  if thumbs.path ~= st.path then thumb_reset(); thumbs.path = st.path end
  local step = thumb_step()
  local key = math.floor(want.t / step)
  local th = thumbs.map[key]
  if not (th and th.w == want.w and th.h == want.h) then
    if thumbs.requested ~= key then
      thumbs.requested = key
      mp.commandv('script-message-to', 'main', 'doga-thumb', st.path, tostring(key), string.format('%.4f', step), tostring(want.w), tostring(want.h))
    end
    -- nearest ready neighbour keeps the preview alive while the exact one decodes
    th = nil
    for d = 1, 3 do
      for _, k in ipairs({ key - d, key + d }) do
        local c = thumbs.map[k]
        if not th and c and c.w == want.w and c.h == want.h then th = c end
      end
    end
  end
  if not th then
    if thumbs.shown then mp.command_native({ 'overlay-remove', THUMB_ID }); thumbs.shown = nil end
    return
  end
  local sig = th.addr .. '@' .. want.x .. ',' .. want.y
  if thumbs.shown ~= sig then
    mp.command_native({ 'overlay-add', THUMB_ID, want.x, want.y, '&' .. th.addr, 0, 'bgra', th.w, th.h, th.w * 4 })
    thumbs.shown = sig
  end
end

mp.register_script_message('doga-thumb-ready', function(path, key, addr, w, h)
  if path ~= st.path then return end
  thumbs.path = path
  thumbs.map[tonumber(key)] = { addr = addr, w = tonumber(w), h = tonumber(h) }
  render()
end)

local function chapter_at(t)
  local name
  for _, c in ipairs(st.chapters) do if t >= c.time then name = c.title end end
  return name
end

local function draw_bar(vw)
  local s, h = st.s, st.h
  local by = h - BAR_H * s
  fill(rect(0, by, vw, BAR_H * s), T.scrim, SCRIM_A)
  zone('bar', 0, by, vw, BAR_H * s)

  -- seek bar
  local sx, sw, sy = 16 * s, vw - 32 * s, by + 8 * s
  local dragging = st.drag and st.drag.id == 'seek'
  local active = dragging or within(sx - 8 * s, sy, sw + 16 * s, 24 * s)
  local th = (active and 8 or 4) * s
  local ty = sy + 12 * s - th / 2
  fill(rect(sx, ty, sw, th), T.line)
  if st.dur > 0 then
    local played = (dragging and st.drag.t or st.pos) / st.dur
    local buf = math.min(1, math.max(played, (st.cache or 0) / st.dur))
    fill(rect(sx, ty, sw * buf, th), T.lineStrong)
    fill(rect(sx, ty, sw * played, th), T.accent)
    for _, c in ipairs(st.chapters) do
      if c.time > 0 and c.time < st.dur then fill(rect(sx + sw * c.time / st.dur - 1 * s, ty, 2 * s, th), T.surface0) end
    end
    if active then
      fill(circle(sx + sw * played, ty + th / 2, 7 * s), T.accentBright)
      local hx = math.max(sx, math.min(sx + sw, st.mx))
      fill(rect(hx - 1 * s, ty - 2 * s, 2 * s, th + 4 * s), T.signal)
      local t = dragging and st.drag.t or seek_time_at(sx, sw)
      local label = fmt_time(t)
      local lw = text_w(label, 15 * s, true) + 16 * s
      local lx = math.max(sx, math.min(sx + sw - lw, hx - lw / 2))
      local ly = sy - 32 * s
      fill(cut(lx, ly, lw, 26 * s, 4 * s), T.scrim, 0x10)
      txt(lx + lw / 2, ly + 13 * s, label, { size = 15, mono = true, weight = 600, an = 5, color = T.accentBright })
      local top = ly
      -- scrub preview: framed thumbnail of the nearest keyframe
      local pv = thumb_geometry()
      if pv then
        local px = r(math.max(sx, math.min(sx + sw - pv.w, hx - pv.w / 2)))
        local py = r(ly - 6 * s - pv.h)
        local b = 2 * s
        fill(cut(px - b, py - b, pv.w + 2 * b, pv.h + 2 * b, 8 * s), T.accentBright)
        fill(rect(px, py, pv.w, pv.h), '000000')
        st.thumb_want = { t = t, x = px, y = py, w = pv.w, h = pv.h }
        top = py - b
      end
      local ch = chapter_at(t)
      if ch and ch ~= '' then
        local cw = math.min(320 * s, text_w(ch, 12 * s) + 16 * s)
        local cx = math.max(sx, math.min(sx + sw - cw, hx - cw / 2))
        fill(rect(cx, top - 26 * s, cw, 20 * s), T.scrim, 0x10)
        txt(cx + cw / 2, top - 16 * s, fit(ch, cw - 16 * s, 12 * s), { size = 12, weight = 500, an = 5 })
      end
    end
  end
  zone('seek', sx - 8 * s, sy, sw + 16 * s, 24 * s, { sx = sx, sw = sw })

  -- controls row
  local ry = by + 32 * s
  local cy = ry + 20 * s
  local x = 16 * s
  ibtn('play', x, ry, st.paused and 'play' or 'pause', { primary = true }); x = x + 44 * s
  ibtn('back', x, ry, 'back'); x = x + 40 * s
  ibtn('fwd', x, ry, 'fwd'); x = x + 44 * s
  ibtn('mute', x, ry, st.mute and 'mute' or 'vol'); x = x + 44 * s
  local vtw = 72 * s
  fill(rect(x, cy - 2 * s, vtw, 4 * s), T.line)
  fill(rect(x, cy - 2 * s, vtw * math.min(1, st.volume / 100), 4 * s), st.mute and T.muted or T.ink)
  if st.volume > 100 then fill(rect(x + vtw - 2 * s, cy - 5 * s, 2 * s, 10 * s), T.accent) end
  zone('vol', x - 4 * s, cy - 10 * s, vtw + 8 * s, 20 * s, { x = x, w = vtw })
  x = x + vtw + 16 * s
  local now_s = fmt_time(st.drag and st.drag.id == 'seek' and st.drag.t or st.pos)
  txt(x, cy, now_s .. '{\\1c&H' .. T.muted .. '&}\\h/\\h' .. fmt_time(st.dur), { size = 13, mono = true, weight = 500, raw = true })

  local rx = vw - 16 * s
  rx = rx - 40 * s; ibtn('full', rx, ry, st.fs and 'exitfull' or 'full')
  rx = rx - 40 * s; ibtn('playlist', rx, ry, 'list', { on = st.panel })
  rx = rx - 40 * s; ibtn('info', rx, ry, 'info', { on = st.info })
  rx = rx - 8 * s
  local w2 = chip('chip-sub', rx, cy, 'subs', chip_label('sub'), 'V')
  rx = rx - w2 - 8 * s
  chip('chip-audio', rx, cy, 'audio', chip_label('audio'), 'B')
end

local function draw_menu(vw)
  local s = st.s
  local cols = { { kind = 'audio', label = 'Audio · B', items = tracks_of('audio') },
                 { kind = 'sub', label = 'Subtitles · V', items = tracks_of('sub') } }
  table.insert(cols[2].items, 1, { off = true, id = 'no', type = 'sub', selected = not selected('sub') })
  local colw, pad, gap = 248 * s, 16 * s, 24 * s
  local rows = 0
  local function row_h(t) return (t.off or track_meta(t) == '') and 36 * s or ROW_H * s end
  local heights = {}
  for ci, c in ipairs(cols) do
    local hsum = 0
    for _, t in ipairs(c.items) do hsum = hsum + row_h(t) end
    heights[ci] = hsum
  end
  local ph = pad + 22 * s + math.max(heights[1], heights[2], 36 * s) + pad
  local pw = pad * 2 + colw * 2 + gap
  local px = math.max(8 * s, vw - 16 * s - pw)
  local py = st.h - BAR_H * s - 8 * s - ph
  fill(rect(px, py, pw, ph), '000000', 0x66, '\\blur12')
  fill(cut(px, py, pw, ph, 8 * s), T.surface1)
  stroke(cut(px, py, pw, ph, 8 * s), T.lineStrong, 1 * s)
  zone('menu', px, py, pw, ph)
  for ci, c in ipairs(cols) do
    local cx = px + pad + (ci - 1) * (colw + gap)
    txt(cx + 12 * s, py + pad + 7 * s, c.label:upper(), { size = 11, weight = 600, color = T.muted, extra = '\\fsp1.5' })
    local y = py + pad + 22 * s
    if #c.items == 0 then
      txt(cx + 12 * s, y + 18 * s, 'None in this file', { size = 14, color = T.muted })
    end
    for _, t in ipairs(c.items) do
      local rh = row_h(t)
      local sel = t.selected
      if sel or within(cx, y, colw, rh) then fill(rect(cx, y, colw, rh), T.surface2) end
      local my = y + (rh == 36 * s and rh / 2 or 18 * s)
      if sel then fill(diamond(cx + 19 * s, my, 5.5 * s), T.accent)
      else stroke(diamond(cx + 19 * s, my, 5 * s), T.lineStrong, 1.5 * s) end
      local name = t.off and 'Off' or track_name(t)
      local tagw = 0
      if not t.off and t.default then tagw = text_w('DEFAULT', 10 * s) + 16 * s end
      local nm = fit(name, colw - 48 * s - tagw, 14 * s)
      txt(cx + 36 * s, my, nm, { size = 14 })
      if tagw > 0 then
        local tx = cx + 36 * s + text_w(nm, 14 * s) + 8 * s
        stroke(rect(tx, my - 7 * s, tagw - 8 * s, 14 * s), T.lineStrong, 1 * s)
        txt(tx + (tagw - 8 * s) / 2, my, 'DEFAULT', { size = 9, weight = 600, an = 5, color = T.muted })
      end
      if not t.off and rh == ROW_H * s then
        txt(cx + 36 * s, y + 35 * s, fit(track_meta(t), colw - 48 * s, 12 * s), { size = 12, weight = 500, color = T.muted })
      end
      zone('trk', cx, y, colw, rh, { kind = c.kind, id = t.id })
      y = y + rh
    end
  end
end

local function draw_panel()
  local s = st.s
  local pw = panel_w()
  local x0 = st.w - pw
  fill(rect(x0, 0, pw, st.h), T.surface1)
  fill(rect(x0, 0, 1 * s, st.h), T.lineStrong)
  zone('panel', x0, 0, pw, st.h)
  -- head
  txt(x0 + 16 * s, 24 * s, 'PLAYLIST · P', { size = 11, weight = 600, color = T.muted, extra = '\\fsp1.5' })
  ibtn('pl-open', st.w - 84 * s, 4 * s, 'open')
  ibtn('pl-close', st.w - 44 * s, 4 * s, 'close')
  fill(rect(x0, TOP_H * s, pw, 1 * s), T.line)
  -- foot
  local foot_h = 56 * s
  local fy = st.h - foot_h
  fill(rect(x0, fy, pw, 1 * s), T.line)
  local n = #st.playlist
  local line1, line2
  if st.series and st.series.name and st.series.matched and st.series.matched > 1 then
    line1 = string.format('Auto · %d of %d videos in this folder', st.series.matched, st.series.total or st.series.matched)
    line2 = 'Series: ' .. st.series.name
  else
    line1 = n == 1 and '1 video' or (n .. ' videos')
    line2 = n > 0 and 'Drag to reorder' or 'Open a file, or drop one here'
  end
  txt(x0 + 16 * s, fy + 18 * s, fit(line1, pw - 32 * s, 12 * s), { size = 12, color = T.muted })
  txt(x0 + 16 * s, fy + 37 * s, fit(line2, pw - 32 * s, 12 * s), { size = 12, color = T.ink })
  -- rows
  local ly, lh = TOP_H * s + 4 * s, fy - TOP_H * s - 8 * s
  local rh = ROW_H * s
  local max_scroll = math.max(0, n * rh - lh)
  st.scroll = math.max(0, math.min(st.scroll, max_scroll))
  zone('pl-list', x0, ly, pw, lh)
  local clip = string.format('\\clip(%d,%d,%d,%d)', r(x0), r(ly), r(st.w), r(ly + lh))
  local drag = st.drag and st.drag.id == 'row' and st.drag.moved and st.drag
  for i, e in ipairs(st.playlist) do
    local y = ly + (i - 1) * rh - st.scroll
    if y + rh > ly and y < ly + lh then
      local title, token = entry_info(e)
      local cur = e.current or e.playing
      local hov = within(x0, math.max(y, ly), pw, rh) and not drag
      if drag and drag.from == i then
        -- leave a gap where the dragged row was
        fill(rect(x0 + 1 * s, y, pw - 1 * s, rh), T.surface0, 0, clip)
      else
        if cur or hov then fill(rect(x0 + 1 * s, y, pw - 1 * s, rh), T.surface2, 0, clip) end
        local tok = token or tostring(i)
        txt(x0 + 16 * s, y + 18 * s, fit(tok, 44 * s, 13 * s, true), { size = 13, mono = true, weight = 600, color = cur and T.accent or T.muted, extra = clip })
        txt(x0 + 64 * s, y + 18 * s, fit(title, pw - 80 * s, 14 * s), { size = 14, extra = clip })
        local meta
        if cur then meta = 'NOW · ' .. short_time(st.pos) .. (st.dur > 0 and (' / ' .. short_time(st.dur)) or '')
        else
          local rec = recent_for(e.filename)
          if rec and rec.watched then meta = 'Watched'
          elseif rec and rec.pos and rec.pos > 5 then meta = 'Stopped at ' .. short_time(rec.pos)
          else meta = ((e.filename or ''):match('%.(%w+)$') or ''):upper() end
        end
        txt(x0 + 64 * s, y + 35 * s, meta, { size = 12, mono = true, weight = 500, color = cur and T.accent or T.muted, extra = clip })
        zone('pl-row', x0, math.max(y, ly), pw, math.min(rh, ly + lh - math.max(y, ly)), { i = i })
      end
    end
  end
  if drag then
    -- accent line marks the drop slot; the lifted row follows the pointer above it
    local slot = drag.to or drag.from
    local dy = ly + (slot - 1) * rh - st.scroll
    fill(rect(x0 + 16 * s, dy - 1 * s, pw - 28 * s, 2 * s), T.accent)
    local e = st.playlist[drag.from]
    if e then
      local title, token = entry_info(e)
      local y = math.max(ly, math.min(ly + lh - rh, st.my - drag.grab))
      stroke(rect(x0 + 4 * s, y, pw - 8 * s, rh), T.accent, 8 * s, 0xA0, '\\blur6')
      fill(rect(x0 + 4 * s, y, pw - 8 * s, rh), T.surface2)
      stroke(rect(x0 + 4 * s, y, pw - 8 * s, rh), T.accent, 1 * s)
      txt(x0 + 16 * s, y + rh / 2, fit(token or tostring(drag.from), 44 * s, 13 * s, true), { size = 13, mono = true, weight = 600, color = T.accent })
      txt(x0 + 64 * s, y + rh / 2, fit(title, pw - 80 * s, 14 * s), { size = 14 })
    end
  end
end

-- Skip button: shown while the current chapter is an opening or ending (by its title).
-- Files without chapters never show it.
local SKIP_KINDS = {
  { label = 'Skip opening', pats = { '^op$', '^op[%s%d%-_:]', '^opening', '^intro', '^avant', 'opening$', 'オープニング' } },
  { label = 'Skip ending', pats = { '^ed$', '^ed[%s%d%-_:]', '^ending', '^outro', '^credits', 'ending$', 'エンディング' } },
}
local function skip_label(title)
  local t = (title or ''):lower():gsub('^%s+', '')
  for _, k in ipairs(SKIP_KINDS) do
    for _, p in ipairs(k.pats) do if t:find(p) then return k.label end end
  end
end

local function draw_skip(vw, vis)
  if st.idle or st.dur <= 0 or not st.chapter or st.chapter < 0 then return end
  local c = st.chapters[st.chapter + 1]
  local label = c and skip_label(c.title)
  if not label then return end
  local s = st.s
  local bw, bh = text_w(label, 14 * s) + 66 * s, 44 * s
  local x = vw - 24 * s - bw
  local y = vis and (st.h - BAR_H * s - 16 * s - bh) or (st.h - 32 * s - bh)
  local hov = within(x, y, bw, bh)
  if hov then
    fill(cut(x, y, bw, bh, 8 * s), T.accent)
  else
    fill(cut(x, y, bw, bh, 8 * s), T.scrim, SCRIM_A)
    stroke(cut(x, y, bw, bh, 8 * s), T.accent, 1.5 * s)
  end
  txt(x + 20 * s, y + bh / 2, label, { size = 14, weight = 600, color = hov and T.onAccent or T.ink })
  icon('chev', x + bw - 36 * s, y + bh / 2 - 9 * s, 18 * s, hov and T.onAccent or T.accent)
  zone('skip', x, y, bw, bh, { i = st.chapter })
end

local function draw_osd(now)
  if not st.osd or now > st.osd_until then return end
  local s, o = st.s, st.osd
  local x = 24 * s
  local y = (controls_visible(now) and TOP_H * s or 0) + 24 * s
  local parts = {}
  local w = 12 * s + 18 * s + 8 * s
  if o.lead then parts[#parts + 1] = { o.lead, T.ink, 600 } end
  if o.value then
    if o.lead then parts[#parts + 1] = { ' · ', T.muted, 400 } end
    parts[#parts + 1] = { o.value, T.ink, 400 }
  end
  if o.bar then parts[#parts + 1] = { '  ', T.ink, 400 } end
  if o.meta and o.meta ~= '' then parts[#parts + 1] = { ' · ' .. o.meta, T.muted, 400 } end
  for _, p in ipairs(parts) do w = w + text_w(p[1], 14 * s) end
  if o.bar then w = w + 96 * s + 8 * s + 40 * s end
  w = w + 12 * s
  fill(cut(x, y, w, 36 * s, 4 * s), T.scrim, SCRIM_A)
  icon(o.icon, x + 12 * s, y + 9 * s, 18 * s, o.off and T.muted or T.accent)
  local tx = x + 38 * s
  local rich = {}
  for _, p in ipairs(parts) do
    rich[#rich + 1] = '{\\1c&H' .. p[2] .. '&\\b' .. p[3] .. '}' .. esc(p[1]):gsub(' ', '\\h')
    tx = tx + text_w(p[1], 14 * s)
  end
  txt(x + 38 * s, y + 18 * s, table.concat(rich), { size = 14, raw = true })
  if o.bar then
    fill(rect(tx, y + 16 * s, 96 * s, 4 * s), T.line)
    fill(rect(tx, y + 16 * s, 96 * s * math.min(1, o.bar / 100), 4 * s), T.accent)
    txt(tx + 96 * s + 40 * s, y + 18 * s, string.format('%d%%', o.bar), { size = 13, mono = true, weight = 500, an = 6 })
  end
end

local function signal_state()
  local vp = mp.get_property_native('video-params') or {}
  local tp = mp.get_property_native('video-target-params') or {}
  local hdr = vp.gamma == 'pq' or vp.gamma == 'hlg'
  local out_hdr = tp.gamma == 'pq' or tp.gamma == 'hlg'
  local state = hdr and (out_hdr and 'Passthrough' or 'Tone-mapped') or 'Exact'
  local parts = {}
  if vp.w then parts[#parts + 1] = vp.w .. '×' .. vp.h end
  local codec = (mp.get_property('video-format') or ''):upper()
  local depth = (vp.pixelformat or ''):match('p(%d%d)') or (vp.pixelformat and vp.pixelformat:match('^nv12') and '8') or nil
  if codec ~= '' then parts[#parts + 1] = codec .. (depth and (' ' .. depth .. '-bit') or '') end
  if hdr then
    parts[#parts + 1] = (vp.gamma == 'pq' and 'HDR10 PQ' or 'HLG') .. (out_hdr and '' or ' → SDR')
    parts[#parts + 1] = out_hdr and (vp.primaries or ''):upper() or 'BT.2390'
  else
    if vp.colormatrix then parts[#parts + 1] = vp.colormatrix:upper() end
    if vp.colorlevels then parts[#parts + 1] = vp.colorlevels:sub(1, 1):upper() .. vp.colorlevels:sub(2) end
  end
  return state, table.concat(parts, ' · ')
end

local function draw_info(vw)
  local s = st.s
  local state, detail = signal_state()
  local x, y = 16 * s, TOP_H * s + 16 * s
  local conv = state == 'Tone-mapped'
  local w = 12 * s + 16 * s + text_w(state:upper(), 11 * s) * 1.1 + 12 * s + text_w(detail, 12 * s) + 16 * s
  fill(cut(x, y, w, 28 * s, 4 * s), T.surface1)
  stroke(cut(x, y, w, 28 * s, 4 * s), T.line, 1 * s)
  fill(diamond(x + 14 * s, y + 14 * s, 4.5 * s), conv and T.danger or T.signal)
  txt(x + 26 * s, y + 14 * s, state:upper(), { size = 11, weight = 600, color = conv and T.danger or T.ink, extra = '\\fsp0.8' })
  txt(x + 26 * s + text_w(state:upper(), 11 * s) * 1.1 + 12 * s, y + 14 * s, detail, { size = 12, weight = 500, color = T.muted })
  local a = selected('audio')
  local lines = {
    'Audio  ' .. (a and (track_name(a) .. ' · ' .. track_meta(a)) or 'none'),
    'File  ' .. basename(st.path or ''),
  }
  for i, l in ipairs(lines) do
    local ly = y + 28 * s + 10 * s + (i - 1) * 24 * s
    fill(rect(x, ly, math.min(vw - 32 * s, text_w(l, 12 * s) + 20 * s), 22 * s), T.scrim, SCRIM_A)
    txt(x + 10 * s, ly + 11 * s, fit(l, vw - 52 * s, 12 * s), { size = 12, weight = 500 })
  end
end

---------------------------------------------------------------------------
-- Startup animation. Never blocks anything: the start screen assembles itself
-- (skippable by any click or a dropped file); a launch with a file gets only a
-- neon frame trace over the already-playing video.
---------------------------------------------------------------------------
local intro = { idle_t0 = nil, frame_t0 = nil, timer = nil, until_t = 0 }

local function animate(seconds)
  intro.until_t = math.max(intro.until_t, mp.get_time() + seconds)
  if intro.timer then return end
  intro.timer = mp.add_periodic_timer(1 / 60, function()
    render()
    if mp.get_time() > intro.until_t then intro.timer:kill(); intro.timer = nil end
  end)
end

local function skip_intro()
  if intro.idle_t0 and mp.get_time() - intro.idle_t0 < K.INTRO_LEN then intro.idle_t0 = mp.get_time() - 10 end
end

local function draw_idle(vw)
  local s, h = st.s, st.h
  fill(rect(0, 0, vw, h), T.surface0)
  zone('idle', 0, 0, vw, h)
  -- launched with a file: stay a quiet frame until it arrives (no start-screen flash)
  if OPT.hasfile and mp.get_time() - SCRIPT_T0 < 2 and not st.demo_idle then return end
  if not intro.idle_t0 then intro.idle_t0 = mp.get_time(); animate(K.INTRO_LEN + 0.1) end
  local t = mp.get_time() - intro.idle_t0
  local ctx = K.new({ out = out, s = s, T = T, ui = OPT.ui, mono = OPT.mono })

  local bw = math.min(vw * 0.5, 560 * s)
  local bh = bw * 0.6
  ctx:intro_blocks(t, { x = vw - bw, y = 0, w = bw, h = bh })

  local gx = 48 * s
  local by = h - 40 * s
  ctx:intro_name(t, 'Dōga', gx, by - 54 * s, 64, 0.35)
  local a1 = 255 - K.span(t, 0.85, 1.15) * 255
  local instr = 'Drop a file anywhere, or press  O  to open one.'
  txt(gx, by - 8 * s, instr, { size = 14, color = T.muted, an = 1, alpha = a1 })
  zone('idle-open', gx, by - 30 * s, text_w(instr, 14 * s), 24 * s)

  if #recent > 0 then
    local split = vw >= 860 * s
    local rx = split and (vw / 2) or gx
    local n = math.min(5, #recent)
    local top = split and (by - n * ROW_H * s) or (by - 150 * s - n * ROW_H * s)
    while n > 0 and top < bh + 40 * s do n = n - 1; top = top + ROW_H * s end
    if n > 0 then
      local a2 = 255 - K.span(t, 0.95, 1.3) * 255
      local rise = (1 - K.out_cubic(K.span(t, 0.95, 1.3))) * 8 * s
      txt(rx + 12 * s, top - 14 * s + rise, 'RECENT', { size = 11, weight = 600, color = T.muted, extra = '\\fsp1.5', alpha = a2 })
      local rw = vw - rx - 32 * s
      for i = 1, n do
        local rr = recent[i]
        local y = top + (i - 1) * ROW_H * s + rise
        if within(rx, y, rw, ROW_H * s) then fill(rect(rx, y, rw, ROW_H * s), T.surface2) end
        ctx:icon('open', rx + 12 * s, y + 8 * s, 18 * s, T.muted, a2)
        txt(rx + 40 * s, y + 17 * s, fit(basename(rr.path), rw - 52 * s, 14 * s), { size = 14, alpha = a2 })
        local meta = rr.watched and 'Watched' or ('Stopped at ' .. short_time(rr.pos) .. (rr.dur and rr.dur > 0 and (' of ' .. short_time(rr.dur)) or ''))
        txt(rx + 40 * s, y + 35 * s, meta, { size = 12, weight = 500, color = T.muted, alpha = a2 })
        zone('recent', rx, y, rw, ROW_H * s, { path = rr.path })
      end
    end
  end
  ctx:intro_scan(t, vw, h)
end

---------------------------------------------------------------------------
-- Context menu (right click): one level of submenus, opened by hover.
---------------------------------------------------------------------------
local CM_W, CM_SUB_W, CM_ROW, CM_HEAD, CM_SEP, CM_PAD = 248, 300, 32, 26, 9, 6

local function radio(label, on, fn, meta) return { label = label, radio = true, on = on, fn = fn, meta = meta } end

-- "For every file": a preferred language for audio / subtitles, stored in settings and
-- applied through mpv's alang / slang, so new files pick it automatically.
local function pref_items(kind)
  local key, prop = kind == 'audio' and 'alang' or 'slang', kind == 'audio' and 'alang' or 'slang'
  local cur = selected(kind)
  local cur_lang = cur and cur.lang and cur.lang ~= '' and cur.lang:lower() or nil
  local pref = st[key]
  local function set(v)
    st[key] = v
    mp.set_property(prop, v or '')
    save_settings()
    osd(kind == 'audio' and 'audio' or 'subs', kind == 'audio' and 'Audio' or 'Subtitles',
      v and ('prefer ' .. lang_name(v) .. ' in every file') or 'use each file\'s default')
  end
  local it = { { sep = true }, { header = 'FOR EVERY FILE' } }
  it[#it + 1] = radio('Each file\'s default', pref == nil, function() set(nil) end)
  it[#it].keep = true
  if pref then
    it[#it + 1] = radio('Prefer ' .. lang_name(pref), true, function() end)
    it[#it].keep = true
  end
  if cur_lang and cur_lang ~= pref then
    it[#it + 1] = radio('Prefer ' .. lang_name(cur_lang), false, function() set(cur_lang) end)
    it[#it].keep = true
  end
  return it
end

local function cm_audio()
  local it = {}
  local list = tracks_of('audio')
  if #list == 0 then it[1] = { header = 'NO AUDIO TRACKS' } end
  for _, t in ipairs(list) do
    it[#it + 1] = radio(track_name(t), t.selected, function() mp.set_property_number('aid', t.id); show_track_osd('audio', t) end, track_meta(t))
  end
  for _, p in ipairs(pref_items('audio')) do it[#it + 1] = p end
  return it
end

local function cm_subs()
  local it = { radio('Off', not selected('sub'), function() mp.set_property('sid', 'no'); show_track_osd('sub', nil) end) }
  for _, t in ipairs(tracks_of('sub')) do
    it[#it + 1] = radio(track_name(t), t.selected, function() mp.set_property_number('sid', t.id); show_track_osd('sub', t) end, track_meta(t))
  end
  local d = mp.get_property_number('sub-delay') or 0
  it[#it + 1] = { sep = true }
  it[#it + 1] = { header = string.format('DELAY  %+.2fs', d) }
  it[#it + 1] = { label = 'Earlier by 50 ms', key = 'Z', keep = true, fn = function() mp.commandv('add', 'sub-delay', -0.05) end }
  it[#it + 1] = { label = 'Later by 50 ms', key = 'X', keep = true, fn = function() mp.commandv('add', 'sub-delay', 0.05) end }
  it[#it + 1] = { label = 'Reset delay', keep = true, disabled = math.abs(d) < 0.001, fn = function() mp.set_property_number('sub-delay', 0) end }
  for _, p in ipairs(pref_items('sub')) do it[#it + 1] = p end
  return it
end

local ASPECTS = { { 'Auto', 'no', -1 }, { '16:9', '16:9', 16 / 9 }, { '4:3', '4:3', 4 / 3 }, { '21:9', '2.333', 2.333 }, { '2.39:1', '2.39', 2.39 } }
local function cm_video()
  local it = {}
  local vt = tracks_of('video')
  if #vt > 1 then
    it[#it + 1] = { header = 'TRACK' }
    for _, t in ipairs(vt) do
      it[#it + 1] = radio(track_name(t), t.selected, function() mp.set_property_number('vid', t.id) end, track_meta(t))
    end
  end
  it[#it + 1] = { header = 'ASPECT RATIO' }
  local cur = mp.get_property_number('video-aspect-override') or -1
  for _, a in ipairs(ASPECTS) do
    local on = (a[3] < 0 and cur <= 0) or (a[3] > 0 and math.abs(cur - a[3]) < 0.01)
    it[#it + 1] = radio(a[1], on, function() mp.set_property('video-aspect-override', a[2]) end, a[3] < 0 and 'from the file' or nil)
    it[#it].keep = true
  end
  it[#it + 1] = { header = 'ROTATE' }
  local rot = mp.get_property_number('video-rotate') or 0
  for _, d in ipairs({ 0, 90, 180, 270 }) do
    it[#it + 1] = radio(d .. '°', rot == d, function() mp.set_property_number('video-rotate', d) end)
    it[#it].keep = true
  end
  it[#it + 1] = { sep = true }
  local di = mp.get_property('deinterlace') == 'yes'
  it[#it + 1] = { label = 'Deinterlace', check = di, keep = true, meta = 'only for interlaced sources',
    fn = function() mp.set_property('deinterlace', di and 'no' or 'yes') end }
  return it
end

local function cm_speed()
  local it = {}
  local sp = mp.get_property_number('speed') or 1
  for _, v in ipairs({ 0.5, 0.75, 1, 1.25, 1.5, 2 }) do
    it[#it + 1] = radio(string.format('%g×', v), math.abs(sp - v) < 0.001, function()
      mp.set_property_number('speed', v)
      osd('play', 'Speed', string.format('%g×', v))
    end, v == 1 and 'normal' or nil)
    it[#it].keep = true
  end
  return it
end

local function cm_theme()
  local it = {}
  for i, t in ipairs(THEMES) do
    it[#it + 1] = radio(t.name, i == theme_i, function() set_theme(i); save_settings(); osd('info', 'Theme', t.name) end)
    it[#it].keep = true
  end
  return it
end

local function cm_main()
  local nofile = st.idle
  local sp = mp.get_property_number('speed') or 1
  return {
    { label = 'Open file…', key = 'O', fn = function() mp.commandv('script-message-to', 'main', 'doga-open') end },
    { sep = true },
    { label = 'Audio', sub = cm_audio, value = not nofile and chip_label('audio') or nil, disabled = nofile },
    { label = 'Subtitles', sub = cm_subs, value = not nofile and chip_label('sub') or nil, disabled = nofile },
    { label = 'Video', sub = cm_video, disabled = nofile },
    { label = 'Speed', sub = cm_speed, value = math.abs(sp - 1) > 0.001 and string.format('%g×', sp) or nil, disabled = nofile },
    { label = 'Theme', sub = cm_theme, value = THEMES[theme_i].name },
    { sep = true },
    { label = 'Playlist', key = 'P', check = st.panel, fn = function() st.panel = not st.panel; apply_margin(); save_settings() end },
    { label = 'Info', key = 'I', check = st.info, disabled = nofile, fn = function() st.info = not st.info end },
    { label = 'Fullscreen', key = 'F', check = st.fs, fn = function() mp.commandv('cycle', 'fullscreen') end },
  }
end

local function cm_height(items)
  local h = CM_PAD * 2
  for _, it in ipairs(items) do h = h + (it.sep and CM_SEP or it.header and CM_HEAD or CM_ROW) end
  return h * st.s
end

local function cm_place(x, y, w, h)
  local m = 4 * st.s
  x = math.max(m, math.min(x, st.w - w - m))
  y = math.max(m, math.min(y, st.h - h - m))
  return x, y
end

-- draws one panel; returns the row geometry so hover can open submenus
local function cm_panel(items, x, y, w, level)
  local s = st.s
  local h = cm_height(items)
  fill(rect(x, y + 6 * s, w, h), '000000', 0x70, '\\blur14')
  fill(cut(x, y, w, h, 8 * s), T.surface1)
  stroke(cut(x, y, w, h, 8 * s), T.lineStrong, 1 * s)
  zone('cm', x, y, w, h)
  local rows = {}
  local ry = y + CM_PAD * s
  for i, it in ipairs(items) do
    local rh = (it.sep and CM_SEP or it.header and CM_HEAD or CM_ROW) * s
    if it.sep then
      fill(rect(x + 10 * s, ry + rh / 2, w - 20 * s, 1 * s), T.line)
    elseif it.header then
      txt(x + 14 * s, ry + rh / 2 + 2 * s, it.header, { size = 10, weight = 600, color = T.muted, extra = '\\fsp1.5' })
    else
      local open = level == 1 and st.cm.sub and st.cm.sub.index == i
      local hov = (within(x, ry, w, rh) or open) and not it.disabled
      if hov then fill(rect(x + 4 * s, ry, w - 8 * s, rh), T.surface2) end
      local cy = ry + rh / 2
      if (it.radio and it.on) or it.check then fill(diamond(x + 18 * s, cy, 4.5 * s), T.accent)
      elseif it.check == false then stroke(diamond(x + 18 * s, cy, 4 * s), T.lineStrong, 1.2 * s) end
      local right = x + w - 14 * s
      if it.sub then icon('chev', right - 14 * s, cy - 7 * s, 14 * s, it.disabled and T.faint or T.muted); right = right - 22 * s end
      local tail = it.key or it.value or it.meta
      if tail then
        local key = it.key ~= nil
        txt(right, cy, tail, { size = 12, weight = key and 600 or 400, an = 6, color = it.disabled and T.faint or T.muted })
        right = right - text_w(tail, 12 * s) - 12 * s
      end
      txt(x + 32 * s, cy, fit(it.label, right - x - 32 * s, 14 * s), { size = 14, color = it.disabled and T.faint or ((it.radio and it.on) and T.accentBright or T.ink) })
      zone('cm-item', x, ry, w, rh, { level = level, i = i })
      rows[i] = { y = ry, h = rh }
    end
    ry = ry + rh
  end
  return rows
end

local function draw_context_menu()
  local cm = st.cm
  local s = st.s
  local w = CM_W * s
  local h = cm_height(cm.items)
  local x, y = cm_place(cm.x, cm.y, w, h)
  -- hover on a main row decides the open submenu
  local ry = y + CM_PAD * s
  for i, it in ipairs(cm.items) do
    local rh = (it.sep and CM_SEP or it.header and CM_HEAD or CM_ROW) * s
    if not it.sep and not it.header and within(x, ry, w, rh) then
      if it.sub and not it.disabled then
        if not cm.sub or cm.sub.index ~= i then cm.sub = { index = i, build = it.sub, items = it.sub(), y = ry } end
      else
        cm.sub = nil
      end
    end
    ry = ry + rh
  end
  cm_panel(cm.items, x, y, w, 1)
  if cm.sub then
    local sw = CM_SUB_W * s
    local sh = cm_height(cm.sub.items)
    local sx = x + w - 4 * s
    if sx + sw > st.w - 4 * s then sx = x - sw + 4 * s end
    local sx2, sy = cm_place(sx, cm.sub.y - CM_PAD * s, sw, sh)
    cm_panel(cm.sub.items, sx2, sy, sw, 2)
  end
end

local function cm_activate(z)
  local cm = st.cm
  local items = z.data.level == 1 and cm.items or (cm.sub and cm.sub.items)
  local it = items and items[z.data.i]
  if not it or it.disabled or it.sep or it.header then return end
  if it.sub then
    cm.sub = { index = z.data.i, build = it.sub, items = it.sub(), y = z.y }
    return
  end
  if it.fn then it.fn() end
  if it.keep and cm.sub then
    cm.sub.items = cm.sub.build()
  else
    st.cm = nil
  end
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------
local ov = mp.create_osd_overlay('ass-events')
local was_visible = false

-- While the controls cover the bottom of the picture, lift dialogue above them.
-- Only the part of the bar that overlaps the video counts (a bottom letterbox absorbs it).
local sub_pos_set = 100
local function lift_subs(vis)
  local pos = 100
  if vis and not st.idle then
    local vid_h = st.h - (st.mt or 0) - (st.mb or 0)
    local overlap = BAR_H * st.s + 8 * st.s - (st.mb or 0)
    if vid_h > 0 and overlap > 0 then pos = math.max(50, math.floor(100 - overlap / vid_h * 100)) end
  end
  if pos ~= sub_pos_set then
    sub_pos_set = pos
    mp.set_property_number('sub-pos', pos)
  end
end

render = function()
  if st.w <= 0 or st.h <= 0 then return end
  out, zones = {}, {}
  local now = mp.get_time()
  local vw = st.w - panel_w()
  if st.idle or st.demo_idle then
    draw_idle(vw)
  else
    local vis = controls_visible(now)
    was_visible = vis
    lift_subs(vis)
    if vis then
      draw_top(vw)
      draw_bar(vw)
      if st.menu then draw_menu(vw) end
    end
    if st.info then draw_info(vw) end
    draw_skip(vw, vis)
  end
  if st.panel then draw_panel() end
  draw_osd(now)
  if st.cm then draw_context_menu() end
  if intro.frame_t0 and not st.idle then
    local t = now - intro.frame_t0
    if t < 0.7 then K.new({ out = out, s = st.s, T = T }):intro_frame(t, st.w, st.h) else intro.frame_t0 = nil end
  end
  ov.res_x, ov.res_y = st.w, st.h
  ov.data = table.concat(out, '\n')
  ov:update()
  thumb_sync()
end

local pending = false
local last_render = 0
local function request_render()
  if pending then return end
  pending = true
  local wait = math.max(0, 0.016 - (mp.get_time() - last_render))
  mp.add_timeout(wait, function()
    pending = false
    last_render = mp.get_time()
    render()
  end)
end

-- hide controls / expire OSD without needing input
mp.add_periodic_timer(0.25, function()
  local now = mp.get_time()
  local vis = controls_visible(now)
  if vis ~= was_visible or (st.osd and now > st.osd_until and now < st.osd_until + 0.3) then render() end
end)

---------------------------------------------------------------------------
-- Recent files
---------------------------------------------------------------------------
local function remember()
  local g = st.last_good
  if not g or not g.path or not g.dur or g.dur <= 0 then return end
  local entry = { path = g.path, pos = g.pos, dur = g.dur, watched = g.pos / g.dur > 0.92 }
  for i = #recent, 1, -1 do if recent[i].path == g.path then table.remove(recent, i) end end
  table.insert(recent, 1, entry)
  while #recent > 20 do table.remove(recent) end
  write_json(recent_path, recent)
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
local function seek_drag_update(final)
  local d = st.drag
  local t = math.max(0, math.min(1, (st.mx - d.sx) / d.sw)) * st.dur
  d.t = t
  local now = mp.get_time()
  if final then
    mp.commandv('seek', t, 'absolute+exact')
  elseif now - (d.last or 0) > 0.04 then
    d.last = now
    mp.commandv('seek', t, 'absolute+keyframes')
  end
end

local function vol_drag_update(d)
  local v = math.max(0, math.min(1, (st.mx - d.x) / d.w)) * 100
  mp.set_property_number('volume', r(v))
end

local function row_slot()
  local s = st.s
  local ly = TOP_H * s + 4 * s
  local slot = math.floor((st.my - ly + st.scroll) / (ROW_H * s) + 0.5) + 1
  return math.max(1, math.min(#st.playlist + 1, slot))
end

local ACTIONS = {
  play = function() mp.commandv('cycle', 'pause') end,
  back = function() mp.commandv('seek', -5) end,
  fwd = function() mp.commandv('seek', 5) end,
  mute = function() mp.commandv('cycle', 'mute') end,
  full = function() mp.commandv('cycle', 'fullscreen') end,
  info = function() st.info = not st.info end,
  playlist = function() st.panel = not st.panel; apply_margin(); save_settings() end,
  ['pl-close'] = function() st.panel = false; apply_margin(); save_settings() end,
  ['pl-open'] = function() mp.commandv('script-message-to', 'main', 'doga-open') end,
  ['idle-open'] = function() mp.commandv('script-message-to', 'main', 'doga-open') end,
  ['chip-audio'] = function() st.menu = st.menu ~= 'chip-audio' and 'chip-audio' or nil end,
  ['chip-sub'] = function() st.menu = st.menu ~= 'chip-sub' and 'chip-sub' or nil end,
  trk = function(z)
    if z.data.kind == 'audio' then
      mp.set_property_number('aid', z.data.id)
      for _, t in ipairs(tracks_of('audio')) do if t.id == z.data.id then show_track_osd('audio', t) end end
    else
      if z.data.id == 'no' then mp.set_property('sid', 'no'); show_track_osd('sub', nil)
      else
        mp.set_property_number('sid', z.data.id)
        for _, t in ipairs(tracks_of('sub')) do if t.id == z.data.id then show_track_osd('sub', t) end end
      end
    end
  end,
  recent = function(z) mp.commandv('loadfile', z.data.path, 'replace') end,
  skip = function(z)
    local nxt = st.chapters[z.data.i + 2]
    if nxt then
      mp.commandv('seek', nxt.time, 'absolute')
    elseif (mp.get_property_number('playlist-pos') or 0) + 1 < (mp.get_property_number('playlist-count') or 0) then
      mp.commandv('playlist-next')
    else
      mp.commandv('seek', math.max(0, st.dur - 0.5), 'absolute')
    end
  end,
}

local function on_left(e)
  msg.debug('left', e.event, st.mx, st.my)
  if e.event == 'down' then skip_intro() end
  if e.event == 'down' or e.event == 'press' then
    render() -- make sure zones match what's on screen
    local z = hit()
    local now = mp.get_time()
    if st.cm then
      if z and z.id == 'cm-item' then cm_activate(z)
      elseif not (z and z.id == 'cm') then st.cm = nil end -- click outside just closes it
      render()
      return
    end
    if st.menu and not (z and (z.id == 'trk' or z.id == 'menu' or z.id == 'chip-audio' or z.id == 'chip-sub')) then
      st.menu = nil; render(); return
    end
    if not z then
      if not st.idle then mp.commandv('cycle', 'pause') end
      return
    end
    if z.id == 'seek' and st.dur > 0 then
      st.drag = { id = 'seek', sx = z.data.sx, sw = z.data.sw, t = st.pos }
      seek_drag_update(false)
    elseif z.id == 'vol' then
      st.drag = { id = 'vol', x = z.data.x, w = z.data.w }
      vol_drag_update(st.drag)
    elseif z.id == 'pl-row' then
      local s = st.s
      local ly = TOP_H * s + 4 * s
      local row_y = ly + (z.data.i - 1) * ROW_H * s - st.scroll
      st.drag = { id = 'row', from = z.data.i, y0 = st.my, grab = st.my - row_y, moved = false }
      if st.last_click.id == z.data.i and now - st.last_click.t < 0.4 then
        st.drag = nil
        mp.commandv('playlist-play-index', z.data.i - 1)
      end
      st.last_click = { t = now, id = z.data.i }
    elseif ACTIONS[z.id] then
      ACTIONS[z.id](z)
    end
    if e.event == 'press' and st.drag then
      if st.drag.id == 'seek' then seek_drag_update(true) end
      st.drag = nil
    end
    render()
  elseif e.event == 'up' then
    local d = st.drag
    st.drag = nil
    if d and d.id == 'seek' then
      st.drag = d; seek_drag_update(true); st.drag = nil
    elseif d and d.id == 'row' and d.moved and d.to then
      local from, to = d.from, d.to
      if to ~= from and to ~= from + 1 then
        mp.commandv('playlist-move', from - 1, to - 1)
      end
    end
    render()
  end
end

mp.add_forced_key_binding('MBTN_LEFT', 'doga-left', on_left, { complex = true })

mp.observe_property('mouse-pos', 'native', function(_, m)
  if not m then return end
  local moved = m.x ~= st.mx or m.y ~= st.my
  st.mx, st.my, st.inside = m.x, m.y, m.hover
  if moved then st.last_move = mp.get_time() end
  local d = st.drag
  if d then
    if d.id == 'seek' then seek_drag_update(false)
    elseif d.id == 'vol' then vol_drag_update(d)
    elseif d.id == 'row' then
      if math.abs(st.my - d.y0) > 4 * st.s then d.moved = true end
      if d.moved then d.to = row_slot() end
    end
  end
  request_render()
end)

local function in_panel() return st.panel and st.mx >= st.w - panel_w() end
local function change_volume(delta)
  local v = math.max(0, math.min(150, (mp.get_property_number('volume') or 100) + delta))
  mp.set_property_number('volume', v)
  if mp.get_property_bool('mute') then mp.set_property_bool('mute', false) end
  osd('vol', 'Volume', nil, nil, { bar = r(v) })
end

mp.add_key_binding(nil, 'cycle-audio', function() cycle('audio', 1) end)
mp.add_key_binding(nil, 'cycle-audio-back', function() cycle('audio', -1) end)
mp.add_key_binding(nil, 'cycle-sub', function() cycle('sub', 1) end)
mp.add_key_binding(nil, 'cycle-sub-back', function() cycle('sub', -1) end)
mp.add_key_binding(nil, 'vol-up', function() change_volume(5) end, { repeatable = true })
mp.add_key_binding(nil, 'vol-down', function() change_volume(-5) end, { repeatable = true })
mp.add_key_binding(nil, 'wheel-up', function()
  if in_panel() then st.scroll = st.scroll - ROW_H * st.s; render() else change_volume(5) end
end, { repeatable = true })
mp.add_key_binding(nil, 'wheel-down', function()
  if in_panel() then st.scroll = st.scroll + ROW_H * st.s; render() else change_volume(-5) end
end, { repeatable = true })
mp.add_key_binding(nil, 'mute', function()
  mp.commandv('cycle', 'mute')
  local m = mp.get_property_bool('mute')
  osd(m and 'mute' or 'vol', 'Volume', m and 'muted' or nil, nil, (not m) and { bar = r(mp.get_property_number('volume') or 100) } or { off = true })
end)
mp.add_key_binding(nil, 'toggle-playlist', function()
  st.panel = not st.panel; apply_margin(); save_settings(); render()
end)
mp.register_script_message('doga-panel', function(v)
  st.panel = v == 'open'; apply_margin(); save_settings(); render()
end)
mp.add_key_binding(nil, 'toggle-info', function() st.info = not st.info; render() end)
mp.add_key_binding(nil, 'open', function() mp.commandv('script-message-to', 'main', 'doga-open') end)
mp.add_key_binding(nil, 'cycle-theme', function()
  set_theme(theme_i + 1); save_settings()
  osd('info', 'Theme', THEMES[theme_i].name)
end)
mp.add_key_binding(nil, 'sub-delay-minus', function()
  mp.commandv('add', 'sub-delay', -0.05)
  osd('subs', 'Subtitle delay', string.format('%+.2fs', mp.get_property_number('sub-delay') or 0))
end, { repeatable = true })
mp.add_key_binding(nil, 'sub-delay-plus', function()
  mp.commandv('add', 'sub-delay', 0.05)
  osd('subs', 'Subtitle delay', string.format('%+.2fs', mp.get_property_number('sub-delay') or 0))
end, { repeatable = true })
mp.add_key_binding(nil, 'dblclick', function()
  local z = hit()
  if z and z.id == 'pl-row' then return end -- handled by the click timer
  if not z and not st.idle then mp.commandv('cycle', 'fullscreen') end
end)
mp.add_key_binding(nil, 'context-menu', function()
  skip_intro()
  st.menu = nil
  st.cm = { x = st.mx, y = st.my, items = cm_main() }
  render()
end)
mp.add_key_binding(nil, 'escape', function()
  if st.cm then st.cm = nil
  elseif st.menu then st.menu = nil
  elseif st.drag then st.drag = nil
  elseif st.info then st.info = false
  elseif st.fs then mp.set_property_bool('fullscreen', false) end
  render()
end)

---------------------------------------------------------------------------
-- Properties
---------------------------------------------------------------------------
local function obs(name, kind, fn) mp.observe_property(name, kind, function(_, v) fn(v); request_render() end) end

obs('osd-dimensions', 'native', function(d)
  if not d then return end
  st.w, st.h = d.w, d.h
  st.mt, st.mb = d.mt or 0, d.mb or 0
  st.s = math.max(1, mp.get_property_number('display-hidpi-scale') or 1)
  apply_margin()
end)
obs('display-hidpi-scale', 'number', function(v) st.s = math.max(1, v or 1) end)
obs('idle-active', 'bool', function(v) st.idle = v and true or false end)
obs('pause', 'bool', function(v) st.paused = v end)
obs('time-pos', 'number', function(v)
  st.pos = v or 0
  if v and st.path then st.last_good = { path = st.path, pos = v, dur = st.dur } end
end)
obs('duration', 'number', function(v) st.dur = v or 0 end)
obs('demuxer-cache-time', 'number', function(v) st.cache = v or 0 end)
obs('volume', 'number', function(v) st.volume = v or 100 end)
obs('mute', 'bool', function(v) st.mute = v end)
obs('fullscreen', 'bool', function(v) st.fs = v end)
-- Remember maximized vs windowed for next launch (the host applies it before the window
-- exists). Fullscreen is never remembered, and changes while fullscreen don't count.
-- Debounced: closing the window briefly reports "not maximized" during teardown, so a
-- state only counts once it has held for half a second.
local max_timer
mp.observe_property('window-maximized', 'bool', function(_, v)
  if v == nil or st.fs or mp.get_property_bool('fullscreen') then return end
  local want = v and true or false
  if max_timer then max_timer:kill() end
  max_timer = mp.add_timeout(0.5, function()
    max_timer = nil
    if want ~= st.maximized and not mp.get_property_bool('fullscreen') then
      st.maximized = want
      save_settings()
    end
  end)
end)
obs('media-title', 'string', function(v) st.title = v or '' end)
obs('path', 'string', function(v) st.path = v end)
obs('track-list', 'native', function(v) st.tracks = v or {} end)
obs('chapter-list', 'native', function(v) st.chapters = v or {} end)
obs('chapter', 'number', function(v) st.chapter = v end)

-- Files dropped on the window (routed by the host so we know where they landed):
-- on the playlist → inserted at that row; subtitle files → added to the current video;
-- anywhere else → they replace what's playing (and the series fills in as usual).
local SUB_EXT = { srt = true, ass = true, ssa = true, vtt = true, sub = true, sup = true, idx = true }
mp.register_script_message('doga-drop', function(x, y, ...)
  local files = { ... }
  x, y = tonumber(x) or 0, tonumber(y) or 0
  skip_intro()
  local subs, media = {}, {}
  for _, f in ipairs(files) do
    local ext = (f:match('%.([%w]+)$') or ''):lower()
    if SUB_EXT[ext] then subs[#subs + 1] = f else media[#media + 1] = f end
  end
  if #media == 0 then
    if #subs > 0 and not st.idle then
      for i, f in ipairs(subs) do mp.commandv('sub-add', f, i == 1 and 'select' or 'auto') end
      osd('subs', 'Subtitles', 'added ' .. basename(subs[1]))
    end
    return
  end
  if st.panel and x >= st.w - panel_w() and #st.playlist > 0 then
    st.mx, st.my = x, y
    local slot = row_slot()
    for i, f in ipairs(media) do mp.commandv('loadfile', f, 'insert-at', tostring(slot - 2 + i)) end
    osd('list', 'Playlist', #media == 1 and ('added ' .. clean_title(media[1])) or (#media .. ' videos added'))
  else
    for i, f in ipairs(media) do mp.commandv('loadfile', f, i == 1 and 'replace' or 'append') end
  end
end)
obs('playlist', 'native', function(v) st.playlist = v or {} end)
mp.register_script_message('doga-series', function(j)
  st.series = j and utils.parse_json(j) or nil
  request_render()
end)
obs('video-params', 'native', function(v)
  local img = mp.get_property_bool('current-tracks/video/image')
  if v and v.dw and v.dh and v.dh > 0 and not img then st.video = { aspect = v.dw / v.dh } else st.video = nil end
end)
mp.register_event('start-file', function() thumb_reset(); thumbs.path = nil end)
-- The launch intro runs once: on the first file-loaded, or right away if the file
-- finished loading before this script did (scripts load on their own thread).
local booted = false
local function boot_intro()
  if booted then return end
  booted = true
  if mp.get_time() - SCRIPT_T0 < 3 then
    intro.frame_t0 = mp.get_time()
    st.last_move = mp.get_time() -- show the chrome once on launch
    animate(0.75)
  end
end
mp.register_event('file-loaded', boot_intro)
mp.register_script_message('doga-demo-idle', function(v)
  st.demo_idle = v == 'on'
  intro.idle_t0 = nil
  render()
end)
mp.register_event('seek', function() st.last_move = mp.get_time(); request_render() end)
mp.register_event('end-file', function() remember() end)
mp.register_event('shutdown', function() remember(); save_settings() end)
mp.add_periodic_timer(15, function() if not st.idle and not st.paused then remember() end end)

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
do
  local s = read_json(settings_path)
  if s then
    for i, t in ipairs(THEMES) do if t.id == s.theme then set_theme(i) end end
    st.panel = s.panel and true or false
    st.maximized = s.maximized and true or false
    st.alang = (s.alang and s.alang ~= '') and s.alang or nil
    st.slang = (s.slang and s.slang ~= '') and s.slang or nil
    if s.volume then mp.set_property_number('volume', s.volume) end
  end
  recent = read_json(recent_path) or {}
  if mp.get_property('path') and mp.get_property_native('duration') then boot_intro() end
end
