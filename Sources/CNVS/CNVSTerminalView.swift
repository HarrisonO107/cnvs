import AppKit
import SwiftTerm

final class CNVSTerminalView: LocalProcessTerminalView {
    override func deleteWordBackward(_ sender: Any?) {
        // Shells and terminal prompt editors use Control-W to erase a word.
        send(txt: "\u{17}")
    }
}
