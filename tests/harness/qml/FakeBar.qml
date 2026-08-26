import QtQuick
import qs.Commons

// The slice of Omarchy's bar API that a bar widget and its popup panel touch.
// Real behaviour where the plugin depends on it (popout ownership, inline
// settings persistence); inert acknowledgement everywhere else.
QtObject {
  id: bar

  property string position: "top"
  property int barSize: Style.bar.sizeHorizontal
  property bool vertical: false
  property color foreground: Color.foreground
  property color background: Color.background
  property color barForeground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property bool foregroundAnimationEnabled: false

  property var activePopout: null
  property var clickTargets: []

  // Records what the widget wrote back, so a test can assert that saved rooms
  // actually round-trip through shell.json rather than living in memory.
  property int writeCount: 0
  property var lastEntry: ({})

  property QtObject shell: QtObject {
    function updateEntryInline(moduleName, entry) {
      bar.lastEntry = entry
      bar.writeCount += 1
      bar.entryWritten(moduleName, entry)
    }
  }

  signal entryWritten(string moduleName, var entry)

  function requestPopout(key) { activePopout = key }
  function releasePopout(key) { if (activePopout === key) activePopout = null }
  function targetBelongsToWindow(target, window) { return true }
  function switchPanelFrom(panel, direction) { return false }
  function showTooltip(owner, text) {}
  function hideTooltip(owner) {}
  function moduleWidgets(moduleName) { return [] }
}
