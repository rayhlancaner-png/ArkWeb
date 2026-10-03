// Offline test of the host's motion smoothing (src/ak_host/motion.h): Spider-Man's frames along a swing-like arc,
// with uneven frame times, hitches, frames that arrive as two snapshots a few ms apart and a teleport, sampled at
// Arkham's own rate. The view must never go back in time, never get ahead of the newest frame, rarely hold while
// frames come steadily, and never slide across a teleport.
#include "../src/ak_host/motion.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

using arkweb::motion::Buffer;
using arkweb::motion::Snap;

static int g_fail = 0;
#define CHECK(c)                                                         \
	do {                                                                 \
		if (!(c)) {                                                      \
			std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #c);   \
			++g_fail;                                                    \
		}                                                                \
	} while (0)

constexpr double kFreq = 1.0e7;  // QPC ticks per second
constexpr double kPi = 3.14159265358979323846;
constexpr double kRadius = 40.0;

static double Arc(double a_t) { return 0.9 * a_t + 0.05 * std::sin(2.0 * kPi * a_t); }  // radians along the arc, always growing

// The hero at a_tHero and the camera of a_tCam (a split frame pairs a new hero with the last camera).
static Snap Frame(double a_tHero, double a_tCam, double a_stamp, double a_jump)
{
	Snap   s{};
	double th = Arc(a_tHero), tc = Arc(a_tCam);
	s.qpc = static_cast<int64_t>(a_stamp * kFreq);
	s.pos[0] = kRadius * std::cos(th) + a_jump, s.pos[1] = 100.0, s.pos[2] = kRadius * std::sin(th);
	s.fwd[0] = static_cast<float>(-std::sin(th)), s.fwd[2] = static_cast<float>(std::cos(th));
	double back = tc - 4.0 / kRadius;
	s.cam[0] = kRadius * std::cos(back) + a_jump, s.cam[1] = 102.0, s.cam[2] = kRadius * std::sin(back);
	s.camF[0] = static_cast<float>(-std::sin(tc)), s.camF[2] = static_cast<float>(std::cos(tc));
	s.camU[1] = 1.0f;
	s.fovY = 60.0f;
	s.camOk = true;
	return s;
}

struct Published
{
	int64_t visible;  // when the host can first read it
	Snap    snap;
};

struct Stats
{
	int    ticks = 0, holds = 0, backInTime = 0, ahead = 0, offPath = 0, slid = 0, turnedAhead = 0;
	double maxCamTurnDeg = 0.0;
};

static double Heading(const float a_f[3]) { return std::atan2(-a_f[0], a_f[2]); }  // along the arc: grows with time

static double WrapPi(double a_r)
{
	while (a_r > kPi) a_r -= 2.0 * kPi;
	while (a_r < -kPi) a_r += 2.0 * kPi;
	return a_r;
}

static Stats Run(unsigned a_seed, double a_splitChance, bool a_hitches, double a_hostHz, double a_teleportAt)
{
	std::mt19937                           rng(a_seed);
	std::uniform_real_distribution<double> u(0.0, 1.0);
	std::vector<Published>                 pubs;
	double                                 t = 0.0, nextHitch = 1.5, jump = 0.0;
	while (t < 30.0) {
		double dt = 0.0167 + (u(rng) * 13.0 - 5.0) / 1000.0;  // 11.7 .. 24.7 ms
		if (a_hitches && t > nextHitch) dt += 0.04 + u(rng) * 0.06, nextHitch += 1.5;
		double tHero = t + dt, tCam = tHero + (2.5 + u(rng) * 4.0) / 1000.0;
		if (a_teleportAt > 0.0 && t < a_teleportAt && tHero >= a_teleportAt) jump = 500.0;  // a rescue: 500 m in one frame
		double lag = (0.2 + u(rng) * 5.0) / 1000.0;
		if (u(rng) < a_splitChance) {
			pubs.push_back({ static_cast<int64_t>((tHero + lag) * kFreq), Frame(tHero, t, tHero, jump) });
			pubs.push_back({ static_cast<int64_t>((tCam + lag) * kFreq), Frame(tHero, tHero, tCam, jump) });
		} else {
			pubs.push_back({ static_cast<int64_t>((tCam + lag) * kFreq), Frame(tHero, tHero, tCam, jump) });
		}
		t = tHero;
	}

	Buffer buf;
	buf.Reset(kFreq);
	Stats       s;
	size_t      next = 0;
	const Snap* newest = nullptr;
	int64_t     lastQpc = 0;
	double      lastTurn = 0.0;
	bool        haveLast = false;
	Snap        last{};
	for (double host = 0.3; host < 29.5; host += 1.0 / a_hostHz + (u(rng) - 0.5) * 0.002) {
		int64_t     now = static_cast<int64_t>(host * kFreq);
		const Snap* read = nullptr;  // the host reads the newest state once per tick
		while (next < pubs.size() && pubs[next].visible <= now) read = &pubs[next++].snap;
		if (read && buf.Push(*read)) newest = read;
		Snap o;
		if (!buf.Sample(now, o) || !newest) continue;
		++s.ticks;
		if (o.qpc < lastQpc) ++s.backInTime;
		if (o.qpc > newest->qpc) ++s.ahead;
		// between two frames on the arc (or on the arc the teleport moved): on a chord, so never outside the circle - a
		// guess ahead along the motion would be - and never far inside it
		auto onArc = [](double a_r) { return a_r < kRadius + 0.01 && a_r > kRadius - 0.15; };
		if (!onArc(std::hypot(o.pos[0], o.pos[2])) && !onArc(std::hypot(o.pos[0] - 500.0, o.pos[2]))) ++s.offPath;
		if (haveLast && std::fabs(o.pos[0] - last.pos[0]) > 50.0 && std::fabs(o.pos[0] - last.pos[0]) < 450.0) ++s.slid;
		if (haveLast && o.qpc == last.qpc && o.qpc == newest->qpc) ++s.holds;  // stuck on the newest frame: the next was late
		double turn = Heading(o.camF);
		if (WrapPi(turn - Heading(newest->camF)) > 1e-4) ++s.turnedAhead;  // the camera turned past the newest frame's
		if (haveLast) s.maxCamTurnDeg = std::max(s.maxCamTurnDeg, std::fabs(WrapPi(turn - lastTurn)) * 180.0 / kPi);
		lastQpc = o.qpc, lastTurn = turn, last = o, haveLast = true;
	}
	return s;
}

