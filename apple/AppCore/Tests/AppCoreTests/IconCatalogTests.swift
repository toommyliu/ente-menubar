import AppKit
import Testing

@testable import AppCore

struct IconCatalogTests {
  private let catalog = IconCatalog.bundled

  private func match(_ issuer: String, source: String = "", id: String = "") -> ServiceIcon? {
    catalog.match(IconRequest(issuer: issuer, iconSrc: source, iconID: id))
  }

  @Test func issuerNormalizationAndCandidateOrder() {
    #expect(match("github.com (Main account)") == ServiceIcon(source: .custom, slug: "github", hex: "181717"))
    #expect(match(" Git Hub (work) ")?.key == "custom-github")
    #expect(match("GitHub.com")?.key == "custom-github")
    #expect(match("Addy.io")?.key == "custom-addy_io")
    #expect(match("certificates.zaka.ai")?.key == "custom-accredible")
    #expect(match("GitHub%20%28work%29")?.key == "custom-github")
  }

  @Test func customAliasesAndSlugPaths() {
    #expect(match("UIDAI")?.key == "custom-aadhaar")
    #expect(match("Unique Identification Authority of India")?.key == "custom-aadhaar")
    #expect(match("Accredible Certificates")?.key == "custom-accredible")
    #expect(match("Google")?.key == "custom-google")
  }

  @Test func explicitChoiceWinsAndRequiresBothDisplayFields() {
    #expect(match("Steam", source: "ente", id: "Google")?.key == "custom-google")
    #expect(match("Google", source: "ente", id: "Steam")?.key == "simple-steam")
    #expect(match("Google", source: "simpleIcon", id: "GitHub")?.key == "custom-github")
    #expect(match("Steam", source: "", id: "Google")?.key == "simple-steam")
    #expect(match("Steam", source: "ente", id: "")?.key == "simple-steam")
    #expect(match("Google", source: "ente", id: "No such service 493") == nil)
  }

  @Test func simpleOnlyServiceAndUnknownIssuer() {
    #expect(match("Steam") == ServiceIcon(source: .simple, slug: "steam", hex: "000000"))
    #expect(match("Unlisted service 493") == nil)
    #expect(match("Counter") == nil)
    #expect(match("") == nil)
  }

  @Test func glyphContrastUsesLiteralBrandColors() {
    #expect(IconBrandColor(hex: "000000").usesThemeColor(dark: true) == true)
    #expect(IconBrandColor(hex: "000000").usesThemeColor(dark: false) == false)
    #expect(IconBrandColor(hex: "181717").usesThemeColor(dark: true) == true)
    #expect(IconBrandColor(hex: "FFFFFF").usesThemeColor(dark: false) == true)
    #expect(IconBrandColor(hex: "FFFFFF").usesThemeColor(dark: true) == false)
    #expect(IconBrandColor(hex: "F38020").usesThemeColor(dark: true) == false)
    #expect(IconBrandColor(hex: "FFFC00").usesThemeColor(dark: false) == false)
  }

  @Test @MainActor func imagesLoadByCatalogKey() throws {
    let google = try #require(match("Google"))
    let image = try #require(ServiceIconImages.shared.image(for: google))
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    #expect(bitmap.pixelsWide == 78)
    #expect(bitmap.pixelsHigh == 78)
    let center = try #require(bitmap.colorAt(x: 48, y: 39)?.usingColorSpace(.sRGB))
    #expect(center.blueComponent > 0.8)
    #expect(center.redComponent < 0.4)
    #expect(ServiceIconImages.shared.image(for: google) === image)
    let toshl = try #require(match("Toshl Finance"))
    let toshlImage = try #require(ServiceIconImages.shared.image(for: toshl))
    let toshlTiff = try #require(toshlImage.tiffRepresentation)
    let toshlBitmap = try #require(NSBitmapImageRep(data: toshlTiff))
    #expect(toshlBitmap.colorAt(x: 39, y: 39)?.alphaComponent == 1)
  }
}
