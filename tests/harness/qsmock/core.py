"""Minimal stand-ins for the `Quickshell` QML module.

Just enough of the real API for Omarchy's Commons/Ui components to load and
render under a plain Qt runtime, so the plugin can be exercised without a
Wayland compositor. Layer-shell behaviour is deliberately flattened: a
PanelWindow is an ordinary window, and the compositor-specific properties are
accepted and ignored.
"""

import os
import subprocess

from PySide6.QtCore import Property, QObject, QPointF, QRect, Qt, Signal, Slot
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QmlAnonymous, QmlAttached, QmlElement, QmlSingleton
from PySide6.QtQuick import QQuickItem, QQuickWindow

from .qmlprops import declare, plain

QML_IMPORT_NAME = "Quickshell"
QML_IMPORT_MAJOR_VERSION = 1


def virtual_geometry(screen):
    """Screen rect the panel geometry is computed against.

    The offscreen platform reports a small fixed screen, so HARNESS_SCREEN lets
    a run pick a realistic desktop size (and, with it, a realistic popup
    position and maximum panel height).
    """
    override = os.environ.get("HARNESS_SCREEN", "")
    if "x" in override:
        width, height = override.split("x", 1)
        return QRect(0, 0, int(width), int(height))
    return screen.geometry()


@QmlAnonymous
class ShellScreen(QObject):
    """Quickshell exposes screens with plain name/width/height; QScreen does not."""

    def __init__(self, screen, parent=None):
        super().__init__(parent)
        self._screen = screen

    @Property(str, constant=True)
    def name(self):
        return self._screen.name()

    @Property(int, constant=True)
    def width(self):
        return virtual_geometry(self._screen).width()

    @Property(int, constant=True)
    def height(self):
        return virtual_geometry(self._screen).height()

    @Property(float, constant=True)
    def devicePixelRatio(self):
        return self._screen.devicePixelRatio()

    def qscreen(self):
        return self._screen


@QmlAnonymous
class PanelAnchors(QObject):
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._top = self._bottom = self._left = self._right = False

    top = declare(bool, "_top", changed, False)
    bottom = declare(bool, "_bottom", changed, False)
    left = declare(bool, "_left", changed, False)
    right = declare(bool, "_right", changed, False)


@QmlAnonymous
class QsWindowAttached(QObject):
    windowChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._item = parent if isinstance(parent, QQuickItem) else None

    @Property(QObject, notify=windowChanged)
    def window(self):
        # Hand back the window itself so `.screen`, `.contentItem` and
        # `.itemPosition()` resolve the way they do under Quickshell.
        return None if self._item is None else self._item.window()


@QmlElement
@QmlAttached(QsWindowAttached)
class QsWindow(QObject):
    @staticmethod
    def qmlAttachedProperties(*args):
        # PySide passes the attaching type alongside the target object.
        return QsWindowAttached(args[-1])


@QmlElement
class Region(QObject):
    """Input-region mask. Accepted and ignored outside a compositor."""

    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._x = self._y = self._width = self._height = 0

    x = declare(int, "_x", changed, 0)
    y = declare(int, "_y", changed, 0)
    width = declare(int, "_width", changed, 0)
    height = declare(int, "_height", changed, 0)


@QmlElement
class TransformWatcher(QObject):
    """Reactivity hook only; the harness never moves the anchor after layout."""

    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._a = None
        self._b = None

    a = declare(QObject, "_a", changed)
    b = declare(QObject, "_b", changed)

    @Property(int, notify=changed)
    def transform(self):
        return 0


@QmlElement
class Variants(QObject):
    """Per-screen duplication. The harness runs one screen, so this stays empty."""

    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._model = None
        self._delegate = None

    model = declare("QVariant", "_model", changed)
    delegate = declare("QVariant", "_delegate", changed)


@QmlElement
@QmlSingleton
class ExclusionMode(QObject):
    Normal = Property(int, lambda self: 0, constant=True)
    Ignore = Property(int, lambda self: 1, constant=True)
    Auto = Property(int, lambda self: 2, constant=True)


@QmlElement
class PanelWindow(QQuickWindow):
    """A layer-shell panel, flattened to an ordinary window.

    Anchoring to screen edges becomes plain geometry, which is all the popup
    positioning in KeyboardPanel actually reads back.
    """

    screenChanged2 = Signal()
    exclusionModeChanged = Signal()
    maskChanged = Signal()
    backingWindowVisibleChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._screen = None
        self._exclusionMode = 0
        self._mask = None
        self._applying = False
        self._anchors = PanelAnchors(self)
        self._anchors.changed.connect(self._apply_anchors)
        self.setFlags(Qt.FramelessWindowHint | Qt.Window)
        self.visibleChanged.connect(self.backingWindowVisibleChanged)
        self.heightChanged.connect(self._apply_anchors)
        self.widthChanged.connect(self._apply_anchors)

    # Typed concretely so QML's grouped-property syntax (`anchors { top: true }`)
    # can resolve the members.
    @Property(PanelAnchors, constant=True)
    def anchors(self):
        return self._anchors

    def _get_screen(self):
        if self._screen is None:
            self._screen = ShellScreen(QGuiApplication.primaryScreen(), self)
        return self._screen

    def _set_screen(self, value):
        if isinstance(value, ShellScreen):
            self._screen = value
            super().setScreen(value.qscreen())
            self.screenChanged2.emit()
            self._apply_anchors()

    screen = Property(ShellScreen, _get_screen, _set_screen, notify=screenChanged2)

    exclusionMode = declare(int, "_exclusionMode", exclusionModeChanged, 0)
    mask = declare(QObject, "_mask", maskChanged)

    @Property(bool, notify=backingWindowVisibleChanged)
    def backingWindowVisible(self):
        return self.isVisible()

    @Slot(QQuickItem, result=QPointF)
    def itemPosition(self, item):
        if item is None:
            return QPointF(0, 0)
        return self.contentItem().mapFromItem(item, QPointF(0, 0))

    def _apply_anchors(self):
        if self._applying:
            return
        a = self._anchors
        if not (a.top or a.bottom or a.left or a.right):
            return
        area = virtual_geometry(self._get_screen().qscreen())
        x, y, w, h = self.x(), self.y(), self.width(), self.height()
        if a.left and a.right:
            x, w = area.x(), area.width()
        elif a.left:
            x = area.x()
        elif a.right:
            x = area.x() + area.width() - w
        if a.top and a.bottom:
            y, h = area.y(), area.height()
        elif a.top:
            y = area.y()
        elif a.bottom:
            y = area.y() + area.height() - h
        self._applying = True
        try:
            self.setGeometry(x, y, w, h)
        finally:
            self._applying = False


@QmlElement
@QmlSingleton
class Quickshell(QObject):
    screensChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._screens = None
        self.detached = []

    @Slot(str, result=str)
    def env(self, name):
        return os.environ.get(name, "")

    @Slot("QVariant")
    def execDetached(self, command):
        from PySide6.QtQml import QJSValue

        if isinstance(command, QJSValue):
            command = command.toVariant()
        argv = [str(part) for part in command]
        self.detached.append(argv)
        try:
            subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass

    @Property("QVariantList", notify=screensChanged)
    def screens(self):
        if self._screens is None:
            self._screens = [ShellScreen(s, self) for s in QGuiApplication.screens()]
        return self._screens
