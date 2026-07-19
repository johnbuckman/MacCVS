import AppKit

// Draw a 1024x1024 master icon: rounded gradient tile with a version-tree glyph and "CVS".
let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let inset = rect.insetBy(dx: 60, dy: 60)
let path = NSBezierPath(roundedRect: inset, xRadius: 200, yRadius: 200)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.34, blue: 0.62, alpha: 1),
    NSColor(calibratedRed: 0.11, green: 0.20, blue: 0.42, alpha: 1)
])!
gradient.draw(in: path, angle: -90)

// Branch/commit graph motif.
let dot = { (x: CGFloat, y: CGFloat, r: CGFloat, c: NSColor) in
    c.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
}
let line = NSBezierPath()
line.lineWidth = 26
NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
line.move(to: NSPoint(x: 330, y: 760))
line.line(to: NSPoint(x: 330, y: 470))
line.curve(to: NSPoint(x: 560, y: 340),
           controlPoint1: NSPoint(x: 330, y: 400),
           controlPoint2: NSPoint(x: 470, y: 340))
line.stroke()
let white = NSColor.white
dot(330, 760, 50, white)
dot(330, 560, 44, NSColor(calibratedRed: 0.55, green: 0.78, blue: 1.0, alpha: 1))
dot(560, 340, 50, NSColor(calibratedRed: 0.55, green: 0.90, blue: 0.70, alpha: 1))

// Wordmark.
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 190, weight: .heavy),
    .foregroundColor: NSColor.white,
    .paragraphStyle: para
]
let text = "CVS" as NSString
let tSize = text.size(withAttributes: attrs)
text.draw(in: NSRect(x: 0, y: 140, width: CGFloat(size), height: tSize.height), withAttributes: attrs)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("icon render failed"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: "icon_master.png"))
print("wrote icon_master.png")
