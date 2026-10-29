import AppKit
import Foundation
import WebKit

struct SourceIcon: Decodable {
  let title: String
  let slug: String?
  let hex: String?
  let altNames: [String]?
}

struct CustomIcons: Decodable {
  let icons: [SourceIcon]
}

struct CatalogIcon: Encodable {
  let source: String
  let slug: String
  let hex: String?
}

struct Catalog: Encodable {
  var custom: [String: CatalogIcon] = [:]
  var simple: [String: CatalogIcon] = [:]
}

func normalize(_ title: String) -> String {
  title.replacingOccurrences(of: " ", with: "").lowercased()
}

func simpleStem(_ title: String) -> String {
  let substitutions: [Character: String] = [
    "á": "a", "à": "a", "â": "a", "ä": "a", "ã": "a",
    "é": "e", "è": "e", "ê": "e", "ë": "e",
    "í": "i", "ì": "i", "î": "i", "ï": "i",
    "ó": "o", "ò": "o", "ô": "o", "ö": "o",
    "ú": "u", "ù": "u", "û": "u", "ü": "u",
    "ç": "c", "ñ": "n", "ř": "r", "š": "s", "ż": "z",
    ".": "dot", "-": "", "&": "and", "+": "plus", ":": "", "'": "",
    "/": "", "!": "", "_": "", "°": "",
  ]
  return title.map { substitutions[$0] ?? String($0) }.joined()
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func rasterize(_ icons: [[String: String]], to output: URL, using web: WKWebView) throws {
  var response: Result<Any, Error>?
  web.callAsyncJavaScript("""
    return await Promise.all(icons.map(async ({key, svg}) => {
      const image = new Image();
      image.src = 'data:image/svg+xml;base64,' + svg;
      await image.decode();
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 78;
      const context = canvas.getContext('2d');
      const scale = 78 / Math.max(image.naturalWidth, image.naturalHeight);
      const width = image.naturalWidth * scale, height = image.naturalHeight * scale;
      context.drawImage(image, (78 - width) / 2, (78 - height) / 2, width, height);
      const pixels = context.getImageData(0, 0, 78, 78).data;
      if (!pixels.some((value, index) => index % 4 === 3 && value > 0)) {
        throw new Error('Empty SVG render: ' + key);
      }
      return {key, png: canvas.toDataURL('image/png').split(',')[1]};
    }));
    """, arguments: ["icons": icons], in: nil, in: .page, completionHandler: { response = $0 })
  let deadline = Date().addingTimeInterval(30)
  while response == nil && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  }
  guard let response, let results = try response.get() as? [[String: String]],
    results.count == icons.count else { throw CocoaError(.fileReadCorruptFile) }
  for result in results {
    guard let key = result["key"], let encoded = result["png"],
      let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
    try data.write(to: output.appending(path: "\(key).png"))
  }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let decoder = JSONDecoder()
let custom = try decoder.decode(CustomIcons.self, from: Data(contentsOf:
  root.appending(path: "vendor/ente/mobile/apps/auth/assets/custom-icons/_data/custom-icons.json")))
let simple = try decoder.decode([SourceIcon].self, from: Data(contentsOf:
  root.appending(path: "vendor/simple-icons/_data/simple-icons.json")))
var catalog = Catalog()
var rendered: Set<String> = []
var images: [[String: String]] = []
for (source, icons, base) in [
  ("custom", custom.icons, "vendor/ente/mobile/apps/auth/assets/custom-icons"),
  ("simple", simple, "vendor/simple-icons"),
] {
  for icon in icons {
    try autoreleasepool {
      let title = normalize(icon.title)
      let slug = icon.slug ?? (source == "custom" ? title : simpleStem(title))
      let record = CatalogIcon(source: source, slug: slug, hex: icon.hex)
      let key = "\(source)-\(slug)"
      if rendered.insert(key).inserted {
        let svg = try Data(contentsOf: root.appending(path: "\(base)/icons/\(slug).svg"))
        images.append(["key": key, "svg": svg.base64EncodedString()])
      }
      if source == "custom" {
        catalog.custom[title] = record
        for alias in icon.altNames ?? [] { catalog.custom[normalize(alias)] = record }
      } else {
        guard let hex = icon.hex, hex.count == 6, UInt32(hex, radix: 16) != nil else {
          throw CocoaError(.fileReadCorruptFile)
        }
        catalog.simple[title] = record
      }
    }
  }
}
NSApplication.shared.setActivationPolicy(.prohibited)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 78, height: 78), configuration: configuration)
web.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:\">", baseURL: nil)
let deadline = Date().addingTimeInterval(30)
while web.isLoading && Date() < deadline {
  RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
for start in stride(from: 0, to: images.count, by: 64) {
  try rasterize(Array(images[start..<min(start + 64, images.count)]), to: output, using: web)
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
try encoder.encode(catalog).write(to: output.appending(path: "catalog.json"))
print("Generated \(rendered.count) icons; \(catalog.custom.count) custom and \(catalog.simple.count) simple lookup names")
