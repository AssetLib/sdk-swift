import SwiftUI
import AssetLib

// Compiled examples: native Image values with explicit per-usage accessibility.
struct WelcomeView: View {
    @State private var images = AssetImageStore()
    let client: AssetClient
    private var artwork: AppArtwork { AppArtwork(store: images) }

    var body: some View {
        artwork.travel.coast
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
            .task {
                images.connect(client)
                await images.refresh(AssetCatalog.all)
            }
    }
}

struct InformativeCoastView: View {
    @Environment(\.locale) private var locale
    let artwork: AppArtwork

    var body: some View {
        let coast = artwork.travel.coastArtwork(locale: locale, requireDescription: true)
        if let description = coast.accessibilityDescription {
            coast.image
                .resizable()
                .scaledToFit()
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(Text(verbatim: description))
        } else {
            Text("Explore coastal trips")
        }
    }
}
