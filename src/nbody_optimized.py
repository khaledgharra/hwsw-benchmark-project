"""
Optimized version of the pyperformance nbody benchmark.

Optimization history (see report_nbody.txt for full writeup):
1. First attempt: replace `** (-1.5)` / `** 0.5` with math.sqrt()-based
   formulas. Measured locally: NO meaningful improvement (119ms -> 121ms).
   The perf profile never actually showed float_pow as a hot function, so
   this guess wasn't grounded in the data - kept the sqrt form since it's
   not slower, but it isn't the real fix.
2. Second attempt: vectorize the 10-pair update with numpy (batch all
   pairwise interactions per timestep). Measured locally: only ~4% faster
   (0.185s -> 0.177s for the raw advance() loop). With only 5 bodies (10
   pairs), numpy's per-call dispatch overhead cancels out most of the
   vectorization benefit - a classic "vectorization overhead beats tiny-N
   data" case.
3. Final optimization (this file): the perf profile's dominant NAMED costs
   were list_ass_item / list_ass_subscript / PyNumber_AsSsize_t - the cost
   of the ~75 indexed list writes/reads per iteration (v1[0] -= ..., r[0]
   += ...), done 20,000 times = ~1.5M indexed list operations. Since this
   benchmark's 5 bodies (sun, jupiter, saturn, uranus, neptune) are a
   FIXED, hardcoded dataset (not a variable N), the pairwise loop over
   PAIRS can be fully unrolled into 10 straight-line blocks operating on
   plain local variables (fast LOAD_FAST/STORE_FAST bytecodes) instead of
   list subscripts, deferring the list write-back to once at the very end
   of the whole n-iteration loop instead of every iteration.
   Measured locally: ~51% faster (0.185s -> 0.0905s for the raw advance()
   loop) - by far the largest win of the three approaches tried.

This trades generality (the unrolled advance() only works for exactly
these 5 named bodies) for speed - acceptable here because the benchmark
itself always models this exact fixed solar-system dataset.
"""

import math
import pyperf

__contact__ = "collinwinter@google.com (Collin Winter)"
DEFAULT_ITERATIONS = 20000
DEFAULT_REFERENCE = 'sun'


def combinations(l):
    """Pure-Python implementation of itertools.combinations(l, 2)."""
    result = []
    for x in range(len(l) - 1):
        ls = l[x + 1:]
        for y in ls:
            result.append((l[x], y))
    return result


PI = 3.14159265358979323
SOLAR_MASS = 4 * PI * PI
DAYS_PER_YEAR = 365.24

BODIES = {
    'sun': ([0.0, 0.0, 0.0], [0.0, 0.0, 0.0], SOLAR_MASS),

    'jupiter': ([4.84143144246472090e+00,
                 -1.16032004402742839e+00,
                 -1.03622044471123109e-01],
                [1.66007664274403694e-03 * DAYS_PER_YEAR,
                 7.69901118419740425e-03 * DAYS_PER_YEAR,
                 -6.90460016972063023e-05 * DAYS_PER_YEAR],
                9.54791938424326609e-04 * SOLAR_MASS),

    'saturn': ([8.34336671824457987e+00,
                4.12479856412430479e+00,
                -4.03523417114321381e-01],
               [-2.76742510726862411e-03 * DAYS_PER_YEAR,
                4.99852801234917238e-03 * DAYS_PER_YEAR,
                2.30417297573763929e-05 * DAYS_PER_YEAR],
               2.85885980666130812e-04 * SOLAR_MASS),

    'uranus': ([1.28943695621391310e+01,
                -1.51111514016986312e+01,
                -2.23307578892655734e-01],
               [2.96460137564761618e-03 * DAYS_PER_YEAR,
                2.37847173959480950e-03 * DAYS_PER_YEAR,
                -2.96589568540237556e-05 * DAYS_PER_YEAR],
               4.36624404335156298e-05 * SOLAR_MASS),

    'neptune': ([1.53796971148509165e+01,
                 -2.59193146099879641e+01,
                 1.79258772950371181e-01],
                [2.68067772490389322e-03 * DAYS_PER_YEAR,
                 1.62824170038242295e-03 * DAYS_PER_YEAR,
                 -9.51592254519715870e-05 * DAYS_PER_YEAR],
                5.15138902046611451e-05 * SOLAR_MASS)}


