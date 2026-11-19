// send-key: manda una combinación de teclas al instante (sin el arranque lento de osascript).
// Uso: send-key <ctrl|cmd|alt|shift>[+…] <left|right|up|down|w|keycode>
// Ej.: send-key ctrl left   → escritorio anterior;  send-key cmd w → cerrar ventana.
// Lo ejecuta skhd (usa su permiso de Accesibilidad para enviar teclas).
import CoreGraphics
import Foundation

let args = CommandLine.arguments

// ---------- send-key swipe left|right [velocidad]: gesto de trackpad para cambiar de escritorio ----------
// Simula el deslizamiento de 3/4 dedos (evento privado "dock swipe", el mismo que usa Mac Mouse
// Fix): macOS hace su animación nativa, pero corta como un deslizamiento rápido, en vez de la
// animación lenta fija de Ctrl+←/→. API no documentada: puede romperse con una actualización.
if args.count >= 3, args[1] == "swipe" {
    let right = args[2] == "right"
    let speed = args.count >= 4 ? (Double(args[3]) ?? 3) : 3
    func post(phase: Int64, progress: Double, velocity: Double) {
        guard let e30 = CGEvent(source: nil), let e29 = CGEvent(source: nil) else { return }
        e30.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)       // kCGSEventDockControl
        e30.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)      // kIOHIDEventTypeDockSwipe
        e30.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)   // fase del gesto
        e30.setIntegerValueField(CGEventField(rawValue: 134)!, value: phase)
        e30.setDoubleValueField(CGEventField(rawValue: 124)!, value: progress) // avance del gesto
        var f = Float32(progress)
        e30.setIntegerValueField(CGEventField(rawValue: 135)!, value: Int64(withUnsafeBytes(of: &f) { $0.load(as: UInt32.self) }))
        e30.setIntegerValueField(CGEventField(rawValue: 41)!, value: 33231)
        e30.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)       // horizontal
        e30.setIntegerValueField(CGEventField(rawValue: 165)!, value: 1)
        if phase == 4 {                                                         // fin: velocidad de salida
            e30.setDoubleValueField(CGEventField(rawValue: 129)!, value: velocity)
            e30.setDoubleValueField(CGEventField(rawValue: 130)!, value: velocity)
        }
        e29.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)       // kCGSEventGesture
        e29.setIntegerValueField(CGEventField(rawValue: 41)!, value: 33231)
        e30.post(tap: .cgSessionEventTap)
        e29.post(tap: .cgSessionEventTap)
    }
    let dir: Double = right ? 1 : -1
    post(phase: 1, progress: 0, velocity: 0)                     // empieza
    usleep(8_000)
    post(phase: 2, progress: 0.05 * dir, velocity: 0)            // un poco de avance
    usleep(8_000)
    post(phase: 4, progress: 0.05 * dir, velocity: speed * dir)  // suelta con velocidad
    exit(0)
}

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
