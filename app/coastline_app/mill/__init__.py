"""Machine control for GRBL mills: serial link, protocol, sessions and programs.

Port of the Swift MillCore package (itself a port of the original C++ sender). No Qt here:
everything runs and tests without a window. Blocking calls run on worker threads.
"""