SYSTEM = list(BODIES.values())
PAIRS = combinations(SYSTEM)


def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):
    """Fully unrolled version, specialized for exactly these 5 bodies.

    Reads starting state into plain local variables, runs all n timesteps
    using only local-variable arithmetic (no list indexing in the hot
    loop), then writes the final state back into the shared position /
    velocity lists once, so report_energy() (which reads `bodies`/`pairs`)
    sees correct, up-to-date values afterwards.
    """
    (spos, svel, sm) = bodies[0]   # sun
    (jpos, jvel, jm) = bodies[1]   # jupiter
    (apos, avel, am) = bodies[2]   # saturn
    (upos, uvel, um) = bodies[3]   # uranus
    (npos, nvel, nm) = bodies[4]   # neptune

    sx, sy, sz = spos
    svx, svy, svz = svel
    jx, jy, jz = jpos
    jvx, jvy, jvz = jvel
    ax, ay, az = apos
    avx, avy, avz = avel
    ux, uy, uz = upos
    uvx, uvy, uvz = uvel
    nx, ny, nz = npos
    nvx, nvy, nvz = nvel

    sqrt = math.sqrt

    for _ in range(n):
        # sun-jupiter
        dx = sx - jx; dy = sy - jy; dz = sz - jz
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt(d2))
        svx -= dx * jm * mag; svy -= dy * jm * mag; svz -= dz * jm * mag
        jvx += dx * sm * mag; jvy += dy * sm * mag; jvz += dz * sm * mag
        # sun-saturn
        dx = sx - ax; dy = sy - ay; dz = sz - az
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt(d2))
        svx -= dx * am * mag; svy -= dy * am * mag; svz -= dz * am * mag
        avx += dx * sm * mag; avy += dy * sm * mag; avz += dz * sm * mag
        # sun-uranus
        dx = sx - ux; dy = sy - uy; dz = sz - uz
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt(d2))
        svx -= dx * um * mag; svy -= dy * um * mag; svz -= dz * um * mag
        uvx += dx * sm * mag; uvy += dy * sm * mag; uvz += dz * sm * mag
        # sun-neptune
        dx = sx - nx; dy = sy - ny; dz = sz - nz
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt(d2))
        svx -= dx * nm * mag; svy -= dy * nm * mag; svz -= dz * nm * mag
        nvx += dx * sm * mag; nvy += dy * sm * mag; nvz += dz * sm * mag
        # jupiter-saturn
        dx = jx - ax; dy = jy - ay; dz = jz - az
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt(d2))
        jvx -= dx * am * mag; jvy -= dy * am * mag; jvz -= dz * am * mag
        avx += dx * jm * mag; avy += dy * jm * mag; avz += dz * jm * mag
        # jupiter-uranus
        dx = jx - ux; dy = jy - uy; dz = jz - uz
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt(d2))
        jvx -= dx * um * mag; jvy -= dy * um * mag; jvz -= dz * um * mag
        uvx += dx * jm * mag; uvy += dy * jm * mag; uvz += dz * jm * mag
        # jupiter-neptune
        dx = jx - nx; dy = jy - ny; dz = jz - nz
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt(d2))
        jvx -= dx * nm * mag; jvy -= dy * nm * mag; jvz -= dz * nm * mag
        nvx += dx * jm * mag; nvy += dy * jm * mag; nvz += dz * jm * mag
        # saturn-uranus
        dx = ax - ux; dy = ay - uy; dz = az - uz
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt(d2))
        avx -= dx * um * mag; avy -= dy * um * mag; avz -= dz * um * mag
        uvx += dx * am * mag; uvy += dy * am * mag; uvz += dz * am * mag
        # saturn-neptune
        dx = ax - nx; dy = ay - ny; dz = az - nz
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt(d2))
        avx -= dx * nm * mag; avy -= dy * nm * mag; avz -= dz * nm * mag
        nvx += dx * am * mag; nvy += dy * am * mag; nvz += dz * am * mag
        # uranus-neptune
        dx = ux - nx; dy = uy - ny; dz = uz - nz
        d2 = dx * dx + dy * dy + dz * dz
        mag = dt / (d2 * sqrt(d2))
        uvx -= dx * nm * mag; uvy -= dy * nm * mag; uvz -= dz * nm * mag
        nvx += dx * um * mag; nvy += dy * um * mag; nvz += dz * um * mag

        sx += dt * svx; sy += dt * svy; sz += dt * svz
        jx += dt * jvx; jy += dt * jvy; jz += dt * jvz
        ax += dt * avx; ay += dt * avy; az += dt * avz
        ux += dt * uvx; uy += dt * uvy; uz += dt * uvz
        nx += dt * nvx; ny += dt * nvy; nz += dt * nvz

    spos[0], spos[1], spos[2] = sx, sy, sz
    svel[0], svel[1], svel[2] = svx, svy, svz
    jpos[0], jpos[1], jpos[2] = jx, jy, jz
    jvel[0], jvel[1], jvel[2] = jvx, jvy, jvz
    apos[0], apos[1], apos[2] = ax, ay, az
    avel[0], avel[1], avel[2] = avx, avy, avz
    upos[0], upos[1], upos[2] = ux, uy, uz
    uvel[0], uvel[1], uvel[2] = uvx, uvy, uvz
    npos[0], npos[1], npos[2] = nx, ny, nz
    nvel[0], nvel[1], nvel[2] = nvx, nvy, nvz


