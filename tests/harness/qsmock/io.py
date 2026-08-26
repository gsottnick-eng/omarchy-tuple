"""Stand-ins for the `Quickshell.Io` QML module: process execution and file reads."""

import os

from PySide6.QtCore import Property, QObject, QProcess, Signal, Slot
from PySide6.QtQml import QmlElement

QML_IMPORT_NAME = "Quickshell.Io"
QML_IMPORT_MAJOR_VERSION = 1


@QmlElement
class StdioCollector(QObject):
    """Buffers a whole stream and hands it over once the process exits."""

    textChanged = Signal()
    streamFinished = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._text = ""
        self._wait_for_end = False

    def _get_text(self):
        return self._text

    def _set_text(self, value):
        if self._text != value:
            self._text = value
            self.textChanged.emit()

    text = Property(str, _get_text, _set_text, notify=textChanged)

    def _get_wait(self):
        return self._wait_for_end

    def _set_wait(self, value):
        self._wait_for_end = value

    waitForEnd = Property(bool, _get_wait, _set_wait)

    def reset(self):
        self._set_text("")

    def feed(self, chunk):
        self._set_text(self._text + chunk)

    def finish(self):
        self.streamFinished.emit()


@QmlElement
class SplitParser(QObject):
    """Emits `read` once per delimited chunk, like the real incremental parser."""

    read = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._split_marker = "\n"
        self._buffer = ""

    def _get_marker(self):
        return self._split_marker

    def _set_marker(self, value):
        self._split_marker = value

    splitMarker = Property(str, _get_marker, _set_marker)

    def reset(self):
        self._buffer = ""

    def feed(self, chunk):
        self._buffer += chunk
        marker = self._split_marker or "\n"
        while marker in self._buffer:
            head, self._buffer = self._buffer.split(marker, 1)
            self.read.emit(head)

    def finish(self):
        if self._buffer:
            tail, self._buffer = self._buffer, ""
            self.read.emit(tail)


@QmlElement
class Process(QObject):
    commandChanged = Signal()
    runningChanged = Signal()
    exited = Signal(int, int)
    started = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._command = []
        self._running = False
        self._stdout = None
        self._stderr = None
        self._working_directory = ""
        self._proc = None

    def _get_command(self):
        return self._command

    def _set_command(self, value):
        self._command = [str(part) for part in (value or [])]
        self.commandChanged.emit()

    command = Property("QVariantList", _get_command, _set_command, notify=commandChanged)

    def _get_stdout(self):
        return self._stdout

    def _set_stdout(self, value):
        self._stdout = value

    stdout = Property(QObject, _get_stdout, _set_stdout)

    def _get_stderr(self):
        return self._stderr

    def _set_stderr(self, value):
        self._stderr = value

    stderr = Property(QObject, _get_stderr, _set_stderr)

    def _get_wd(self):
        return self._working_directory

    def _set_wd(self, value):
        self._working_directory = value

    workingDirectory = Property(str, _get_wd, _set_wd)

    def _get_running(self):
        return self._running

    def _set_running(self, value):
        if value and not self._running:
            self._start()
        elif not value and self._running:
            self._stop()

    running = Property(bool, _get_running, _set_running, notify=runningChanged)

    def _start(self):
        if not self._command:
            return
        self._running = True
        self.runningChanged.emit()
        # Each run starts from an empty buffer, as the real collector does.
        for stream in (self._stdout, self._stderr):
            if stream is not None:
                stream.reset()
        self._proc = QProcess(self)
        self._proc.setProgram(self._command[0])
        self._proc.setArguments(self._command[1:])
        if self._working_directory:
            self._proc.setWorkingDirectory(self._working_directory)
        self._proc.readyReadStandardOutput.connect(self._drain_stdout)
        self._proc.readyReadStandardError.connect(self._drain_stderr)
        self._proc.finished.connect(self._on_finished)
        self._proc.errorOccurred.connect(self._on_error)
        self._proc.start()
        self.started.emit()

    def _stop(self):
        if self._proc is not None:
            self._proc.kill()

    def _decode(self, data):
        return bytes(data).decode("utf-8", "replace")

    def _drain_stdout(self):
        chunk = self._decode(self._proc.readAllStandardOutput())
        if chunk and self._stdout is not None:
            self._stdout.feed(chunk)

    def _drain_stderr(self):
        chunk = self._decode(self._proc.readAllStandardError())
        if chunk and self._stderr is not None:
            self._stderr.feed(chunk)

    def _on_error(self, error):
        if error == QProcess.FailedToStart:
            self._finalize(127, 1)

    def _on_finished(self, exit_code, exit_status):
        self._drain_stdout()
        self._drain_stderr()
        self._finalize(exit_code, 0 if exit_status == QProcess.NormalExit else 1)

    def _finalize(self, exit_code, exit_status):
        if not self._running:
            return
        self._running = False
        for stream in (self._stdout, self._stderr):
            if stream is not None:
                stream.finish()
        self.runningChanged.emit()
        self.exited.emit(exit_code, exit_status)
        self._proc = None


@QmlElement
class FileView(QObject):
    loaded = Signal()
    loadFailed = Signal(int)
    fileChanged = Signal()
    pathChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._path = ""
        self._watch_changes = False
        self._print_errors = True
        self._block = False
        self._text = ""

    def _get_path(self):
        return self._path

    def _set_path(self, value):
        self._path = value
        self.pathChanged.emit()
        self.reload()

    path = Property(str, _get_path, _set_path, notify=pathChanged)

    def _flag(attr, default):
        def getter(self):
            return getattr(self, attr, default)

        def setter(self, value):
            setattr(self, attr, value)

        return Property(bool, getter, setter)

    watchChanges = _flag("_watch_changes", False)
    printErrors = _flag("_print_errors", True)
    blockLoadingUntilLoaded = _flag("_block", False)
    del _flag

    @Slot(result=str)
    def text(self):
        return self._text

    @Slot()
    def reload(self):
        try:
            with open(os.path.expanduser(self._path), "r", encoding="utf-8") as handle:
                self._text = handle.read()
        except OSError:
            self._text = ""
            self.loadFailed.emit(2)
            return
        self.loaded.emit()


@QmlElement
class IpcHandler(QObject):
    """Accepts the declaration so panels load; the harness calls methods directly."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._target = ""
        self._enabled = True

    def _get_target(self):
        return self._target

    def _set_target(self, value):
        self._target = value

    target = Property(str, _get_target, _set_target)

    def _get_enabled(self):
        return self._enabled

    def _set_enabled(self, value):
        self._enabled = value

    enabled = Property(bool, _get_enabled, _set_enabled)