int main()
{
	// Steady frames (one snapshot each, as the camera-update hook gives): the delay covers the jitter.
	Stats a = Run(1, 0.0, false, 60.0, 0.0);
	std::printf("steady, 60 Hz:          %d ticks, %d held, %d back in time, %d ahead, %d off the path\n", a.ticks, a.holds, a.backInTime, a.ahead, a.offPath);
	CHECK(a.ticks > 1500 && a.backInTime == 0 && a.ahead == 0 && a.offPath == 0);
	CHECK(a.holds < a.ticks / 100);
	Stats b = Run(2, 0.0, false, 144.0, 0.0);
	std::printf("steady, 144 Hz:         %d ticks, %d held, %d back in time, %d ahead, %d off the path\n", b.ticks, b.holds, b.backInTime, b.ahead, b.offPath);
	CHECK(b.ticks > 3500 && b.backInTime == 0 && b.ahead == 0 && b.offPath == 0);
	CHECK(b.holds < b.ticks / 100);

	// Split frames (the polling fallback): two snapshots a few ms apart don't make the delay too short.
	Stats e = Run(5, 0.5, false, 144.0, 0.0);
	std::printf("split frames, 144 Hz:   %d ticks, %d held, %d back in time, %d ahead, %d off the path\n", e.ticks, e.holds, e.backInTime, e.ahead, e.offPath);
	CHECK(e.backInTime == 0 && e.ahead == 0 && e.offPath == 0);
	CHECK(e.holds < e.ticks / 100);

	// Hitches and split frames: held, never guessed ahead - the camera never turns past the newest frame's.
	Stats c = Run(3, 0.5, true, 144.0, 0.0);
	std::printf("hitches + split frames: %d ticks, %d held, %d back in time, %d ahead, %d off the path, %d turned ahead (largest turn per tick %.1f deg)\n",
		c.ticks, c.holds, c.backInTime, c.ahead, c.offPath, c.turnedAhead, c.maxCamTurnDeg);
	CHECK(c.backInTime == 0 && c.ahead == 0 && c.offPath == 0 && c.turnedAhead == 0);

	// A teleport: the view jumps with it, never through the 500 m between.
	Stats d = Run(4, 0.0, false, 60.0, 10.0);
	std::printf("teleport:               %d ticks, %d slid across, %d back in time, %d ahead\n", d.ticks, d.slid, d.backInTime, d.ahead);
	CHECK(d.slid == 0 && d.backInTime == 0 && d.ahead == 0);

	// A cut of more than 90 degrees in one frame switches cleanly (no zero-length direction in between).
	Buffer cut;
	cut.Reset(kFreq);
	Snap s0 = Frame(0.0, 0.0, 1.0, 0.0), s1 = s0;
	s1.qpc = static_cast<int64_t>(1.0167 * kFreq);
	for (int i = 0; i < 3; ++i) s1.camF[i] = -s0.camF[i];
	cut.Push(s0), cut.Push(s1);
	for (int k = 0; k <= 10; ++k) {
		Snap o;
		cut.Sample(static_cast<int64_t>((1.0 + 0.0167 * k / 10.0) * kFreq + cut.Delay() * kFreq), o);
		CHECK(std::fabs(std::hypot(o.camF[0], o.camF[1], o.camF[2]) - 1.0) < 1e-3);
	}

	std::printf(g_fail ? "%d FAILED\n" : "all motion tests passed\n", g_fail);
	return g_fail != 0;
}
