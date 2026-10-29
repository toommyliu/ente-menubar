import AppCore
import AppKit

@main struct ContextCheck {
  @MainActor static func main() async {
    guard let browser = NSWorkspace.shared.runningApplications.first(where: {
      $0.bundleIdentifier == "net.imput.helium"
    }), let bundleID = browser.bundleIdentifier else {
      print("No running Helium browser")
      exit(1)
    }
    let provider = LiveContextProvider()
    let context = await provider.context(
      for: ApplicationContext(bundleID: bundleID, name: browser.localizedName ?? "Helium"),
      websiteSuggestions: true)
    guard let hostname = context.hostname else {
      print("No hostname available")
      exit(1)
    }
    print(hostname)
  }
}
