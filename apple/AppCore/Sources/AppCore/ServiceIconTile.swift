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
        let tinted = brand != nil || loaded.icon.source == .simple
        Image(nsImage: loaded.image)
          .resizable()
          .renderingMode(tinted ? .template : .original)
          .interpolation(.high)
          .scaledToFit()
          .foregroundStyle(tint(brand))
          .frame(width: 20, height: 20)
          .frame(width: 24, height: 24)
      } else {
        Text(String((issuer.isEmpty ? account : issuer).prefix(1)).uppercased())
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 22, height: 22)
          .foregroundStyle(.secondary)
          .background(Color.primary.opacity(0.09), in: Circle())
          .frame(width: 24, height: 24)
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

  private func tint(_ brand: IconBrandColor?) -> Color {
    guard let brand, !brand.usesThemeColor(dark: colorScheme == .dark) else { return .primary }
    return Color(red: brand.red, green: brand.green, blue: brand.blue)
  }
}
