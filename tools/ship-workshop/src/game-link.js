// ASTROSPIKE game link. scripts/ships.py appends this after Codex's
// workshop (codex-workshop.html, kept untouched) together with
// window.ASTROSPIKE_SHIPS, the game's ASTROSPIKECore/Ships.json.
//
// Everything the game reads that Codex's page has no field for -- the look
// (bolt, beam, flame, smoke, nozzles), exhaust width, role, blurb -- rides
// on design.effects.game. Codex's validators ignore extra keys there, so
// undo, saved ships, backups and series drafts all carry it untouched.
// "Download for game" writes a whole Ships.json: slots never saved here are
// copied verbatim, so an export with no edits is byte-for-byte a no-op.
(() => {
  const GAME = window.ASTROSPIKE_SHIPS;
  const SLOTS = [...GAME.hulls, ...GAME.concepts];
  const HULL_COUNT = GAME.hulls.length;
  const HULL_KEY = 'astrospike-game-hulls-v1', SLOT_KEY = 'astrospike-game-slot';
  // Mirrors HullLook.limits in ASTROSPIKECore/HullLook.swift.
  const LIMITS = {
    smokeSize: [0.2, 3], smokeLife: [0.2, 3], smokeOpacity: [0.1, 2], smokeAmount: [0, 3],
    flameLength: [0.3, 2.5], flicker: [0, 0.5], nozzles: [1, 3], nozzleSpacing: [0, 40],
    nozzleY: [-19, 0], exhaustWidth: [0.3, 3],
  };
  const BOLTS = ['needle', 'slug', 'wave', 'chevron', 'block', 'shard', 'twin', 'orb'];
  const BEAMS = ['dashes', 'pulses', 'ripples', 'chevrons', 'heavy', 'glitch', 'twin', 'sparkle'];
  const SMOKES = ['vapour', 'soot', 'bubbles', 'wisps', 'glitter'];

  const clamp = (v, [a, b]) => Math.min(b, Math.max(a, v));
  const round3 = v => Math.round(v * 1000) / 1000;
  const hex = c => '#' + c.map(x => Math.round(clamp(x, [0, 1]) * 255).toString(16).padStart(2, '0')).join('');
  const rgb = h => [1, 3, 5].map(i => round3(parseInt(h.slice(i, i + 2), 16) / 255));
  const make = (tag, props = {}) => Object.assign(document.createElement(tag), props);

  let hullStore = {};
  try { hullStore = JSON.parse(localStorage.getItem(HULL_KEY) || '{}') || {}; } catch {}
  const saveHulls = () => { try { localStorage.setItem(HULL_KEY, JSON.stringify(hullStore)); } catch { status('Browser storage unavailable. Download for game to keep your hulls.'); } };
  let slot = 0;
  try { let s = Number(localStorage.getItem(SLOT_KEY)); if (Number.isInteger(s) && s >= -1 && s < SLOTS.length) slot = s; } catch {}

  const slotLabel = i => i < HULL_COUNT ? `Hull ${i + 1} · ${SLOTS[i].id}` : `Concept ${String(i - HULL_COUNT + 1).padStart(3, '0')}`;
  // A slot's saved work: hulls in their own store, concepts in Codex's
  // Series 01 drafts so its Collection and Review screens see the same ship.
  function slotDraft(i) {
    if (i < HULL_COUNT) return hullStore[SLOTS[i].id] || null;
    return seriesDrafts[seriesConfig[i - HULL_COUNT].id] || null;
  }

  // Codex's own engine fields, for a ship drawn in Codex's page before the
  // game link existed: carry its flame and smoke over as closely as the
  // game's look can hold them.
  function customisedCodex(e) { return e && Object.keys(DEFAULT_EFFECTS).some(k => k !== 'enabled' && e[k] !== DEFAULT_EFFECTS[k]); }
  function fromCodex(e, g) {
    const L = g.look;
    L.flame = rgb(e.flameColor); L.flameCore = rgb(e.coreColor); L.smoke = rgb(e.smokeColor);
    L.nozzles = clamp(e.nozzles, LIMITS.nozzles);
    L.nozzleSpacing = round3(clamp(e.spacing, LIMITS.nozzleSpacing));
    L.nozzleY = round3(clamp(e.nozzleY, LIMITS.nozzleY));
    L.flameLength = round3(clamp(e.flameLength / 13, LIMITS.flameLength));
    L.flicker = round3(clamp(e.pulse / 200, LIMITS.flicker));
    L.smokeStyle = { Puffs: 'soot', Mist: 'vapour', Streaks: 'wisps' }[e.smokeStyle] || L.smokeStyle;
    L.smokeSize = round3(clamp(e.smokeSize / 2, LIMITS.smokeSize));
    L.smokeLife = round3(clamp(e.smokeLifetime / 1.5, LIMITS.smokeLife));
    L.smokeOpacity = round3(clamp(e.smokeOpacity / 35 * 0.8, LIMITS.smokeOpacity));
    L.smokeAmount = round3(clamp(e.smokeAmount / 35, LIMITS.smokeAmount));
    g.exhaustWidth = round3(clamp(e.flameWidth / 3, LIMITS.exhaustWidth));
  }
  // What the game would get for design d placed in slot i: its own game
  // fields if it has them, else Codex's engine fields if customised, else
  // the look of the game ship it was started from, else the slot's own.
  // Role and blurb always come from the slot until edited here.
  function gameOf(d, i = slot) {
    if (d.effects && d.effects.game) return d.effects.game;
    let start = SLOTS.findIndex(s => s.id === d.gameId);
    let base = SLOTS[start >= 0 ? start : i >= 0 ? i : 0], home = SLOTS[i >= 0 ? i : 0];
    let g = { look: clone(base.look), exhaustWidth: base.exhaustWidth, role: home.role, blurb: home.blurb };
    if (customisedCodex(d.effects)) fromCodex(d.effects, g);
    return g;
  }
  function ensureGame() {
    normalizeEffects(design);
    if (!design.effects.game) design.effects.game = clone(gameOf(design));
    return design.effects.game;
  }
  function toGame(d, i) {
    const g = gameOf(d, i);
    return {
      id: SLOTS[i].id, name: d.name.trim(), role: g.role, blurb: g.blurb, exhaustWidth: g.exhaustWidth,
      outline: { silhouette: clone(d.points), details: d.details.map(x => ({ points: clone(x.points), closed: x.closed })) },
      look: clone(g.look),
    };
  }
  const current = i => { let d = slotDraft(i); return d ? toGame(d, i) : SLOTS[i]; };
  const differs = i => JSON.stringify(current(i)) !== JSON.stringify(SLOTS[i]);

  // ---- Controls -----------------------------------------------------------
  // One field per game value. `get`/`set` read and write gameOf(design).
  let editing = false;
  function bind(input, apply) {
    input.addEventListener('input', () => {
      if (!editing) { checkpoint(); editing = true; }
      apply(ensureGame(), input.value);
      render();
    });
    input.addEventListener('change', () => { editing = false; persist(); });
  }
  const outputs = [];
  function control(label, kind, get, set, opts = {}) {
    const l = make('label', { className: 'field game-field' });
    const span = make('span', { textContent: label + ' ' });
    const out = make('output');
    span.append(out);
    let input;
    if (kind === 'select') { input = make('select'); opts.choices.forEach(c => input.add(new Option(c, c))); }
    else if (kind === 'text') { input = make('input', { type: 'text', maxLength: opts.max || 80 }); }
    else if (kind === 'color') { input = make('input', { type: 'color' }); }
    else { input = make('input', { type: 'range', min: opts.range[0], max: opts.range[1], step: opts.step || 0.05 }); }
    l.append(span, input);
    bind(input, (g, v) => set(g, kind === 'range' ? round3(clamp(Number(v), opts.range)) : kind === 'color' ? rgb(v) : v));
    outputs.push(g => {
      const v = get(g);
      if (document.activeElement !== input || kind !== 'text') input.value = kind === 'color' ? hex(v) : v;
      out.textContent = kind === 'range' ? (opts.whole ? v : Number(v).toFixed(2)) : '';
    });
    return l;
  }
  const look = (key, label, kind, opts) => control(label, kind, g => g.look[key], (g, v) => { g.look[key] = v; }, opts);
  const range = key => ({ range: LIMITS[key] });

  // ---- Engine panel: the game's flame and smoke replace Codex's fields ----
  const engine = groups.Exhaust.panel;
  // Codex's fields stay in the page (its saves and imports still read them)
  // but out of sight: the game never sees them.
  const animateRow = $('fxAnimate').closest('.row');
  for (const node of Array.from(engine.children)) node.style.display = 'none';
  engine.append(animateRow);
  engine.append(
    make('h2', { textContent: 'Flame' }),
    look('flame', 'Flame colour', 'color'),
    look('flameCore', 'Core colour', 'color'),
    look('flameLength', 'Flame length', 'range', range('flameLength')),
    look('flicker', 'Flicker', 'range', { range: LIMITS.flicker, step: 0.01 }),
    control('Flame width', 'range', g => g.exhaustWidth, (g, v) => { g.exhaustWidth = v; }, range('exhaustWidth')),
    look('nozzles', 'Nozzles', 'range', { range: LIMITS.nozzles, step: 1, whole: true }),
    look('nozzleSpacing', 'Nozzle spacing', 'range', { range: LIMITS.nozzleSpacing, step: 0.5 }),
    look('nozzleY', 'Nozzle position', 'range', { range: LIMITS.nozzleY, step: 0.5 }),
    make('h2', { textContent: 'Smoke' }),
    look('smokeStyle', 'Smoke style', 'select', { choices: SMOKES }),
    look('smoke', 'Smoke colour', 'color'),
    look('smokeAmount', 'Amount', 'range', range('smokeAmount')),
    look('smokeSize', 'Puff size', 'range', range('smokeSize')),
    look('smokeLife', 'Linger', 'range', range('smokeLife')),
    look('smokeOpacity', 'Thickness', 'range', range('smokeOpacity')),
  );

  // ---- Weapons and Game panels, ahead of More -----------------------------
  for (const name of ['Weapons', 'Game']) { makeCustomPanel(name); $('customTabs').insertBefore(groups[name].button, moreMenu); }
  const weapons = groups.Weapons.panel, game = groups.Game.panel;
  const canvas = make('canvas', { width: 640, height: 220, className: 'game-weapon-preview' });
  const weaponFields = make('div', { className: 'game-weapon-fields' });
  weaponFields.append(
    look('bolt', 'Bolt', 'select', { choices: BOLTS }),
    look('beam', 'Tractor beam', 'select', { choices: BEAMS }),
    look('primary', 'Beam and bolt colour', 'color'),
    look('secondary', 'Accent colour', 'color'),
  );
  weapons.append(canvas, weaponFields);

  const slotPicker = make('select', { id: 'gameSlot' });
  const openSlot = make('button', { textContent: 'Open slot' });
  const saveSlot = make('button', { textContent: 'Save to game slot', className: 'primary' });
  const resetSlot = make('button', { textContent: 'Reset slot' });
  const downloadGame = make('button', { textContent: 'Download for game', className: 'primary' });
  const slotNote = make('p', { className: 'game-note' });
  const gameStatus = make('p', { className: 'game-note' });
  const pickerField = make('label', { className: 'field game-slot-field' });
  pickerField.append(make('span', { textContent: 'Game slot' }), slotPicker);
  const actions = make('div', { className: 'game-actions' });
  actions.append(openSlot, saveSlot, resetSlot, downloadGame);
  game.append(
    pickerField,
    control('Role', 'text', g => g.role, (g, v) => { g.role = v; }, { max: 40 }),
    control('Blurb', 'text', g => g.blurb, (g, v) => { g.blurb = v; }, { max: 140 }),
    actions, slotNote, gameStatus,
  );

  function fillPicker() {
    slotPicker.replaceChildren(new Option('Not in game', '-1'));
    const hulls = make('optgroup', { label: 'Hulls' }), concepts = make('optgroup', { label: 'Concepts (unreleased)' });
    SLOTS.forEach((s, i) => (i < HULL_COUNT ? hulls : concepts).append(new Option(`${slotLabel(i)} · ${current(i).name}${differs(i) ? ' *' : ''}`, String(i))));
    slotPicker.append(hulls, concepts);
    slotPicker.value = String(slot);
  }
  function setSlot(i) {
    slot = i;
    try { localStorage.setItem(SLOT_KEY, String(i)); } catch {}
    slotPicker.value = String(i);
    syncGame();
  }
  slotPicker.onchange = () => { setSlot(Number(slotPicker.value)); render(); };

  function syncGame() {
    const g = gameOf(design);
    outputs.forEach(f => f(g));
    const edited = SLOTS.filter((_, i) => differs(i)).length;
    slotNote.textContent = slot < 0
      ? 'Pick the game slot this ship replaces. Nothing reaches the game until you Save to game slot, then Download for game.'
      : (slot === 0 ? 'Lancet\'s outline is the hitbox every ship uses online. Changing its shape changes online physics; the game\'s tests will ask for a wire bump. ' : '')
        + `Slot now holds “${current(slot).name}”${differs(slot) ? ' (edited here)' : ' (as in the game)'}.`
        + (slot >= 0 && slot < HULL_COUNT ? ' This hull flies in AstroCross too: same shape, flame and bolt colour.' : '');
    gameStatus.textContent = `${edited} of ${SLOTS.length} ships differ from the game. Download for game saves Ships.json; then run python3 scripts/ships.py import ~/Downloads/Ships.json in the ASTROSPIKE folder (or ask Claude to import it). Import writes both ASTROSPIKE and AstroCross.`;
    saveSlot.disabled = resetSlot.disabled = openSlot.disabled = slot < 0;
  }

  openSlot.onclick = () => {
    const draft = slotDraft(slot);
    checkpoint();
    design = draft ? clone(draft) : fresh(PRESETS[slot]);
    normalizeEffects(design);
    activeSavedShipId = null; editedSeriesIndex = null; activeEvolutionId = null; selected = -1; detailIndex = 0;
    render();
    status(`Opened ${slotLabel(slot)} “${design.name}”${draft ? ' (your saved version)' : ''}.`);
  };

  function nameClash(name, except) {
    const n = name.trim().toLowerCase();
    return SLOTS.findIndex((_, i) => i !== except && current(i).name.trim().toLowerCase() === n);
  }
  saveSlot.onclick = () => {
    if (slot < 0) return;
    if (!design.name.trim()) { status('Name the ship before saving it to the game.'); return; }
    if (!validDesign(design) || crossing()) { status('Fix crossed edges or invalid points before saving to the game.'); return; }
    const clash = nameClash(design.name, slot);
    if (clash >= 0) { status(`${slotLabel(clash)} is already called “${current(clash).name}”. Every ship needs its own name.`); return; }
    if (!confirm(`Put “${design.name}” into ${slotLabel(slot)}, replacing “${current(slot).name}”?`)) return;
    ensureGame();
    if (slot < HULL_COUNT) { hullStore[SLOTS[slot].id] = clone(design); saveHulls(); }
    else {
      const j = slot - HULL_COUNT;
      seriesDrafts[seriesConfig[j].id] = clone(design);
      conceptShips[j] = { ...conceptShips[j], name: design.name, points: clone(design.points), details: clone(design.details) };
      saveSeries();
    }
    persist(); fillPicker(); syncGame();
    status(`Saved “${design.name}” to ${slotLabel(slot)}. Download for game when you are ready to send it.`);
  };
  resetSlot.onclick = () => {
    if (slot < 0 || !slotDraft(slot)) { status(`${slotLabel(slot)} already matches the game.`); return; }
    if (!confirm(`Throw away your version of ${slotLabel(slot)} and go back to “${SLOTS[slot].name}”?`)) return;
    if (slot < HULL_COUNT) { delete hullStore[SLOTS[slot].id]; saveHulls(); }
    else {
      const j = slot - HULL_COUNT, p = PRESETS[slot];
      delete seriesDrafts[seriesConfig[j].id];
      conceptShips[j] = { ...conceptShips[j], name: p.name, points: clone(p.points), details: clone(p.details) };
      saveSeries();
    }
    fillPicker(); syncGame();
    status(`${slotLabel(slot)} is back to the game's “${SLOTS[slot].name}”.`);
  };

  downloadGame.onclick = () => {
    const ships = SLOTS.map((_, i) => current(i));
    const seen = new Map();
    for (const [i, s] of ships.entries()) {
      const n = s.name.trim().toLowerCase();
      if (!n) { status(`${slotLabel(i)} has no name.`); return; }
      if (seen.has(n)) { status(`${slotLabel(seen.get(n))} and ${slotLabel(i)} are both called “${s.name}”. Rename one first.`); return; }
      seen.set(n, i);
    }
    const file = { schema: GAME.schema, version: GAME.version, hulls: ships.slice(0, HULL_COUNT), concepts: ships.slice(HULL_COUNT) };
    const a = make('a', { download: 'Ships.json', href: URL.createObjectURL(new Blob([JSON.stringify(file, null, 2)], { type: 'application/json' })) });
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    status(`Downloaded Ships.json with ${SLOTS.filter((_, i) => differs(i)).length} edited ships.`);
  };

  // A starter shape that came from the game points the picker at its slot;
  // saving still asks first.
  const showPresetsBeforeGame = showPresets;
  showPresets = function () {
    showPresetsBeforeGame();
    document.querySelectorAll('.preset').forEach(b => {
      const start = b.onclick;
      b.onclick = () => { start(); const i = SLOTS.findIndex(s => s.id === design.gameId); if (i >= 0) setSlot(i); };
    });
  };
  $('collection').onchange = showPresets; $('search').oninput = showPresets; showPresets();
  const editCollectibleBeforeGame = $('editCollectible').onclick;
  $('editCollectible').onclick = () => { editCollectibleBeforeGame(); if (editedSeriesIndex !== null) setSlot(HULL_COUNT + editedSeriesIndex); };

  // ---- Stage preview: draw the game's flame and smoke ---------------------
  drawEffects = function (time = 1.25, group = fxGroup) {
    group.replaceChildren();
    const g = gameOf(design), L = g.look;
    const add = (tag, attrs) => group.append(element(tag, attrs));
    const y = -L.nozzleY, smoke = hex(L.smoke), flame = hex(L.flame), core = hex(L.flameCore);
    const offsets = Array.from({ length: L.nozzles }, (_, i) => (i - (L.nozzles - 1) / 2) * L.nozzleSpacing);
    const w = 3 * g.exhaustWidth * (L.nozzles > 1 ? 0.5 : 1);
    for (const [n, x] of offsets.entries()) {
      const amount = Math.round(12 * L.smokeAmount);
      for (let i = 0; i < amount; i++) {
        const age = ((i / Math.max(1, amount) + time / (1.5 * L.smokeLife)) % 1 + 1) % 1;
        const drift = Math.sin(i * 12.9 + n * 5) * 5 * age, py = y + 6 + age * (18 + L.smokeLife * 12);
        const r = 2 * L.smokeSize * (0.35 + age * 1.8), opacity = Math.min(1, 0.35 * L.smokeOpacity / 0.8) * (1 - age) ** 1.5;
        const cx = x + drift;
        switch (L.smokeStyle) {
          case 'vapour': add('ellipse', { cx, cy: py, rx: r, ry: r * 1.8, fill: smoke, opacity: opacity * 0.45 }); break;
          case 'wisps': add('path', { d: `M${cx} ${py} l${Math.sin(i) * r} ${r * 3}`, stroke: smoke, 'stroke-width': r * 0.5, opacity, fill: 'none', 'stroke-linecap': 'round' }); break;
          case 'bubbles': add('circle', { cx, cy: py, r, fill: 'none', stroke: smoke, 'stroke-width': 0.3, opacity }); break;
          case 'glitter': add('circle', { cx, cy: py, r: 0.25 + r * 0.15, fill: smoke, opacity: opacity * (0.5 + 0.5 * Math.abs(Math.sin(time * 9 + i))), style: 'mix-blend-mode:screen' }); break;
          default: add('circle', { cx, cy: py, r, fill: smoke, opacity });
        }
      }
      const flick = 1 + Math.sin(time * 23 + n * 2) * L.flicker, length = 13 * L.flameLength * flick;
      add('path', { d: `M${x - w / 2} ${y} Q${x - w * 0.7} ${y + length * 0.55} ${x} ${y + length} Q${x + w * 0.7} ${y + length * 0.55} ${x + w / 2} ${y} Z`, fill: flame, opacity: 0.7 });
      add('path', { d: `M${x - w * 0.22} ${y} L${x} ${y + length * 0.6} L${x + w * 0.22} ${y} Z`, fill: core, opacity: 0.95 });
      add('rect', { x: x - 1, y: y - 1.2, width: 2, height: 1.5, rx: 0.25, fill: '#17252e', stroke: '#a1b8bf', 'stroke-width': 0.2 });
    }
  };

  // ---- Weapons preview: the bolt in flight above, the beam below ----------
  const ctx = canvas.getContext('2d');
  const css = c => `rgb(${c.map(v => Math.round(v * 255)).join(',')})`;
  function puff(x, y, w, h, color, alpha = 1, rot = 0) {
    ctx.save(); ctx.translate(x, y); ctx.rotate(rot); ctx.scale(w / 2, h / 2);
    const grad = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
    grad.addColorStop(0, color); grad.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.globalAlpha = alpha; ctx.fillStyle = grad; ctx.beginPath(); ctx.arc(0, 0, 1, 0, Math.PI * 2); ctx.fill(); ctx.restore();
  }
  function shape(kind, x, y, size, color, alpha = 1, rot = 0, aspect = 1) {
    ctx.save(); ctx.translate(x, y); ctx.rotate(rot); ctx.scale(size / 2 * aspect, size / 2);
    ctx.globalAlpha = alpha; ctx.fillStyle = color; ctx.strokeStyle = color; ctx.lineWidth = 0.25; ctx.beginPath();
    if (kind === 'chevron') { ctx.moveTo(1, 0); ctx.lineTo(-0.6, 0.9); ctx.lineTo(-0.2, 0); ctx.lineTo(-0.6, -0.9); ctx.closePath(); ctx.fill(); }
    else if (kind === 'square') { ctx.rect(-1, -1, 2, 2); ctx.fill(); }
    else if (kind === 'diamond') { ctx.moveTo(1, 0); ctx.lineTo(0, 1); ctx.lineTo(-1, 0); ctx.lineTo(0, -1); ctx.closePath(); ctx.fill(); }
    else if (kind === 'ring') { ctx.arc(0, 0, 0.85, 0, Math.PI * 2); ctx.stroke(); }
    else if (kind === 'star') { for (let k = 0; k < 8; k++) { const r = k % 2 ? 0.25 : 1, a = k * Math.PI / 4; ctx.lineTo(Math.cos(a) * r, Math.sin(a) * r); } ctx.closePath(); ctx.fill(); }
    ctx.restore();
  }
  function drawBolt(L, t) {
    const P = css(L.primary), A = css(L.secondary), y = 60, x = 40 + ((t * 260) % 560);
    for (let k = 1; k <= 6; k++) puff(x - k * 14, y, 14 - k, 14 - k, P, 0.35 - k * 0.05);
    switch (L.bolt) {
      case 'needle': puff(x, y, 52, 12, P, 0.9); puff(x, y, 30, 4, A); break;
      case 'slug': puff(x, y, 44, 44, P, 0.9); puff(x, y, 19, 19, A); for (let k = 0; k < 4; k++) puff(x - 20 - ((t * 300 + k * 17) % 50), y + Math.sin(k * 3.1) * 12, 5, 5, A, 0.7); break;
      case 'wave': { const s = 0.85 + 0.3 * Math.sin(t * 35); puff(x, y, 18, 42 * s, P, 0.9); puff(x, y, 8, 22, A); break; }
      case 'chevron': shape('chevron', x, y, 34, P); puff(x, y, 10, 10, A); break;
      case 'block': shape('square', x, y, 30, P, 1, t * 12.6); shape('square', x, y, 14, A, 1, t * 12.6); break;
      case 'shard': shape('diamond', x, y, 26, P, Math.sin(t * 40) > 0 ? 1 : 0.25, 0, 40 / 26); shape('diamond', x, y, 10, A, 1, 0, 2); break;
      case 'twin': puff(x, y - 6, 20, 20, P, 0.9); puff(x, y + 6, 20, 20, P, 0.9); puff(x, y - 6, 8, 8, A); puff(x, y + 6, 8, 8, A); break;
      case 'orb': puff(x, y, 34, 34, P, 0.85); puff(x, y, 13, 13, A); for (let k = 0; k < 3; k++) shape('star', x - 10 - k * 9, y + Math.sin(t * 20 + k) * 7, 9, '#fff', 0.7, t * 3); break;
    }
  }
  function drawBeam(L, t) {
    const P = css(L.primary), A = css(L.secondary);
    const from = [70, 160], to = [560, 160], control = [315, 160 + 18 * Math.sin(t * (L.beam === 'ripples' ? 3 : 1.4))];
    // The ship's nose the beam pours into.
    ctx.save(); ctx.globalAlpha = 0.9; ctx.fillStyle = design.paint; ctx.beginPath(); ctx.moveTo(to[0] + 4, to[1]); ctx.lineTo(to[0] + 40, to[1] - 18); ctx.lineTo(to[0] + 40, to[1] + 18); ctx.closePath(); ctx.fill(); ctx.restore();
    const widths = { heavy: 5, pulses: 4.5, twin: 2.2, dashes: 2.2 };
    let alpha = 0.85;
    if (L.beam === 'pulses') alpha *= 0.6 + 0.4 * Math.abs(Math.sin(t * 5));
    if (L.beam === 'glitch' && Math.sin(t * 53) > 0.6) alpha *= 0.15;
    ctx.save(); ctx.strokeStyle = P; ctx.globalAlpha = alpha; ctx.lineWidth = widths[L.beam] || 3; ctx.lineCap = 'round';
    if (L.beam === 'dashes') { ctx.setLineDash([7, 6]); ctx.lineDashOffset = -t * 140; }
    if (L.beam === 'chevrons') { ctx.setLineDash([16, 7]); ctx.lineDashOffset = -t * 110; }
    for (const shift of L.beam === 'twin' ? [-4, 4] : [0]) {
      ctx.beginPath(); ctx.moveTo(from[0], from[1] + shift); ctx.quadraticCurveTo(control[0], control[1] + shift, to[0], to[1] + shift); ctx.stroke();
    }
    ctx.restore();
    // Motes pour in from the far end toward the nose.
    const count = { glitch: 9, heavy: 13, pulses: 13, ripples: 7 }[L.beam] || 18;
    for (let k = 0; k < count; k++) {
      const p = (k / count + t * 0.6) % 1, spread = Math.sin(k * 7.3) * 40 * (1 - p);
      const x = from[0] + (to[0] - from[0]) * p, y = from[1] + spread, color = k % 4 === 0 ? A : P, a = 0.8 * (0.3 + 0.7 * p);
      const inward = Math.atan2(to[1] - y, to[0] - x);
      switch (L.beam) {
        case 'dashes': puff(x, y, 18, 4, color, a, inward); break;
        case 'chevrons': shape('chevron', x, y, 13, color, a, inward); break;
        case 'ripples': shape('ring', x, y, 12, color, a); break;
        case 'glitch': shape('diamond', x, y, 11, color, a, inward); break;
        case 'sparkle': shape('star', x, y, 12, k % 2 ? '#fff' : color, a, t * 2 + k); break;
        case 'heavy': shape('square', x, y, 10, color, a, inward); break;
        default: puff(x, y, L.beam === 'pulses' ? 12 : 7, L.beam === 'pulses' ? 12 : 7, color, a);
      }
    }
  }
  function weaponFrame(now) {
    if (!weapons.hidden && !document.querySelector('.layout').hidden) {
      const t = $('fxAnimate').checked ? now / 1000 : 1.25, L = gameOf(design).look;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.fillStyle = '#0b1013'; ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.globalCompositeOperation = 'lighter';
      drawBolt(L, t); drawBeam(L, t);
      ctx.globalCompositeOperation = 'source-over';
    }
    requestAnimationFrame(weaponFrame);
  }
  requestAnimationFrame(weaponFrame);

  // ---- Labels and leftovers ----------------------------------------------
  $('swift').hidden = true;
  const exportIntro = groups.Export.panel.querySelector('small');
  if (exportIntro) exportIntro.textContent = 'Editable ship file restores this design. SVG is a picture. To send ships to the game, use the Game tab.';
  groups.Paint.panel.append(make('p', { className: 'game-note', textContent: 'Preview only. In a match the game fills every hull with its team colour; paint is not exported.' }));
  const hints = {
    Exhaust: 'The flame and smoke the game draws behind this ship.',
    Weapons: 'This ship\'s bolts and tractor beam.',
    Game: 'Choose which game ship this replaces, save it there, then download Ships.json.',
  };
  const openPanelBeforeGame = openCustomPanel;
  openCustomPanel = function (name) {
    openPanelBeforeGame(name);
    if (hints[name]) saveExplanation.textContent = hints[name] + ' Save ship keeps your working design.';
    if (name === 'Game') { fillPicker(); syncGame(); }
  };
  const renderBeforeGame = render;
  render = function () { renderBeforeGame(); syncGame(); };

  fillPicker();
  render();
})();
