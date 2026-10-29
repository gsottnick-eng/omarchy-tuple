#!/usr/bin/env python3
"""Run the Tuple bar widget outside a Wayland session.

Loads the real plugin entry point together with Omarchy's real Commons/Ui
components, backed by the minimal Quickshell stand-ins in qsmock/. Processes
are executed for real, so the panel talks to whichever `tuple` binary is on
PATH: the scripted fake in tests/fake-tuple for tests, never a real account
in a loop.

Examples:
    main.py --shot panel.png --theme tokyo-night        # render the dropdown
    main.py --dump state.json --do 'call:Grace Hopper'  # drive it, then read state
"""

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

sys.path.insert(0, str(HERE))

from PySide6.QtCore import Q_ARG, QMetaObject, QObject, Qt, QTimer, QUrl  # noqa: E402
from PySide6.QtGui import QColor, QGuiApplication, QImage, QPainter  # noqa: E402
from PySide6.QtQml import QJSValue, QQmlApplicationEngine, QQmlEngine, QQmlExpression  # noqa: E402

from qsmock import core, io, wayland  # noqa: E402,F401  (import registers the QML types)


def build_import_root(omarchy_shell: Path) -> Path:
    """Expose Omarchy's Commons/Ui as the `qs.*` module namespace they expect."""
    root = HERE / ".qsroot"
    (root / "qs").mkdir(parents=True, exist_ok=True)
    for name in ("Commons", "Ui"):
        link = root / "qs" / name
        target = omarchy_shell / name
        if not target.is_dir():
            raise SystemExit(
                f"missing {target}; pass --omarchy <path to omarchy/shell>"
            )
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(target)
    # A system-wide Quickshell install puts its real modules on Qt's import
    # path; these plugin-less qmldirs win, so the qsmock registrations are used.
    for module in ("Quickshell", "Quickshell.Io", "Quickshell.Wayland"):
        directory = root.joinpath(*module.split("."))
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "qmldir").write_text(f"module {module}\n")
    return root


def apply_theme(theme: Path, font_size: int) -> None:
    """Point HOME at a throwaway Omarchy config so the panel renders themed.

    Color and Style read the active theme and `[font] base-size` from the
    user's home directory, so screenshots are only representative if those
    files exist.
    """
    if not theme.is_dir():
        raise SystemExit(f"no such theme: {theme}")
    home = Path(tempfile.mkdtemp(prefix="omarchy-home-"))
    current = home / ".local" / "state" / "omarchy" / "current"
    current.mkdir(parents=True)
    (current / "theme").symlink_to(theme)
    config = home / ".config" / "omarchy"
    config.mkdir(parents=True)
    (config / "shell.toml").write_text(f"[font]\nbase-size = {font_size}\n")
    os.environ["HOME"] = str(home)


STORE_PROPS = (
    "probed",
    "installed",
    "binaryPath",
    "canShare",
    "canSettings",
    "pickerPending",
    "settings",
    "daemonRunning",
    "stoppedByUser",
    "loggedIn",
    "online",
    "inCall",
    "connected",
    "muted",
    "sharing",
    "version",
    "updateVersion",
    "loggingIn",
    "loginUrl",
    "status",
    "error",
    "calling",
    "installing",
    "installMessage",
    "summary",
)
PANEL_PROPS = ("opened", "ready", "ringing", "search", "focusSection", "barText")


def read(obj: QObject, name: str, default=None):
    value = obj.property(name)
    # QML `var` properties holding JS values arrive as QJSValue.
    if isinstance(value, QJSValue):
        value = value.toVariant()
    return default if value is None else value


def snapshot(plugin: QObject, store: QObject) -> dict:
    state = {name: read(store, name) for name in STORE_PROPS}
    state["user"] = read(store, "user")
    state["participants"] = read(store, "participants", [])
    state["contacts"] = read(store, "contacts", [])
    state["rooms"] = read(store, "rooms", [])
    state["panel"] = {name: read(plugin, name) for name in PANEL_PROPS}
    state["panel"]["rooms"] = read(plugin, "rooms", [])
    state["panel"]["people"] = read(plugin, "people", [])
    state["detached"] = core.DETACHED
    return state


