// send-key: manda una combinación de teclas al instante (sin el arranque lento de osascript).
// Uso: send-key <ctrl|cmd|alt|shift>[+…] <left|right|up|down|w|keycode>
// Ej.: send-key ctrl left   → escritorio anterior;  send-key cmd w → cerrar ventana.
// Lo ejecuta skhd (usa su permiso de Accesibilidad para enviar teclas).
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write("uso: send-key <mods> <tecla>\n".data(using: .utf8)!); exit(2) }
var flags: CGEventFlags = []
for m in args[1].split(separator: "+") {
    switch m {
    case "ctrl": flags.insert(.maskControl)
    case "cmd": flags.insert(.maskCommand)
    case "alt": flags.insert(.maskAlternate)
    case "shift": flags.insert(.maskShift)
    default: break
    }
}
let named: [String: CGKeyCode] = ["left": 123, "right": 124, "down": 125, "up": 126, "w": 13]
guard let key = named[args[2]] ?? CGKeyCode(args[2]) else { exit(2) }
// Las flechas llevan además las banderas de tecla de función/teclado numérico, como las reales
if (123...126).contains(key) { flags.insert(.maskSecondaryFn); flags.insert(.maskNumericPad) }
let src = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
    e?.flags = flags
    e?.post(tap: .cghidEventTap)
}
