-- Dōga Setup: drawn by the same engine and kit as the player.
-- Screens: welcome (where + options) → installing (seek-bar progress) → done | error.

local mp = require 'mp'
local utils = require 'mp.utils'

local OPT = {
  uidir = mp.get_opt('doga-uidir') or '',
  ui = mp.get_opt('doga-uifont') or 'Segoe UI',
  mono = mp.get_opt('doga-monofont') or 'Consolas',
  dir = mp.get_opt('setup-dir') or '',
  version = mp.get_opt('setup-version') or '',
  existing = mp.get_opt('setup-existing') == 'yes',
  dry = mp.get_opt('setup-dryrun') == 'yes',
  auto = mp.get_opt('setup-auto') == 'yes',
  desktop = mp.get_opt('setup-desktop') ~= 'no',
  assoc = mp.get_opt('setup-assoc') ~= 'no',
}
package.path = OPT.uidir .. '/?.lua;' .. package.path
local K = require 'kit'

-- Setup wears the theme Dōga is already set to (Nightshade on a first install).
local function read_theme()
  local base = os.getenv('APPDATA')
  if not base then return 1 end
  for _, name in ipairs({ 'settings.json', 'settings.json.bak' }) do
    local f = io.open(base .. '\\Doga\\' .. name, 'rb')
    if f then
      local t = utils.parse_json(f:read('*a'))
      f:close()
      if type(t) == 'table' and type(t.theme) == 'string' then return K.theme_index(t.theme) end
    end
  end
  return 1
end
local theme_i = read_theme()
local TH = K.THEMES[theme_i]
local T = K.colors(theme_i)
mp.set_property('background-color', '#' .. TH.c.surface0)

local st = {
  w = 0, h = 0, s = 1, mx = -1, my = -1,
  screen = 'welcome', screen_t0 = 0, t0 = mp.get_time(),
  dir = OPT.dir, desktop = OPT.desktop, assoc = OPT.assoc,
  target = 0, shown = 0, label = '', err = nil,
  press = nil,
}
local zones = {}
local ov = mp.create_osd_overlay('ass-events')

local function hit()
  for i = #zones, 1, -1 do
    local z = zones[i]
    if st.mx >= z.x and st.mx < z.x + z.w and st.my >= z.y and st.my < z.y + z.h then return z end
  end
end
local function hovering(id) local z = hit(); return z and z.id == id end

local function go(screen)
  st.screen, st.screen_t0 = screen, mp.get_time()
end

---------------------------------------------------------------------------
-- pieces
---------------------------------------------------------------------------
local function button(ctx, id, x, y, w, h, label, primary, alpha)
  local s = ctx.s
  local hov = hovering(id)
  if primary then
    if hov then ctx:stroke(K.cut(x, y, w, h, 8 * s), T.accent, 12 * s, 0x90 + alpha * 0.4, '\\blur7') end
    ctx:fill(K.cut(x, y, w, h, 8 * s), st.press == id and T.accentStrong or T.accent, alpha)
    ctx:txt(x + w / 2, y + h / 2, label, { size = 15, weight = 600, an = 5, color = T.onAccent, alpha = alpha })
  else
    if hov then ctx:fill(K.cut(x, y, w, h, 6 * s), T.surface2, alpha) end
    ctx:txt(x + w / 2, y + h / 2, label, { size = 14, weight = 500, an = 5, color = hov and T.ink or T.muted, alpha = alpha })
  end
  ctx:zone(id, x, y, w, h)
end

local function checkbox(ctx, id, x, y, on, label, caption, alpha)
  local s = ctx.s
  local hov = hovering(id)
  local w = 560 * s
  if hov then ctx:fill(K.rect(x - 10 * s, y - 6 * s, w, 40 * s), T.surface1, alpha) end
  local cy = y + 14 * s
  if on then ctx:fill(K.diamond(x + 8 * s, cy, 6.5 * s), T.accent, alpha)
  else ctx:stroke(K.diamond(x + 8 * s, cy, 6 * s), hov and T.muted or T.lineStrong, 1.5 * s, alpha) end
  ctx:txt(x + 28 * s, cy, label, { size = 14, alpha = alpha })
  if caption then
    ctx:txt(x + 28 * s + K.text_w(label, 14 * s) + 12 * s, cy + 1 * s, caption, { size = 12, color = T.muted, alpha = alpha })
  end
  ctx:zone(id, x - 10 * s, y - 6 * s, w, 40 * s)