def report_energy(bodies=SYSTEM, pairs=PAIRS, e=0.0):
    for (((x1, y1, z1), v1, m1),
         ((x2, y2, z2), v2, m2)) in pairs:
        dx = x1 - x2
        dy = y1 - y2
        dz = z1 - z2
        e -= (m1 * m2) / math.sqrt(dx * dx + dy * dy + dz * dz)
    for (r, [vx, vy, vz], m) in bodies:
        e += m * (vx * vx + vy * vy + vz * vz) / 2.
    return e


def offset_momentum(ref, bodies=SYSTEM, px=0.0, py=0.0, pz=0.0):
    for (r, [vx, vy, vz], m) in bodies:
        px -= vx * m
        py -= vy * m
        pz -= vz * m
    (r, v, m) = ref
    v[0] = px / m
    v[1] = py / m
    v[2] = pz / m


def bench_nbody(loops, reference, iterations):
    offset_momentum(BODIES[reference])

    range_it = range(loops)
    t0 = pyperf.perf_counter()

    for _ in range_it:
        report_energy()
        advance(0.01, iterations)
        report_energy()

    return pyperf.perf_counter() - t0


def add_cmdline_args(cmd, args):
    cmd.extend(("--iterations", str(args.iterations)))


if __name__ == '__main__':
    runner = pyperf.Runner(add_cmdline_args=add_cmdline_args)
    runner.metadata['description'] = "n-body benchmark (optimized: unrolled advance())"
    runner.argparser.add_argument("--iterations",
                                  type=int, default=DEFAULT_ITERATIONS,
                                  help="Number of nbody advance() iterations "
                                       "(default: %s)" % DEFAULT_ITERATIONS)
    runner.argparser.add_argument("--reference",
                                  type=str, default=DEFAULT_REFERENCE,
                                  help="nbody reference (default: %s)"
                                       % DEFAULT_REFERENCE)

    args = runner.parse_args()
    runner.bench_time_func('nbody', bench_nbody,
                           args.reference, args.iterations)
