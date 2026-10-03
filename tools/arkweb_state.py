"""Prints 1 when both games are linked and Spider-Man already stands on Gotham, else 0.

play.ps1 asks before it starts gotham_stream.py: a streamer started again mid-session has to resume (--resume)
instead of placing Gotham anew.
"""
import arkweb_proto as proto


def main():
	try:
		link = proto.Link()
		gs = link.read_slot(proto.OFF_GUEST, proto.GUEST)
		on = bool(gs) and link.alive("host") and link.alive("guest") and gs["flags"] & proto.GUEST_ANCHORED != 0
	except Exception:  # no mapping of this protocol (another ArkWeb version running): not ours to resume
		on = False
	print(1 if on else 0)


if __name__ == "__main__":
	main()