end

---------------------------------------------------------------------------
-- render
---------------------------------------------------------------------------
local function render()
  if st.w <= 0 then return end
  zones = {}
  local s, W, H = st.s, st.w, st.h
  local ctx = K.new({ s = s, T = T, theme = TH, ui = OPT.ui, mono = OPT.mono, zones = zones })
  local now = mp.get_time()
  local t = now - st.t0
  local ts = now - st.screen_t0

  ctx:fill(K.rect(0, 0, W, H), T.surface0)
  local bw = math.min(W * 0.48, 420 * s)
  ctx:intro_blocks(t, { x = W - bw, y = 0, w = bw, h = bw * 0.6 })

  local x0 = 48 * s
  ctx:intro_name(t, 'Dōga', x0, 118 * s, 56, 0.3)
  local a_head = 255 - K.span(t, 0.8, 1.1) * 255
  ctx:txt(x0, 152 * s, 'Plays the file exactly as it was made.', { size = 14, color = T.muted, alpha = a_head })
  local tag = 'v' .. OPT.version .. (OPT.existing and '  ·  update' or '') .. (OPT.dry and '  ·  dry run' or '')
  ctx:txt(x0, 178 * s, tag, { size = 11, mono = true, color = OPT.dry and T.signal or T.faint, alpha = a_head })

  -- each screen fades and rises in
  local enter = (st.screen == 'welcome') and K.span(t, 0.95, 1.35) or K.span(ts, 0, 0.3)
  local a = 255 - K.out_cubic(enter) * 255
  local rise = (1 - K.out_cubic(enter)) * 10 * s
  local y0 = 270 * s + rise
  local bx, by, bwid, bh = W - 48 * s - 168 * s, H - 48 * s - 44 * s, 168 * s, 44 * s

  if st.screen == 'welcome' then
    ctx:txt(x0, y0, 'INSTALL TO', { size = 11, weight = 600, color = T.muted, extra = '\\fsp1.5', alpha = a })
    local fy, fw, fh = y0 + 16 * s, math.min(W - x0 - 48 * s, 640 * s), 42 * s
    ctx:fill(K.cut(x0, fy, fw, fh, 6 * s), T.surface1, a)
    ctx:stroke(K.cut(x0, fy, fw, fh, 6 * s), hovering('browse') and T.lineStrong or T.line, 1 * s, a)
    ctx:txt(x0 + 14 * s, fy + fh / 2, K.fit((st.dir:gsub('/', '\\')), fw - 120 * s, 13 * s, true), { size = 13, mono = true, alpha = a })
    ctx:txt(x0 + fw - 16 * s, fy + fh / 2, 'Change', { size = 13, weight = 600, an = 6, color = hovering('browse') and T.accentBright or T.accent, alpha = a })
    ctx:zone('browse', x0, fy, fw, fh)

    local oy = fy + fh + 30 * s
    checkbox(ctx, 'opt-desktop', x0 + 10 * s, oy, st.desktop, 'Desktop shortcut', nil, a)
    checkbox(ctx, 'opt-assoc', x0 + 10 * s, oy + 44 * s, st.assoc, 'Open video files with Dōga', 'you confirm it in Default apps', a)

    ctx:txt(x0, by + bh / 2, 'Just for you · no admin rights · Start menu shortcut included', { size = 12, color = T.faint, alpha = a })
    button(ctx, 'install', bx, by, bwid, bh, OPT.existing and 'Update' or 'Install', true, a)
    button(ctx, 'cancel', bx - 112 * s, by, 100 * s, bh, 'Cancel', false, a)

  elseif st.screen == 'installing' then
    ctx:txt(x0, y0 + 10 * s, OPT.existing and 'Updating' or 'Installing', { size = 22, weight = 600, alpha = a })
    local px, pw, py = x0, W - x0 * 2, y0 + 64 * s
    local th = 6 * s
    ctx:fill(K.rect(px, py, pw, th), T.line, a)
    local fw = pw * st.shown
    ctx:fill(K.rect(px, py, fw, th), T.accent, a)
    -- a glint runs along the filled part
    local g = (ts * 0.9) % 1
    local gx = px + (fw + 120 * s) * g - 120 * s
    local gl, gr = math.max(px, gx), math.min(px + fw, gx + 120 * s)
    if gr > gl then ctx:fill(K.rect(gl, py, gr - gl, th), T.accentBright, 0x80) end
    ctx:fill(K.rect(px + fw - 1 * s, py - 10 * s, 2 * s, th + 20 * s), T.signal, a)
    ctx:thumb(px + fw, py + th / 2, 8 * s, T.accentBright, a)
    ctx:txt(px, py + 36 * s, st.label, { size = 14, color = T.muted, alpha = a })
    ctx:txt(px + pw, py + 36 * s, string.format('%3d%%', math.floor(st.shown * 100 + 0.5)), { size = 15, mono = true, weight = 600, an = 6, color = T.accentBright, alpha = a })

  elseif st.screen == 'done' then
    ctx:fill(K.cut(x0, y0, 44 * s, 44 * s, 8 * s), T.accent, a)
    ctx:icon('check', x0 + 10 * s, y0 + 10 * s, 24 * s, T.onAccent, a)
    ctx:txt(x0 + 64 * s, y0 + 12 * s, OPT.existing and 'Dōga is up to date.' or 'Dōga is installed.', { size = 22, weight = 600, alpha = a })
    local where = 'Find it in the Start menu' .. (st.desktop and ' and on your desktop.' or '.')
    ctx:txt(x0 + 64 * s, y0 + 36 * s, where, { size = 14, color = T.muted, alpha = a })
    local ly = y0 + 92 * s
    if OPT.auto then
      ctx:txt(x0 + 64 * s, ly - 10 * s, 'Reopening Dōga…', { size = 14, color = T.accentBright, alpha = a })
    elseif st.assoc then
      ctx:fill(K.cut(x0, ly, math.min(W - x0 * 2, 640 * s), 64 * s, 6 * s), T.surface1, a)
      ctx:icon('info', x0 + 16 * s, ly + 20 * s, 24 * s, T.signal, a)
      ctx:txt(x0 + 52 * s, ly + 22 * s, 'One more step to open videos with Dōga', { size = 14, weight = 600, alpha = a })
      ctx:txt(x0 + 52 * s, ly + 44 * s, 'Windows asks you to pick the default player yourself.', { size = 12, color = T.muted, alpha = a })
      local ow = 168 * s
      local obx = x0 + math.min(W - x0 * 2, 640 * s) - ow - 12 * s
      button(ctx, 'defaults', obx, ly + 12 * s, ow, 40 * s, 'Open Default apps', false, a)
    end
    if OPT.dry then
      ctx:txt(x0, by + bh / 2, 'Dry run: files were copied; shortcuts and registry were skipped.', { size = 12, color = T.signal, alpha = a })
    end
    button(ctx, 'launch', bx, by, bwid, bh, 'Launch Dōga', true, a)
    button(ctx, 'close', bx - 112 * s, by, 100 * s, bh, 'Close', false, a)

  elseif st.screen == 'error' then
    ctx:txt(x0, y0 + 10 * s, 'Setup couldn’t finish', { size = 22, weight = 600, color = T.danger, alpha = a })
    ctx:txt(x0, y0 + 46 * s, K.fit(st.err or '', W - x0 * 2, 14 * s), { size = 14, color = T.muted, alpha = a })
    button(ctx, 'retry', bx, by, bwid, bh, 'Try again', true, a)
    button(ctx, 'close', bx - 112 * s, by, 100 * s, bh, 'Close', false, a)
  end

  ctx:intro_scan(t, W, H)
  ov.res_x, ov.res_y = W, H
  ov.data = table.concat(ctx.out, '\n')
  ov:update()
