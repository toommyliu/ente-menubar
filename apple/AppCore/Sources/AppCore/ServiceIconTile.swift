import AppKit
import SwiftUI

@MainActor final class ServiceIconImages {
  static let shared = ServiceIconImages()
  private let images = NSCache<NSString, NSImage>()

  func image(for icon: ServiceIcon) -> NSImage? {
    if let image = images.object(forKey: icon.key as NSString) { return image }
    guard let url = Bundle.module.url(forResource: icon.key, withExtension: "png",
                                     subdirectory: "GeneratedIcons"),
      let image = NSImage(contentsOf: url) else { return nil }
    images.setObject(image, forKey: icon.key as NSString)
    return image
  }
}

struct ServiceIconTile: View {
  let issuer: String
  let account: String
  let iconSrc: String
  let iconID: String
  @State private var loaded: LoadedIcon?
  @Environment(\.colorScheme) private var colorScheme

  private struct LoadedIcon {
    let icon: ServiceIcon
    let image: NSImage
  }

  var body: some View {
    Group {
      if let loaded {
        let brand = loaded.icon.hex.map(IconBrandColor.init)
        Image(nsImage: loaded.image)
          .resizable()
          .renderingMode(loaded.icon.source == .simple ? .template : .original)
          .scaledToFit()
          .frame(width: 19, height: 19)
          .foregroundStyle(brand?.usesBlackGlyph == true ? Color.black : .white)
          .frame(width: 26, height: 26)
          .background(
            loaded.icon.source == .simple
              ? Color(red: brand?.red ?? 0, green: brand?.green ?? 0, blue: brand?.blue ?? 0)
              : Color(white: 0.96),
            in: RoundedRectangle(cornerRadius: 7)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 7)
              .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1),
                            lineWidth: 0.5)
          }
      } else {
        Text(String((issuer.isEmpty ? account : issuer).prefix(1)).uppercased())
          .font(.system(size: 12, weight: .bold))
          .frame(width: 26, height: 26)
          .foregroundStyle(.white)
          .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
      }
    }
    .accessibilityHidden(true)
    .onChange(of: IconRequest(issuer: issuer, iconSrc: iconSrc, iconID: iconID), initial: true) {
      _, request in
      if let icon = IconCatalog.bundled.match(request),
        let image = ServiceIconImages.shared.image(for: icon) {
        loaded = LoadedIcon(icon: icon, image: image)
      } else {
        loaded = nil
      }
    }
  }
}
