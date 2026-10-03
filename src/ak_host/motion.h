// Spider-Man's motion, smoothed for Arkham's ticks (main.cpp; tests/motion_test.cpp runs it offline).
//
// The guest publishes one snapshot per Spider-Man frame - the hero and his camera as the camera was updated -
// stamped with that moment's QueryPerformanceCounter time, the same clock in both processes. Arkham ticks at its
// own rate, so every tick samples the motion a little in the past and interpolates between the two snapshots
// around that moment: Batman and the view move smoothly, and together.
//
// How far in the past: nearly the longest recent gap between snapshots (the 90th percentile of the last 31: a
// hitch doesn't stretch it, and two snapshots of one split frame don't shorten it the way an average would) plus
// the guest's publish, so the snapshot after the sampled moment has nearly always arrived. When it hasn't (a
// hitch), the newest is held. Nothing is extrapolated: a guess has to be taken back when the real frame comes.
// The old guess went up to 50 ms ahead from the last two snapshots - which could be 2 ms apart, so 25 times their
// difference, rotations included - and pulled the camera back every few frames while swinging. The sampled
// moment never runs backwards either.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace arkweb::motion
{
	struct Snap
	{
		int64_t qpc;              // when Spider-Man's frame was taken (QueryPerformanceCounter)
		double  pos[3];           // hero feet, guest space
		float   fwd[3];           // hero forward
		double  cam[3];           // camera position
		float   camF[3], camU[3];  // camera forward and up
		float   fovY;             // Spider-Man's vertical field of view, degrees (0 = not known)
		bool    camOk;
	};

	class Buffer
	{
	public:
		static constexpr int    kSnaps = 32;
		static constexpr double kPublishSlack = 0.006;  // s: the guest publishes every 4 ms, then the read here
		static constexpr double kTeleport = 20.0;       // m in one frame: a teleport, never slid across

		void Reset(double a_qpcFreq)
		{
			_count = _next = 0;
			_qpcFreq = a_qpcFreq > 0.0 ? a_qpcFreq : 1.0e7;
			_lastT = 0;
		}

		// A snapshot from the link; false when it isn't newer than the newest (the same frame again).
		bool Push(const Snap& a_s)
		{
			if (!a_s.qpc || (_count && a_s.qpc <= At(_count - 1).qpc)) return false;
			_snaps[_next] = a_s;
			_next = (_next + 1) % kSnaps;
			if (_count < kSnaps) ++_count;
			return true;
		}

		double FrameDt() const { return Gap(0.5); }                                                      // s, the median gap
		double Delay() const { return std::clamp(Gap(0.9) + kPublishSlack, 0.010, 0.070); }  // s behind now

		// The motion at Delay() before a_now (QPC); false before the first snapshot.
		bool Sample(int64_t a_now, Snap& a_out)
		{
			if (!_count) return false;
			int64_t t = std::max(a_now - static_cast<int64_t>(Delay() * _qpcFreq), _lastT);  // the delay grows after slow frames
			_lastT = t;
			const Snap& newest = At(_count - 1);
			if (t >= newest.qpc) {  // past everything that came: hold the newest
				a_out = newest;
				return true;
			}
			for (int i = _count - 2; i >= 0; --i) {
				const Snap& a = At(i);
				if (a.qpc > t) continue;
				const Snap& b = At(i + 1);
				if (Dist(a.pos, b.pos) > kTeleport || Dist(a.cam, b.cam) > kTeleport) {
					a_out = a;  // a teleport happens at b's frame
					return true;
				}
				Blend(a, b, static_cast<double>(t - a.qpc) / static_cast<double>(b.qpc - a.qpc), a_out);
				return true;
			}
			a_out = At(0);  // older than everything we have
			return true;
		}

	private:
		const Snap& At(int a_i) const { return _snaps[(_next - _count + a_i + 2 * kSnaps) % kSnaps]; }  // 0 = oldest

		// That fraction of the recent gaps between snapshots is at most this long, s (pauses of 0.25 s and more left out).
		double Gap(double a_fraction) const
		{
			double gaps[kSnaps];
			int    n = 0;
			for (int i = 1; i < _count; ++i) {
				double g = (At(i).qpc - At(i - 1).qpc) / _qpcFreq;
				if (g < 0.25) gaps[n++] = g;
			}
			if (n < 4) return 1.0 / 60.0;
			int k = std::min(n - 1, static_cast<int>(n * a_fraction));
			std::nth_element(gaps, gaps + k, gaps + n);
			return gaps[k];
		}

		static double Dist(const double a_a[3], const double a_b[3]) { return std::hypot(a_a[0] - a_b[0], a_a[1] - a_b[1], a_a[2] - a_b[2]); }

		// Between two directions; more than 90 degrees apart (a cut) it switches halfway instead of passing through zero.
		static void BlendDir(const float a_a[3], const float a_b[3], float a_t, float a_out[3])
		{
			if (a_a[0] * a_b[0] + a_a[1] * a_b[1] + a_a[2] * a_b[2] < 0.0f) {
				const float* s = a_t < 0.5f ? a_a : a_b;
				a_out[0] = s[0], a_out[1] = s[1], a_out[2] = s[2];
				return;
			}
			for (int i = 0; i < 3; ++i) a_out[i] = a_a[i] + (a_b[i] - a_a[i]) * a_t;
			float l = std::sqrt(a_out[0] * a_out[0] + a_out[1] * a_out[1] + a_out[2] * a_out[2]);
			if (l > 1e-6f) a_out[0] /= l, a_out[1] /= l, a_out[2] /= l;
		}

		static void Blend(const Snap& a_a, const Snap& a_b, double a_t, Snap& a_out)
		{
			a_t = std::clamp(a_t, 0.0, 1.0);
			const float t = static_cast<float>(a_t);
			for (int i = 0; i < 3; ++i) {
				a_out.pos[i] = a_a.pos[i] + (a_b.pos[i] - a_a.pos[i]) * a_t;
				a_out.cam[i] = a_a.cam[i] + (a_b.cam[i] - a_a.cam[i]) * a_t;
			}
			BlendDir(a_a.fwd, a_b.fwd, t, a_out.fwd);
			BlendDir(a_a.camF, a_b.camF, t, a_out.camF);
			BlendDir(a_a.camU, a_b.camU, t, a_out.camU);
			a_out.camOk = a_a.camOk && a_b.camOk;
			a_out.fovY = a_a.fovY > 0.0f && a_b.fovY > 0.0f ? a_a.fovY + (a_b.fovY - a_a.fovY) * t : a_b.fovY;
			a_out.qpc = a_a.qpc + static_cast<int64_t>((a_b.qpc - a_a.qpc) * a_t);
		}

		Snap    _snaps[kSnaps] = {};
		int     _count = 0, _next = 0;
		double  _qpcFreq = 1.0e7;
		int64_t _lastT = 0;  // the moment sampled last
	};
}