end

local start_install -- defined below

-- 60 fps while something moves; otherwise render on input
mp.add_periodic_timer(1 / 60, function()
  local now = mp.get_time()
  if st.screen == 'installing' then
    -- ease the bar toward the real progress so short installs still read
    st.shown = st.shown + (st.target - st.shown) * 0.12
    if st.target >= 1 and st.shown > 0.995 and st.done_at and now - st.done_at > 0.35 then
      st.shown = 1
      go(st.final or 'done')
    end
  end
  -- update mode: install by itself after the intro, then reopen Dōga
  if OPT.auto then
    if st.screen == 'welcome' and not st.auto_started and now - st.t0 > 1.4 then
      st.auto_started = true
      start_install()
    elseif st.screen == 'done' and not st.auto_launched and now - st.screen_t0 > 1.2 then
      st.auto_launched = true
      mp.commandv('script-message-to', 'main', 'setup-launch', st.dir)
    end
  end
  if now - st.t0 < 1.5 or now - st.screen_t0 < 0.4 or st.screen == 'installing' then render() end
end)

---------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------
start_install = function()
  st.target, st.shown, st.label, st.done_at, st.final = 0, 0, 'Preparing', nil, nil
  go('installing')
  mp.commandv('script-message-to', 'main', 'setup-install', st.dir, st.desktop and '1' or '0', st.assoc and '1' or '0')
