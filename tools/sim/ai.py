import math
from sim import V, Arena, Config

def norm_angle(a):
    v = math.fmod(a, 2 * math.pi)
    if v > math.pi: v -= 2 * math.pi
    if v < -math.pi: v += 2 * math.pi
    return v

DIFF = {
    'rookie': dict(interval=24, aim=0.26, strike=1.8),
    'pilot':  dict(interval=12, aim=0.12, strike=2.5),
    'ace':    dict(interval=6,  aim=0.03, strike=3.2),
}

# flight controller
BRAKE = 2.0        # deceleration the guidance law counts on
VCAP = 2.6
ACCEL_GAIN = 3.5
THRUST_GATE = 0.34
TURN_GAIN = 4.0
TURN_DEADZONE = 0.06

class NewAI:
    STANDOFF = 0.145
    RUNUP = 0.24
    CARRY_LIMIT = 36
    DRIVE_WINDOW = 0.40
    HORIZON = 120       # 2.0 s at 60 Hz

    def __init__(self, difficulty='pilot', arena=None, config=None):
        self.d = difficulty
        self.arena = arena or Arena()
        self.config = config or Config()
        self.plan_tick = None
        self.shot = V(-1, 0)
        self.intercept = None
        self.has_intercept = False
        self.eta = 9.0
        self.aim_error = 0.0
        self.home = None
        self.carry = 0

    @property
    def p(self): return DIFF[self.d]

    def shot_from(self, point, home_sign):
        a = self.arena
        aim = V(-home_sign * 0.60, a.floorY + 0.22)
        shot = (aim - point).norm()
        if shot.x * home_sign > -0.35:
            shot = V(-home_sign * 0.35, shot.y).norm()
        headroom = max(0.0, min(1.0, (point.y - (a.netTopY + 0.10)) / 0.55))
        min_up = 0.62 - 0.48 * headroom
        if shot.y < min_up:
            shot = V(-home_sign * math.sqrt(max(0.0, 1 - min_up * min_up)), min_up)
        return shot

    def clamped(self, point, home_sign):
        a = self.arena
        p = point.copy()
        min_x = 0.12 if p.y < a.netTopY + 0.30 else 0.03
        if p.x * home_sign < min_x: p.x = home_sign * min_x
        if abs(p.x) > a.halfWidth - 0.10: p.x = home_sign * (a.halfWidth - 0.10)
        p.y = max(a.floorY + 0.14, min(a.ceilingY - 0.10, p.y))
        return p

    def plan(self, eng, ship, home_sign):
        a = self.arena
        top = a.netTopY + 0.75
        bottom = a.floorY + 0.26
        p, v, r = eng.ball.pos.copy(), eng.ball.vel.copy(), eng.ball.radius
        dt = 1 / 60
        g = self.config.gravity.y * self.config.ballGravityMultiplier
        speed = ship.vel.length()
        fallback = None
        for step in range(1, self.HORIZON + 1):
            v.y += g * dt
            p = p + v * dt
            if p.x - r <= -a.halfWidth: p.x = -a.halfWidth + r; v.x = abs(v.x) * 0.94
            if p.x + r >= a.halfWidth: p.x = a.halfWidth - r; v.x = -abs(v.x) * 0.94
            if p.y + r >= a.ceilingY: p.y = a.ceilingY - r; v.y = -abs(v.y) * 0.94
            if p.y - r <= a.floorY: p.y = a.floorY + r; v.y = abs(v.y) * 0.90
            if abs(p.x) <= a.netHalfWidth + r and p.y - r <= a.netTopY:
                side = -1.0 if p.x < 0 else 1.0
                p.x = side * (a.netHalfWidth + r); v.x = side * abs(v.x) * 0.94
            if p.x * home_sign <= 0.06 or p.y > top or p.y < bottom:
                continue
            t = step * dt
            shot = self.shot_from(p, home_sign)
            raw_stand = p - shot * (self.STANDOFF + self.RUNUP)
            if raw_stand.y < a.floorY + 0.16:
                continue          # the run-up would sit inside the killing floor
            stand = self.clamped(raw_stand, home_sign)
            need = (stand - ship.pos).length()
            reach = 0.45 * speed * t + 1.6 * t * t
            if fallback is None: fallback = (p.copy(), t, shot)
            if need + 0.05 <= reach:
                return (True, p.copy(), t, shot)
        if fallback is not None:
            return (True, fallback[0], fallback[1], fallback[2])
        guard = V(home_sign * 0.42, a.netTopY + 0.34)
        return (False, guard, 9.0, self.shot_from(guard, home_sign))

    def input(self, eng, team, tick):
        a = self.arena
        dt = self.config.stepDuration
        ship = eng.ships[team]
        home_sign = -1.0 if ship.homeSide == 'cyan' else 1.0
        projected = (ship.pos.x + ship.vel.x * 1.20) * home_sign
        danger = projected < -(a.opponentCrossingLimit - 0.12)
        # How much altitude a full recovery costs from here: swing the nose upright
        # (the ship only turns at a fixed rate) and then brake at full thrust.
        turn = abs(norm_angle(math.pi / 2 - ship.angle)) / self.config.torqueAcceleration
        gravity_pull = -self.config.gravity.y
        speed_after_turn = -ship.vel.y + gravity_pull * turn
        drop_while_turning = max(0.0, -ship.vel.y * turn + 0.5 * gravity_pull * turn * turn)
        net_lift = max(0.5, self.config.maximumThrustAcceleration - gravity_pull)
        brake = (speed_after_turn * speed_after_turn / (2 * net_lift)
                 if speed_after_turn > 0 else 0.0)
        recovering = ship.pos.y - drop_while_turning - brake < a.floorY + 0.04
        pinned = (ship.pos.y < a.netTopY + 0.20
                  and abs(ship.pos.x) < 0.20 and ship.pos.x * home_sign < 0.20)

        elapsed = 0.0 if self.plan_tick is None else float(tick - self.plan_tick) * dt
        remaining = max(0.0, self.eta - elapsed)
        stale = (self.intercept is None or self.home != ship.homeSide
                 or self.plan_tick is None or tick - self.plan_tick >= self.p['interval'])
        if stale:
            has, point, eta, shot = self.plan(eng, ship, home_sign)
            # Hold the current plan while the new one agrees with it: re-cutting the
            # stance every reaction tick is what makes a bot flail beside the ball.
            settled_plan = (self.has_intercept and has and remaining > 0.001
                            and (point - self.intercept).length() < 0.12)
            if not settled_plan:
                self.has_intercept, self.intercept, self.eta, self.shot = has, point, eta, shot
                self.plan_tick = tick
                remaining = eta
            else:
                self.shot = shot
            self.aim_error = math.sin((tick + (17 if team == 'cyan' else 43)) * 0.17) * self.p['aim']
            self.home = ship.homeSide

        to_ball = eng.ball.pos - ship.pos
        distance = to_ball.length()
        self.carry = self.carry + 1 if distance < 0.17 else 0
        ball_home = eng.ball.pos.x * home_sign > -0.02
        anchor = eng.ball.pos if (distance < 0.34 and ball_home) else self.intercept
        stance = self.clamped(anchor - self.shot * self.STANDOFF, home_sign)
        stand = self.clamped(anchor - self.shot * (self.STANDOFF + self.RUNUP), home_sign)

        behind = to_ball.norm().dot(self.shot) if distance > 1e-6 else 1.0
        forced = self.carry >= self.CARRY_LIMIT and ball_home
        if not self.has_intercept:
            target, closing = self.intercept, V(0, 0)      # ready position
            press = False
        else:
            # Wait a run-up behind the ball, then slide onto the contact point so the
            # ship is moving along the shot line exactly when the ball arrives.
            lead = min(1.0, remaining / self.DRIVE_WINDOW)
            if behind < 0.20 and distance < 0.45:
                lead = 1.0                                 # wrong side: swing back first
            target = self.clamped(
                anchor - self.shot * (self.STANDOFF + self.RUNUP * lead), home_sign)
            closing = self.shot * (self.p['strike'] * (1 - lead))
            press = lead < 0.5
        if forced:
            target, closing, press = stance, self.shot * (self.p['strike'] * 1.4), True
        if pinned:                                         # too low beside the net
            target, closing = V(home_sign * 0.34, a.netTopY + 0.34), V(0, 0)
        if recovering:                                     # climb out, nothing else matters
            target, closing = V(ship.pos.x, a.floorY + 0.32), V(0, 0)

        pe = target - ship.pos
        d = pe.length()
        approach = min(VCAP, math.sqrt(2 * BRAKE * max(0.0, d - 0.015)))
        desired_v = (pe.norm() * approach if d > 1e-6 else V(0, 0)) + closing
        headroom = max(0.0, ship.pos.y - (a.floorY + 0.08))
        desired_v.y = max(desired_v.y, -math.sqrt(2 * 2.6 * max(0.0, headroom - 0.04)))
        need = (desired_v - ship.vel) * ACCEL_GAIN - self.config.gravity
        if danger: need.x = home_sign * (7 + abs(ship.vel.x) * 2)
        # the lower the ship flies, the closer to vertical its thrust must stay,
        # so it can always arrest a fall before the ground kills it
        margin = max(0.0, min(1.0, (ship.pos.y - (a.floorY + 0.06)) / 0.40))
        min_pitch = 0.42 + 0.30 * (1 - margin)      # 25 deg high up, 60 deg near the floor
        need.y = max(need.y, abs(need.x) * math.tan(min_pitch))
        if margin < 0.35: need.y = max(need.y, 3.0)

        desired = math.atan2(need.y, need.x)
        if not (danger or press or recovering): desired += self.aim_error
        err = norm_angle(desired - ship.angle)
        self.dbg = dict(target=str(target), need=str(need), desired=round(desired,3),
                        err=round(err,3), rec=recovering, danger=danger, pinned=pinned,
                        dv=str(desired_v), press=press)
        demand = err * TURN_GAIN
        torque = 0.0 if abs(demand) < TURN_DEADZONE else max(-1.0, min(1.0, demand))
        axis = V(math.cos(ship.angle), math.sin(ship.angle))
        if danger: thrust = math.cos(ship.angle) * home_sign > 0.25
        else: thrust = need.dot(axis) > self.config.maximumThrustAcceleration * THRUST_GATE
        return (torque, thrust)
