-- PocketRush : mini simulateur FPV (drone, avion, aile volante) dans ta radio EdgeTX
-- PocketRush: a tiny FPV simulator (quad, plane, flying wing) running on your EdgeTX radio
-- https://github.com/starman-tech/PocketRush
--
-- Copyright (C) 2026 starman-tech
-- Ce programme est un logiciel libre : GNU General Public License version 3 (voir LICENSE).
-- This program is free software under the GNU General Public License v3 (see LICENSE).
--
-- Ecrans noir et blanc 212x64 (Taranis X9D / X9D+ / X9E, en niveaux de gris) et ecrans couleur.
-- Installation : copier ce fichier dans /SCRIPTS/TOOLS/ de la carte SD de la radio.
-- Lancement : touche SYS -> page OUTILS -> "PocketRush". Records gardes dans /SCRIPTS/TOOLS/PocketRush.rec
-- ATTENTION : le script lit les vrais manches et interrupteurs. Choisis avant un modele qui n'emet pas,
-- sinon un appareil allume et arme reagirait aussi.
--
-- Interrupteurs : SF = armer / desarmer (gaz a zero pour armer)
--                 SE = mode : haut ANGLE (STAB), milieu HORIZON, bas ACRO (MANUEL)
--                 SH = recommencer au depart
-- Menu          : molette pour choisir une ligne, ENT pour la modifier (molette), ENT pour valider ;
--                 "> VOLER" puis ENT pour partir. En vol : ENT recommence, EXIT revient au menu.
-- Avion / aile  : lancement a la main en mettant les gaz une fois arme.
local toolName = "TNS|PocketRush|TNE"

local W, H = LCD_W or 212, LCD_H or 64
local XMAX, YMAX = W - 1, H - 1
local CX, CY = W / 2, H / 2
local COLOR = lcd.RGB ~= nil and W > 212
local sin, cos, sqrt, abs, floor, atan = math.sin, math.cos, math.sqrt, math.abs, math.floor, math.atan
local asin, rad, fmt, mmax, mmin, PI = math.asin, math.rad, string.format, math.max, math.min, math.pi
local G = 9.81
local NEAR, EYE = 0.3, 0.2                      -- coupe avant de la camera ; hauteur camera, en m
local FPROJ = (W / 2) / math.tan(rad(60))       -- champ de vision horizontal de 120 deg
local SOLIDL = SOLID or 0
local SML, INV, RGT, MID = SMLSIZE or 0, INVERS or 0, RIGHT or 0, MIDSIZE or 0
local FONT = COLOR and 0 or SML                 -- police du HUD
local TH = COLOR and 18 or 7                    -- hauteur d'une ligne de texte
local RECFILE = "/SCRIPTS/TOOLS/PocketRush.rec"
local MODESW = getValue("se") ~= nil and "se" or "sa"   -- pas de SE (Q X7...) : modes sur SA
local MODESWN = string.upper(MODESW)
local NARROW = W < 200                          -- ecrans 128x64

