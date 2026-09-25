"""Tests for the engine host, run on the Mac with the desktop Python (see PythonHost/README.md).

The stand-in for the app's `_ytdlpgui` module is installed here, before any test module
imports the host.
"""

from . import support

support.install_fake_app()
