-- Dōga drawing kit: themes, ASS primitives, icons and the intro composition.
-- Used by installer.lua for everything, and by doga.lua for the themes and the startup animation.
-- A context collects ASS events into ctx.out; the caller owns the overlay.

local K = {}

-- Each theme is a palette plus a small visual signature:
--   kanji  one character that names it (夜 night, 氷 ice, 紅 crimson, 炭 charcoal)
--   motif  the texture used for signature strips   dots | facets | stripes | weave
--   thumb  the shape of the seek thumb             circle | diamond | blade | block
--   trim   the detail on panel corners             neon | double | stripes | minimal
--   cover  the start-screen composition
K.THEMES = {
  { id = 'nightshade', name = 'Nightshade', kanji = '夜',
    style = { motif = 'dots', thumb = 'circle', trim = 'neon', cover = 'nightshade' }, c = {
    surface0 = '0b0912', surface1 = '13101d', surface2 = '1c1729', scrim = '07050c', line = '2e2642',
    lineStrong = '4a3d6b', ink = 'ece8f6', muted = 'a69cc0', faint = '6f6689', accent = 'b57bff',
    accentStrong = '8a3dff', accentBright = 'd4b3ff', accentDim = '2a1d4d', onAccent = '0b0912',
    signal = '3ee6ff', danger = 'ff5c7a' } },
  { id = 'glacier', name = 'Glacier', kanji = '氷',
    style = { motif = 'facets', thumb = 'diamond', trim = 'double', cover = 'glacier' }, c = {
    surface0 = '05090c', surface1 = '0b141a', surface2 = '122029', scrim = '020609', line = '1e3340',
    lineStrong = '2f5163', ink = 'e3f4fa', muted = '8fb3c2', faint = '557583', accent = '3ee0ff',
    accentStrong = '0fb5d9', accentBright = 'a8f1ff', accentDim = '0e3542', onAccent = '05090c',
    signal = 'c38bff', danger = 'ff6b6b' } },
  { id = 'redline', name = 'Redline', kanji = '紅',
    style = { motif = 'stripes', thumb = 'blade', trim = 'stripes', cover = 'redline' }, c = {
    surface0 = '0c0608', surface1 = '170c10', surface2 = '221218', scrim = '080305', line = '3a1d27',
    lineStrong = '5e2f3f', ink = 'f8e9ee', muted = 'c49aa8', faint = '7e5b66', accent = 'ff3d7f',
    accentStrong = 'e01e63', accentBright = 'ffb3cc', accentDim = '4a1528', onAccent = '0c0608',
    signal = 'ff9a3d', danger = 'ffd23f' } },
  { id = 'carbon', name = 'Carbon', kanji = '炭',
    style = { motif = 'weave', thumb = 'block', trim = 'minimal', cover = 'carbon' }, c = {
    surface0 = '000000', surface1 = '0a0a0a', surface2 = '161616', scrim = '000000', line = '2a2a2a',
    lineStrong = '444444', ink = 'e0e0e0', muted = 'b3b3b3', faint = '6b6b6b', accent = 'e6e6e6',
    accentStrong = 'bfbfbf', accentBright = 'ffffff', accentDim = '1f1f1f', onAccent = '000000',
    signal = 'b57bff', danger = 'ff5c7a' } },
}
for i, t in ipairs(K.THEMES) do t.n = i end

-- theme colours as ASS BGR
local COLORS = {}
function K.colors(i)
  local t = COLORS[i]
  if not t then
    t = {}
    for k, v in pairs(K.THEMES[i].c) do t[k] = v:sub(5, 6) .. v:sub(3, 4) .. v:sub(1, 2) end
    COLORS[i] = t
  end
  return t
end
-- index of a theme id (1 when unknown)
function K.theme_index(id)
  for i, t in ipairs(K.THEMES) do if t.id == id then return i end end
  return 1
end

local function r(x) return math.floor(x + 0.5) end
K.r = r
local function P(v) return r(v * 4) end
local function A(a) return string.format('%02X', math.max(0, math.min(255, r(a or 0)))) end
K.A = A

-- easing
function K.clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end
function K.out_cubic(x) x = K.clamp01(x); return 1 - (1 - x) ^ 3 end
function K.out_expo(x) x = K.clamp01(x); return x >= 1 and 1 or 1 - 2 ^ (-10 * x) end
function K.in_out(x) x = K.clamp01(x); return x < 0.5 and 4 * x ^ 3 or 1 - (-2 * x + 2) ^ 3 / 2 end
-- progress of t within [a, b]
function K.span(t, a, b) return K.clamp01((t - a) / (b - a)) end

function K.esc(s)
  s = tostring(s or '')
  return (s:gsub('\\', '\\\239\187\191'):gsub('{', '\\{'):gsub('\n', ' '))
