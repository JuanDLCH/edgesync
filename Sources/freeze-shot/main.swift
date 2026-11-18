// freeze-shot: captura con la pantalla CONGELADA. Toma una foto de todos los monitores al instante,
// la muestra encima a pantalla completa y se elige sobre esa foto (lo que pase debajo, p. ej.
// mensajes nuevos, no cambia la imagen). Resultado → portapapeles (PNG).
//   pasar el mouse = resalta la ventana · clic = esa ventana · clic en la barra de menú = monitor
//   completo · arrastrar = área · Esc = cancelar. Suena el obturador de macOS al capturar.
// Necesita permiso de Grabación de pantalla (lo hereda de quien lo ejecuta, p. ej. skhd).
import AppKit

// ---------- Foto de cada monitor (screencapture -x, un archivo por monitor) ----------
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("freeze-shot-\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

var displayCount: UInt32 = 0
CGGetActiveDisplayList(0, nil, &displayCount)
var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
CGGetActiveDisplayList(displayCount, &displays, &displayCount)

// Ventanas visibles en el momento de congelar, de adelante hacia atrás (coordenadas globales,
// arriba-izquierda). Solo apps normales: JankyBorders y similares también dibujan ventanas.
let windowsAtFreeze: [CGRect] = {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"], wd > 40, ht > 40 else { return nil }
        return CGRect(x: x, y: y, width: wd, height: ht)
    }
}()

let files = (0..<displays.count).map { tmp.appendingPathComponent("d\($0).png").path }
let cap = Process()
cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
cap.arguments = ["-x"] + files            // -x: sin sonido; un archivo por monitor, en el orden de la lista
try? cap.run(); cap.waitUntilExit()

var shots: [CGDirectDisplayID: CGImage] = [:]
for (i, d) in displays.enumerated() {
    if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: files[i]) as CFURL, nil),
       // cargarla ya (por defecto se decodifica al dibujar, y el archivo se borra enseguida → negro)
       let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
        shots[d] = img
    }
}
try? FileManager.default.removeItem(at: tmp)
if shots.isEmpty {
    FileHandle.standardError.write("freeze-shot: sin permiso de Grabación de pantalla\n".data(using: .utf8)!)
    exit(1)
}

// ---------- Interfaz ----------
let mainH = NSScreen.screens[0].frame.height
var overlays: [NSWindow] = []

let shutter = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)

func finish(_ image: CGImage?) {
    guard let img = image, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { exit(1) }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setData(png, forType: .png)
    // quitar la foto congelada ya y dejar sonar el obturador (el mismo de las capturas de macOS)
    for o in overlays { o.orderOut(nil) }
    shutter?.play()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
}

// Cursor en cruz propio: líneas blancas con borde oscuro (se ve sobre cualquier fondo) y un hueco
// en el centro para ver el pixel exacto
let crossCursor: NSCursor = {
    let size: CGFloat = 33, c = size / 2, gap: CGFloat = 3, arm: CGFloat = 14
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        func lines() {
            ctx.move(to: CGPoint(x: c - arm, y: c)); ctx.addLine(to: CGPoint(x: c - gap, y: c))
            ctx.move(to: CGPoint(x: c + gap, y: c)); ctx.addLine(to: CGPoint(x: c + arm, y: c))
            ctx.move(to: CGPoint(x: c, y: c - arm)); ctx.addLine(to: CGPoint(x: c, y: c - gap))
            ctx.move(to: CGPoint(x: c, y: c + gap)); ctx.addLine(to: CGPoint(x: c, y: c + arm))
        }
        ctx.setLineCap(.square)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor); ctx.setLineWidth(3); lines(); ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1); lines(); ctx.strokePath()
        return true
    }
    return NSCursor(image: img, hotSpot: NSPoint(x: c, y: c))
}()

final class Overlay: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ShotView: NSView {
    let image: CGImage
    let screenFrame: NSRect          // coordenadas de Cocoa
    var start: NSPoint? = nil
    var current: NSPoint? = nil
    var hover: NSRect? = nil         // ventana bajo el mouse (coordenadas de la vista)

