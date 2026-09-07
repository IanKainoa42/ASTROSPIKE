"""Faithful Python port of ASTROSPIKECore simulation (for tuning only)."""
import math

class V:
    __slots__ = ('x', 'y')
    def __init__(self, x=0.0, y=0.0): self.x = float(x); self.y = float(y)
    def __add__(s, o): return V(s.x + o.x, s.y + o.y)
    def __sub__(s, o): return V(s.x - o.x, s.y - o.y)
    def __mul__(s, k): return V(s.x * k, s.y * k)
    __rmul__ = __mul__
    def __truediv__(s, k): return V(s.x / k, s.y / k)
    def dot(s, o): return s.x * o.x + s.y * o.y
    def length(s): return math.hypot(s.x, s.y)
    def copy(s): return V(s.x, s.y)
    def norm(s):
        l = s.length()
        return V(s.x / l, s.y / l) if l > 1e-12 else V(0, 0)
    def __repr__(s): return f"({s.x:.4f},{s.y:.4f})"


class Arena:
    def __init__(self, net_top=-0.46):
        self.halfWidth = 0.96
        self.floorY = -0.78
        self.ceilingY = 0.78
        self.netHalfWidth = 0.018
        self.netTopY = net_top
        self.goalInnerX = 0.018
        self.goalOuterX = 0.128
        self.goalMinimumDownwardSpeed = 0.25
    @property
    def opponentCrossingLimit(self): return self.halfWidth / 2
    def goalDefender(self, ball):
        if not (ball.vel.y < -self.goalMinimumDownwardSpeed): return None
        ax = abs(ball.pos.x)
        if not (self.goalInnerX <= ax <= self.goalOuterX): return None
        s = -1.0 if ball.pos.x < 0 else 1.0
        if not (ball.vel.x * s > 0.05): return None
        roof = self.floorY + (ax - self.goalInnerX)
        if not (ball.pos.y <= roof + ball.radius): return None
        return 'cyan' if ball.pos.x < 0 else 'orange'


class Ball:
    def __init__(self, pos, vel=None, radius=0.045):
        self.pos = pos; self.vel = vel or V(); self.radius = radius


class Ship:
    def __init__(self, pos, angle, vel=None, home=None):
        self.pos = pos; self.vel = vel or V(); self.angle = angle
        self.angularVelocity = 0.0; self.isDestroyed = False; self.thrustLevel = 0.0
        self.homeSide = home or ('cyan' if pos.x < 0 else 'orange')


class Config:
    def __init__(self, **kw):
        self.stepDuration = 1 / 120
        self.gravity = V(0, -2)
        self.initialThrustAcceleration = 5.5
        self.maximumThrustAcceleration = 5.5
        self.thrustRampRate = 0.0
        self.torqueAcceleration = 3.0
        self.ballGravityMultiplier = 0.72
        self.ballDropHeight = 0.60
        self.ballDropSpeed = 0.18
        self.serveDelay = 1.35
        self.allowedFloorBounces = 2
        self.minimumBallSeparationSpeed = 0.45
        self.crossingPushBack = 30.0
        self.crossingDrag = 5.0
        for k, v in kw.items(): setattr(self, k, v)


def opponent(t): return 'orange' if t == 'cyan' else 'cyan'


def swept_circle_time(start, end, center, radius):
    d = end - start
    off = start - center
    a = d.dot(d)
    if a <= 1e-7: return None
    b = 2 * off.dot(d)
    c = off.dot(off) - radius * radius
    disc = b * b - 4 * a * c
    if disc < 0: return None
    root = math.sqrt(disc)
    t = (-b - root) / (2 * a)
    return t if 0 <= t <= 1 else None