end

local ACT = {
  browse = function() mp.commandv('script-message-to', 'main', 'setup-browse') end,
  ['opt-desktop'] = function() st.desktop = not st.desktop end,
  ['opt-assoc'] = function() st.assoc = not st.assoc end,
  install = start_install,
  retry = start_install,
  cancel = function() mp.commandv('quit') end,
  close = function() mp.commandv('quit') end,
  launch = function() mp.commandv('script-message-to', 'main', 'setup-launch', st.dir) end,
  defaults = function() mp.commandv('script-message-to', 'main', 'setup-default-apps') end,
}

mp.add_forced_key_binding('MBTN_LEFT', 'setup-left', function(e)
  if e.event == 'down' then
    if mp.get_time() - st.t0 < 1.2 then st.t0 = mp.get_time() - 10 end -- click skips the intro
    local z = hit()
    st.press = z and z.id
    render()
  elseif e.event == 'up' then
    local z = hit()
    local id = st.press
    st.press = nil
    if z and z.id == id and ACT[id] then ACT[id]() end
    render()
  end
end, { complex = true })

mp.add_forced_key_binding('ENTER', 'setup-enter', function()
  if st.screen == 'welcome' then start_install()
  elseif st.screen == 'done' then ACT.launch()
  elseif st.screen == 'error' then start_install() end
end)
mp.add_forced_key_binding('ESC', 'setup-esc', function()
  if st.screen ~= 'installing' then mp.commandv('quit') end
end)
-- the window's close button: the same, so files are never left half-copied
mp.add_forced_key_binding('CLOSE_WIN', 'setup-close', function()
  if st.screen ~= 'installing' then mp.commandv('quit') end
end)

mp.observe_property('mouse-pos', 'native', function(_, m)
  if not m then return end
  st.mx, st.my = m.x, m.y
  render()
end)
mp.observe_property('osd-dimensions', 'native', function(_, d)
  if not d then return end
  st.w, st.h = d.w, d.h
  -- the layout is designed at 880 × 560; scale it to the window, whatever the DPI
  st.s = math.max(0.75, math.min(d.w / 880, d.h / 560))
  render()
end)

---------------------------------------------------------------------------
-- messages from the host
---------------------------------------------------------------------------
mp.register_script_message('setup-dir', function(d) st.dir = d; render() end)
mp.register_script_message('setup-progress', function(f, label)
  st.target = math.max(st.target, tonumber(f) or 0)
  if label and label ~= 'Done' then st.label = label end
end)
mp.register_script_message('setup-done', function(state, m)
  if state == 'ok' then
    st.target, st.done_at, st.final = 1, mp.get_time(), 'done'
  else
    st.err = m
    go('error')
  end
  render()
end)
