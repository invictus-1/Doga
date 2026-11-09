-- Dōga drawing kit: themes, ASS primitives, icons and the intro composition.
-- Used by installer.lua for everything, and by doga.lua for the startup animation.
-- A context collects ASS events into ctx.out; the caller owns the overlay.

local K = {}

K.THEMES = {
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

-- theme colours as ASS BGR
function K.colors(i)
  local t = {}
  for k, v in pairs(K.THEMES[i].c) do t[k] = v:sub(5, 6) .. v:sub(3, 4) .. v:sub(1, 2) end
  return t
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

function K.text_w(s, px, mono)
  local w = 0
  for _, ch in ipairs(utf8_chars(s)) do
    if #ch >= 3 then w = w + px * (ch == '—' and 0.62 or ch == '·' and 0.3 or 1.0)
    elseif mono then w = w + px * 0.6
    elseif ch:match('[ilI%.,:;|!\' ]') then w = w + px * 0.25
    elseif ch:match('[mwMW]') then w = w + px * 0.72
    elseif ch:match('[A-Z]') then w = w + px * 0.56
    else w = w + px * 0.47 end
  end
  return w
end

function K.fit(s, maxw, px, mono)
  if K.text_w(s, px, mono) <= maxw then return s end
  local acc, ell = {}, K.text_w('…', px, mono)
  for _, ch in ipairs(utf8_chars(s)) do
    acc[#acc + 1] = ch
    if K.text_w(table.concat(acc), px, mono) + ell > maxw then acc[#acc] = nil; break end
  end
  return table.concat(acc) .. '…'
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

local FSK_UI, FSK_MONO = 1.6, 1.2

local Ctx = {}
Ctx.__index = Ctx

-- K.new{ s = hidpi scale, T = colours, ui = font, mono = font, out = table (optional) }
function K.new(o)
  return setmetatable({ out = o.out or {}, s = o.s or 1, T = o.T, ui = o.ui or 'Segoe UI', mono = o.mono or 'Consolas', zones = o.zones or {} }, Ctx)
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

-- t: seconds since start (>= INTRO_LEN draws the settled state)
-- box: { x, y, w, h } region for the composition (bleeds off its top/right)
function Ctx:intro_blocks(t, box)
  local T, s = self.T, self.s
  local k = math.min(box.w / 480, box.h / 288)
  local ox, oy = box.x + box.w - 480 * k, box.y
  local function X(v) return ox + v * k end
  local function Y(v) return oy + v * k end
  local c = 16 * k -- 2 × cut-md

  -- blocks slide in from the right, staggered, with an expo settle
  local function block(color, x, y, w, h, c1, c2, a0, a1, from_y)
    local p = K.out_expo(K.span(t, a0, a1))
    if p <= 0 then return end
    local dx = (1 - p) * (from_y and 0 or 520 * k)
    local dy = (1 - p) * (from_y and 120 * k or 0)
    self:fill(K.cut(X(x) + dx, Y(y) + dy, w * k, h * k, c1, c2), color, (1 - K.span(t, a0, a0 + 0.12)) * 255)
  end
  block(T.line, 312, 136, 184, 168, c, 0, 0.18, 0.70)
  block(T.accentBright, 216, -16, 160, 136, 0, c, 0.12, 0.62)
  block(T.accent, 40, -16, 160, 248, 0, c, 0.06, 0.56)
  block(T.signal, 216, 136, 80, 96, c, c, 0.32, 0.74, true)
  -- dot grid on the field, appearing from the top-right corner inward
  for j = 0, 5 do
    for i = 0, 5 do
      local d = (5 - i + j) / 10
      local a = K.span(t, 0.45 + d * 0.4, 0.7 + d * 0.4)
      if a > 0 then self:fill(K.circle(X(336 + i * 24), Y(160 + j * 24), 2 * k), T.faint, 255 - a * 255) end
    end
  end
  -- the seek-bar motif draws itself
  local tp = K.out_cubic(K.span(t, 0.55, 0.85))
  if tp > 0 then self:fill(K.rect(X(40), Y(254), 256 * k * tp, 4 * k), T.line) end
  -- …and fills all the way: a finished bar, not a half-watched one
  local pp = K.out_cubic(K.span(t, 0.75, 1.25))
  if pp > 0 then self:fill(K.rect(X(40), Y(254), 256 * k * pp, 4 * k), T.accent) end
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