class Engine:
    def __init__(self, arena=None, config=None):
        self.arena = arena or Arena()
        self.config = config or Config()
        self.ships = {'cyan': Ship(V(-0.55, -0.55), math.pi / 2),
                      'orange': Ship(V(0.55, -0.55), math.pi / 2)}
        self.ball = Ball(V(0, 0.60))
        self.score = {'cyan': 0, 'orange': 0}
        self.floor_contacts = {'cyan': 0, 'orange': 0}
        self.phase = 'playing'
        self.tick = 0
        self.serveTicksRemaining = 0
        self.events = []
        self.contacts = []

    # ---- rules
    def _award(self, team, reason):
        self.score[team] += 1
        self.floor_contacts = {'cyan': 0, 'orange': 0}
        ev = [('point', team, reason)]
        pts, opp = self.score[team], self.score[opponent(team)]
        if pts >= 11 or (pts >= 7 and pts - opp >= 2):
            self.phase = 'finished'; ev.append(('matchEnded', team))
        else:
            self.phase = 'serve'
        return ev

    def resolve_rules(self, contacts):
        if self.phase != 'playing': return []
        for c in contacts:
            if c[0] == 'goal':
                return self._award(opponent(c[1]), 'goal')
        for c in contacts:
            if c[0] == 'ship':
                self.floor_contacts = {'cyan': 0, 'orange': 0}
            elif c[0] == 'cross':
                self.floor_contacts[c[1]] = 0
            elif c[0] == 'floor':
                self.floor_contacts[c[1]] += 1
                if self.floor_contacts[c[1]] > self.config.allowedFloorBounces:
                    return self._award(opponent(c[1]), 'thirdBounce')
        destr = [(c[1], c[2]) for c in contacts if c[0] == 'destroyed']
        teams = set(t for t, _ in destr)
        if len(teams) == 2:
            self.floor_contacts = {'cyan': 0, 'orange': 0}
            self.phase = 'serve'
            return [('rallyReset',)]
        if destr:
            return self._award(opponent(destr[0][0]), destr[0][1])
        return []

    # ---- collisions
    def swept_net_hit(self, start, end, radius):
        limit = self.arena.netHalfWidth + radius
        d = end - start
        if abs(start.x) <= limit and start.y - radius <= self.arena.netTopY:
            from_left = start.x <= 0
            pen = limit - abs(start.x)
            toward = d.x > 0 if from_left else d.x < 0
            if pen > 1e-7 or toward:
                return (V(-limit if from_left else limit, start.y), from_left)
        if abs(d.x) <= 1e-7:
            if abs(end.x) <= limit and end.y - radius <= self.arena.netTopY:
                return (V(-limit if start.x < 0 else limit, end.y), start.x < 0)
            return None
        from_left = start.x < 0
        boundary = -limit if from_left else limit
        crossed = end.x >= boundary if from_left else end.x <= boundary
        if not crossed: return None
        t = (boundary - start.x) / d.x
        if not (0 <= t <= 1): return None
        hy = start.y + d.y * t
        if hy - radius > self.arena.netTopY: return None
        return (V(boundary, hy), from_left)

    def swept_net_contact(self, start, end, radius):
        cap = V(0.0, self.arena.netTopY)
        cr = radius + self.arena.netHalfWidth
        t = swept_circle_time(start, end, cap, cr)
        end_overlap = (end - cap).length() <= cr
        if t is None and end_overlap: t = 1.0
        if t is not None:
            contact = start + (end - start) * t
            n = contact - cap
            l = n.length()
            n = V(-1 if start.x <= 0 else 1, 0) if l <= 1e-6 else n / l
            return (cap + n * cr, n)
        hit = self.swept_net_hit(start, end, radius)
        if hit is None: return None
        return (hit[0], V(-1.0 if hit[1] else 1.0, 0))

    def resolve_arena_collision(self, ship, prev, team, lethal, contacts, effects):
        R = 0.065
        nc = self.swept_net_contact(prev, ship.pos, R)
        if nc is not None:
            cpos, n = nc
            ship.pos = cpos
            inward = ship.vel.dot(n)
            if inward < 0: ship.vel = ship.vel - n * ((1 + 0.45) * inward)
            effects.append(('collision', ship.pos.copy(), abs(inward)))
        if ship.pos.y - R <= self.arena.floorY:
            ship.pos.y = self.arena.floorY + R
            ship.vel.y = max(0, -ship.vel.y * 0.12)
        if ship.pos.y + R >= self.arena.ceilingY:
            ship.pos.y = self.arena.ceilingY - R
            ship.vel.y = min(0, -ship.vel.y * 0.3)
        if ship.pos.x - R <= -self.arena.halfWidth:
            ship.pos.x = -self.arena.halfWidth + R
            ship.vel.x = max(0, -ship.vel.x * 0.3)
        if ship.pos.x + R >= self.arena.halfWidth:
            ship.pos.x = self.arena.halfWidth - R
            ship.vel.x = min(0, -ship.vel.x * 0.3)

    def destroy(self, ship, team, reason, contacts):
        if ship.isDestroyed: return
        ship.isDestroyed = True; ship.thrustLevel = 0
        contacts.append(('destroyed', team, reason))

    def resolve_ship_ship(self, prevs, lethal, contacts, effects):
        c, o = self.ships['cyan'], self.ships['orange']
        if c.isDestroyed or o.isDestroyed: return
        pc, po = prevs['cyan'], prevs['orange']
        rs, re = pc - po, c.pos - o.pos
        t = swept_circle_time(rs, re, V(0, 0), 0.13)
        if t is None: return
        impact = (c.vel - o.vel).length()
        n = rs + (re - rs) * t
        l = n.length()
        n = n / l if l > 1e-6 else V(-1, 0)
        closing = max(0.0, -(c.vel - o.vel).dot(n))
        if closing > 0:
            imp = n * (closing * 0.82)
            c.vel = c.vel + imp; o.vel = o.vel - imp
        effects.append(('collision', (c.pos + o.pos) / 2, impact))

    def resolve_ball_ship(self, prev_ball, prev_ships, contacts):
        ball_end = self.ball.pos
        earliest = None
        for team in ('cyan', 'orange'):
            s = self.ships[team]
            if s.isDestroyed: continue
            ps = prev_ships[team]
            axis = V(math.cos(s.angle), math.sin(s.angle))
            fixtures = [
                (ps - axis * 0.045, s.pos - axis * 0.045, 0.048),
                (ps, s.pos, 0.055),
                (ps + axis * 0.060, s.pos + axis * 0.060, 0.035),
            ]
            for f in fixtures:
                t = swept_circle_time(prev_ball - f[0], ball_end - f[1], V(0, 0),
                                      self.ball.radius + f[2])
                if t is None: continue
                if earliest is None or t < earliest[2]:
                    earliest = (team, f, t)
        if earliest is None: return
        team, f, t = earliest
        ship = self.ships[team]
        bc = prev_ball + (ball_end - prev_ball) * t
        fc = f[0] + (f[1] - f[0]) * t
        n = bc - fc
        l = n.length()
        n = n / l if l > 1e-6 else V(-1, 0)
        self.ball.pos = f[1] + n * (self.ball.radius + f[2])
        rel = self.ball.vel - ship.vel
        inward = rel.dot(n)
        if inward >= 0: return
        inv_ball, inv_ship = 1 / 0.45, 1 / 1.60
        imp = -(1 + 0.95) * inward / (inv_ball + inv_ship)
        self.ball.vel = self.ball.vel + n * imp * inv_ball
        ship.vel = ship.vel - n * imp * inv_ship
        floor_v = self.config.minimumBallSeparationSpeed
        if floor_v > 0:
            sep = (self.ball.vel - ship.vel).dot(n)
            if sep < floor_v:
                self.ball.vel = self.ball.vel + n * (floor_v - sep)
        contacts.append(('ship', team))

    def swept_net_cap_hit(self, start, end, radius):
        center = V(0.0, self.arena.netTopY)
        cr = radius + self.arena.netHalfWidth
        t = swept_circle_time(start, end, center, cr)
        if t is None: return None
        contact = start + (end - start) * t
        n = contact - center
        l = n.length()
        if l <= 1e-6: return None
        n = n / l
        if abs(n.x) < 0.02 and n.y > 0:
            idx = self.score['cyan'] + self.score['orange']
            n = V(-0.18 if idx % 2 == 0 else 0.18, 1).norm()
        if self.ball.vel.dot(n) >= 0: return None
        return (center + n * cr, n)

    def resolve_ball_collision(self, prev, contacts):
        g = self.arena.goalDefender(self.ball)
        if g is not None:
            contacts.append(('goal', g)); return
        r = self.ball.radius
        cap = self.swept_net_cap_hit(prev, self.ball.pos, r)
        if cap is not None:
            self.ball.pos, n = cap[0], cap[1]
            inward = self.ball.vel.dot(n)
            if inward < 0: self.ball.vel = self.ball.vel - n * ((1 + 0.94) * inward)
        else:
            nh = self.swept_net_hit(prev, self.ball.pos, r)
            if nh is not None:
                self.ball.pos = nh[0]
                self.ball.vel.x = (-abs(self.ball.vel.x) * 0.94 if nh[1]
                                   else abs(self.ball.vel.x) * 0.94)
            elif (prev.x < 0) != (self.ball.pos.x < 0):
                contacts.append(('cross', 'cyan' if self.ball.pos.x < 0 else 'orange'))
        a = self.arena
        if self.ball.pos.y - r <= a.floorY:
            self.ball.pos.y = a.floorY + r
            self.ball.vel.y = abs(self.ball.vel.y) * 0.90
            contacts.append(('floor', 'cyan' if self.ball.pos.x < 0 else 'orange'))
        if self.ball.pos.y + r >= a.ceilingY:
            self.ball.pos.y = a.ceilingY - r
            self.ball.vel.y = -abs(self.ball.vel.y) * 0.94
        if self.ball.pos.x - r <= -a.halfWidth:
            self.ball.pos.x = -a.halfWidth + r
            self.ball.vel.x = abs(self.ball.vel.x) * 0.94
        if self.ball.pos.x + r >= a.halfWidth:
            self.ball.pos.x = a.halfWidth - r
            self.ball.vel.x = -abs(self.ball.vel.x) * 0.94

    # ---- serve
    def stage_serve(self, team):
        x = 0.0 if team is None else (-self.arena.halfWidth / 2 if team == 'cyan'
                                      else self.arena.halfWidth / 2)
        self.ball = Ball(V(x, self.config.ballDropHeight), V(0, 0), self.ball.radius)
        self.serveTicksRemaining = max(1, round(self.config.serveDelay / self.config.stepDuration))

    def advance_serve(self):
        self.ball.vel = V(0, 0)
        if self.serveTicksRemaining > 0: self.serveTicksRemaining -= 1
        if self.serveTicksRemaining: return
        for team in ('cyan', 'orange'):
            s = self.ships[team]
            if s.isDestroyed:
                self.ships[team] = Ship(V(-0.55 if s.homeSide == 'cyan' else 0.55, -0.55),
                                        math.pi / 2, home=s.homeSide)
        self.ball.vel = V(0, -self.config.ballDropSpeed)
        self.floor_contacts = {'cyan': 0, 'orange': 0}
        self.phase = 'playing'

    def step(self, inputs):
        dt = self.config.stepDuration
        contacts, effects = [], []
        prevs = {t: self.ships[t].pos.copy() for t in ('cyan', 'orange')}
        lethal = False  # shipped Swift has no lethal path at all
        for team in ('cyan', 'orange'):
            ship = self.ships[team]
            if ship.isDestroyed: continue
            torque, thrust = inputs.get(team, (0.0, False))
            torque = max(-1.0, min(1.0, torque))
            ship.angularVelocity = torque * self.config.torqueAcceleration
            ship.angle += ship.angularVelocity * dt
            acc = self.config.gravity.copy()
            if thrust:
                ship.thrustLevel = (min(self.config.maximumThrustAcceleration,
                                        ship.thrustLevel + self.config.thrustRampRate * dt)
                                    if ship.thrustLevel > 0 else self.config.initialThrustAcceleration)
                acc = acc + V(math.cos(ship.angle), math.sin(ship.angle)) * ship.thrustLevel
            else:
                ship.thrustLevel = 0.0
            intrusion = 1.0 if ship.homeSide == 'cyan' else -1.0
            depth = ship.pos.x * intrusion - self.arena.opponentCrossingLimit
            if depth > 0:
                acc.x -= intrusion * self.config.crossingPushBack * depth
                acc = acc - ship.vel * (self.config.crossingDrag * min(1.0, depth / 0.20))
            ship.vel = ship.vel + acc * dt
            ship.pos = ship.pos + ship.vel * dt
            self.resolve_arena_collision(ship, prevs[team], team, lethal, contacts, effects)
        self.resolve_ship_ship(prevs, lethal, contacts, effects)

        if self.phase == 'serve':
            self.advance_serve()
            self.contacts = contacts
            self.events = effects
            self.tick += 1
            return
        prev_ball = self.ball.pos.copy()
        self.ball.vel = self.ball.vel + self.config.gravity * self.config.ballGravityMultiplier * dt
        self.ball.pos = self.ball.pos + self.ball.vel * dt
        self.resolve_ball_ship(prev_ball, prevs, contacts)
        self.resolve_ball_collision(prev_ball, contacts)
        self.contacts = contacts
        rule_events = self.resolve_rules(contacts)
        self.events = rule_events + effects
        if self.phase == 'serve':
            conceding = None
            for e in rule_events:
                if e[0] == 'point': conceding = opponent(e[1]); break
            self.stage_serve(conceding)
        self.tick += 1
