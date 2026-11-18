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
// Pulsar también las teclas modificadoras (no solo marcar las banderas): los atajos del sistema,
// como Ctrl+→ para cambiar de escritorio, miran el estado real de Control/Command.
let src = CGEventSource(stateID: .hidSystemState)
var mods: [(CGKeyCode, CGEventFlags)] = []
if flags.contains(.maskControl) { mods.append((59, .maskControl)) }
if flags.contains(.maskCommand) { mods.append((55, .maskCommand)) }
if flags.contains(.maskAlternate) { mods.append((58, .maskAlternate)) }
if flags.contains(.maskShift) { mods.append((56, .maskShift)) }
var held: CGEventFlags = []
func post(_ k: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: down)
    e?.flags = f
    e?.post(tap: .cghidEventTap)
    usleep(8_000)
}
for (k, f) in mods { held.insert(f); post(k, true, held) }
post(key, true, flags)
post(key, false, flags)
for (k, f) in mods.reversed() { held.remove(f); post(k, false, held) }
