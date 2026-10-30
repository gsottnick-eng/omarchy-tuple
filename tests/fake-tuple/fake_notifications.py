"""A notification server on a private session bus, for testing bin/tuple-notify.

Run inside `dbus-run-session` with the system Python (it needs python-gobject):
it owns org.freedesktop.Notifications, runs the notifier given as argv[1] with
this script's stdin, and prints each Notify call it received as a JSON line.
"""

import json
import subprocess
import sys

from gi.repository import Gio, GLib

INTERFACE = """
<node><interface name="org.freedesktop.Notifications">
  <method name="Notify">
    <arg type="s" direction="in"/><arg type="u" direction="in"/>
    <arg type="s" direction="in"/><arg type="s" direction="in"/>
    <arg type="s" direction="in"/><arg type="as" direction="in"/>
    <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
    <arg type="u" direction="out"/>
  </method>
</interface></node>
"""

received = []
loop = GLib.MainLoop()


def on_call(connection, sender, path, interface, method, params, invocation):
    app, _, icon, summary, body = params.unpack()[:5]
    received.append({"app": app, "icon": icon, "summary": summary, "body": body})
    invocation.return_value(GLib.Variant("(u)", (len(received),)))


def run_notifier(connection, name):
    notifier = subprocess.Popen([sys.argv[1]], stdin=sys.stdin)

    def wait():
        if notifier.poll() is None:
            return True
        loop.quit()
        return False

    GLib.timeout_add(20, wait)


bus = Gio.bus_get_sync(Gio.BusType.SESSION)
info = Gio.DBusNodeInfo.new_for_xml(INTERFACE).interfaces[0]
bus.register_object("/org/freedesktop/Notifications", info, on_call, None, None)
Gio.bus_own_name_on_connection(
    bus, "org.freedesktop.Notifications", Gio.BusNameOwnerFlags.NONE, run_notifier, None
)
GLib.timeout_add_seconds(10, loop.quit)
loop.run()
for call in received:
    print(json.dumps(call))