    init(image: CGImage, screenFrame: NSRect) {
        self.image = image; self.screenFrame = screenFrame
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: crossCursor) }
    override func cursorUpdate(with event: NSEvent) { crossCursor.set() }
    // mouseMoved en todos los monitores, no solo en la ventana que tiene el teclado
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    var dragging: Bool {
        guard let s = start, let c = current else { return false }
        return abs(c.x - s.x) > 4 || abs(c.y - s.y) > 4
    }
    var selection: NSRect? {
        if dragging, let s = start, let c = current {
            return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
        }
        return hover
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(image, in: bounds)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        if let sel = selection {
            ctx.addRect(bounds); ctx.addRect(sel)
            ctx.fillPath(using: .evenOdd)              // oscurece todo menos la selección
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(dragging ? 1 : 2)
            ctx.stroke(sel.insetBy(dx: 1, dy: 1))
        } else {
            ctx.fill(bounds)
        }
    }

    // vista (Cocoa, origen abajo-izq) → recorte en píxeles de la foto (Retina = 2×)
    func crop(_ r: NSRect) -> CGImage? {
        let sx = CGFloat(image.width) / bounds.width, sy = CGFloat(image.height) / bounds.height
        let px = CGRect(x: r.minX * sx, y: (bounds.height - r.maxY) * sy, width: r.width * sx, height: r.height * sy).integral
        return image.cropping(to: px)
    }

    // Alto de la barra de menú (la mayor entre monitores: a veces un secundario dice que no tiene)
    var menuBarHeight: CGFloat {
        NSScreen.screens.map { $0.frame.maxY - $0.visibleFrame.maxY }.max() ?? 0
    }
    // Sobre la barra de menú → el monitor completo; si no, la ventana bajo el mouse
    func targetAt(_ p: NSPoint) -> NSRect? {
        if p.y >= bounds.height - max(menuBarHeight, 24) { return bounds }
        return windowAt(p)
    }

    func windowAt(_ p: NSPoint) -> NSRect? {
        let g = CGPoint(x: screenFrame.minX + p.x, y: mainH - (screenFrame.minY + p.y))   // global arriba-izq
        guard let w = windowsAtFreeze.first(where: { $0.contains(g) }) else { return nil }
        let r = NSRect(x: w.minX - screenFrame.minX, y: (mainH - w.maxY) - screenFrame.minY, width: w.width, height: w.height)
        return r.intersection(bounds)                  // solo la parte de este monitor
    }

    func setHover(_ p: NSPoint) {
        let h = targetAt(p)
        if h != hover { hover = h; needsDisplay = true }
        for o in overlays where o != window {          // los otros monitores sin resaltado
            if let v = o.contentView as? ShotView, v.hover != nil { v.hover = nil; v.needsDisplay = true }
        }
    }

    // el cursor se fija en cada movimiento: en ventanas sin foco macOS volvería a la flecha
    override func mouseMoved(with e: NSEvent) { crossCursor.set(); setHover(convert(e.locationInWindow, from: nil)) }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        start = p; current = p
    }
    override func mouseDragged(with e: NSEvent) {
        crossCursor.set()
        current = convert(e.locationInWindow, from: nil); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil)
        if dragging, let sel = selection { finish(crop(sel)); return }
        // clic sin arrastrar: la ventana bajo el mouse, o el monitor entero si es sobre la barra de menú
        if let r = targetAt(current!) { finish(crop(r)) }
        start = nil; current = nil; needsDisplay = true
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { finish(nil) }             // Esc
    }
    override func cancelOperation(_ sender: Any?) { finish(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

for scr in NSScreen.screens {
    guard let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let img = shots[CGDirectDisplayID(num.uint32Value)] else { continue }
    let w = Overlay(contentRect: scr.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .screenSaver
    w.isOpaque = true
    w.hasShadow = false
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let v = ShotView(image: img, screenFrame: scr.frame)
    w.contentView = v
    w.setFrame(scr.frame, display: true)
    overlays.append(w)
}

// Teclado (Esc) en el monitor del mouse; resaltar ya la ventana que está bajo el mouse
let mouse = NSEvent.mouseLocation
let keyOverlay = overlays.first { NSMouseInRect(mouse, $0.frame, false) } ?? overlays.first
for o in overlays { o.orderFrontRegardless() }
app.activate(ignoringOtherApps: true)
keyOverlay?.makeKeyAndOrderFront(nil)
crossCursor.set()
if let v = keyOverlay?.contentView as? ShotView {
    keyOverlay?.makeFirstResponder(v)
    v.setHover(v.convert(keyOverlay!.mouseLocationOutsideOfEventStream, from: nil))
}
app.run()