def invoke(obj: QObject, name: str, *args):
    """Call a QML-declared function. Its parameters arrive as QVariant."""
    return QMetaObject.invokeMethod(
        obj, name, Qt.DirectConnection, *[Q_ARG("QVariant", arg) for arg in args]
    )


def apply_step(step: str, plugin: QObject, store: QObject, harness=None):
    """Run one scripted interaction, named the way a user would describe it."""
    name, _, argument = step.partition(":")

    def entry(collection):
        items = read(store, collection, []) or []
        for item in items:
            if argument in (
                item.get("name"),
                item.get("email"),
                item.get("slug"),
            ) or argument == str(items.index(item)):
                return item
        raise SystemExit(f"{step}: no {collection} matching {argument!r}")

    simple = {
        "open": (plugin, "open"),
        "close": (plugin, "close"),
        "sign-in": (store, "signIn"),
        "sign-out": (store, "signOut"),
        "mute": (store, "toggleMute"),
        "share": (store, "toggleShare"),
        "leave": (store, "leave"),
        "accept": (store, "accept"),
        "start": (store, "start"),
        "stop": (store, "stop"),
        "install": (store, "install"),
        "diagnose": (store, "diagnose"),
    }
    if name == "share-panel":
        # QML functions on the panel aren't invokable from Python attributes or
        # the metaobject; evaluate in the panel's own QML context.
        expression = QQmlExpression(
            QQmlEngine.contextForObject(plugin), plugin, "shareFromPanel()"
        )
        expression.evaluate()
        if expression.hasError():
            print(expression.error(), file=sys.stderr)
    elif name in simple:
        invoke(*simple[name])
    elif name == "code":
        invoke(store, "submitCode", argument)
    elif name == "call":
        invoke(store, "callPerson", entry("contacts"))
    elif name == "favorite":
        invoke(store, "favoritePerson", entry("contacts"))
    elif name == "join":
        invoke(store, "joinRoom", entry("rooms"))
    elif name == "join-url":
        invoke(store, "joinUrl", argument)
    elif name == "search":
        plugin.setProperty("search", argument)
    elif name == "flag":
        Path(os.environ["FAKE_TUPLE_STATE"], argument).touch()
    elif name == "unflag":
        (Path(os.environ["FAKE_TUPLE_STATE"]) / argument).unlink(missing_ok=True)
    elif name == "setting":
        key, _, value = argument.partition("=")
        invoke(store, "setSetting", key, value)
    elif name == "wait":
        pass
    else:
        raise SystemExit(f"unknown step: {step}")