-- couleurs : ecran couleur, ou 16 niveaux de gris (repli noir et blanc si GREY n'existe pas)
local C = {}
if COLOR then
  local rgb = lcd.RGB
  C.sky, C.ground, C.grid = rgb(120, 175, 240), rgb(95, 150, 70), rgb(65, 110, 45)
  C.line, C.gate, C.gate2, C.pole = rgb(20, 20, 20), rgb(255, 110, 0), rgb(255, 200, 140), rgb(90, 60, 30)
  C.txt, C.bg, C.ghost = rgb(255, 255, 255), rgb(0, 0, 0), rgb(200, 0, 200)
else
  C.ground = GREY and GREY(3) or nil
  C.grid = GREY and GREY(8) or 0
  C.gate2 = GREY and GREY(9) or 0
  C.ghost = GREY and GREY(6) or 0
  C.line, C.gate, C.pole = 0, 0, 0
end

local function clamp(v, a, b)
  if v < a then return a elseif v > b then return b end
  return v
end

-- ---------------------------------------------------------------- reglages (menu)
local VEH = { "DRONE", "AVION", "AILE" }
local COURSES = { "OVALE", "HUIT", "VAGUE" }
local MODES = { { "ACRO", "ANGLE", "HORIZ" }, { "MANUEL", "STAB", "HORIZ" } }
-- rates facon Betaflight : rc = RC rate x10, sup = super rate x100, expo = expo x100
local set = { veh = 1, course = 1, rc = 10, sup = 70, expo = 20, tilt = 15, power = 4, wind = 0, grid = 2 }
local SETTINGS = {
  { key = "veh", label = "Appareil", min = 1, max = 3, step = 1, names = VEH },
  { key = "course", label = "Circuit", min = 1, max = 3, step = 1, names = COURSES },
  { key = "rc", label = "RC rate", min = 5, max = 25, step = 1, div = 10 },
  { key = "sup", label = "Super rate", min = 0, max = 90, step = 5, div = 100 },
  { key = "expo", label = "Expo", min = 0, max = 80, step = 5, div = 100 },
  { key = "tilt", label = "Camera drone (deg)", min = 0, max = 50, step = 5 },
  { key = "power", label = "Puissance", min = 2, max = 10, step = 1 },
  { key = "wind", label = "Vent (m/s)", min = 0, max = 12, step = 2 },
  { key = "grid", label = "Sol 0=uni 2=dense", min = 0, max = 2, step = 1 },
}
local sel, editing = 0, false                   -- ligne choisie (0 = VOLER), modification en cours

-- ---------------------------------------------------------------- records (carte SD)
local best = {}                                -- cle = appareil * 10 + circuit
local function loadRecords()
  if not (io and io.open) then return end
  local f = io.open(RECFILE, "r")
  if not f then return end
  local s = io.read(f, 1024) or ""
  io.close(f)
  for v, c, t in string.gmatch(s, "(%d+) (%d+) ([%d%.]+)") do
    best[tonumber(v) * 10 + tonumber(c)] = tonumber(t)
  end
end

local function saveRecords()
  if not (io and io.open) then return end
  local f = io.open(RECFILE, "w")
  if not f then return end
  for k, t in pairs(best) do io.write(f, fmt("%d %d %.2f\n", floor(k / 10), k % 10, t)) end
  io.close(f)
end

-- ---------------------------------------------------------------- circuits
-- 8 portes le long d'une courbe fermee ; avion et aile : tout x2,2. Poteaux de decor autour.
local GATES, NG, POLES = {}, 8, {}
local scale, built = 0, 0
local HEIGHTS = { { 2.5, 3, 5, 2.5, 2, 4, 6, 3 }, { 3, 3, 4, 3, 3, 3, 4, 3 }, { 2, 8, 3, 12, 2, 10, 4, 14 } }

local function curve(c, t)                      -- point et tangente de la courbe du circuit
  if c == 2 then return 50 * sin(t), 25 * sin(2 * t), 50 * cos(t), 50 * cos(2 * t) end
  local A, B = (c == 1) and 45 or 40, (c == 1) and 25 or 30
  return A * cos(t), B * sin(t), -A * sin(t), B * cos(t)
end

local function buildCourse(s, c)
  scale, built = s, c
  for k = 1, NG do
    local t = (c == 2) and (PI / 8 + (k - 1) * PI / 4) or (-PI / 2 + (k - 1) * PI / 4)
    local x, y, tx, ty = curve(c, t)
    x, y = x * s, y * s
    local n = sqrt(tx * tx + ty * ty)
    tx, ty = tx / n, ty / n
    local g = { x = x, y = y, z = HEIGHTS[c][k] * s, nx = tx, ny = ty, rx = ty, ry = -tx, a = 2 * s, b = 1.5 * s }
    local function frame(a, b)
      local lx, ly = x - a * g.rx, y - a * g.ry
      local rx, ry = x + a * g.rx, y + a * g.ry
      local zb, zt = g.z - b, g.z + b
      return { lx, ly, zb, rx, ry, zb, rx, ry, zt, lx, ly, zt }
    end
    g.p = frame(g.a, g.b)                           -- cadre exterieur
    g.q = frame(g.a - 0.25 * s, g.b - 0.25 * s)     -- cadre interieur (porte en gras)
    GATES[k] = g
  end
  local hp = { 6, 9, 12, 6, 9, 12, 9 }
  POLES = {}
  for k = 1, NG do
    local th = -PI / 2 + (k - 0.5) * PI / 4
    for side = 1, 2 do
      local A2, B2 = ((side == 1) and 30 or 60) * s, ((side == 1) and 12 or 38) * s
      local tx, ty = -A2 * sin(th), B2 * cos(th)
      local n = sqrt(tx * tx + ty * ty)
      POLES[#POLES + 1] = { x = A2 * cos(th), y = B2 * sin(th), h = hp[(k + side) % #hp + 1] * s,
                            tx = tx / n * 0.8 * s, ty = ty / n * 0.8 * s, dz = 3 * s }
    end
  end
end

-- ---------------------------------------------------------------- etat
local px, py, pz, vx, vy, vz = 0, 0, 0, 0, 0, 0
local Fx, Fy, Fz, Lx, Ly, Lz, Ux, Uy, Uz = 1, 0, 0, 0, 1, 0, 0, 0, 1   -- axes avant / gauche / haut
local cFx, cFy, cFz, cLx, cLy, cLz, cUx, cUy, cUz = 1, 0, 0, 0, 1, 0, 0, 0, 1 -- axes de la camera
local screen = "menu"                          -- "menu", "fly", "crash"
local armed, armSwPrev, shPrev = false, false, false
local mode, veh, key = 2, 1, 11
local nextGate, gatesDone = 1, 0
local lapStart = nil
local lastTime, crashTime = nil, 0
local msgText, msgUntil = nil, 0
local thr01, speed = 0, 0
local wdir, wx, wy = 0, 0, 0                   -- vent : direction de base et vitesse actuelle
-- fantome du meilleur tour : positions toutes les 0,3 s, un seul garde en memoire (appareil + circuit)
local ghost, ghostKey, ghostRec, ghostT = nil, 0, {}, 0

local function message(txt, now, duration)
  msgText, msgUntil = txt, now + duration
end

local function tone(f, ms)
  if playTone then playTone(f, ms, 0) end
end

local function reset(now)
  veh = set.veh
  key = veh * 10 + set.course
  local s = (veh == 1) and 1 or 2.2
  if s ~= scale or set.course ~= built then buildCourse(s, set.course) end
  local g = GATES[1]
  local back = (veh == 1) and 15 or 45
  px, py, pz = g.x - g.nx * back, g.y - g.ny * back, 0
  vx, vy, vz = 0, 0, 0
  Fx, Fy, Fz = g.nx, g.ny, 0
  Lx, Ly, Lz = -g.ny, g.nx, 0
  Ux, Uy, Uz = 0, 0, 1
  nextGate, gatesDone, lapStart = 1, 0, nil
  armed, speed = false, 0
  wdir = math.random() * 2 * PI
  ghostRec = {}
  if key ~= ghostKey then ghost = nil end
  screen = "fly"
end

local function stick(name)
  local v = (getValue(name) or 0) / 1024
  if v > 1 then return 1 elseif v < -1 then return -1 end
  if abs(v) < 0.02 then return 0 end
  return v
end

-- vitesse de rotation en rad/s pour un manche v (-1..1), formule des rates Betaflight
local function bfRate(v)
  local a, e = abs(v), set.expo / 100
  local rc, sr = set.rc / 10, set.sup / 100
  if rc > 2 then rc = rc + 14.54 * (rc - 2) end
  local r = 200 * rc * v * (a * a * a * e + 1 - e)
  if sr > 0 then r = r / clamp(1 - a * sr, 0.01, 1) end
  return rad(r)
end

-- ---------------------------------------------------------------- physique commune
local function levelOnGround()
  -- pose a plat : garde seulement le cap
  local n = sqrt(Fx * Fx + Fy * Fy)
  if n < 1e-3 then Fx, Fy = 1, 0 else Fx, Fy = Fx / n, Fy / n end
  Fz, Lx, Ly, Lz, Ux, Uy, Uz = 0, -Fy, Fx, 0, 0, 0, 1
end

-- tourne les axes avec les vitesses angulaires p (roulis), q (tangage, + = nez en bas), r (lacet, + = gauche)
local function rotate(p, q, r, dt)
  local wxa = p * Fx + q * Lx + r * Ux
  local wya = p * Fy + q * Ly + r * Uy
  local wza = p * Fz + q * Lz + r * Uz
  local wn = sqrt(wxa * wxa + wya * wya + wza * wza)
  if wn > 1e-6 then
    local kx, ky, kz = wxa / wn, wya / wn, wza / wn
    local c, s = cos(wn * dt), sin(wn * dt)
    local c1 = 1 - c
    local d = kx * Fx + ky * Fy + kz * Fz
    local nx = Fx * c + (ky * Fz - kz * Fy) * s + kx * d * c1
    local ny = Fy * c + (kz * Fx - kx * Fz) * s + ky * d * c1
    local nz = Fz * c + (kx * Fy - ky * Fx) * s + kz * d * c1
    d = kx * Lx + ky * Ly + kz * Lz
    local mx = Lx * c + (ky * Lz - kz * Ly) * s + kx * d * c1
    local my = Ly * c + (kz * Lx - kx * Lz) * s + ky * d * c1
    local mz = Lz * c + (kx * Ly - ky * Lx) * s + kz * d * c1
    Fx, Fy, Fz, Lx, Ly, Lz = nx, ny, nz, mx, my, mz
  end
  local n = sqrt(Fx * Fx + Fy * Fy + Fz * Fz)
  Fx, Fy, Fz = Fx / n, Fy / n, Fz / n
  local d = Lx * Fx + Ly * Fy + Lz * Fz
  Lx, Ly, Lz = Lx - d * Fx, Ly - d * Fy, Lz - d * Fz
  n = sqrt(Lx * Lx + Ly * Ly + Lz * Lz)
  Lx, Ly, Lz = Lx / n, Ly / n, Lz / n
  Ux, Uy, Uz = Fy * Lz - Fz * Ly, Fz * Lx - Fx * Lz, Fx * Ly - Fy * Lx
end

-- vitesses angulaires "auto-stabilisees" : inclinaison visee proportionnelle au manche
-- (trim : assiette tenue manche au centre, quelques degres nez haut pour un avion)
local function levelRates(ail, ele, maxBank, maxPitch, k, trim)
  local bank = asin(clamp(Lz, -1, 1))
  local pitch = asin(clamp(Fz, -1, 1))
  return k * (ail * maxBank - bank), k * (pitch - trim + ele * maxPitch)
end

local function physicsDrone(dt, ail, ele, rud, thr)
  local p, q, r = bfRate(ail), bfRate(ele), -bfRate(rud)
  if mode ~= 1 then
    local pa, qa = levelRates(ail, ele, rad(55), rad(55), 7, 0)
    if mode == 2 then
      p, q, r = pa, qa, r * 0.5
    else
      local b = mmax(abs(ail), abs(ele))         -- HORIZON : stabilise au centre, acro au bout
      p, q = pa * (1 - b) + p * b, qa * (1 - b) + q * b
    end
  end
  rotate(p, q, r, dt)
  local T = thr * set.power * G                   -- poussee le long de l'axe haut
  local ax, ay, az = vx - wx, vy - wy, vz         -- vitesse par rapport a l'air
  local drag = 0.3 + 0.025 * sqrt(ax * ax + ay * ay + az * az)
  vx = vx + (Ux * T - drag * ax) * dt
  vy = vy + (Uy * T - drag * ay) * dt
  vz = vz + (Uz * T - G - drag * az) * dt
  px, py, pz = px + vx * dt, py + vy * dt, pz + vz * dt
  if pz <= 0 then
    if vz < -6 or (vx * vx + vy * vy) > 64 or Uz < 0.5 then return "crash" end
    pz = 0
    if vz < 0 then vz = 0 end
    vx, vy = vx * 0.8, vy * 0.8
    if T < G then levelOnGround() end
  end
end

-- avion / aile : portance proportionnelle a la vitesse-air au carre et a l'incidence, decrochage,
-- le nez suit la trajectoire (stabilite), gouvernes moins efficaces a basse vitesse
local function physicsPlane(dt, ail, ele, rud, thr)
  local wing = (veh == 3)
  local ax, ay, az = vx - wx, vy - wy, vz         -- vitesse par rapport a l'air
  local vF = ax * Fx + ay * Fy + az * Fz
  local vU = ax * Ux + ay * Uy + az * Uz
  local vL = ax * Lx + ay * Ly + az * Lz
  local alpha = (vF > 1) and atan(-vU / vF) or 0.4     -- incidence
  local beta = (vF > 1) and atan(vL / vF) or 0         -- glissade
  local kv = clamp(vF / 14, 0.15, 1.4)                 -- efficacite des gouvernes
  local p = bfRate(ail) * (wing and 0.65 or 0.5) * kv
  local q = bfRate(ele) * 0.3 * kv
  local r = wing and 0 or -bfRate(rud) * 0.15 * kv
  if mode ~= 1 then
    local pa, qa = levelRates(ail, ele, rad(60), rad(30), 4, rad(4))
    pa, qa = pa * kv, qa * kv
    if mode == 2 then
      p, q = pa, qa
    else
      local b = mmax(abs(ail), abs(ele))
      p, q = pa * (1 - b) + p * b, qa * (1 - b) + q * b
    end
  end
  q = q + 4 * (alpha - 0.05) * kv                     -- le nez revient sur la trajectoire (trim 3 deg)
  r = r + 4 * beta * kv
  local slow = clamp(1 - vF / 9, 0, 1)                -- trop lent : le nez tombe vers le sol
  if slow > 0 then
    q = q + 1.2 * slow * (Fx * Ly - Fy * Lx)
    r = r + 1.2 * slow * (Fx * Uy - Fy * Ux)
  end
  rotate(p, q, r, dt)
  -- forces (masse de 1 kg)
  local cl = alpha
  if abs(alpha) > 0.26 then                            -- decrochage au-dela de 15 deg
    cl = (alpha > 0 and 1 or -1) * mmax(0.04, 0.52 - abs(alpha))
  end
  local lift = (wing and 0.58 or 0.62) * vF * vF * cl
  local side = -0.4 * vL * abs(vF)
  local sp2 = ax * ax + ay * ay + az * az
  local sp = sqrt(sp2)
  local drag = (wing and 0.009 or 0.012) * sp2 + 0.006 * lift * lift / G
  local T = thr * set.power * 0.3 * G                  -- helice : poussee vers l'avant
  local fx = Fx * T + Ux * lift + Lx * side
  local fy = Fy * T + Uy * lift + Ly * side
  local fz = Fz * T + Uz * lift + Lz * side - G
  if sp > 0.01 then
    fx, fy, fz = fx - ax / sp * drag, fy - ay / sp * drag, fz - az / sp * drag
  end
  vx, vy, vz = vx + fx * dt, vy + fy * dt, vz + fz * dt
  px, py, pz = px + vx * dt, py + vy * dt, pz + vz * dt
  if pz <= 0 then
    if vz < -4 or Uz < 0.8 or sqrt(vx * vx + vy * vy) > 30 then return "crash" end
    pz = 0                                             -- atterrissage : il roule et freine
    if vz < 0 then vz = 0 end
    vx, vy = vx * (1 - 0.8 * dt), vy * (1 - 0.8 * dt)
    if lift < G then levelOnGround() end
  end
end

-- traversee des portes entre la position precedente (ox, oy, oz) et la position actuelle
local function checkGates(ox, oy, oz)
  local m = 0.35 * scale
  for k = 1, NG do
    local g = GATES[k]
    local s0 = (ox - g.x) * g.nx + (oy - g.y) * g.ny
    local s1 = (px - g.x) * g.nx + (py - g.y) * g.ny
    if (s0 < 0) ~= (s1 < 0) then
      local t = s0 / (s0 - s1)
      local xi, yi, zi = ox + (px - ox) * t, oy + (py - oy) * t, oz + (pz - oz) * t
      local au = abs((xi - g.x) * g.rx + (yi - g.y) * g.ry)
      local aw = abs(zi - g.z)
      if au < g.a and aw < g.b then
        if k == nextGate and s1 >= 0 then return "pass", k end
      elseif (au < g.a + m and aw < g.b + m) or (abs(au - g.a) < m and zi < g.z) then
        return "crash", k
      end
    end
  end
end

-- ---------------------------------------------------------------- dessin
local function clipPoint(x, y, ox, oy, h, v)
  if h == 1 then
    y = y + (oy - y) * (0 - x) / (ox - x); x = 0
  elseif h == 2 then
    y = y + (oy - y) * (XMAX - x) / (ox - x); x = XMAX
  elseif v == 1 then
    x = x + (ox - x) * (0 - y) / (oy - y); y = 0
  else
    x = x + (ox - x) * (YMAX - y) / (oy - y); y = YMAX
  end
  return x, y
end

-- trace un segment 2D en le coupant aux bords de l'ecran (Cohen-Sutherland)
local function line2d(x1, y1, x2, y2, col)
  for _ = 1, 5 do
    local h1 = (x1 < 0 and 1) or (x1 > XMAX and 2) or 0
    local v1 = (y1 < 0 and 1) or (y1 > YMAX and 2) or 0
    local h2 = (x2 < 0 and 1) or (x2 > XMAX and 2) or 0
    local v2 = (y2 < 0 and 1) or (y2 > YMAX and 2) or 0
    if h1 == 0 and v1 == 0 and h2 == 0 and v2 == 0 then
      lcd.drawLine(floor(x1 + 0.5), floor(y1 + 0.5), floor(x2 + 0.5), floor(y2 + 0.5), SOLIDL, col)
      return
    end
    if (h1 ~= 0 and h1 == h2) or (v1 ~= 0 and v1 == v2) then return end
    if h1 ~= 0 or v1 ~= 0 then
      x1, y1 = clipPoint(x1, y1, x2, y2, h1, v1)
    else
      x2, y2 = clipPoint(x2, y2, x1, y1, h2, v2)
    end
  end
end

-- trace un segment 3D vu par la camera (perspective + coupe derriere la camera)
local function seg(ax, ay, az, bx, by, bz, col)
  local ez = pz + EYE
  local dx, dy, dz = ax - px, ay - py, az - ez
  local za = dx * cFx + dy * cFy + dz * cFz
  local ya = dx * cLx + dy * cLy + dz * cLz
  local ua = dx * cUx + dy * cUy + dz * cUz
  dx, dy, dz = bx - px, by - py, bz - ez
  local zb = dx * cFx + dy * cFy + dz * cFz
  local yb = dx * cLx + dy * cLy + dz * cLz
  local ub = dx * cUx + dy * cUy + dz * cUz
  if za < NEAR then
    if zb < NEAR then return end
    local t = (NEAR - za) / (zb - za)
    za, ya, ua = NEAR, ya + (yb - ya) * t, ua + (ub - ua) * t
  elseif zb < NEAR then
    local t = (NEAR - zb) / (za - zb)
    zb, yb, ub = NEAR, yb + (ya - yb) * t, ub + (ua - ub) * t
  end
  line2d(CX - FPROJ * ya / za, CY - FPROJ * ua / za, CX - FPROJ * yb / zb, CY - FPROJ * ub / zb, col)
end

local function setCamera()
  local t = rad((veh == 1) and set.tilt or 5)
  local c, s = cos(t), sin(t)
  cFx, cFy, cFz = Fx * c + Ux * s, Fy * c + Uy * s, Fz * c + Uz * s
  cUx, cUy, cUz = Ux * c - Fx * s, Uy * c - Fy * s, Uz * c - Fz * s
  cLx, cLy, cLz = Lx, Ly, Lz
end

-- sol sous l'horizon : pour chaque ligne de l'ecran, la partie dont le rayon de vue descend
-- (composante verticale du rayon = A + B * x, lineaire le long de la ligne)
local function drawSky()
  if not C.ground then return end
  local B = -cLz / FPROJ
  local A0 = cFz + cLz * CX / FPROJ
  local st = COLOR and 2 or 1
  for y = 0, YMAX, st do
    local A = A0 - cUz * (y + st / 2 - CY) / FPROJ
    local x1, x2
    if abs(B) < 1e-6 then
      if A < 0 then x1, x2 = 0, XMAX end
    else
      local xs = -A / B
      if B > 0 then x1, x2 = 0, xs else x1, x2 = xs, XMAX end
      if x1 < 0 then x1 = 0 end
      if x2 > XMAX then x2 = XMAX end
      if x2 < x1 then x1 = nil end
    end
    if x1 then
      if st == 1 then
        lcd.drawLine(floor(x1 + 0.5), y, floor(x2 + 0.5), y, SOLIDL, C.ground)
      else
        lcd.drawFilledRectangle(floor(x1 + 0.5), y, floor(x2 - x1 + 1.5), st, C.ground)
      end
    end
  end
end

local function drawHorizon()
  -- deux directions horizontales lointaines devant la camera
  local hx, hy = cFx, cFy
  local n = sqrt(hx * hx + hy * hy)
  if n < 0.05 then return end
  hx, hy = hx / n, hy / n
  local x1, y1, x2, y2
  for i = 1, 2 do
    local k = (i == 1) and 1.2 or -1.2
    local dx, dy = hx - hy * k, hy + hx * k
    local z = dx * cFx + dy * cFy
    if z <= 0.01 then return end
    local sx = CX - FPROJ * (dx * cLx + dy * cLy) / z
    local sy = CY - FPROJ * (dx * cUx + dy * cUy) / z
    if i == 1 then x1, y1 = sx, sy else x2, y2 = sx, sy end
  end
  local ex, ey = x2 - x1, y2 - y1
  line2d(x1 - ex * 20, y1 - ey * 20, x2 + ex * 20, y2 + ey * 20, C.line)
end

local function drawGround()
  if set.grid == 0 then return end
  local S = 10
  if pz > 25 then S = 40 elseif pz > 8 then S = 20 end   -- plus haut : mailles plus grandes
  local R = (set.grid == 2) and S * 4 or S * 2
  local x0, y0 = floor(px / S) * S, floor(py / S) * S
  for i = -R, R, S do
    seg(x0 + i, y0 - R, 0, x0 + i, y0 + R, 0, C.grid)
    seg(x0 - R, y0 + i, 0, x0 + R, y0 + i, 0, C.grid)
  end
end

-- croix 3D (ombre au sol, fantome)
local function cross(x, y, z, hs, col)
  seg(x - hs, y, z, x + hs, y, z, col)
  seg(x, y - hs, z, x, y + hs, z, col)
  if z > 0 then seg(x, y, z - hs, x, y, z + hs, col) end
end

-- poteaux de decor, ombre et fantome
local function drawScenery(now)
  local far = 70 * scale
  for i = 1, #POLES do
    local o = POLES[i]
    local dx, dy = o.x - px, o.y - py
    if dx * dx + dy * dy < far * far and dx * cFx + dy * cFy + (o.h / 2 - pz) * cFz > -2 then
      seg(o.x, o.y, 0, o.x, o.y, o.h, C.pole)
      for z = o.dz, o.h, o.dz do
        seg(o.x - o.tx, o.y - o.ty, z, o.x + o.tx, o.y + o.ty, z, C.pole)
      end
    end
  end
  if pz > 0.3 then cross(px, py, 0, (veh == 1) and 0.6 or 1, C.line) end
  if ghost and ghostKey == key and lapStart then
    local i = floor((now - lapStart) / 30) * 3
    if ghost[i + 3] then cross(ghost[i + 1], ghost[i + 2], ghost[i + 3], (veh == 1) and 0.5 or 1.2, C.ghost) end
  end
end

local function drawFrame(q, col)
  seg(q[1], q[2], q[3], q[4], q[5], q[6], col)
  seg(q[4], q[5], q[6], q[7], q[8], q[9], col)
  seg(q[7], q[8], q[9], q[10], q[11], q[12], col)
  seg(q[10], q[11], q[12], q[1], q[2], q[3], col)
end

-- seulement la prochaine porte (en gras) et celle d'apres (plus claire) : ecran moins charge
local function drawGates()
  for i = 1, 2 do
    local k = (nextGate + i - 2) % NG + 1
    local g = GATES[k]
    local dx, dy, dz = g.x - px, g.y - py, g.z - pz
    if dx * cFx + dy * cFy + dz * cFz > -4 * scale then
      local q = g.p
      drawFrame(q, (i == 1) and C.gate or C.gate2)
      if i == 1 then drawFrame(g.q, C.gate) end
      seg(q[1], q[2], q[3], q[1], q[2], 0, C.gate2)
      seg(q[4], q[5], q[6], q[4], q[5], 0, C.gate2)
    end
  end
end

local function textWidth(txt, flags)
  if lcd.sizeText then return (lcd.sizeText(txt, flags)) end
  local fs = floor((flags or 0) / 256) % 8            -- taille de police (bits 8 a 10 des options)
  return #txt * ((fs == 2 and 4) or (fs == 3 and 8) or (fs == 4 and 11) or 6)
end

-- texte lisible sur le decor : blanc sur fond noir
local function hudText(x, y, txt, right)
  if COLOR then
    local w = textWidth(txt, FONT)
    if right then x = x - w end
    lcd.drawFilledRectangle(x - 2, y - 1, w + 4, TH, C.bg)
    lcd.drawText(x, y, txt, FONT + C.txt)
  else
    lcd.drawText(x, y, txt, SML + INV + (right and RGT or 0))
  end
end

-- repere de la prochaine porte : carre si elle est visible, fleche sur le bord sinon
local function drawTarget()
  local g = GATES[nextGate]
  local dx, dy, dz = g.x - px, g.y - py, g.z - pz
  local z = dx * cFx + dy * cFy + dz * cFz
  local y = dx * cLx + dy * cLy + dz * cLz
  local u = dx * cUx + dy * cUy + dz * cUz
  local m = COLOR and 6 or 2
  if z > NEAR then
    local sx, sy = CX - FPROJ * y / z, CY - FPROJ * u / z
    if sx >= m and sx <= XMAX - m and sy >= m and sy <= YMAX - m then
      lcd.drawRectangle(floor(sx) - m, floor(sy) - m, 2 * m + 1, 2 * m + 1, C.gate)
      return
    end
  end
  local ay = CY - TH / 2
  if u > abs(y) then ay = TH + 2 elseif -u > abs(y) then ay = YMAX - 2 * TH - 2 end
  if y > 0 then hudText(5, ay, "<<") else hudText(XMAX - 5, ay, ">>", true) end
end

local function drawHud(now)
  local names = MODES[(veh == 1) and 1 or 2]
  hudText(5, 1, armed and names[mode] or "DESARME")
  hudText(COLOR and 110 or 44, 1, fmt("P%d/%d", nextGate, NG))
  if lapStart then hudText(XMAX - 6, 1, fmt("%.1fs", (now - lapStart) / 100), true) end
  if best[key] then
    lcd.drawText(XMAX - 6, 1 + TH, fmt("rec %.1f", best[key]), FONT + RGT + (COLOR and C.line or 0))
  end
  hudText(5, YMAX - TH + 1, fmt("%dkm/h", floor(speed * 3.6 + 0.5)))
  hudText(XMAX - 6, YMAX - TH + 1, fmt("%.1fm", pz), true)
  local bw = COLOR and 6 or 2
  local hb = floor(thr01 * (H - 2) + 0.5)                -- barre des gaz sur le bord gauche
  if hb > 0 then lcd.drawFilledRectangle(0, H - hb, bw, hb, C.line) end
  -- variometre a droite : barre vers le haut quand on monte, vers le bas quand on descend
  local vmax = floor(H * 0.28)
  local vb = floor(clamp(vz / 8, -1, 1) * vmax + 0.5)
  lcd.drawLine(XMAX - bw - 2, CY, XMAX, CY, SOLIDL, C.line)
  if vb > 0 then lcd.drawFilledRectangle(XMAX - bw, CY - vb, bw + 1, vb, C.line)
  elseif vb < 0 then lcd.drawFilledRectangle(XMAX - bw, CY + 1, bw + 1, -vb, C.line) end
  local r = COLOR and 10 or 4
  lcd.drawLine(CX - r, CY, CX + r, CY, SOLIDL, C.line)  -- reticule
  lcd.drawLine(CX, CY - r + 1, CX, CY + r - 1, SOLIDL, C.line)
  if msgText and now < msgUntil then
    local f = MID + (COLOR and 0 or INV)
    local w = textWidth(msgText, f)
    if COLOR then
      lcd.drawFilledRectangle(CX - w / 2 - 6, CY - 3 * TH, w + 12, TH + 8, C.bg)
      lcd.drawText(CX - w / 2, CY - 3 * TH + 2, msgText, f + C.txt)
    else
      lcd.drawText(CX - w / 2, CY - 14, msgText, f)
    end
  end
end

local function drawMenu(now)
  local txt = COLOR and C.line or 0
  if COLOR then lcd.clear(C.sky) else lcd.clear() end
  lcd.drawFilledRectangle(0, 0, W, TH + 1, COLOR and C.bg or 0)
  lcd.drawText(2, 1, "POCKETRUSH", FONT + (COLOR and C.txt or INV))
  local rec = best[set.veh * 10 + set.course]
  if rec then
    lcd.drawText(XMAX - 2, 1, fmt("record %.1fs", rec), FONT + RGT + (COLOR and C.txt or INV))
  end
  -- liste qui defile sur les petits ecrans (ligne 0 = VOLER)
  local rows = floor((H - 2 * TH - 4) / TH)
  local first = clamp(sel - floor(rows / 2), 0, mmax(0, #SETTINGS - rows + 1))
  for i = first, mmin(#SETTINGS, first + rows - 1) do
    local yy = 2 + (i - first + 1) * TH
    local label, vt = "> VOLER", ""
    if i > 0 then
      local s = SETTINGS[i]
      local v = set[s.key]
      label = s.label
      vt = s.names and s.names[v] or (s.div and fmt("%.2f", v / s.div)) or tostring(v)
      if editing and i == sel then vt = "[" .. vt .. "]" end
    end
    if i == sel then
      if COLOR then
        lcd.drawFilledRectangle(0, yy - 1, W, TH, C.bg)
        lcd.drawText(4, yy, label, FONT + C.txt)
        lcd.drawText(XMAX - 4, yy, vt, FONT + RGT + C.txt)
      else
        lcd.drawText(4, yy, label, SML + INV)
        lcd.drawText(XMAX - 4, yy, vt, SML + RGT + INV)
      end
    else
      lcd.drawText(4, yy, label, FONT + txt)
      lcd.drawText(XMAX - 4, yy, vt, FONT + RGT + txt)
    end
  end
  if COLOR then
    local y0 = 2 + (#SETTINGS + 1) * TH
    local mx = 200 * set.rc / 10 / mmax(0.01, 1 - set.sup / 100)
    lcd.drawText(4, y0, fmt("rotation max %d deg/s   SF armer   %s mode : haut ANGLE, milieu HORIZON, bas ACRO", floor(mx), MODESWN), FONT + txt)
  end
  local help
  local phase = floor(now / 200) % (NARROW and 3 or 2)
  if phase == 0 then
    if NARROW then
      help = editing and "molette:regler ENT:valider" or "molette:choisir ENT:modifier"
    else
      help = editing and "molette : regler   ENT : valider" or "molette : choisir   ENT : modifier"
    end
  elseif COLOR then
    help = "! modele SIMU (rien n'emet)  -  SH depart  -  avion/aile : gaz pour lancer"
  elseif not NARROW then
    help = fmt("SF arme %s mode SH depart !SIMU", MODESWN)
  elseif phase == 1 then
    help = fmt("SF arme  %s mode  SH depart", MODESWN)
  else
    help = "! modele SIMU : rien n'emet"
  end
  lcd.drawText(2, YMAX - TH + 1, help, FONT + txt)
end

-- ---------------------------------------------------------------- touches
local function evIs(ev, ...)
  if not ev or ev == 0 then return false end
  for i = 1, select("#", ...) do
    local c = select(i, ...)
    if c ~= nil and ev == c then return true end
  end
  return false
end

local function keyEnter(ev) return evIs(ev, EVT_VIRTUAL_ENTER, EVT_ENTER_BREAK) end
local function keyExit(ev) return evIs(ev, EVT_VIRTUAL_EXIT, EVT_EXIT_BREAK) end
-- Sur les radios a molette, "suivant" et "augmenter" ont le meme code : on decide selon qu'on
-- modifie une valeur ou qu'on se deplace dans la liste, jamais les deux a la fois.
local function keyUp(ev)          -- molette a droite / touche +
  if editing then
    return evIs(ev, EVT_VIRTUAL_INC, EVT_VIRTUAL_INC_REPT, EVT_PLUS_BREAK, EVT_PLUS_REPT, EVT_ROT_RIGHT)
  end
  return evIs(ev, EVT_VIRTUAL_NEXT, EVT_VIRTUAL_NEXT_REPT, EVT_ROT_RIGHT, EVT_MINUS_BREAK, EVT_MINUS_REPT)
end
local function keyDown(ev)        -- molette a gauche / touche -
  if editing then
    return evIs(ev, EVT_VIRTUAL_DEC, EVT_VIRTUAL_DEC_REPT, EVT_MINUS_BREAK, EVT_MINUS_REPT, EVT_ROT_LEFT)
  end
  return evIs(ev, EVT_VIRTUAL_PREV, EVT_VIRTUAL_PREV_REPT, EVT_ROT_LEFT, EVT_PLUS_BREAK, EVT_PLUS_REPT)
end
local function keyPage(ev) return evIs(ev, EVT_VIRTUAL_NEXT_PAGE, EVT_PAGE_BREAK) end

-- ---------------------------------------------------------------- boucle principale
local function init()
  buildCourse(1, 1)
  loadRecords()
  screen = "menu"
end

local function runMenu(event, now)
  if keyExit(event) then
    if not editing then return 1 end
    editing = false
  elseif keyEnter(event) then
    if sel == 0 then
      reset(now)
      armSwPrev = (getValue("sf") or 0) > 0     -- deja sur "arme" : il faudra le rebasculer
      lastTime = now
      return 0
    end
    editing = not editing
  elseif keyPage(event) then
    editing, sel = false, (sel + 1) % (#SETTINGS + 1)
  else
    local up, down = keyUp(event), keyDown(event)
    if editing then
      local s = SETTINGS[sel]
      if up then set[s.key] = mmin(s.max, set[s.key] + s.step)
      elseif down then set[s.key] = mmax(s.min, set[s.key] - s.step) end
    elseif up then
      sel = (sel + 1) % (#SETTINGS + 1)
    elseif down then
      sel = (sel - 1) % (#SETTINGS + 1)
    end
  end
  drawMenu(now)
  return 0
end

local function onGatePassed(k, now)
  tone(1800, 60)
  if k == 1 then
    if lapStart and gatesDone >= NG then
      local lap = (now - lapStart) / 100
      if not best[key] or lap < best[key] then
        best[key] = lap
        ghost, ghostKey = ghostRec, key        -- le meilleur tour devient le fantome
        saveRecords()
        message(fmt("RECORD %.1fs", lap), now, 200)
        tone(2400, 200)
      else
        message(fmt("TOUR %.1fs", lap), now, 200)
      end
    end
    lapStart, gatesDone = now, 1
    ghostRec, ghostT = {}, now
  else
    gatesDone = gatesDone + 1
  end
  nextGate = k % NG + 1
end

local function step(dt, thr, now)
  local ox, oy, oz = px, py, pz
  if not armed or (veh > 1 and pz <= 0) then thr = 0 end   -- avion pose : pas de roulage, on le lance
  -- vent : rafales autour de la valeur reglee, direction qui varie un peu
  local t = now / 100
  local ws = set.wind * (1 + 0.35 * sin(0.7 * t) + 0.2 * sin(1.9 * t))
  local wd = wdir + 0.3 * sin(0.23 * t)
  wx, wy = ws * cos(wd), ws * sin(wd)
  local ail, ele, rud = stick("ail"), stick("ele"), stick("rud")
  local res
  if veh == 1 then
    res = physicsDrone(dt, ail, ele, rud, thr)
  else
    -- deux sous-pas : la portance reagit vite, l'integration reste stable
    res = physicsPlane(dt / 2, ail, ele, rud, thr)
    if res ~= "crash" then res = physicsPlane(dt / 2, ail, ele, rud, thr) end
  end
  speed = sqrt(vx * vx + vy * vy + vz * vz)
  -- enregistrement du tour en cours pour le fantome (toutes les 0,3 s, 90 s max)
  if lapStart and now - ghostT >= 30 and #ghostRec < 900 then
    ghostT = ghostT + 30
    ghostRec[#ghostRec + 1], ghostRec[#ghostRec + 2], ghostRec[#ghostRec + 3] = px, py, pz
  end
  local k
  if res ~= "crash" then res, k = checkGates(ox, oy, oz) end
  if res == "crash" then
    screen, crashTime = "crash", now
    message("CRASH !", now, 150)
    tone(300, 300)
  elseif res == "pass" then
    onGatePassed(k, now)
  end
end

local function run(event)
  local now = getTime()
  if screen == "menu" then return runMenu(event, now) end
  if keyExit(event) then screen = "menu"; return 0 end

  -- interrupteurs : SH (ressort) recommence, SE (ou SA) choisit le mode, SF arme
  local sh = (getValue("sh") or 0) > 0
  if keyEnter(event) or (sh and not shPrev) then reset(now) end
  shPrev = sh
  local se = getValue(MODESW) or 0
  mode = (se < -500 and 2) or (se > 500 and 1) or 3
  local armSw = (getValue("sf") or 0) > 0

  local dt = lastTime and (now - lastTime) / 100 or 0
  lastTime = now
  if dt > 0.06 then dt = 0.06 end

  local thr = (stick("thr") + 1) / 2
  thr01 = thr
  if screen == "crash" then
    if now - crashTime > 150 then reset(now) end
  else
    if not armed then
      if armSw and not armSwPrev then
        if thr < 0.08 then
          armed = true; msgText = nil; tone(1000, 80)
          if veh > 1 then message("GAZ POUR LANCER", now, 200) end
        else
          message("GAZ A ZERO", now, 150)
        end
      elseif not armSw and (not msgText or now >= msgUntil) then
        message("ARMER : SF", now, 50)
      elseif armSw and armSwPrev and (not msgText or now >= msgUntil) then
        message("REBASCULE SF", now, 50)
      end
    elseif not armSw then
      armed = false; tone(500, 120)
    end
    -- lancement a la main de l'avion / l'aile : arme, gaz au-dessus de 30 %
    if armed and veh > 1 and pz <= 0 and thr > 0.3 then
      -- lance nez releve de 10 deg a 13 m/s
      local c, s = cos(rad(10)), sin(rad(10))
      Fx, Fy, Fz, Ux, Uy, Uz = Fx * c + Ux * s, Fy * c + Uy * s, Fz * c + Uz * s, Ux * c - Fx * s, Uy * c - Fy * s, Uz * c - Fz * s
      pz = 1.5
      vx, vy, vz = Fx * 13, Fy * 13, Fz * 13
      msgText = nil
      tone(1400, 100)
    end
    -- desarme en l'air : plus de poussee ; desarme au sol : il reste pose
    if dt > 0 and (armed or pz > 0) then step(dt, thr, now) end
  end
  armSwPrev = armSw

  setCamera()
  if COLOR then lcd.clear(C.sky) else lcd.clear() end
  drawSky()
  drawGround()
  drawHorizon()
  drawScenery(now)
  drawGates()
  drawTarget()
  drawHud(now)
  return 0
end

-- acces pour les tests sur ordinateur (inutilise sur la radio)
if POCKETRUSH_TEST then
  POCKETRUSH_TEST.state = function()
    return px, py, pz, vx, vy, vz, Fx, Fy, Fz, Lx, Ly, Lz, Ux, Uy, Uz, nextGate, screen, armed, best[key], mode, veh
  end
  POCKETRUSH_TEST.place = function(x, y, z, vx_, vy_, vz_)
    px, py, pz, vx, vy, vz = x, y, z, vx_, vy_, vz_
  end
  POCKETRUSH_TEST.gate = function(k)
    local g = GATES[k]
    return g.x, g.y, g.z, g.nx, g.ny
  end
  POCKETRUSH_TEST.settings = set
  POCKETRUSH_TEST.rate = bfRate
  POCKETRUSH_TEST.ghost = function() return (ghost and ghostKey == key) and #ghost or 0 end
  POCKETRUSH_TEST.wind = function() return wx, wy end
end

return { init = init, run = run }