end

local function utf8_chars(s)
  local out = {}
  for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do out[#out + 1] = ch end
  return out
end
K.chars = utf8_chars

-- Rough advance width (px): good enough for layout and ellipsis. Calibrated against Chakra
-- Petch / JetBrains Mono as rendered by libass. These run for every label on every redraw, so
-- they walk the bytes in place and build no tables.
local byte = string.byte
local ASCII_K = {}
for b = 0, 127 do ASCII_K[b] = 0.47 end
for b = byte('A'), byte('Z') do ASCII_K[b] = 0.56 end
for ch in ('mwMW'):gmatch('.') do ASCII_K[byte(ch)] = 0.72 end
for ch in ('ilI.,:;|!\' '):gmatch('.') do ASCII_K[byte(ch)] = 0.25 end
-- end of the character that starts at i (a lead byte and the continuation bytes after it)
local function char_end(s, i, n)
  local j = i + 1
  while j <= n do
    local c = byte(s, j)
    if c < 128 or c > 191 then break end
    j = j + 1
  end
  return j - 1
end
-- width factor of the character s[i..j] whose first byte is b
local function char_k(s, i, j, b, mono)
  if j - i >= 2 then -- CJK / wide; the em dash is narrower
    if j - i == 2 and b == 226 and byte(s, i + 1) == 128 and byte(s, i + 2) == 148 then return 0.62 end
    return 1.0
  end
  if mono then return 0.6 end
  return ASCII_K[b] or 0.47
end

function K.text_w(s, px, mono)
  local w, i, n = 0, 1, #s
  while i <= n do
    local b = byte(s, i)
    if b <= 127 or (b >= 194 and b <= 244) then
      local j = char_end(s, i, n)
      w = w + px * char_k(s, i, j, b, mono)
      i = j + 1
    else
      i = i + 1 -- a stray byte has no width
    end
  end
  return w
end

function K.fit(s, maxw, px, mono)
  if K.text_w(s, px, mono) <= maxw then return s end
  -- keep the characters that fit beside the ellipsis (which is one px wide)
  local w, i, n, keep, acc = 0, 1, #s, 0, nil
  while i <= n do
    local b = byte(s, i)
    if b <= 127 or (b >= 194 and b <= 244) then
      local j = char_end(s, i, n)
      w = w + px * char_k(s, i, j, b, mono)
      if w + px > maxw then break end
      if acc then acc[#acc + 1] = s:sub(i, j) else keep = j end
      i = j + 1
    else
      if not acc then acc = { s:sub(1, keep) } end -- stray bytes are dropped, so piece it together
      i = i + 1
    end
  end
  return (acc and table.concat(acc) or s:sub(1, keep)) .. '…'
end

-- path builders (absolute px)
function K.poly(pts)
  local t = { 'm', P(pts[1]), P(pts[2]), 'l' }
  for i = 3, #pts, 2 do t[#t + 1] = P(pts[i]); t[#t + 1] = P(pts[i + 1]) end
  return table.concat(t, ' ') .. ' '
end
function K.rect(x, y, w, h) return K.poly({ x, y, x + w, y, x + w, y + h, x, y + h }) end
-- chamfer top-left (c1) and bottom-right (c2)
function K.cut(x, y, w, h, c1, c2)
  c2 = c2 or c1
  return K.poly({ x + c1, y, x + w, y, x + w, y + h - c2, x + w - c2, y + h, x, y + h, x, y + c1 })
end
function K.circle(cx, cy, rad)
  local k = rad * 0.5523
  return string.format('m %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d ',
    P(cx - rad), P(cy),
    P(cx - rad), P(cy - k), P(cx - k), P(cy - rad), P(cx), P(cy - rad),
    P(cx + k), P(cy - rad), P(cx + rad), P(cy - k), P(cx + rad), P(cy),
    P(cx + rad), P(cy + k), P(cx + k), P(cy + rad), P(cx), P(cy + rad),
    P(cx - k), P(cy + rad), P(cx - rad), P(cy + k), P(cx - rad), P(cy))
end
function K.diamond(cx, cy, rad) return K.poly({ cx, cy - rad, cx + rad, cy, cx, cy + rad, cx - rad, cy }) end

-- A polyline that stays open when stroked (ASS closes every shape: walk it back instead).
function K.open(pts)
  local p = {}
  for i = 1, #pts do p[i] = pts[i] end
  for i = #pts - 3, 3, -2 do p[#p + 1] = pts[i]; p[#p + 1] = pts[i + 1] end
  return K.poly(p)
end

-- A theme's motif as one filled path covering (x, y, w, h). u: px per unit; cell: lattice size.
local pattern_cache, pattern_n = {}, 0
function K.pattern(kind, x, y, w, h, u, cell)
  local key = table.concat({ kind, r(x * 4), r(y * 4), r(w * 4), r(h * 4), r(u * 100), cell or 0 }, ',')
  if pattern_cache[key] then return pattern_cache[key] end
  local t = {}
  if kind == 'facets' then
    -- hairline X per cell: a diamond lattice
    local c = cell or h
    local th = 1.3 * u
    for j = 0, math.max(1, math.floor(h / c + 0.01)) - 1 do
      for i = 0, math.max(1, math.floor(w / c + 0.01)) - 1 do
        local x0, y0 = x + i * c, y + j * c
        t[#t + 1] = K.poly({ x0, y0, x0 + th, y0, x0 + c, y0 + c, x0 + c - th, y0 + c })
        t[#t + 1] = K.poly({ x0, y0 + c, x0 + th, y0 + c, x0 + c, y0, x0 + c - th, y0 })
      end
    end
  elseif kind == 'stripes' then
    -- bars leaning right
    local bw, pitch, lean = 3 * u, 7 * u, h * 0.5
    for i = 0, math.floor((w - lean - bw) / pitch) do
      local x0 = x + i * pitch
      t[#t + 1] = K.poly({ x0 + lean, y, x0 + lean + bw, y, x0 + bw, y + h, x0, y + h })
    end
  elseif kind == 'weave' then
    -- twill: short dashes, each row stepped along
    local dw, dh, px, py = 5 * u, 2 * u, 8 * u, 3 * u
    for j = 0, math.floor((h - dh) / py) do
      local x0 = x + (j * 3 * u) % px
      while x0 + dw <= x + w + 0.01 do
        t[#t + 1] = K.rect(x0, y + j * py, dw, dh)
        x0 = x0 + px
      end
    end
  else
    -- dots: a small matrix
    local d, p = 2 * u, 6 * u
    for j = 0, math.floor((h - d) / p) do
      for i = 0, math.floor((w - d) / p) do t[#t + 1] = K.rect(x + i * p, y + j * p, d, d) end
    end
  end
  local path = table.concat(t)
  if pattern_n > 96 then pattern_cache, pattern_n = {}, 0 end
  pattern_cache[key] = path
  pattern_n = pattern_n + 1
  return path
end

-- The seek thumb in a theme's shape. Returns the body and, for the round one, its centre dot.
function K.thumb(kind, cx, cy, rad)
  if kind == 'diamond' then
    return K.diamond(cx, cy, rad * 1.3)
  elseif kind == 'blade' then
    local hw, hh, sk = rad * 0.5, rad * 1.35, rad * 0.4
    return K.poly({ cx - hw + sk, cy - hh, cx + hw + sk, cy - hh, cx + hw - sk, cy + hh, cx - hw - sk, cy + hh })
  elseif kind == 'block' then
    return K.rect(cx - rad * 0.45, cy - rad * 1.3, rad * 0.9, rad * 2.6)
  end
  return K.circle(cx, cy, rad), K.circle(cx, cy, rad * 0.3)
end

local FSK_UI, FSK_MONO = 1.6, 1.2

local Ctx = {}
Ctx.__index = Ctx

-- K.new{ s = hidpi scale, T = colours, theme = K.THEMES entry, ui = font, mono = font, out = table (optional) }
function K.new(o)
  return setmetatable({ out = o.out or {}, s = o.s or 1, T = o.T, theme = o.theme or K.THEMES[1],
    ui = o.ui or 'Segoe UI', mono = o.mono or 'Consolas', zones = o.zones or {} }, Ctx)
end

function Ctx:fill(cmds, color, alpha, extra)
  self.out[#self.out + 1] = '{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H' .. color .. '&\\1a&H' .. A(alpha) .. '&' .. (extra or '') .. '\\p3}' .. cmds .. '{\\p0}'
end
function Ctx:stroke(cmds, color, width, alpha, extra)
  self.out[#self.out + 1] = string.format('{\\an7\\pos(0,0)\\bord%.2f\\shad0\\1a&HFF&\\3c&H%s&\\3a&H%s&%s\\p3}%s{\\p0}',
    width / 2, color, A(alpha), extra or '', cmds)
end
-- o: size (css px), mono, weight, color, alpha, an, extra, raw
function Ctx:txt(x, y, s, o)
  o = o or {}
  local px = (o.size or 14) * self.s
  self.out[#self.out + 1] = string.format('{\\an%d\\pos(%d,%d)\\bord0\\shad0\\fn%s\\fs%d\\b%d\\1c&H%s&\\1a&H%s&\\q2%s}%s',
    o.an or 4, r(x), r(y), o.mono and self.mono or self.ui, r(px * (o.mono and FSK_MONO or FSK_UI)), o.weight or 400,
    o.color or self.T.ink, A(o.alpha), o.extra or '', o.raw and s or K.esc(s))
end
function Ctx:zone(id, x, y, w, h, data) self.zones[#self.zones + 1] = { id = id, x = x, y = y, w = w, h = h, data = data } end

-- The theme's signature strip.
function Ctx:motif(x, y, w, h, color, alpha, extra)
  self:fill(K.pattern(self.theme.style.motif, x, y, w, h, self.s), color, alpha, extra)
end

-- The theme's seek thumb.
function Ctx:thumb(cx, cy, rad, color, alpha, extra)
  local body, dot = K.thumb(self.theme.style.thumb, cx, cy, rad)
  self:fill(body, color, alpha, extra)
  if dot then self:fill(dot, self.T.onAccent, alpha, extra) end
end

-- The theme's detail on a cut panel (x, y, w, h; c = its chamfer). Drawn over the panel's outline.
function Ctx:trim(x, y, w, h, c)
  local T, s, kind = self.T, self.s, self.theme.style.trim
  if kind == 'neon' then
    -- a lit bracket hugging each cut corner
    local a, b = 12 * s, 28 * s
    self:stroke(K.open({ x, y + c + a, x, y + c, x + c, y, x + c + b, y }), T.accent, 1.5 * s)
    self:stroke(K.open({ x + w, y + h - c - a, x + w, y + h - c, x + w - c, y + h, x + w - c - b, y + h }), T.accent, 1.5 * s)
  elseif kind == 'double' then
    -- a second bevel inside each cut corner, like a ground facet
    local d, th = 5 * s, 1.2 * s
    self:fill(K.poly({ x, y + c + d, x + c + d, y, x + c + d + th, y, x, y + c + d + th })
      .. K.poly({ x + w, y + h - c - d, x + w - c - d, y + h, x + w - c - d - th, y + h, x + w, y + h - c - d - th }), T.accent)
  elseif kind == 'stripes' then
    -- three speed stripes riding the edge after each cut
    local t = {}
    for i = 0, 2 do
      local x0 = x + c + 6 * s + i * 7 * s
      t[#t + 1] = K.poly({ x0 + 2 * s, y, x0 + 6 * s, y, x0 + 4 * s, y + 3 * s, x0, y + 3 * s })
      local x1 = x + w - c - 6 * s - i * 7 * s
      t[#t + 1] = K.poly({ x1 - 4 * s, y + h - 3 * s, x1, y + h - 3 * s, x1 - 2 * s, y + h, x1 - 6 * s, y + h })
    end
    self:fill(table.concat(t), T.accent)
  else
    -- registration ticks in the two square corners
    local m, a, th = 4 * s, 6 * s, 1 * s
    self:fill(K.rect(x + w - m - a, y + m, a, th) .. K.rect(x + w - m - th, y + m, th, a)
      .. K.rect(x + m, y + h - m - th, a, th) .. K.rect(x + m, y + h - m - a, th, a), T.faint)
  end
end

-- Icons on a 24 grid: 'f' filled, 's' open stroke, 'c' closed stroke.
K.ICONS = {
  play = { { 'f', { 7, 4.5, 19, 12, 7, 19.5 } } },
  open = { { 'c', { 3.5, 5.5, 10, 5.5, 12, 8, 20.5, 8, 20.5, 18.5, 3.5, 18.5 } } },
  check = { { 's', { 5, 12.5, 9.5, 17, 19, 7.5 } } },
  close = { { 's', { 6, 6, 18, 18 } }, { 's', { 18, 6, 6, 18 } } },
  chev = { { 's', { 9, 5.5, 15.5, 12, 9, 18.5 } } },
  info = { { 'c', { 12, 3.5, 20.5, 12, 12, 20.5, 3.5, 12 } }, { 's', { 12, 11, 12, 16 } }, { 'f', { 11.1, 7.3, 12.9, 7.3, 12.9, 9.1, 11.1, 9.1 } } },
}
function Ctx:icon(name, x, y, size, color, alpha)
  local k = size / 24
  for _, part in ipairs(K.ICONS[name] or {}) do
    local kind, src = part[1], part[2]
    local pts = {}
    for i = 1, #src, 2 do pts[#pts + 1] = x + src[i] * k; pts[#pts + 1] = y + src[i + 1] * k end
    if kind == 'f' then
      self:fill(K.poly(pts), color, alpha)
    else
      if kind == 's' and #pts > 4 then
        for i = #src - 3, 1, -2 do pts[#pts + 1] = x + src[i] * k; pts[#pts + 1] = y + src[i + 1] * k end
      end
      self:stroke(K.poly(pts), color, 1.75 * k, alpha)
    end
  end
end

---------------------------------------------------------------------------
-- The intro: the design system's cover composition, assembled.
-- Coordinates are in cover units (480 × 288); `box` maps them to the screen.
---------------------------------------------------------------------------
K.INTRO_LEN = 1.3

-- deterministic jitter for the glitch
local function noise(i, f) local v = math.sin(i * 12.9898 + f * 78.233) * 43758.5453; return v - math.floor(v) end

-- Cover shapes, in cover units.
local function box(x, y, w, h) return { x, y, x + w, y, x + w, y + h, x, y + h } end
local function cutb(x, y, w, h, c1, c2) return { x + c1, y, x + w, y, x + w, y + h - c2, x + w - c2, y + h, x, y + h, x, y + c1 } end
local function dia(cx, cy, rad) return { cx, cy - rad, cx + rad, cy, cx, cy + rad, cx - rad, cy } end
local function add_plus(list, cx, cy, arm, th)
  list[#list + 1] = box(cx - arm, cy - th / 2, arm * 2, th)
  list[#list + 1] = box(cx - th / 2, cy - arm, th, arm * 2)
end

-- A group of shapes that moves and fades together (one block and what is printed on it).
local Layer = {}
Layer.__index = Layer
function Layer:fill(pts, color) self.ctx:fill(self.path(pts, self.dx, self.dy), color, self.a) end
-- (outlines land on whole pixels, or the line comes out uneven along its length)
function Layer:stroke(pts, color, wd) self.ctx:stroke(self.path(pts, self.dx, self.dy, true), color, wd * self.k, self.a) end
function Layer:many(list, color)
  local t = {}
  for i, pts in ipairs(list) do t[i] = self.path(pts, self.dx, self.dy) end
  if #t > 0 then self.ctx:fill(table.concat(t), color, self.a) end
end
-- o.size is in cover units
function Layer:text(x, y, str, o)
  local px, py = self.pt(x, y)
  o.size = o.size * self.k / self.ctx.s
  o.alpha = self.a
  self.ctx:txt(px + self.dx, py + self.dy, str, o)
end

-- The accent slab carries the theme's number and its kanji, like a poster.
local function slab_print(L, g, fax, kx)
  local T, th = g.T, g.theme
  L:text(54, 14, string.format('%02d', th.n), { size = 15, mono = true, weight = 700, color = T.onAccent, an = 4 })
  L:fill(box(54, 27, 132, g.hair), T.onAccent)
  L:text(kx or 50, 222, th.kanji, { size = 92, weight = 600, color = T.onAccent, an = 1, extra = fax and ('\\fax' .. fax) or nil })
end

local COVER = {}

-- Nightshade: a night city. Film-strip sprockets, lit windows, a dot matrix, crosshairs.
function COVER.nightshade(g)
  local T, t, k = g.T, g.t, g.k
  local L = g.block(0.18, 0.70)
  if L then L:fill(cutb(312, 136, 184, 168, 16, 0), T.line) end
  L = g.block(0.22, 0.74)
  if L then
    L:fill(cutb(392, -16, 104, 136, 0, 16), T.accentDim)
    local lit, hot = {}, {}
    for j = 0, 8 do
      for i = 0, 4 do
        local n = noise(i * 7 + 3, j * 5 + 1)
        if n > 0.8 then hot[#hot + 1] = box(404 + i * 13, 8 + j * 12, 7, 5)
        elseif n > 0.38 then lit[#lit + 1] = box(404 + i * 13, 8 + j * 12, 7, 5) end
      end
    end
    L:many(lit, T.accentStrong)
    L:many(hot, T.accentBright)
  end
  L = g.block(0.12, 0.62)
  if L then
    L:fill(cutb(216, -16, 160, 136, 0, 16), T.accentBright)
    local holes = {}
    for i = 0, 11 do holes[#holes + 1] = box(228 + i * 12, 8, 6, 4) end
    for i = 0, 9 do holes[#holes + 1] = box(228 + i * 12, 106, 6, 4) end
    L:many(holes, T.accentStrong)
  end
  L = g.block(0.06, 0.56)
  if L then
    L:fill(cutb(40, -16, 160, 248, 0, 16), T.accent)
    slab_print(L, g)
  end
  L = g.block(0.32, 0.74, true)
  if L then L:fill(cutb(216, 136, 80, 96, 16, 16), T.signal) end
  -- dot grid on the field, appearing from the top-right corner inward
  for j = 0, 5 do
    for i = 0, 5 do
      local d = (5 - i + j) / 10
      local a = K.span(t, 0.45 + d * 0.4, 0.7 + d * 0.4)
      if a > 0 then g.ctx:fill(K.circle(g.X(336 + i * 24), g.Y(160 + j * 24), 2 * k), T.faint, 255 - a * 255) end
    end
  end
  L = g.detail(0.8, 1.05)
  if L then
    local marks = {}
    add_plus(marks, 208, 128, 5, g.hair); add_plus(marks, 304, 128, 5, g.hair); add_plus(marks, 384, 128, 5, g.hair)
    L:many(marks, T.muted)
  end
end

-- Glacier: cut ice. Deep facets, a diamond, a split crystal, a hairline lattice.
function COVER.glacier(g)
  local T = g.T
  local L = g.block(0.18, 0.70)
  if L then L:fill(cutb(312, 136, 184, 168, 64, 0), T.line) end
  L = g.block(0.22, 0.74)
  if L then
    L:fill({ 408, -16, 496, -16, 496, 104 }, T.accentDim)
    L:stroke({ 392, 0, 480, 120, 392, 120 }, T.accent, 1.5)
  end
  L = g.block(0.12, 0.62)
  if L then L:fill(cutb(216, -16, 160, 136, 0, 56), T.accentBright) end
  L = g.block(0.06, 0.56)
  if L then
    L:fill(cutb(40, -16, 160, 248, 0, 72), T.accent)
    slab_print(L, g)
  end
  L = g.block(0.32, 0.74, true)
  if L then L:fill(dia(256, 184, 48), T.signal) end
  L = g.detail(0.6, 1.0)
  if L then
    local lines, c, w = {}, 32, g.hair * 1.4
    for j = 0, 3 do
      for i = 0, 3 do
        local x, y = 356 + i * c, 164 + j * c
        lines[#lines + 1] = { x, y, x + w, y, x + c, y + c, x + c - w, y + c }
        lines[#lines + 1] = { x, y + c, x + w, y + c, x + c, y, x + c - w, y }
      end
    end
    L:many(lines, T.lineStrong)
  end
  L = g.detail(0.8, 1.05)
  if L then L:many({ dia(208, 128, 4), dia(304, 128, 4), dia(384, 128, 4) }, T.muted) end
end

-- Redline: speed. Everything leans, stripes thin out to the right, a tach scale runs into the red.
function COVER.redline(g)
  local T = g.T
  local L = g.block(0.18, 0.70)
  if L then L:fill(box(312, 136, 232, 168), T.line) end
  L = g.block(0.22, 0.74)
  if L then
    L:many({ box(392, -16, 28, 136), box(428, -16, 16, 136) }, T.accentDim)
    L:many({ box(452, -16, 8, 136), box(468, -16, 4, 136) }, T.accent)
  end
  L = g.block(0.12, 0.62)
  if L then
    L:fill(box(216, -16, 160, 136), T.accentBright)
    L:many({ box(228, 90, 136, 3), box(268, 99, 96, 3), box(308, 108, 56, 3) }, T.accent)
  end
  L = g.block(0.06, 0.56)
  if L then
    L:fill(box(40, -16, 160, 248), T.accent)
    slab_print(L, g, -0.18, 80)
  end
  L = g.block(0.32, 0.74, true)
  if L then L:fill(box(216, 136, 80, 96), T.signal) end
  L = g.detail(0.6, 1.0)
  if L then
    local cool, red = {}, {}
    for i = 0, 19 do
      local tick = box(328 + i * 8, 150, 2, (i % 5 == 0) and 16 or 8)
      if i >= 15 then red[#red + 1] = tick else cool[#cool + 1] = tick end
    end
    L:many(cool, T.faint)
    L:many(red, T.accent)
  end
end

-- Carbon: a print proof. One solid slab, outlines, a twill weave, a single spot of colour.
function COVER.carbon(g)
  local T = g.T
  local L = g.block(0.18, 0.70)
  if L then L:fill(cutb(312, 136, 184, 168, 16, 0), T.line) end
  L = g.block(0.22, 0.74)
  if L then
    L:fill(cutb(392, -16, 104, 136, 0, 16), T.accentDim)
    L:stroke(cutb(392, -16, 104, 136, 0, 16), T.lineStrong, 1)
  end
  L = g.block(0.12, 0.62)
  if L then
    L:stroke(cutb(216, 1, 160, 119, 0, 16), T.accentBright, 1.5)
    local mark = {}
    add_plus(mark, 296, 60, 10, g.hair)
    L:many(mark, T.muted)
  end
  L = g.block(0.06, 0.56)
  if L then
    L:fill(cutb(40, -16, 160, 248, 0, 16), T.accent)
    slab_print(L, g)
  end
  L = g.block(0.32, 0.74, true)
  if L then
    L:stroke(cutb(216, 136, 80, 96, 16, 16), T.lineStrong, 1)
    L:fill(cutb(216, 136, 40, 40, 8, 8), T.signal)
  end
  L = g.detail(0.6, 1.0)
  if L then
    local dashes = {}
    for j = 0, 17 do
      local x = 328 + (j * 8) % 20
      while x + 12 <= 476 do dashes[#dashes + 1] = box(x, 152 + j * 8, 12, 3); x = x + 20 end
    end
    L:many(dashes, T.lineStrong)
  end
  L = g.detail(0.8, 1.05)
  if L then
    local marks = {}
    add_plus(marks, 208, 128, 5, g.hair); add_plus(marks, 304, 128, 5, g.hair); add_plus(marks, 384, 128, 5, g.hair)
    L:many(marks, T.muted)
  end
end

-- t: seconds since start (>= INTRO_LEN draws the settled state)
-- box: { x, y, w, h } region for the composition (bleeds off its top/right)
function Ctx:intro_blocks(t, area)
  local T, th = self.T, self.theme
  local k = math.min(area.w / 480, area.h / 288)
  local ox, oy = area.x + area.w - 480 * k, area.y
  -- Redline leans: the whole cover is sheared around its middle line
  local lean = th.style.cover == 'redline' and 0.18 or 0
  local function pt(x, y) return ox + (x + lean * (144 - y)) * k, oy + y * k end
  local function path(pts, dx, dy, snap)
    local o = {}
    for i = 1, #pts, 2 do
      local px, py = pt(pts[i], pts[i + 1])
      o[i], o[i + 1] = px + dx, py + dy
      if snap then o[i], o[i + 1] = r(o[i]), r(o[i + 1]) end
    end
    return K.poly(o)
  end
  local g = { t = t, k = k, T = T, theme = th, ctx = self, hair = math.max(1, 1.2 / k) }
  function g.X(v) return ox + v * k end
  function g.Y(v) return oy + v * k end
  -- blocks slide in from the right (or rise), staggered, with an expo settle
  function g.block(a0, a1, from_y)
    local p = K.out_expo(K.span(t, a0, a1))
    if p <= 0 then return nil end
    return setmetatable({ ctx = self, path = path, pt = pt, k = k,
      dx = (1 - p) * (from_y and 0 or 520 * k), dy = (1 - p) * (from_y and 120 * k or 0),
      a = (1 - K.span(t, a0, a0 + 0.12)) * 255 }, Layer)
  end
  -- details fade in where they stand
  function g.detail(a0, a1)
    local a = K.span(t, a0, a1)
    if a <= 0 then return nil end
    return setmetatable({ ctx = self, path = path, pt = pt, k = k, dx = 0, dy = 0, a = 255 - a * 255 }, Layer)
  end

  (COVER[th.style.cover] or COVER.nightshade)(g)

  -- the seek-bar motif draws itself
  local tp = K.out_cubic(K.span(t, 0.55, 0.85))
  if tp > 0 then self:fill(path(box(40, 254, 256 * tp, 4), 0, 0), T.line) end
  -- …and fills all the way: a finished bar, not a half-watched one
  local pp = K.out_cubic(K.span(t, 0.75, 1.25))
  if pp > 0 then
    self:fill(path(box(40, 254, 256 * pp, 4), 0, 0), T.accent)
    local hx, hy = pt(40 + 256 * pp, 256)
    self:thumb(hx, hy, 5 * k, T.accentBright)
  end
  -- the theme signs its cover
  local L = g.detail(0.95, 1.25)
  if L then
    L:text(40, 276, th.name:upper(), { size = 10, mono = true, weight = 500, color = T.muted, an = 4, extra = '\\fsp' .. r(2 * k) })
    L:text(296, 276, string.format('THEME %02d', th.n), { size = 10, mono = true, weight = 500, color = T.faint, an = 6 })
  end
end

-- A horizontal scanline sweeping down the whole area, leaving nothing behind.
function Ctx:intro_scan(t, w, h)
  local p = K.span(t, 0.0, 0.5)
  if p <= 0 or p >= 1 then return end
  local y = K.in_out(p) * h
  local a = 255 - math.sin(p * math.pi) * 255
  self:fill(K.rect(0, y - 10 * self.s, w, 20 * self.s), self.T.accent, 200 + (a / 255) * 55, '\\blur' .. r(12 * self.s))
  self:fill(K.rect(0, y - 1 * self.s, w, 2 * self.s), self.T.accentBright, a)
end

-- The name, glitched in letter by letter. (x, y) is the baseline-left; size in css px.
function Ctx:intro_name(t, name, x, y, size, t0)
  t0 = t0 or 0.35
  local T, s = self.T, self.s
  local chars = utf8_chars(name)
  local px = size * s
  local cx = x
  for i, ch in ipairs(chars) do
    local ti = t0 + (i - 1) * 0.07
    local a = K.span(t, ti, ti + 0.05)
    if a > 0 then
      local settle = K.span(t, ti, ti + 0.22)
      local jit = (1 - settle) * 10 * s
      local jx = (noise(i, math.floor(t * 30)) - 0.5) * jit
      if settle < 1 then
        local sp = (1 - settle) * 6 * s
        self:txt(cx + jx - sp, y, ch, { size = size, weight = 600, an = 1, color = T.signal, alpha = 120 + settle * 135 })
        self:txt(cx + jx + sp, y, ch, { size = size, weight = 600, an = 1, color = T.accent, alpha = 120 + settle * 135 })
      end
      self:txt(cx + jx, y, ch, { size = size, weight = 600, an = 1, alpha = 255 - a * 255 })
    end
    cx = cx + K.text_w(ch, px) * 1.02
  end
end

-- HUD corners: L-brackets that draw in at two opposite corners, each with a small mono
-- label typing in beside it. `u` is the layout unit (px per 1280×720 design px).
function Ctx:intro_hud(t, w, h, u, top_label, bottom_label)
  local T = self.T
  local m, arm, th = 28 * u, 56 * u, math.max(1, 2 * u)
  local p = K.out_expo(K.span(t, 0.12, 0.6))
  if p <= 0 then return end
  local a = 255 - K.span(t, 0.12, 0.3) * 255
  -- top-left
  self:fill(K.rect(m, m, arm * p, th), T.accent, a)
  self:fill(K.rect(m, m, th, arm * p), T.accent, a)
  -- bottom-right
  self:fill(K.rect(w - m - arm * p, h - m - th, arm * p, th), T.accent, a)
  self:fill(K.rect(w - m - th, h - m - arm * p, th, arm * p), T.accent, a)
  -- tick marks along the brackets, like a reticle
  for i = 1, 3 do
    local q = K.span(t, 0.35 + i * 0.05, 0.5 + i * 0.05)
    if q > 0 then
      self:fill(K.rect(m + arm + 8 * u + (i - 1) * 10 * u, m, 4 * u, th), T.lineStrong, 255 - q * 255)
      self:fill(K.rect(w - m - arm - 12 * u - (i - 1) * 10 * u, h - m - th, 4 * u, th), T.lineStrong, 255 - q * 255)
    end
  end
  -- labels type in character by character
  local function typed(s, a0)
    local chars = utf8_chars(s)
    local n = math.floor(#chars * K.span(t, a0, a0 + 0.45) + 0.5)
    return table.concat(chars, '', 1, math.max(0, n)), n < #chars
  end
  local px = 11 * u / self.s
  local s1, typing1 = typed(top_label, 0.45)
  if s1 ~= '' then
    self:txt(m + 14 * u, m + 22 * u, s1 .. (typing1 and '▌' or ''), { size = px, mono = true, weight = 500, color = T.muted, an = 4 })
  end
  local s2, typing2 = typed(bottom_label, 0.7)
  if s2 ~= '' then
    self:txt(w - m - 14 * u, h - m - 22 * u, s2 .. (typing2 and '▌' or ''), { size = px, mono = true, weight = 500, color = T.muted, an = 6 })
  end
end

-- A rule that draws itself left to right with a bright head, then settles into `line`.
function Ctx:intro_rule(t, x, y, w, u, t0)
  local T = self.T
  local p = K.out_cubic(K.span(t, t0, t0 + 0.45))
  if p <= 0 then return end
  local th = math.max(1, 2 * u)
  self:fill(K.rect(x, y, w * p, th), T.accent)
  if p < 1 then self:fill(K.rect(x + w * p - 24 * u, y, 24 * u, th), T.accentBright) end
end

-- File-open intro: a neon frame traces the window edge from the top-left, then fades.
function Ctx:intro_frame(t, w, h)
  local s, T = self.s, self.T
  local p = K.out_cubic(K.span(t, 0, 0.38))
  local fade = K.span(t, 0.38, 0.65)
  if fade >= 1 then return end
  local a = fade * 255
  local th = 2 * s
  local per = w + h
  local len = per * p
  -- clockwise: top then right; counter-clockwise: left then bottom
  local function run(first, second, horiz_first)
    local l1 = math.min(len, first)
    local l2 = math.max(0, len - first)
    if horiz_first then
      self:fill(K.rect(0, 0, l1, th), T.accent, a)
      if l2 > 0 then self:fill(K.rect(w - th, 0, th, math.min(l2, second)), T.accent, a) end
    else
      self:fill(K.rect(0, 0, th, l1), T.accent, a)
      if l2 > 0 then self:fill(K.rect(0, h - th, math.min(l2, second), th), T.accent, a) end
    end
  end
  run(w, h, true)
  run(h, w, false)
  -- a bright head where the two runs meet
  if p >= 1 and fade < 0.6 then
    self:fill(K.rect(w - 24 * s, h - th, 24 * s, th), T.accentBright, a)
  end
end

return K