def compose(background: str) -> QImage:
    """Flatten every visible window into one image, largest first."""
    windows = [w for w in QGuiApplication.topLevelWindows() if w.isVisible()]
    grabs = []
    for window in windows:
        grab = window.grabWindow() if hasattr(window, "grabWindow") else None
        if grab is not None and not grab.isNull():
            grabs.append((window, grab))
    if not grabs:
        raise SystemExit("nothing visible to capture")

    width = max(w.x() + g.width() for w, g in grabs)
    height = max(w.y() + g.height() for w, g in grabs)
    canvas = QImage(width, height, QImage.Format_ARGB32_Premultiplied)
    canvas.fill(QColor(background))

    painter = QPainter(canvas)
    for window, grab in sorted(
        grabs, key=lambda pair: -(pair[1].width() * pair[1].height())
    ):
        painter.drawImage(window.x(), window.y(), grab)
    painter.end()
    return canvas


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--omarchy", default=os.environ.get("OMARCHY_SHELL", "/usr/share/omarchy/shell")
    )
    parser.add_argument("--plugin", default=str(REPO / "Panel.qml"))
    parser.add_argument(
        "--settings", default="{}", help="inline widget settings as JSON"
    )
    parser.add_argument("--shot", help="write a PNG of the rendered bar and panel")
    parser.add_argument("--dump", help="write observed state as JSON")
    parser.add_argument("--open", dest="open_panel", action="store_true", default=True)
    parser.add_argument("--closed", dest="open_panel", action="store_false")
    parser.add_argument(
        "--settle",
        type=int,
        default=2500,
        help="ms to let the client answer before capturing",
    )
    parser.add_argument("--background", default="#0b0e12")
    parser.add_argument(
        "--theme", help="Omarchy theme name to render with, e.g. tokyo-night"
    )
    parser.add_argument(
        "--font-size",
        type=int,
        default=12,
        help="Omarchy [font] base-size for --theme runs",
    )
    parser.add_argument(
        "--do",
        default="",
        help="comma-separated interactions, e.g. 'call:0,wait:1200,mute'",
    )
    parser.add_argument(
        "--dump-each", help="directory for a state dump after every interaction"
    )
    parser.add_argument(
        "--step-delay", type=int, default=900, help="ms between interactions"
    )
    args = parser.parse_args()

    omarchy_shell = Path(args.omarchy).expanduser().resolve()
    import_root = build_import_root(omarchy_shell)
    if args.theme:
        apply_theme(omarchy_shell.parent / "themes" / args.theme, args.font_size)

    app = QGuiApplication(sys.argv[:1])
    engine = QQmlApplicationEngine()
    engine.addImportPath(str(import_root))
    engine.addImportPath(str(HERE / "qml"))

    engine.setInitialProperties(
        {
            "pluginUrl": QUrl.fromLocalFile(str(Path(args.plugin).resolve())),
            "pluginSettings": json.loads(args.settings),
        }
    )
    engine.warnings.connect(
        lambda warnings: [print(w.toString(), file=sys.stderr) for w in warnings]
    )
    engine.load(QUrl.fromLocalFile(str(HERE / "qml" / "Harness.qml")))
    if not engine.rootObjects():
        return 2

    harness = engine.rootObjects()[0]
    status = {"code": 0}

    def capture():
        plugin = harness.property("plugin")
        if plugin is None:
            print("plugin failed to load", file=sys.stderr)
            status["code"] = 3
            app.quit()
            return
        store = harness.property("store")

        try:
            if args.dump:
                state = snapshot(plugin, store)
                Path(args.dump).parent.mkdir(parents=True, exist_ok=True)
                Path(args.dump).write_text(json.dumps(state, indent=2, default=str))
            if args.shot:
                Path(args.shot).parent.mkdir(parents=True, exist_ok=True)
                compose(args.background).save(args.shot)
        except Exception as error:  # a broken capture must not hang the run
            import traceback

            traceback.print_exc()
            print(f"capture failed: {error}", file=sys.stderr)
            status["code"] = 5
        finally:
            app.quit()

    steps = [step.strip() for step in args.do.split(",") if step.strip()]
    recorded: list[str] = []

    def run_next():
        if not steps:
            QTimer.singleShot(args.step_delay, capture)
            return
        step = steps.pop(0)
        plugin = harness.property("plugin")
        store = harness.property("store")
        if plugin is None or store is None:
            print("plugin not ready for interactions", file=sys.stderr)
            status["code"] = 3
            app.quit()
            return
        delay = (
            int(step.partition(":")[2]) if step.startswith("wait:") else args.step_delay
        )
        apply_step(step, plugin, store, harness)

        def record(index=len(recorded), label=step):
            if not args.dump_each:
                return
            directory = Path(args.dump_each)
            directory.mkdir(parents=True, exist_ok=True)
            safe = label.replace("/", "_").replace(":", "-")
            state = snapshot(plugin, store)
            (directory / f"{index:02d}-{safe}.json").write_text(
                json.dumps(state, indent=2, default=str)
            )

        recorded.append(step)

        def finish_step():
            # One timer for both, so a step's dump can never land after the
            # next step has started; Qt's coarse timers may fire 5% early or late.
            record()
            run_next()

        QTimer.singleShot(delay, finish_step)

    if args.open_panel:
        QTimer.singleShot(args.settle, harness.openPanel)
        QTimer.singleShot(args.settle + 400, run_next)
    else:
        QTimer.singleShot(args.settle, run_next)

    app.exec()
    return status["code"]


if __name__ == "__main__":
    raise SystemExit(main())
