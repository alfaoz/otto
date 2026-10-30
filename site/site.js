// the opening's fingerprint: a Touch ID print in dots, read top to bottom once, with what agents did pinned to it.
// the pointer presses the dots under it. reduced motion gets the print already read.
const print = document.querySelector('.print');

if (print) {
  const canvas = print.querySelector('canvas');
  const svg = print.querySelector('svg');
  const tags = [...print.querySelectorAll('.tag')];
  const ctx = canvas.getContext('2d');
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const GAP = 4; // css px between dots
  const READ = 1800; // ms for the read to cross the print
  let W = 0, H = 0, dots = [], start = null, pointer = null, queued = false;

  const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
  const hash = (x, y) => { const s = Math.sin(x * 127.1 + y * 311.7) * 43758.5453; return s - Math.floor(s); };

  // where the dots are and how strong each is: ridges looping round a core, inside a fingertip
  function layout() {
    const box = print.getBoundingClientRect();
    W = box.width; H = box.height;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    dots = [];
    for (let py = GAP / 2; py < H; py += GAP) {
      for (let px = GAP / 2; px < W; px += GAP) {
        const x = (px - W * 0.5) / W, y = (py - H * 0.5) / W;
        const tip = 1 - smooth(0.7, 1, (x / 0.35) ** 2 + (y / (y < 0 ? 0.47 : 0.41)) ** 2);
        // a loop: rings round a short upright core, flattening into arcs across the bottom of the finger
        const cy = Math.min(Math.max(y, -0.07), 0.03);
        const ring = Math.hypot(x * 1.05, (y - cy) * 0.95);
        const base = 0.17 + (y - 0.1) * 1.1 + 0.9 * x * x;
        const low = smooth(0.06, 0.24, y);
        const warp = 0.011 * Math.sin(9 * x + 4 * y) + 0.008 * Math.sin(-7 * x + 11 * y + 1.3) + 0.006 * Math.sin(17 * x - 6 * y + 2);
        const phase = (ring * (1 - low) + base * low + warp) * Math.PI * 2 * 26;
        // the odd ridge ending, so it reads as skin and not as a drawing
        const breaks = smooth(0.12, 0.3, Math.abs(Math.sin(31 * x + 7 * Math.sin(13 * y)) * Math.sin(23 * y - 3 * x)));
        const ridge = smooth(0.3, 0.95, 0.5 + 0.5 * Math.cos(phase)) * (0.35 + 0.65 * breaks);
        const v = Math.min(1, ridge * tip * (0.78 + 0.44 * hash(px, py)));
        // a faint screen of dots around the print
        const field = 1 - smooth(0.15, 0.62, Math.hypot(x, y * 0.85));
        if (v < 0.05 && field < 0.03) continue;
        dots.push({ x: px, y: py, v: v < 0.05 ? 0 : v, field, at: py / H });
      }
    }
  }

  // each tag sits where its data-at says (anchor x y, tag x y, in % of the print), with a line to its anchor
  function pin() {
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
    svg.replaceChildren();
    const ns = 'http://www.w3.org/2000/svg';
    for (const tag of tags) {
      const [ax, ay, tx, ty] = tag.dataset.at.split(' ').map(Number);
      const a = { x: ax / 100 * W, y: ay / 100 * H };
      const w = tag.offsetWidth, h = tag.offsetHeight;
      const left = Math.min(Math.max(tx / 100 * W - w / 2, -W * 0.08), W * 1.08 - w);
      const top = ty / 100 * H - h / 2;
      tag.style.left = `${left}px`;
      tag.style.top = `${top}px`;
      const sx = Math.min(Math.max(a.x, left), left + w);
      const sy = a.y > top + h ? top + h : a.y < top ? top : top + h / 2;
      const line = document.createElementNS(ns, 'line');
      line.setAttribute('x1', sx); line.setAttribute('y1', sy);
      line.setAttribute('x2', a.x); line.setAttribute('y2', a.y);
      const mark = document.createElementNS(ns, 'rect');
      mark.setAttribute('x', a.x - 2.5); mark.setAttribute('y', a.y - 2.5);
      mark.setAttribute('width', 5); mark.setAttribute('height', 5);
      svg.append(line, mark);
      tag.pinned = { parts: [line, mark], at: ay / 100 };
    }
  }

  function draw(now) {
    queued = false;
    // how far the read has gone, in heights of the print: ahead of it the print is barely there, at it the dots flare
    const read = still || start === null ? (start === null && !still ? -1 : 2) : ((now - start) / READ) * 1.25 - 0.1;
    ctx.clearRect(0, 0, W, H);
    const buckets = Array.from({ length: 12 }, () => new Path2D());
    for (const d of dots) {
      const behind = read - d.at;
      const seen = behind >= 0;
      const flare = seen ? Math.max(0, 1 - behind / 0.07) : 0;
      let r, a;
      if (d.v) {
        r = GAP * 0.52 * d.v * (1 + 0.5 * flare);
        a = seen ? 0.35 + 0.65 * d.v : 0.07;
      } else {
        r = 0.75;
        a = d.field * (seen ? 0.22 : 0.08);
      }
      if (pointer) {
        const near = Math.hypot(d.x - pointer.x, d.y - pointer.y);
        if (near < 80) {
          const p = (1 - near / 80) ** 2;
          r *= 1 + 1.1 * p;
          a = Math.min(1, a + 0.35 * p);
        }
      }
      a = Math.min(1, a + flare * 0.5);
      if (r < 0.3 || a < 0.02) continue;
      const p = buckets[Math.min(11, Math.floor(a * 12))];
      p.moveTo(d.x + r, d.y);
      p.arc(d.x, d.y, r, 0, Math.PI * 2);
    }
    buckets.forEach((p, i) => {
      ctx.fillStyle = `rgba(240, 236, 226, ${(i + 0.5) / 12})`;
      ctx.fill(p);
    });
    for (const tag of tags) {
      const on = read >= tag.pinned.at;
      tag.classList.toggle('on', on);
      for (const part of tag.pinned.parts) part.classList.toggle('on', on);
    }
    if (!still && start !== null && read < 1.2) queue();
  }
  const queue = () => { if (!queued) { queued = true; requestAnimationFrame(draw); } };

  const ready = () => { layout(); pin(); queue(); };
  document.fonts.ready.then(ready);
  new ResizeObserver(() => { if (Math.abs(print.getBoundingClientRect().width - W) > 1) ready(); }).observe(print);
  new IntersectionObserver((seen, watcher) => {
    if (!seen.some((s) => s.isIntersecting)) return;
    watcher.disconnect();
    start = performance.now();
    queue();
  }, { threshold: 0.4 }).observe(print);

  if (matchMedia('(pointer: fine)').matches) {
    print.addEventListener('pointermove', (e) => {
      const box = print.getBoundingClientRect();
      pointer = { x: e.clientX - box.left, y: e.clientY - box.top };
      queue();
    });
    print.addEventListener('pointerleave', () => { pointer = null; queue(); });
  }
}

