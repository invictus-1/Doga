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
  version = mp.get_opt('doga-version') or '',
  portable = mp.get_opt('doga-portable') == 'yes', -- running from an unzipped folder (no installer)
}
package.path = OPT.uidir .. '/?.lua;' .. package.path
local K = require 'kit'
local SCRIPT_T0 = mp.get_time()

---------------------------------------------------------------------------
-- Themes: palettes and each theme's signature (motif, thumb, trim, cover) live in kit.lua.
---------------------------------------------------------------------------
local THEMES = K.THEMES
local SCRIM_A = 0x38 -- 78% opaque
local T, TH, theme_i = {}, K.THEMES[1], 1
local function set_theme(i)
  theme_i = ((i - 1) % #THEMES) + 1
  TH = THEMES[theme_i]
  T = K.colors(theme_i)
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

local function parse_file(p)
  local f = io.open(p, 'rb'); if not f then return nil, false end
  local s = f:read('*a'); f:close()
  return (utils.parse_json(s)), true
end
local function read_json(p)
  if not p then return nil end
  local t, there = parse_file(p)
  if t then return t end
  -- Damaged, or a save was cut short: take the copy that was being written, else the one
  -- before it. (A file that was simply deleted stays deleted: that is how settings are reset.)
  local tmp, has_tmp = parse_file(p .. '.tmp')
  if not there and not has_tmp then return nil end
  return tmp or (parse_file(p .. '.bak'))
end
-- Never leaves the file half-written: the new one is written beside it and swapped in, and the
-- previous one stays as .bak.
local function write_json(p, t)
  if not p then return end
  local s = utils.format_json(t); if not s then return end
  local f = io.open(p .. '.tmp', 'wb'); if not f then return end
  local ok = f:write(s)
  f:close()
  if not ok then os.remove(p .. '.tmp'); return end
  os.remove(p .. '.bak'); os.rename(p, p .. '.bak'); os.rename(p .. '.tmp', p)
end
-- Everything the Settings page edits. Defaults are what Dōga does out of the box.
local cfg = {
  seek_step = 5,          -- seconds for ← →
  hwdec = true,           -- hardware decoding (picture is identical either way)
  sub_scale = 1.0,        -- subtitle size
  lift_subs = true,       -- move subtitles above the controls while they show
  resume = true,          -- resume where you stopped
  autoplaylist = true,    -- build the playlist from the opened file's folder
  skip_button = true,     -- "Skip opening/ending" button
  updates = true,         -- quiet daily update check
  volume_mode = 'remember', -- 'remember' | 'reset' (always 100%)
  audio_device = 'auto',
  audio_delay = 0,        -- seconds; remembered (it's the headphones', not the file's)
  display = '',           -- monitor the window was last on (applied by the host at launch)
  series_tracks = true,   -- the audio and subtitles picked in one episode follow to the rest
  ontop = false,          -- keep the window above other windows
  keys = {},              -- hotkey overrides: action id → key ('' = unassigned)
}

local function save_settings()
  write_json(settings_path, {
    theme = THEMES[theme_i].id, panel = st.panel, volume = st.volume, maximized = st.maximized and true or false,
    alang = st.alang or '', slang = st.slang or '',
    seek_step = cfg.seek_step, hwdec = cfg.hwdec, sub_scale = cfg.sub_scale, lift_subs = cfg.lift_subs,
    resume = cfg.resume, autoplaylist = cfg.autoplaylist, skip_button = cfg.skip_button, updates = cfg.updates,
    volume_mode = cfg.volume_mode, audio_device = cfg.audio_device, keys = cfg.keys,
    audio_delay = cfg.audio_delay, display = cfg.display,
    series_tracks = cfg.series_tracks, ontop = cfg.ontop,
  })
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
local A = K.A
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
-- kit's drawing context on this frame, for the pieces a theme shapes (motif, thumb, trim)
local function kctx() return K.new({ out = out, s = st.s, T = T, theme = TH, ui = OPT.ui, mono = OPT.mono }) end

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
    if ch then return code .. ' ' .. (CHANNELS[ch] or ch .. 'ch') end
  end
  return code
end

---------------------------------------------------------------------------
-- OSD message
---------------------------------------------------------------------------
local render -- forward
local open_settings -- forward (Settings page, defined further down)
local hotkey_label = function(id) return '' end -- forward: current key for an action, as shown to people
local nudge_audio, delay_text -- forward: audio delay (Settings section)
local function osd(icon_name, lead, value, meta, opts)
  st.osd = { icon = icon_name, lead = lead, value = value, meta = meta, bar = opts and opts.bar, off = opts and opts.off }
  st.osd_until = mp.get_time() + 1.2
  render()
end

-- A track picked by hand belongs to this file only. What carries it to the next episode is
-- the series memory (further down), which matches by language and title, not by number.
local function pick_track(kind, id)
  mp.set_property('file-local-options/' .. (kind == 'audio' and 'aid' or 'sid'), tostring(id))
end
local series_keep = function() return false end -- forward: remember a pick for the series

local function show_track_osd(kind, t)
  local function note(meta, kept)
    if not kept then return meta end
    return (meta ~= '' and (meta .. ' · ') or '') .. 'whole series'
  end
  if kind == 'audio' then
    if #tracks_of('audio') == 1 then
      osd('audio', 'Audio', track_name(t), note(track_meta(t), false) .. ' · only track')
    else
      osd('audio', 'Audio', track_name(t), note(track_meta(t), series_keep('audio', t)))
    end
  elseif t then
    osd('subs', 'Subtitles', track_name(t), note(track_meta(t), series_keep('sub', t)))
  else
    osd('subs', nil, 'Subtitles off', series_keep('sub', nil) and 'whole series' or nil, { off = true })
  end
end

local function cycle(kind, dir)
  local list = tracks_of(kind)
  local cur
  for i, t in ipairs(list) do if t.selected then cur = i end end
  if kind == 'audio' then
    if #list == 0 then osd('audio', 'Audio', 'none in this file', nil, { off = true }); return end
    local n = (((cur or 1) - 1 + dir) % #list) + 1
    pick_track('audio', list[n].id)
    show_track_osd('audio', list[n])
  else
    if #list == 0 then osd('subs', 'Subtitles', 'none in this file', nil, { off = true }); return end
    local total = #list + 1 -- the extra slot is Off
    local n = ((((cur or total) - 1 + dir) % total) + 1)
    if n == total then
      pick_track('sub', 'no'); show_track_osd('sub', nil)
    else
      pick_track('sub', list[n].id); show_track_osd('sub', list[n])
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
-- Tracks per series: the audio and subtitles picked in one episode follow to the rest.
-- A pick is kept as what the track is (language, title, position), never as a bare number,
-- so an episode laid out differently gets the matching track or is left to its default.
---------------------------------------------------------------------------
local series_path = OPT.datadir ~= '' and utils.join_path(OPT.datadir, 'series.json') or nil
local series_db   -- newest first: { dir, name, stem, audio = sig, sub = sig | { off = true } }
local series_done -- the file the memory was last applied to
local function series_all()
  if not series_db then
    local t = read_json(series_path)
    series_db = type(t) == 'table' and t or {}
  end
  return series_db
end
local function dir_key(path)
  return (((path or ''):gsub('/', '\\')):match('^(.*)\\[^\\]*$') or ''):lower()
end
-- "Show - 03 [1080p].mkv" → "show": what the file names of one series share
local function stem_key(path)
  local t = clean_title(path):lower():gsub('%d+', ' '):gsub('[%s%p]+', ' ')
  return (t:gsub('^ ', ''):gsub(' $', ''))
end
-- The series a file is part of: the host's detection when it covers the file, otherwise
-- other playlist entries from the same folder whose names differ only by a number.
local function series_id(path)
  if not path then return nil end
  local dir, stem = dir_key(path), stem_key(path)
  local sr = st.series
  if sr and sr.name and (sr.matched or 0) > 1 and sr.entries and sr.entries[path] ~= nil then return dir, sr.name, stem end
  if stem ~= '' then
    for _, e in ipairs(st.playlist) do
      if e.filename ~= path and dir_key(e.filename) == dir and stem_key(e.filename) == stem then return dir, nil, stem end
    end
  end
  return nil
end
local function series_choice(path)
  local dir, stem = dir_key(path), stem_key(path)
  local sr = st.series
  local name = sr and sr.entries and sr.entries[path] ~= nil and sr.name or nil
  for i, c in ipairs(series_all()) do
    if c.dir == dir and ((name and c.name == name) or (stem ~= '' and c.stem == stem)) then return c, i end
  end
end
local function track_sig(t, list)
  local n = 0
  for i, x in ipairs(list) do if x.id == t.id then n = i end end
  return { lang = (t.lang or ''):lower(), title = t.external and '' or (t.title or ''), n = n, of = #list,
    forced = t.forced and true or false, ext = t.external and true or false }
end
-- The track in `list` that is the same thing as the remembered one, or nil. The language has
-- to agree; among those, the same title wins, then the same position.
local function series_match(list, w)
  local best, best_score
  for i, t in ipairs(list) do
    local lang = (t.lang or ''):lower()
    local title = t.external and '' or (t.title or '')
    local ok = lang == (w.lang or '')
    if ok and lang == '' then ok = (title ~= '' and title == w.title) or (i == w.n and #list == w.of) end
    if ok then
      local sc = 0
      if title == (w.title or '') then sc = sc + (title ~= '' and 8 or 2) end
      if i == w.n then sc = sc + (#list == w.of and 4 or 2) end
      if (t.forced and true or false) == (w.forced and true or false) then sc = sc + 1 end
      if (t.external and true or false) == (w.ext and true or false) then sc = sc + 1 end
      if not best or sc > best_score then best, best_score = t, sc end
    end
  end
  return best
end
series_keep = function(kind, t)
  if not cfg.series_tracks then return false end
  local dir, name, stem = series_id(st.path)
  if not dir then return false end
  local list = tracks_of(kind)
  local db = series_all()
  local c, i = series_choice(st.path)
  if c then table.remove(db, i) else c = { dir = dir } end
  c.name, c.stem = name or c.name, stem
  c[kind] = t and track_sig(t, list) or { off = true }
  table.insert(db, 1, c)
  while #db > 100 do table.remove(db) end
  write_json(series_path, db)
  return true
end
local function series_apply(path, tracks)
  if not cfg.series_tracks or not path then return end
  local c = series_choice(path)
  if not c then return end
  for _, kind in ipairs({ 'audio', 'sub' }) do
    local w = c[kind]
    if type(w) == 'table' then
      local id
      if w.off then
        id = 'no'
      else
        local list = {}
        for _, t in ipairs(tracks) do if t.type == kind then list[#list + 1] = t end end
        local t = series_match(list, w)
        id = t and t.id
      end
      if id then pick_track(kind, id) end
    end
  end
  series_done = path
end
-- Before mpv chooses this file's tracks, so nothing is heard or seen switching.
mp.add_hook('on_preloaded', 50, function()
  series_done = nil
  series_apply(mp.get_property('path'), mp.get_property_native('track-list') or {})
end)

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

local function chip_w(label, key)
  local s = st.s
  local tw = text_w(label, 12 * s)
  -- the key box fits whatever key is assigned (and disappears if none is)
  local kw = (key and key ~= '') and math.max(14 * s, text_w(key, 10 * s, true) + 6 * s) or 0
  return 8 * s + 16 * s + 4 * s + tw + (kw > 0 and (6 * s + kw) or 0) + 8 * s, tw, kw
end

local function chip(id, right_x, cy, icon_name, label, key)
  local s = st.s
  local w, tw, kw = chip_w(label, key)
  local x, y, h = right_x - w, cy - 14 * s, 28 * s
  local hov = within(x, y, w, h) or st.menu == id
  fill(cut(x, y, w, h, 4 * s), hov and T.line or T.surface2)
  icon(icon_name, x + 8 * s, cy - 8 * s, 16 * s, T.muted)
  txt(x + 28 * s, cy, label, { size = 12, weight = 600, color = label == 'Off' and T.muted or T.ink })
  if kw > 0 then
    local kx = x + 28 * s + tw + 6 * s
    stroke(rect(kx, cy - 7 * s, kw, 14 * s), T.lineStrong, 1 * s)
    txt(kx + kw / 2, cy + 0.5 * s, key, { size = 10, mono = true, an = 5, color = T.muted })
  end
  zone(id, x, y, w, h)
  return w
end

local function draw_top(vw)
  local s = st.s
  fill(rect(0, 0, vw, TOP_H * s), T.scrim, SCRIM_A)
  zone('topbar', 0, 0, vw, TOP_H * s)
  -- the theme's signature closes the bar on the right
  local sig = vw >= 420 * s and 72 * s or 0
  if sig > 0 then kctx():motif(vw - 16 * s - sig, 20 * s, sig, 8 * s, T.lineStrong) end
  txt(16 * s, 24 * s, fit(st.title, vw - 32 * s - (sig > 0 and sig + 16 * s or 0), 18 * s), { size = 18, weight = 600 })
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

local function thumb_geometry()
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
  -- another file, or another preview size (the window moved to a display with another scale)
  if thumbs.path ~= st.path or thumbs.w ~= want.w or thumbs.h ~= want.h then
    thumb_reset()
    thumbs.path, thumbs.w, thumbs.h = st.path, want.w, want.h
  end
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
      kctx():thumb(sx + sw * played, ty + th / 2, 7 * s, T.accentBright)
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

  -- controls row. A narrow window sheds what it can do without, in this order: the key hints
  -- on the chips, the total time, the volume slider (the wheel still works), then the chips
  -- (B, V and the right-click menu still work).
  local ry = by + 32 * s
  local cy = ry + 20 * s
  local now_s = fmt_time(st.drag and st.drag.id == 'seek' and st.drag.t or st.pos)
  local dur_s = fmt_time(st.dur)
  local sub_l, aud_l = chip_label('sub'), chip_label('audio')
  local sub_k, aud_k = hotkey_label('sub'), hotkey_label('audio')
  local show_dur, show_vol, show_chips = true, true, true
  local function need()
    local left = (16 + 44 + 40 + 44 + 44 + (show_vol and 88 or 0)) * s
      + text_w(show_dur and (now_s .. ' / ' .. dur_s) or now_s, 13 * s, true)
    local right = (16 + 120) * s
    if show_chips then right = right + 8 * s + chip_w(sub_l, sub_k) + 8 * s + chip_w(aud_l, aud_k) end
    return left + 16 * s + right
  end
  if need() > vw then sub_k, aud_k = nil, nil end
  if need() > vw then show_dur = false end
  if need() > vw then show_vol = false end
  if need() > vw then
    show_chips = false
    -- with the chips gone there may be room for the slider again
    show_vol = true
    if need() > vw then show_vol = false end
  end
  local x = 16 * s
  ibtn('play', x, ry, st.paused and 'play' or 'pause', { primary = true }); x = x + 44 * s
  ibtn('back', x, ry, 'back'); x = x + 40 * s
  ibtn('fwd', x, ry, 'fwd'); x = x + 44 * s
  ibtn('mute', x, ry, st.mute and 'mute' or 'vol'); x = x + 44 * s
  if show_vol then
    local vtw = 72 * s
    fill(rect(x, cy - 2 * s, vtw, 4 * s), T.line)
    fill(rect(x, cy - 2 * s, vtw * math.min(1, st.volume / 100), 4 * s), st.mute and T.muted or T.ink)
    if st.volume > 100 then fill(rect(x + vtw - 2 * s, cy - 5 * s, 2 * s, 10 * s), T.accent) end
    zone('vol', x - 4 * s, cy - 10 * s, vtw + 8 * s, 20 * s, { x = x, w = vtw })
    x = x + vtw + 16 * s
  end
  txt(x, cy, now_s .. (show_dur and ('{\\1c&H' .. T.muted .. '&}\\h/\\h' .. dur_s) or ''), { size = 13, mono = true, weight = 500, raw = true })

  local rx = vw - 16 * s
  rx = rx - 40 * s; ibtn('full', rx, ry, st.fs and 'exitfull' or 'full')
  rx = rx - 40 * s; ibtn('playlist', rx, ry, 'list', { on = st.panel })
  rx = rx - 40 * s; ibtn('info', rx, ry, 'info', { on = st.info })
  if show_chips then
    rx = rx - 8 * s
    local w2 = chip('chip-sub', rx, cy, 'subs', sub_l, sub_k)
    rx = rx - w2 - 8 * s
    chip('chip-audio', rx, cy, 'audio', aud_l, aud_k)
  end
end

local function draw_menu(vw)
  local s = st.s
  local cols = { { kind = 'audio', label = 'Audio · ' .. hotkey_label('audio'), items = tracks_of('audio') },
                 { kind = 'sub', label = 'Subtitles · ' .. hotkey_label('sub'), items = tracks_of('sub') } }
  table.insert(cols[2].items, 1, { off = true, id = 'no', type = 'sub', selected = not selected('sub') })
  local colw, pad, gap = 248 * s, 16 * s, 24 * s
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
  kctx():trim(px, py, pw, ph, 8 * s)
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
  txt(x0 + 16 * s, 24 * s, 'PLAYLIST · ' .. hotkey_label('playlist'), { size = 11, weight = 600, color = T.muted, extra = '\\fsp1.5' })
  kctx():motif(st.w - 92 * s - 48 * s, 20 * s, 48 * s, 8 * s, T.lineStrong)
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
        local rec = not cur and recent_for(e.filename) or nil
        local seen = rec and rec.watched
        txt(x0 + 64 * s, y + 18 * s, fit(title, pw - (seen and 108 or 80) * s, 14 * s), { size = 14, color = seen and T.muted or T.ink, extra = clip })
        local meta, part
        if cur then
          meta = 'NOW · ' .. short_time(st.pos) .. (st.dur > 0 and (' / ' .. short_time(st.dur)) or '')
          part = st.dur > 0 and st.pos / st.dur or nil
        elseif seen then
          meta = 'Watched'
        elseif rec and rec.pos and rec.pos > 5 then
          meta = 'Stopped at ' .. short_time(rec.pos)
          part = rec.dur and rec.dur > 0 and rec.pos / rec.dur or nil
        else
          meta = ((e.filename or ''):match('%.(%w+)$') or ''):upper()
        end
        txt(x0 + 64 * s, y + 35 * s, meta, { size = 12, mono = true, weight = 500, color = cur and T.accent or T.muted, extra = clip })
        if seen then
          -- finished: a quiet tick at the row's right edge
          local k, tx, ty = 18 * s / 24, x0 + pw - 36 * s, y + 9 * s
          stroke(poly({ tx + 5 * k, ty + 12.5 * k, tx + 9.5 * k, ty + 17 * k, tx + 19 * k, ty + 7.5 * k, tx + 9.5 * k, ty + 17 * k }),
            T.muted, 1.75 * k, 0, clip)
        elseif part then
          -- started: how far it got, as a hairline under the row (accent for the one playing)
          local lx, lw = x0 + 64 * s, pw - 80 * s
          fill(rect(lx, y + rh - 2 * s, lw, 2 * s), T.line, 0, clip)
          fill(rect(lx, y + rh - 2 * s, r(lw * math.max(0, math.min(1, part))), 2 * s), cur and T.accent or T.muted, 0, clip)
        end
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
  if not cfg.skip_button or st.idle or st.dur <= 0 or not st.chapter or st.chapter < 0 then return end
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

-- "Resumed at 12:34 · Start over" for a few seconds after a file picks up where it left off.
local function draw_resumed(vw, vis, now)
  local rs = st.resumed
  if not rs or now > rs.until_t or st.idle then return end
  local s = st.s
  local lead = 'Resumed at ' .. short_time(rs.pos)
  local action = 'Start over'
  local key = hotkey_label('start-over')
  local bw = text_w(lead, 14 * s) + text_w(action, 14 * s) + (key ~= '' and text_w(key, 12 * s) + 22 * s or 0) + 50 * s
  local bh = 44 * s
  local x = 24 * s
  local y = vis and (st.h - BAR_H * s - 16 * s - bh) or (st.h - 32 * s - bh)
  local hov = within(x, y, bw, bh)
  fill(cut(x, y, bw, bh, 8 * s), hov and T.surface2 or T.scrim, hov and 0 or SCRIM_A)
  stroke(cut(x, y, bw, bh, 8 * s), hov and T.accent or T.lineStrong, 1.5 * s)
  txt(x + 18 * s, y + bh / 2, lead, { size = 14 })
  local ax = x + 18 * s + text_w(lead, 14 * s) + 18 * s
  txt(ax, y + bh / 2, action, { size = 14, weight = 600, color = T.accentBright })
  if key ~= '' then
    local kx = ax + text_w(action, 14 * s) + 10 * s
    local kw = text_w(key, 12 * s) + 12 * s
    stroke(rect(kx, y + bh / 2 - 10 * s, kw, 20 * s), T.lineStrong, 1 * s)
    txt(kx + kw / 2, y + bh / 2, key, { size = 11, weight = 600, an = 5, color = T.muted })
  end
  zone('start-over', x, y, bw, bh)
end

-- A file that couldn't be played: say which one and why, in plain words.
local function friendly_error(err)
  local e = (err or ''):lower()
  if e:find('unrecognized') or e:find('format') then return 'This isn\'t a format Dōga can read, or the file is damaged.' end
  if e:find('loading failed') or e:find('open') then return 'The file couldn\'t be opened. It may be missing, damaged or still downloading.' end
  if e:find('no audio or video') or e:find('nothing to play') then return 'The file has no video or audio that can be played.' end
  if e:find('denied') or e:find('permission') then return 'Windows didn\'t allow Dōga to read this file.' end
  return 'Playback failed (' .. (err ~= '' and err or 'unknown error') .. ').'
end

local function draw_error_card(x, y, maxw)
  local er = st.error
  if not er then return end
  local s = st.s
  local title = 'Couldn’t play “' .. er.file .. '”'
  local w = math.min(maxw, math.max(text_w(title, 15 * s), text_w(er.msg, 13 * s)) + 56 * s)
  local h = 72 * s
  fill(cut(x, y, w, h, 8 * s), T.surface1)
  stroke(cut(x, y, w, h, 8 * s), T.danger, 1.5 * s)
  fill(diamond(x + 22 * s, y + 26 * s, 5 * s), T.danger)
  txt(x + 38 * s, y + 26 * s, fit(title, w - 56 * s, 15 * s), { size = 15, weight = 600 })
  txt(x + 38 * s, y + 50 * s, fit(er.msg, w - 56 * s, 13 * s), { size = 13, color = T.muted })
  zone('error-card', x, y, w, h)
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
  local ctx = K.new({ out = out, s = s, T = T, theme = TH, ui = OPT.ui, mono = OPT.mono })

  -- Everything here is laid out on a 1280×720 design canvas scaled to the window (u = px
  -- per design px), so a small window, a maximized one and fullscreen 4K look the same.
  local u = math.min(vw / 1280, h / 720)

  local bw = 620 * u
  local bh = bw * 0.6
  ctx:intro_blocks(t, { x = vw - bw, y = 0, w = bw, h = bh })
  ctx:intro_hud(t, vw, h, u, 'DŌGA  //  動画 PLAYER', 'v' .. OPT.version .. '  ·  GPU-NEXT  ·  D3D11')

  local gx = 76 * u
  local name_y = h - 210 * u
  ctx:intro_name(t, 'Dōga', gx, name_y, 128 * u / s, 0.35)
  ctx:intro_rule(t, gx + 4 * u, name_y + 30 * u, 460 * u, u, 0.75)
  local a1 = 255 - K.span(t, 0.85, 1.15) * 255
  local isz = math.max(13, 16 * u / s)
  txt(gx + 4 * u, name_y + 74 * u, 'Plays the file exactly as it was made.', { size = isz, color = T.ink, an = 1, alpha = a1 })
  local instr = 'Drop a file anywhere, or press  ' .. hotkey_label('open') .. '  to open one.'
  txt(gx + 4 * u, name_y + 104 * u, instr, { size = isz, color = T.muted, an = 1, alpha = a1 })
  zone('idle-open', gx, name_y + 80 * u, text_w(instr, isz * s), 28 * u)
  local by = h - 64 * u

  -- the last file couldn't be played
  if st.error then draw_error_card(42 * u, 28 * u + (st.update and 100 or 46) * u, vw * 0.5) end

  -- a newer Dōga is out: one quiet chip, top-left
  if st.update then
    local label = st.update.state == 'downloading' and string.format('Downloading %s… %d%%', st.update.version, st.update.pct or 0)
      or ('Update to ' .. st.update.version)
    local uw, uh = text_w(label, 13 * s) + 52 * s, 36 * s
    local ux, uy = 42 * u, 28 * u + 46 * u -- under the top-left HUD label
    local hov = within(ux, uy, uw, uh) and st.update.state ~= 'downloading'
    local ua = 255 - K.span(t, 1.0, 1.3) * 255
    fill(cut(ux, uy, uw, uh, 6 * s), hov and T.accent or T.surface1, ua)
    stroke(cut(ux, uy, uw, uh, 6 * s), T.accent, 1.5 * s, ua)
    txt(ux + 16 * s, uy + uh / 2, label, { size = 13, weight = 600, color = hov and T.onAccent or T.ink, alpha = ua })
    ctx:icon('chev', ux + uw - 30 * s, uy + uh / 2 - 8 * s, 16 * s, hov and T.onAccent or T.accent, ua)
    zone('update', ux, uy, uw, uh)
  end

  -- Continue (one row: the file you stopped in, or the next episode of the series you
  -- finished one of) above Recent. The Continue row is never repeated under Recent.
  local cont = st.cont
  if cont or #recent > 0 then
    -- scales with the window like the rest, but never smaller than normal UI text
    local k = math.max(s, u)
    local f = k / s -- font multiplier (txt sizes are css px × s)
    local rh = ROW_H * k
    local gap = 34 * k -- between the Continue row and Recent's first row (holds the header)
    local split = vw >= 860 * s
    local rx = split and (vw / 2) or gx
    local rows = {}
    for _, rr in ipairs(recent) do
      if #rows >= (cont and 4 or 5) then break end
      if not (cont and rr.path == cont.path) then rows[#rows + 1] = rr end
    end
    local n = #rows
    local bottom = split and by or (by - 150 * k)
    local limit = bh + 40 * u + 20 * k
    local function top_of() return bottom - n * rh - (cont and (rh + (n > 0 and gap or 0)) or 0) end
    while n > 0 and top_of() < limit do n = n - 1 end
    if cont and top_of() < limit then cont = nil end
    if cont or n > 0 then
      local a2 = 255 - K.span(t, 0.95, 1.3) * 255
      local y = top_of() + (1 - K.out_cubic(K.span(t, 0.95, 1.3))) * 8 * k
      local rw = vw - rx - 32 * k
      local function head(label)
        txt(rx + 12 * k, y - 14 * k, label, { size = 11 * f, weight = 600, color = T.muted, extra = '\\fsp1.5', alpha = a2 })
      end
      local function line(icon_name, color, title, meta, path)
        if within(rx, y, rw, rh) then fill(rect(rx, y, rw, rh), T.surface2) end
        ctx:icon(icon_name, rx + 12 * k, y + 8 * k, 18 * k, color, a2)
        txt(rx + 40 * k, y + 17 * k, fit(title, rw - 52 * k, 14 * k), { size = 14 * f, alpha = a2 })
        txt(rx + 40 * k, y + 35 * k, fit(meta, rw - 52 * k, 12 * k), { size = 12 * f, weight = 500, color = T.muted, alpha = a2 })
        zone('recent', rx, y, rw, rh, { path = path })
        y = y + rh
      end
      local function stopped(e)
        return 'Stopped at ' .. short_time(e.pos) .. (e.dur and e.dur > 0 and (' of ' .. short_time(e.dur)) or '')
      end
      if cont then
        head('CONTINUE')
        local meta = (cont.pos or 0) > 5 and stopped(cont) or (cont.series and ('Next in ' .. cont.series) or 'Next episode')
        line('play', T.accent, clean_title(cont.path), meta, cont.path)
        if n > 0 then y = y + gap end
      end
      if n > 0 then
        head('RECENT')
        for i = 1, n do
          local rr = rows[i]
          line('open', T.muted, basename(rr.path), rr.watched and 'Watched' or stopped(rr), rr.path)
        end
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
    it[#it + 1] = radio(track_name(t), t.selected, function() pick_track('audio', t.id); show_track_osd('audio', t) end, track_meta(t))
  end
  local d = cfg.audio_delay or 0
  it[#it + 1] = { sep = true }
  it[#it + 1] = { header = 'DELAY  ' .. delay_text(d) }
  it[#it + 1] = { label = 'Earlier by 50 ms', key = hotkey_label('audio-minus'), keep = true, fn = function() nudge_audio(-0.05) end }
  it[#it + 1] = { label = 'Later by 50 ms', key = hotkey_label('audio-plus'), keep = true, fn = function() nudge_audio(0.05) end }
  it[#it + 1] = { label = 'Reset delay', keep = true, disabled = math.abs(d) < 0.001, fn = function() nudge_audio(0) end }
  for _, p in ipairs(pref_items('audio')) do it[#it + 1] = p end
  return it
end

local function cm_subs()
  local it = { radio('Off', not selected('sub'), function() pick_track('sub', 'no'); show_track_osd('sub', nil) end) }
  for _, t in ipairs(tracks_of('sub')) do
    it[#it + 1] = radio(track_name(t), t.selected, function() pick_track('sub', t.id); show_track_osd('sub', t) end, track_meta(t))
  end
  local d = mp.get_property_number('sub-delay') or 0
  it[#it + 1] = { sep = true }
  it[#it + 1] = { header = string.format('DELAY  %+.2fs', d) }
  it[#it + 1] = { label = 'Earlier by 50 ms', key = hotkey_label('sub-minus'), keep = true, fn = function() mp.commandv('add', 'sub-delay', -0.05) end }
  it[#it + 1] = { label = 'Later by 50 ms', key = hotkey_label('sub-plus'), keep = true, fn = function() mp.commandv('add', 'sub-delay', 0.05) end }
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
  it[#it + 1] = { label = 'Screenshot', key = hotkey_label('shot'), fn = function() mp.commandv('script-binding', 'doga/screenshot') end }
  it[#it + 1] = { label = 'Copy frame', key = hotkey_label('copy'), fn = function() mp.commandv('script-binding', 'doga/copy-frame') end }
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
    it[#it + 1] = radio(t.name, i == theme_i, function() set_theme(i); save_settings(); osd('info', 'Theme', t.name) end, t.kanji)
    it[#it].keep = true
  end
  return it
end

local function set_ontop(v)
  cfg.ontop = v and true or false
  mp.set_property_bool('ontop', cfg.ontop)
  save_settings()
  osd('info', 'Always on top', cfg.ontop and 'on' or 'off', nil, { off = not cfg.ontop })
end

local function start_update()
  if not st.update or st.update.state == 'downloading' then return end
  if OPT.portable then
    -- a portable folder is replaced by hand: show where the new zip is
    mp.commandv('script-message-to', 'main', 'doga-open-url', 'https://github.com/invictus-1/Doga/releases/latest')
    osd('info', 'Update', st.update.version, 'opening the download page')
    return
  end
  st.update.state, st.update.pct = 'downloading', 0
  mp.commandv('script-message-to', 'main', 'doga-update-install')
  osd('info', 'Update', 'downloading ' .. st.update.version)
end

local function cm_main()
  local nofile = st.idle
  local sp = mp.get_property_number('speed') or 1
  local top = {}
  if st.update then
    if st.update.state == 'downloading' then
      top = { { label = string.format('Downloading update… %d%%', st.update.pct or 0), disabled = true }, { sep = true } }
    else
      top = { { label = 'Update to ' .. st.update.version, value = 'new', fn = start_update }, { sep = true } }
    end
  end
  local items = {
    { label = 'Open file…', key = hotkey_label('open'), fn = function() mp.commandv('script-message-to', 'main', 'doga-open') end },
    { sep = true },
    { label = 'Audio', sub = cm_audio, value = not nofile and chip_label('audio') or nil, disabled = nofile },
    { label = 'Subtitles', sub = cm_subs, value = not nofile and chip_label('sub') or nil, disabled = nofile },
    { label = 'Video', sub = cm_video, disabled = nofile },
    { label = 'Speed', sub = cm_speed, value = math.abs(sp - 1) > 0.001 and string.format('%g×', sp) or nil, disabled = nofile },
    { label = 'Theme', sub = cm_theme, value = THEMES[theme_i].name },
    { sep = true },
    { label = 'Playlist', key = hotkey_label('playlist'), check = st.panel, fn = function() st.panel = not st.panel; apply_margin(); save_settings() end },
    { label = 'Info', key = hotkey_label('info'), check = st.info, disabled = nofile, fn = function() st.info = not st.info end },
    { label = 'Fullscreen', key = hotkey_label('full'), check = st.fs, fn = function() mp.commandv('cycle', 'fullscreen') end },
    { label = 'Always on top', key = hotkey_label('ontop'), check = cfg.ontop, fn = function() set_ontop(not cfg.ontop) end },
    { sep = true },
    { label = 'Settings…', key = hotkey_label('settings'), fn = function() open_settings() end },
  }
  for i = #top, 1, -1 do table.insert(items, 1, top[i]) end
  return items
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
  kctx():trim(x, y, w, h, 8 * s)
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
-- Settings: applying them, hotkeys, and the Settings page
---------------------------------------------------------------------------
local function apply_cfg()
  mp.set_property('hwdec', cfg.hwdec and 'auto-safe' or 'no')
  mp.set_property_number('sub-scale', cfg.sub_scale)
  mp.set_property('save-position-on-quit', cfg.resume and 'yes' or 'no')
  mp.set_property('resume-playback', cfg.resume and 'yes' or 'no')
  if cfg.audio_device and cfg.audio_device ~= '' then mp.set_property('audio-device', cfg.audio_device) end
  mp.set_property_number('audio-delay', cfg.audio_delay or 0)
  mp.set_property_bool('ontop', cfg.ontop and true or false)
end

delay_text = function(d)
  d = d or 0
  return string.format('%+d ms', math.floor(d * 1000 + (d >= 0 and 0.5 or -0.5)))
end
nudge_audio = function(delta)
  cfg.audio_delay = (delta == 0) and 0 or math.floor(((cfg.audio_delay or 0) + delta) * 1000 + 0.5) / 1000
  mp.set_property_number('audio-delay', cfg.audio_delay)
  save_settings()
  osd('audio', 'Audio delay', delay_text(cfg.audio_delay), cfg.audio_delay == 0 and 'in sync with the video' or (cfg.audio_delay > 0 and 'sound later' or 'sound earlier'))
end

-- Every remappable action, with its default key (from ui/input.conf) and what it runs.
local HOTKEYS = {
  { id = 'pause', label = 'Play / pause', key = 'SPACE', cmd = 'no-osd cycle pause' },
  { id = 'audio', label = 'Next audio track', key = 'b', cmd = 'script-binding doga/cycle-audio' },
  { id = 'audio-back', label = 'Previous audio track', key = 'B', cmd = 'script-binding doga/cycle-audio-back' },
  { id = 'sub', label = 'Next subtitle track', key = 'v', cmd = 'script-binding doga/cycle-sub' },
  { id = 'sub-back', label = 'Previous subtitle track', key = 'V', cmd = 'script-binding doga/cycle-sub-back' },
  { id = 'seek-back', label = 'Seek back', key = 'LEFT', cmd = 'script-binding doga/seek-back' },
  { id = 'seek-fwd', label = 'Seek forward', key = 'RIGHT', cmd = 'script-binding doga/seek-fwd' },
  { id = 'vol-up', label = 'Volume up', key = 'UP', cmd = 'script-binding doga/vol-up' },
  { id = 'vol-down', label = 'Volume down', key = 'DOWN', cmd = 'script-binding doga/vol-down' },
  { id = 'mute', label = 'Mute', key = 'm', cmd = 'script-binding doga/mute' },
  { id = 'full', label = 'Fullscreen', key = 'ENTER', cmd = 'no-osd cycle fullscreen' },
  { id = 'ontop', label = 'Always on top', key = 't', cmd = 'script-binding doga/toggle-ontop' },
  { id = 'playlist', label = 'Playlist', key = 'p', cmd = 'script-binding doga/toggle-playlist' },
  { id = 'next', label = 'Next in playlist', key = 'PGDWN', cmd = 'no-osd playlist-next' },
  { id = 'prev', label = 'Previous in playlist', key = 'PGUP', cmd = 'no-osd playlist-prev' },
  { id = 'info', label = 'Info', key = 'i', cmd = 'script-binding doga/toggle-info' },
  { id = 'open', label = 'Open file', key = 'o', cmd = 'script-binding doga/open' },
  { id = 'sub-minus', label = 'Subtitles earlier', key = 'z', cmd = 'script-binding doga/sub-delay-minus' },
  { id = 'sub-plus', label = 'Subtitles later', key = 'x', cmd = 'script-binding doga/sub-delay-plus' },
  { id = 'audio-minus', label = 'Audio earlier', key = 'Ctrl+z', cmd = 'script-binding doga/audio-delay-minus' },
  { id = 'audio-plus', label = 'Audio later', key = 'Ctrl+x', cmd = 'script-binding doga/audio-delay-plus' },
  { id = 'start-over', label = 'Back to the start', key = 'HOME', cmd = 'script-binding doga/start-over' },
  { id = 'shot', label = 'Screenshot (picture only)', key = 's', cmd = 'script-binding doga/screenshot' },
  { id = 'shot-subs', label = 'Screenshot with subtitles', key = 'S', cmd = 'script-binding doga/screenshot-subs' },
  { id = 'copy', label = 'Copy frame to clipboard', key = 'Ctrl+c', cmd = 'script-binding doga/copy-frame' },
  { id = 'frame-back', label = 'Previous frame', key = ',', cmd = 'no-osd frame-back-step' },
  { id = 'frame-fwd', label = 'Next frame', key = '.', cmd = 'no-osd frame-step' },
  { id = 'theme', label = 'Next theme', key = 'Ctrl+t', cmd = 'script-binding doga/cycle-theme' },
  { id = 'settings', label = 'Settings', key = 'Ctrl+,', cmd = 'script-binding doga/settings' },
  { id = 'quit', label = 'Quit', key = 'q', cmd = 'quit' },
}

local function key_of(h) local k = cfg.keys[h.id]; if k == nil then return h.key end; return k end
local HOTKEY_BY_ID = {}
for _, h in ipairs(HOTKEYS) do HOTKEY_BY_ID[h.id] = h end

local KEY_NAMES = { SPACE = 'Space', ENTER = 'Enter', LEFT = '←', RIGHT = '→', UP = '↑', DOWN = '↓', ESC = 'Esc', BS = 'Backspace',
  DEL = 'Delete', INS = 'Insert', PGUP = 'Page Up', PGDWN = 'Page Down', HOME = 'Home', END = 'End', TAB = 'Tab' }
local function key_label(k)
  if not k or k == '' then return '—' end
  local mods, base = k:match('^(.-%+)([^+]+)$')
  if not mods then mods, base = '', k end
  if base:match('^%u$') then mods = mods .. 'Shift+' end
  base = KEY_NAMES[base] or (#base == 1 and base:upper()) or base
  return mods .. base
end
hotkey_label = function(id)
  local h = HOTKEY_BY_ID[id]
  if not h then return '' end
  local k = key_of(h)
  return k == '' and '' or key_label(k)
end

-- Hotkey overrides are forced bindings layered over ui/input.conf.
local applied_keys = {}
local function apply_keys()
  for _, n in ipairs(applied_keys) do mp.remove_key_binding(n) end
  applied_keys = {}
  local taken = {}
  for _, h in ipairs(HOTKEYS) do local k = key_of(h); if k ~= '' then taken[k] = true end end
  for _, h in ipairs(HOTKEYS) do
    local k = cfg.keys[h.id]
    if k ~= nil and k ~= h.key then
      if not taken[h.key] then -- the old default key now does nothing
        local n = 'kb-off-' .. h.id
        mp.add_forced_key_binding(h.key, n, function() end)
        applied_keys[#applied_keys + 1] = n
      end
      if k ~= '' then
        local n = 'kb-' .. h.id
        mp.add_forced_key_binding(k, n, function() mp.command(h.cmd) end, { repeatable = true })
        applied_keys[#applied_keys + 1] = n
      end
    end
  end
end

-- Key capture: while waiting, every ordinary key (with modifiers) is caught once.
local CAPTURE = {}
do
  local base = {}
  for c in ('abcdefghijklmnopqrstuvwxyz0123456789'):gmatch('.') do base[#base + 1] = c end
  for _, c in ipairs({ ',', '.', '/', ';', "'", '[', ']', '-', '=', '`' }) do base[#base + 1] = c end
  for i = 1, 12 do base[#base + 1] = 'F' .. i end
  for _, c in ipairs({ 'SPACE', 'ENTER', 'TAB', 'BS', 'DEL', 'INS', 'HOME', 'END', 'PGUP', 'PGDWN', 'LEFT', 'RIGHT', 'UP', 'DOWN', 'ESC' }) do base[#base + 1] = c end
  for _, b in ipairs(base) do
    CAPTURE[#CAPTURE + 1] = b
    for _, m in ipairs({ 'Ctrl+', 'Alt+', 'Ctrl+Shift+' }) do CAPTURE[#CAPTURE + 1] = m .. b end
    if b:match('^%l$') then CAPTURE[#CAPTURE + 1] = b:upper() -- Shift+letter
    elseif #b > 1 and b ~= 'ESC' then CAPTURE[#CAPTURE + 1] = 'Shift+' .. b end
  end
end
local capture_names = {}
local function stop_capture()
  for _, n in ipairs(capture_names) do mp.remove_key_binding(n) end
  capture_names = {}
  st.capture = nil
end
local function captured(k)
  local id = st.capture
  stop_capture()
  if k == 'ESC' or not id then render(); return end
  local moved
  for _, h in ipairs(HOTKEYS) do
    if h.id ~= id and key_of(h) == k then cfg.keys[h.id] = ''; moved = h.label end
  end
  for _, h in ipairs(HOTKEYS) do
    if h.id == id then cfg.keys[id] = (k == h.key) and nil or k end
  end
  apply_keys()
  save_settings()
  osd('info', 'Hotkey', key_label(k), moved and ('taken from “' .. moved .. '”') or nil)
end
local function start_capture(id)
  stop_capture()
  st.capture = id
  for i, k in ipairs(CAPTURE) do
    local n = 'cap-' .. i
    mp.add_forced_key_binding(k, n, function() captured(k) end)
    capture_names[#capture_names + 1] = n
  end
  render()
end

-- The page ------------------------------------------------------------------
local SECTIONS = { 'General', 'Playback', 'Subtitles', 'Audio', 'Hotkeys', 'About' }
local ENGINE = {}

open_settings = function(section)
  st.cm, st.menu = nil, nil
  st.settings = { section = section or (st.settings and st.settings.section) or 'General', scroll = 0 }
  ENGINE.mpv = ENGINE.mpv or (mp.get_property('mpv-version') or ''):gsub('^mpv ', '')
  ENGINE.ffmpeg = ENGINE.ffmpeg or mp.get_property('ffmpeg-version') or ''
  render()
end
local function close_settings() stop_capture(); st.settings = nil; render() end

-- control helpers (all drawn inside the content clip)
local function seg(ctx_clip, id, x, y, opts, current, data)
  -- right-aligned row of chips; returns nothing
  local s = st.s
  local h = 32 * s
  local widths, total = {}, 0
  for i, o in ipairs(opts) do widths[i] = text_w(o[1], 13 * s) + 28 * s; total = total + widths[i] + 6 * s end
  local cx = x - total + 6 * s
  for i, o in ipairs(opts) do
    local on = o[2] == current
    local hov = within(cx, y, widths[i], h)
    fill(cut(cx, y, widths[i], h, 4 * s), on and T.accent or (hov and T.line or T.surface2), 0, ctx_clip)
    txt(cx + widths[i] / 2, y + h / 2, o[1], { size = 13, weight = on and 600 or 500, an = 5, color = on and T.onAccent or T.ink, extra = ctx_clip })
    zone('set-seg', cx, y, widths[i], h, { id = id, value = o[2], extra = data })
    cx = cx + widths[i] + 6 * s
  end
end
local function sbutton(clip, id, x, y, label, data, primary)
  local s = st.s
  local w, h = text_w(label, 13 * s) + 32 * s, 32 * s
  x = x - w
  local hov = within(x, y, w, h)
  if primary then
    fill(cut(x, y, w, h, 4 * s), hov and T.accentStrong or T.accent, 0, clip)
    txt(x + w / 2, y + h / 2, label, { size = 13, weight = 600, an = 5, color = T.onAccent, extra = clip })
  else
    fill(cut(x, y, w, h, 4 * s), hov and T.line or T.surface2, 0, clip)
    stroke(cut(x, y, w, h, 4 * s), T.lineStrong, 1 * s, 0, clip)
    txt(x + w / 2, y + h / 2, label, { size = 13, weight = 500, an = 5, extra = clip })
  end
  zone(id, x, y, w, h, data)
  return w
end

local ONOFF = { { 'On', true }, { 'Off', false } }

-- Each section returns rows: { h = height, draw = function(x, y, w, clip) }
-- ctrl_w: how much room (css px) the control on the right needs; the description gets the rest
local function row(label, desc, control, h, ctrl_w)
  return { h = (h or 64) , draw = function(x, y, w, clip)
    local s = st.s
    txt(x, y + (desc and 22 or 32) * s, label, { size = 14, weight = 500, extra = clip })
    local dw = control and (w - (ctrl_w or 200) * s - 24 * s) or w
    if desc then txt(x, y + 44 * s, fit(desc, dw, 12 * s), { size = 12, color = T.muted, extra = clip }) end
    if control then control(x + w, y + 16 * s, clip) end
    fill(rect(x, y + (h or 64) * s - 1 * s, w, 1 * s), T.line, 0, clip)
  end }
end
local function onoff(key)
  return function(rx, y, clip) seg(clip, key, rx, y, ONOFF, cfg[key]) end
end

local function lang_line(kind)
  local pref = st[kind == 'audio' and 'alang' or 'slang']
  return row(kind == 'audio' and 'Preferred audio language' or 'Preferred subtitle language',
    pref and ('Every file opens with ' .. lang_name(pref) .. ' when it has it') or 'Each file\'s default · set it from right-click › ' .. (kind == 'audio' and 'Audio' or 'Subtitles'),
    function(rx, y, clip)
      if pref then sbutton(clip, 'set-clear-lang', rx, y, 'Clear ' .. lang_name(pref), { kind = kind }) end
    end)
end

local function section_rows(name)
  local s = st.s
  local rows = {}
  if name == 'General' then
    rows[#rows + 1] = { h = 142, draw = function(x, y, w, clip)
      txt(x, y + 22 * s, 'Theme', { size = 14, weight = 500, extra = clip })
      local tw = math.min(150 * s, (w - 3 * 12 * s) / 4)
      local ch = 86 * s
      for i, th in ipairs(THEMES) do
        local c = K.colors(i)
        local tx, ty = x + (i - 1) * (tw + 12 * s), y + 40 * s
        local on = i == theme_i
        fill(cut(tx, ty, tw, ch, 6 * s), c.surface1, 0, clip)
        -- a miniature of the theme's cover: the slab with its kanji, the bright block, the
        -- signal, and its motif filling the rest
        local bx, by, bh = tx + 10 * s, ty + 10 * s, 30 * s
        local sw = r(tw * 0.3)
        fill(rect(bx, by, sw, bh), c.accent, 0, clip)
        txt(bx + sw / 2, by + bh / 2, th.kanji, { size = 15, weight = 600, an = 5, color = c.onAccent, extra = clip })
        local b2, b3 = r(tw * 0.14), r(tw * 0.07)
        fill(rect(bx + sw + 3 * s, by, b2, bh), c.accentBright, 0, clip)
        fill(rect(bx + sw + b2 + 6 * s, by, b3, bh), c.signal, 0, clip)
        local mx = bx + sw + b2 + b3 + 10 * s
        local mw = tx + tw - 10 * s - mx
        if mw >= 8 * s then fill(K.pattern(th.style.motif, mx, by, mw, bh, s, 10 * s), c.lineStrong, 0, clip) end
        -- its seek bar and thumb
        local ly, lw = ty + 52 * s, tw - 20 * s
        fill(rect(bx, ly - 1.5 * s, lw, 3 * s), c.line, 0, clip)
        fill(rect(bx, ly - 1.5 * s, lw * 0.62, 3 * s), c.accent, 0, clip)
        local body, dot = K.thumb(th.style.thumb, bx + lw * 0.62, ly, 4.5 * s)
        fill(body, c.accentBright, 0, clip)
        if dot then fill(dot, c.onAccent, 0, clip) end
        txt(bx, ty + 71 * s, th.name, { size = 12, weight = on and 600 or 400, color = c.ink, extra = clip })
        stroke(cut(tx, ty, tw, ch, 6 * s), on and T.accentBright or (within(tx, ty, tw, ch) and T.lineStrong or T.line), on and 2 * s or 1 * s, 0, clip)
        zone('set-theme', tx, ty, tw, ch, { i = i })
      end
      fill(rect(x, y + 142 * s - 1 * s, w, 1 * s), T.line, 0, clip)
    end }
    rows[#rows + 1] = row('Resume where you stopped', 'Reopening a file continues from the same moment, with the same tracks', onoff('resume'))
    rows[#rows + 1] = row('Build the playlist from the folder', 'Opening one episode lines up the rest of its series', onoff('autoplaylist'))
    rows[#rows + 1] = row('“Skip opening / ending” button', 'Shown while a chapter is an opening or ending', onoff('skip_button'))
    rows[#rows + 1] = row('Window', 'Opens where and how you left it: on the same monitor, maximized or fitted to the video. Fullscreen is always manual.', nil)
    rows[#rows + 1] = row('Always on top', 'Keeps Dōga above other windows · ' .. hotkey_label('ontop'), onoff('ontop'))
    rows[#rows + 1] = row('Screenshots', hotkey_label('shot') .. ' saves the exact frame · ' .. hotkey_label('shot-subs') .. ' includes subtitles · Pictures › Dōga',
      function(rx, y, clip) sbutton(clip, 'set-open-shots', rx, y, 'Open folder') end, 64, 150)
  elseif name == 'Playback' then
    rows[#rows + 1] = row('Seek step', 'How far ← and → jump', function(rx, y, clip)
      seg(clip, 'seek_step', rx, y, { { '3s', 3 }, { '5s', 5 }, { '10s', 10 }, { '15s', 15 }, { '30s', 30 } }, cfg.seek_step)
    end)
    rows[#rows + 1] = row('Hardware decoding', 'Lighter on the CPU; the picture is identical either way', onoff('hwdec'))
    rows[#rows + 1] = lang_line('audio')
    rows[#rows + 1] = lang_line('sub')
    rows[#rows + 1] = row('Same tracks for a whole series', 'The audio and subtitles you pick follow to the next episodes', onoff('series_tracks'))
  elseif name == 'Subtitles' then
    rows[#rows + 1] = row('Size', 'Scales plain and styled subtitles alike', function(rx, y, clip)
      seg(clip, 'sub_scale', rx, y, { { '80%', 0.8 }, { '90%', 0.9 }, { '100%', 1.0 }, { '115%', 1.15 }, { '130%', 1.3 } }, cfg.sub_scale)
    end)
    rows[#rows + 1] = row('Move above the controls', 'Dialogue steps up while the bar is showing; signs never move', onoff('lift_subs'))
  elseif name == 'Audio' then
    rows[#rows + 1] = row('Volume on launch', 'Remember your last volume, or always start at 100%', function(rx, y, clip)
      seg(clip, 'volume_mode', rx, y, { { 'Remember', 'remember' }, { 'Always 100%', 'reset' } }, cfg.volume_mode)
    end, 64, 320)
    rows[#rows + 1] = row('Audio delay  ' .. delay_text(cfg.audio_delay),
      'For Bluetooth headphones or out-of-sync files · ' .. hotkey_label('audio-minus') .. ' / ' .. hotkey_label('audio-plus'),
      function(rx, y, clip)
        local w1 = sbutton(clip, 'set-adelay', rx, y, 'Reset', { d = 0 })
        local w2 = sbutton(clip, 'set-adelay', rx - w1 - 8 * s, y, '+50 ms', { d = 0.05 })
        sbutton(clip, 'set-adelay', rx - w1 - w2 - 16 * s, y, '−50 ms', { d = -0.05 })
      end, 64, 300)
    rows[#rows + 1] = { h = 40, draw = function(x, y, w, clip)
      txt(x, y + 26 * s, 'OUTPUT DEVICE', { size = 10, weight = 600, color = T.muted, extra = '\\fsp1.5' .. clip })
    end }
    local cur = mp.get_property('audio-device') or 'auto'
    local devices = {}
    for _, d in ipairs(mp.get_property_native('audio-device-list') or {}) do
      -- the normal Windows devices only (skip duplicates mpv lists from other backends)
      if d.name == 'auto' or d.name:match('^wasapi/') then devices[#devices + 1] = d end
    end
    for _, d in ipairs(devices) do
      rows[#rows + 1] = { h = 40, draw = function(x, y, w, clip)
        local on = d.name == cur
        if on or within(x, y, w, 40 * s) then fill(rect(x - 8 * s, y, w + 16 * s, 40 * s), T.surface2, 0, clip) end
        if on then fill(diamond(x + 8 * s, y + 20 * s, 5 * s), T.accent, 0, clip) end
        txt(x + 26 * s, y + 20 * s, fit(d.name == 'auto' and 'System default' or (d.description or d.name), w - 40 * s, 14 * s),
          { size = 14, color = on and T.accentBright or T.ink, extra = clip })
        zone('set-device', x - 8 * s, y, w + 16 * s, 40 * s, { name = d.name })
      end }
    end
  elseif name == 'Hotkeys' then
    rows[#rows + 1] = { h = 52, draw = function(x, y, w, clip)
      txt(x, y + 18 * s, 'Click a key, then press the new one. Esc cancels.', { size = 12, color = T.muted, extra = clip })
      sbutton(clip, 'set-keys-reset', x + w, y + 2 * s, 'Reset all')
    end }
    for _, h in ipairs(HOTKEYS) do
      rows[#rows + 1] = { h = 44, draw = function(x, y, w, clip)
        local waiting = st.capture == h.id
        local k = key_of(h)
        local custom = cfg.keys[h.id] ~= nil
        if within(x, y, w, 44 * s) or waiting then fill(rect(x - 8 * s, y, w + 16 * s, 44 * s), T.surface2, 0, clip) end
        txt(x, y + 22 * s, h.label, { size = 14, extra = clip })
        local label = waiting and 'Press a key…' or key_label(k)
        local kw = text_w(label, 13 * s) + 24 * s
        local kx = x + w - kw
        fill(cut(kx, y + 7 * s, kw, 30 * s, 4 * s), waiting and T.accent or T.surface1, 0, clip)
        stroke(cut(kx, y + 7 * s, kw, 30 * s, 4 * s), waiting and T.accent or (custom and T.accent or T.lineStrong), 1 * s, 0, clip)
        txt(kx + kw / 2, y + 22 * s, label, { size = 13, weight = 600, an = 5, color = waiting and T.onAccent or (k == '' and T.faint or T.ink), extra = clip })
        if custom and not waiting then txt(kx - 12 * s, y + 22 * s, 'changed', { size = 11, an = 6, color = T.accent, extra = clip }) end
        zone('set-key', x - 8 * s, y, w + 16 * s, 44 * s, { id = h.id })
      end }
    end
  elseif name == 'About' then
    rows[#rows + 1] = { h = 132, draw = function(x, y, w, clip)
      txt(x, y + 76 * s, 'Dōga', { size = 48, weight = 600, an = 1, extra = clip })
      txt(x + text_w('Dōga', 48 * s) + 16 * s, y + 70 * s, 'v' .. OPT.version, { size = 14, mono = true, an = 1, color = T.accentBright, extra = clip })
      txt(x, y + 102 * s, 'Plays the file exactly as it was made.', { size = 14, color = T.muted, extra = clip })
      fill(rect(x, y + 132 * s - 1 * s, w, 1 * s), T.line, 0, clip)
    end }
    local status = st.update_status or (st.update and ('Version ' .. st.update.version .. ' is available') or 'Checks GitHub daily')
    rows[#rows + 1] = row('Updates', status, function(rx, y, clip)
      local bw
      if st.update then
        bw = sbutton(clip, 'update', rx, y, 'Update to ' .. st.update.version, nil, true)
      else
        bw = sbutton(clip, 'set-check-now', rx, y, 'Check now')
      end
      seg(clip, 'updates', rx - bw - 16 * s, y, { { 'Daily', true }, { 'Never', false } }, cfg.updates)
    end, 64, 400)
    rows[#rows + 1] = row('Engine', 'mpv ' .. (ENGINE.mpv or '') .. ' · FFmpeg ' .. (ENGINE.ffmpeg or '') .. ' · libplacebo (gpu-next, D3D11)', nil)
    rows[#rows + 1] = row('Your settings', OPT.portable and 'Portable · kept in the data folder beside doga.exe'
      or 'Settings, resume positions and recent files stay on this PC, in %APPDATA%\\Doga', function(rx, y, clip)
      sbutton(clip, 'set-open-data', rx, y, 'Open folder')
    end, 64, 150)
    rows[#rows + 1] = row('Source & licenses', 'MIT · bundles libmpv (GPL-2.0+) and OFL fonts', function(rx, y, clip)
      local w1 = sbutton(clip, 'set-open-url', rx, y, 'Licenses', { url = 'https://github.com/invictus-1/Doga/blob/main/THIRD_PARTY.md' })
      sbutton(clip, 'set-open-url', rx - w1 - 8 * s, y, 'GitHub', { url = 'https://github.com/invictus-1/Doga' })
    end, 64, 220)
  end
  return rows
end

local function draw_settings()
  local S = st.settings
  local s, W, H = st.s, st.w, st.h
  fill(rect(0, 0, W, H), '000000', 0x50)
  zone('set-backdrop', 0, 0, W, H)
  local pw = math.min(W - 48 * s, 920 * s)
  local ph = math.min(H - 48 * s, 640 * s)
  local px, py = r((W - pw) / 2), r((H - ph) / 2)
  fill(rect(px, py + 10 * s, pw, ph), '000000', 0x60, '\\blur16')
  fill(cut(px, py, pw, ph, 10 * s), T.surface1)
  stroke(cut(px, py, pw, ph, 10 * s), T.lineStrong, 1 * s)
  kctx():trim(px, py, pw, ph, 10 * s)
  zone('set-panel', px, py, pw, ph)
  -- header
  txt(px + 28 * s, py + 34 * s, 'Settings', { size = 20, weight = 600 })
  local cx, cy = px + pw - 48 * s, py + 14 * s
  if within(cx, cy, 36 * s, 36 * s) then fill(rect(cx, cy, 36 * s, 36 * s), T.surface2) end
  icon('close', cx + 8 * s, cy + 8 * s, 20 * s, T.muted)
  zone('set-close', cx, cy, 36 * s, 36 * s)
  if pw >= 420 * s then kctx():motif(cx - 16 * s - 72 * s, py + 28 * s, 72 * s, 8 * s, T.lineStrong) end
  fill(rect(px, py + 64 * s, pw, 1 * s), T.line)
  -- nav
  local nx, nw = px + 12 * s, 176 * s
  for i, name in ipairs(SECTIONS) do
    local y = py + 76 * s + (i - 1) * 42 * s
    local on = S.section == name
    if on or within(nx, y, nw, 40 * s) then fill(rect(nx, y, nw, 40 * s), T.surface2) end
    if on then fill(diamond(nx + 16 * s, y + 20 * s, 4.5 * s), T.accent) end
    txt(nx + 32 * s, y + 20 * s, name, { size = 14, weight = on and 600 or 400, color = on and T.accentBright or T.ink })
    zone('set-nav', nx, y, nw, 40 * s, { name = name })
  end
  fill(rect(px + 200 * s, py + 65 * s, 1 * s, ph - 65 * s), T.line)
  -- content (scrolls, clipped)
  local x0, y0 = px + 228 * s, py + 72 * s
  local w0, h0 = pw - 256 * s, ph - 84 * s
  local clip = string.format('\\clip(%d,%d,%d,%d)', r(x0 - 12 * s), r(y0), r(x0 + w0 + 12 * s), r(y0 + h0))
  local rows = section_rows(S.section)
  local total = 0
  for _, rw in ipairs(rows) do total = total + rw.h * s end
  S.max_scroll = math.max(0, total - h0)
  S.scroll = math.max(0, math.min(S.scroll or 0, S.max_scroll))
  zone('set-content', x0 - 12 * s, y0, w0 + 24 * s, h0)
  local y = y0 - S.scroll
  for _, rw in ipairs(rows) do
    local rh = rw.h * s
    if y + rh > y0 and y < y0 + h0 then
      local nz = #zones
      rw.draw(x0, y, w0, clip)
      -- zones of rows cut by the clip must not catch clicks outside the visible area
      for i = nz + 1, #zones do
        local z = zones[i]
        local top, bot = math.max(z.y, y0), math.min(z.y + z.h, y0 + h0)
        if bot <= top then z.w = 0 else z.y, z.h = top, bot - top end
      end
    end
    y = y + rh
  end
  if S.max_scroll > 0 then -- thin scroll indicator
    local bh = h0 * h0 / (h0 + S.max_scroll)
    fill(rect(px + pw - 6 * s, y0 + (h0 - bh) * S.scroll / S.max_scroll, 3 * s, bh), T.lineStrong)
  end
end

local SET_ACT = {
  ['set-close'] = close_settings,
  ['set-backdrop'] = close_settings,
  ['set-nav'] = function(z) stop_capture(); st.settings.section = z.data.name; st.settings.scroll = 0 end,
  ['set-theme'] = function(z) set_theme(z.data.i); save_settings() end,
  ['set-seg'] = function(z)
    local id, v = z.data.id, z.data.value
    cfg[id] = v
    if id == 'updates' then st.update_status = v and 'Checks GitHub daily' or 'Off · check by hand' end
    apply_cfg(); save_settings()
  end,
  ['set-device'] = function(z) cfg.audio_device = z.data.name; apply_cfg(); save_settings() end,
  ['set-adelay'] = function(z) nudge_audio(z.data.d) end,
  ['set-open-shots'] = function() mp.commandv('script-message-to', 'main', 'doga-open-shots') end,
  ['set-clear-lang'] = function(z)
    local key = z.data.kind == 'audio' and 'alang' or 'slang'
    st[key] = nil; mp.set_property(key, ''); save_settings()
  end,
  ['set-key'] = function(z) start_capture(z.data.id) end,
  ['set-keys-reset'] = function() cfg.keys = {}; apply_keys(); save_settings(); osd('info', 'Hotkeys', 'back to the defaults') end,
  ['set-check-now'] = function()
    st.update_status = 'Checking…'
    mp.commandv('script-message-to', 'main', 'doga-update-check')
  end,
  ['set-open-data'] = function() mp.commandv('script-message-to', 'main', 'doga-open-data') end,
  ['set-open-url'] = function(z) mp.commandv('script-message-to', 'main', 'doga-open-url', z.data.url) end,
}

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
  if cfg.lift_subs and vis and not st.idle then
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
    draw_resumed(vw, vis, now)
  end
  if st.panel then draw_panel() end
  draw_osd(now)
  if st.cm then draw_context_menu() end
  if st.settings then draw_settings() end
  if intro.frame_t0 and not st.idle then
    local t = now - intro.frame_t0
    if t < 0.7 then kctx():intro_frame(t, st.w, st.h) else intro.frame_t0 = nil end
  end
  -- most renders (a time tick, a mouse move over the picture) draw exactly what is already up
  local data = table.concat(out, '\n')
  if data ~= ov.data or ov.res_x ~= st.w or ov.res_y ~= st.h then
    ov.res_x, ov.res_y = st.w, st.h
    ov.data = data
    ov:update()
  end
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
  if st.resumed and now > st.resumed.until_t then st.resumed = nil; render() end
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
  while #recent > 200 do table.remove(recent) end -- the start screen lists five; the rest feed the watched marks
  write_json(recent_path, recent)
end

-- The start screen's Continue row. Stopped partway: that file. Finished it: the host looks
-- up what follows it in its series (answer in doga-next) and the first one not yet watched is offered.
local function refresh_continue()
  st.cont = nil
  local r0 = recent[1]
  if not r0 or not r0.path then return end
  if not r0.watched then
    if (r0.pos or 0) > 5 then st.cont = { path = r0.path, pos = r0.pos, dur = r0.dur } end
    return
  end
  mp.commandv('script-message-to', 'main', 'doga-next', r0.path)
end
mp.register_script_message('doga-next', function(j)
  local d = j and utils.parse_json(j)
  local r0 = recent[1]
  if type(d) ~= 'table' or not r0 or not r0.watched or d['for'] ~= r0.path then return end
  for _, e in ipairs(d.next or {}) do
    local rec = recent_for(e[1])
    if not (rec and rec.watched) then
      st.cont = { path = e[1], pos = rec and rec.pos or 0, dur = rec and rec.dur or 0, series = d.name }
      break
    end
  end
  request_render()
end)

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
  back = function() mp.commandv('no-osd', 'seek', -cfg.seek_step) end,
  fwd = function() mp.commandv('no-osd', 'seek', cfg.seek_step) end,
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
      pick_track('audio', z.data.id)
      for _, t in ipairs(tracks_of('audio')) do if t.id == z.data.id then show_track_osd('audio', t) end end
    else
      if z.data.id == 'no' then pick_track('sub', 'no'); show_track_osd('sub', nil)
      else
        pick_track('sub', z.data.id)
        for _, t in ipairs(tracks_of('sub')) do if t.id == z.data.id then show_track_osd('sub', t) end end
      end
    end
  end,
  recent = function(z) mp.commandv('loadfile', z.data.path, 'replace') end,
  update = function() start_update() end,
  ['start-over'] = function() st.resumed = nil; mp.commandv('seek', 0, 'absolute') end,
  ['error-card'] = function() st.error = nil end,
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
    if st.settings then
      if st.capture and not (z and z.id == 'set-key') then stop_capture() end
      if z and SET_ACT[z.id] then SET_ACT[z.id](z)
      elseif z and ACTIONS[z.id] then ACTIONS[z.id](z) end
      render()
      return
    end
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
  if st.settings then st.settings.scroll = (st.settings.scroll or 0) - 56 * st.s; render(); return end
  if in_panel() then st.scroll = st.scroll - ROW_H * st.s; render() else change_volume(5) end
end, { repeatable = true })
mp.add_key_binding(nil, 'wheel-down', function()
  if st.settings then st.settings.scroll = (st.settings.scroll or 0) + 56 * st.s; render(); return end
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
-- From the host's updater (src/update.rs).
mp.register_script_message('doga-update', function(state, version, extra)
  msg.info('update:', state, version or '', extra or '')
  if state == 'available' then
    st.update = { state = 'available', version = version }
    st.update_status = 'Version ' .. version .. ' is available'
  elseif state == 'downloading' and st.update then
    st.update.state, st.update.pct = 'downloading', tonumber(extra) or 0
    osd('info', 'Update', 'downloading ' .. version, nil, { bar = st.update.pct })
  elseif state == 'verifying' then
    osd('info', 'Update', 'checking the signature')
  elseif state == 'verified' then
    osd('info', 'Update', version .. ' downloaded and verified (dry run)')
    if st.update then st.update.state = 'available' end
  elseif state == 'current' then
    st.update = nil
    st.update_status = 'Up to date (checked just now)'
    osd('info', 'Update', 'Dōga is up to date')
  elseif state == 'error' then
    st.update_status = 'Couldn’t check: ' .. (version or 'unknown error')
    osd('info', 'Update', version or 'failed', nil, { off = true })
    if st.update then st.update.state = 'available' end
  end
  render()
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
mp.add_key_binding(nil, 'settings', function()
  if st.settings then close_settings() else open_settings() end
end)
mp.add_key_binding(nil, 'audio-delay-minus', function() nudge_audio(-0.05) end, { repeatable = true })
mp.add_key_binding(nil, 'audio-delay-plus', function() nudge_audio(0.05) end, { repeatable = true })
mp.add_key_binding(nil, 'start-over', function()
  if st.idle then return end
  st.resumed = nil
  mp.commandv('seek', 0, 'absolute')
  osd('back', 'Back to the start', nil)
end)
-- Screenshots: the exact decoded frame (no controls; subtitles only with Shift), PNG,
-- into Pictures\Dōga (set by the host).
local function screenshot(mode)
  if st.idle then return end
  local r = mp.command_native({ 'screenshot', mode })
  local name = type(r) == 'table' and r.filename and basename(r.filename)
  if name then osd('open', 'Screenshot', name, 'Pictures › Dōga')
  else osd('open', 'Screenshot', 'couldn\'t be saved', nil, { off = true }) end
end
mp.add_key_binding(nil, 'screenshot', function() screenshot('video') end)
mp.add_key_binding(nil, 'screenshot-subs', function() screenshot('subtitles') end)
-- Ctrl+C: the same exact frame (no controls, no subtitles) onto the clipboard. The host does
-- the copying and answers with doga-copied.
mp.add_key_binding(nil, 'copy-frame', function()
  if st.idle then return end
  mp.commandv('script-message-to', 'main', 'doga-copy-frame')
end)
mp.register_script_message('doga-copied', function(state, w, h)
  if state == 'ok' then osd('open', 'Frame copied', w .. ' × ' .. h, 'paste it anywhere')
  else osd('open', 'Frame', 'couldn\'t be copied', nil, { off = true }) end
end)
mp.add_key_binding(nil, 'toggle-ontop', function() set_ontop(not cfg.ontop) end)
mp.add_key_binding(nil, 'seek-back', function() mp.commandv('no-osd', 'seek', -cfg.seek_step) end, { repeatable = true })
mp.add_key_binding(nil, 'seek-fwd', function() mp.commandv('no-osd', 'seek', cfg.seek_step) end, { repeatable = true })
mp.add_key_binding(nil, 'context-menu', function()
  if st.settings then return end
  skip_intro()
  st.menu = nil
  st.cm = { x = st.mx, y = st.my, items = cm_main() }
  render()
end)
mp.add_key_binding(nil, 'escape', function()
  if st.settings then close_settings(); return end
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
obs('idle-active', 'bool', function(v)
  st.idle = v and true or false
  if st.idle then refresh_continue() end
end)
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
  -- The series is only known now. If its remembered tracks couldn't be found by file name
  -- while the file was loading, apply them late.
  if st.path and series_done ~= st.path then series_apply(st.path, st.tracks) end
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

-- Resume chip: the first playback-restart after a load tells us where playback began.
local check_resume = false
mp.register_event('file-loaded', function()
  st.error = nil
  check_resume = true
end)
mp.register_event('playback-restart', function()
  if not check_resume then return end
  check_resume = false
  local p = mp.get_property_number('time-pos') or 0
  if cfg.resume and p > 5 then
    st.resumed = { pos = p, until_t = mp.get_time() + 6 }
    st.last_move = mp.get_time()
    render()
  end
end)

-- A file that failed: remember which and why (the playlist carries on by itself).
mp.register_event('end-file', function(e)
  if e.reason ~= 'error' then return end
  local name
  for _, it in ipairs(st.playlist) do
    if it.id == e.playlist_entry_id then name = basename(it.filename) end
  end
  st.error = { file = name or 'this file', msg = friendly_error(e.file_error) }
  msg.info('could not play', st.error.file, '-', e.file_error or '', '->', st.error.msg)
  osd('info', 'Couldn’t play', st.error.file, nil, { off = true })
  render()
end)

-- Remember the monitor (debounced; the host opens the next window there).
local display_timer
mp.observe_property('display-names', 'native', function(_, v)
  local d = type(v) == 'table' and v[1] or nil
  if not d or d == '' then return end
  if display_timer then display_timer:kill() end
  display_timer = mp.add_timeout(1.0, function()
    display_timer = nil
    if d ~= cfg.display then cfg.display = d; save_settings() end
  end)
end)
mp.register_script_message('doga-demo-idle', function(v)
  st.demo_idle = v == 'on'
  intro.idle_t0 = nil
  render()
end)
mp.register_event('seek', function() st.last_move = mp.get_time(); request_render() end)
mp.register_event('end-file', function()
  remember()
  if mp.get_property_bool('idle-active') then refresh_continue() end
end)
-- The host waits for this goodbye before it lets the engine go, so the last save always lands.
mp.register_event('shutdown', function()
  remember(); save_settings()
  mp.commandv('script-message-to', 'main', 'doga-bye')
end)
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
    for k, v in pairs(cfg) do
      if s[k] ~= nil and type(s[k]) == type(v) then cfg[k] = s[k] end
    end
    if type(cfg.keys) ~= 'table' then cfg.keys = {} end
    if cfg.volume_mode == 'remember' and s.volume then mp.set_property_number('volume', s.volume) end
  end
  apply_cfg()
  apply_keys()
  recent = read_json(recent_path) or {}
  refresh_continue()
  if mp.get_property('path') and mp.get_property_native('duration') then boot_intro() end
end
