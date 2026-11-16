import AppKit

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
canvas.fill()

// An e-paper sheet with a single blue update stroke. The mark stays legible at Dock sizes.
let shell = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 210, yRadius: 210)
NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.96, alpha: 1).setFill()
shell.fill()

let paper = NSBezierPath(roundedRect: NSRect(x: 194, y: 183, width: 636, height: 658), xRadius: 48, yRadius: 48)
NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
paper.fill()
let inset = NSBezierPath(roundedRect: NSRect(x: 213, y: 202, width: 598, height: 620), xRadius: 32, yRadius: 32)
NSColor(calibratedWhite: 0.995, alpha: 1).setFill()
inset.fill()

let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
ink.setFill()
NSBezierPath(roundedRect: NSRect(x: 273, y: 654, width: 342, height: 44), xRadius: 14, yRadius: 14).fill()
NSBezierPath(roundedRect: NSRect(x: 273, y: 566, width: 477, height: 28), xRadius: 10, yRadius: 10).fill()
NSBezierPath(roundedRect: NSRect(x: 273, y: 510, width: 406, height: 28), xRadius: 10, yRadius: 10).fill()
NSBezierPath(roundedRect: NSRect(x: 273, y: 454, width: 453, height: 28), xRadius: 10, yRadius: 10).fill()

let blue = NSColor(calibratedRed: 0.02, green: 0.43, blue: 0.91, alpha: 1)
blue.setFill()
NSBezierPath(roundedRect: NSRect(x: 273, y: 317, width: 477, height: 42), xRadius: 16, yRadius: 16).fill()
ink.setFill()
NSBezierPath(roundedRect: NSRect(x: 273, y: 317, width: 213, height: 42), xRadius: 16, yRadius: 16).fill()

// A detached corner suggests a fresh frame being sent to the display.
blue.setFill()
let corner = NSBezierPath()
corner.move(to: NSPoint(x: 705, y: 778))
corner.line(to: NSPoint(x: 778, y: 778))
corner.line(to: NSPoint(x: 778, y: 705))
corner.line(to: NSPoint(x: 755, y: 705))
corner.line(to: NSPoint(x: 755, y: 755))
corner.line(to: NSPoint(x: 705, y: 755))
corner.close()
corner.fill()

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("icon render failed") }
try png.write(to: URL(fileURLWithPath: "Assets/AppIcon.png"))
