// Generated offline by generate-catalog.py. Commit this file; do not edit it.
import SwiftUI
import AssetLib

enum AssetCatalog {
    enum `Travel` {
        static let `coast` = AssetReference(key: "travel.coast", width: 1200, height: 900)
        static let `ridge` = AssetReference(key: "travel.ridge", width: 1200, height: 900)
    }
    enum `Tasks` {
        static let `garden` = AssetReference(key: "tasks.garden", width: 600, height: 400)
    }
    static let all: [AssetReference] = [`Travel`.`coast`, `Travel`.`ridge`, `Tasks`.`garden`]
}

@MainActor struct AppArtwork {
    let store: AssetImageStore
    var bundle: Bundle = .main
    var `travel`: `Travel` { `Travel`(store: store, bundle: bundle) }
    @MainActor struct `Travel` {
        let store: AssetImageStore
        let bundle: Bundle
        var `coast`: Image { store.image(for: AssetCatalog.`Travel`.`coast`, fallback: Image(decorative: "coast", bundle: bundle)) }
        func `coastArtwork`(locale: Locale = .current, requireDescription: Bool = false) -> AssetArtwork {
            store.artwork(for: AssetCatalog.`Travel`.`coast`, fallback: Image(decorative: "coast", bundle: bundle), bundledAccessibility: try! AssetAccessibility(defaultLocale: "en", descriptions: ["en": "A coastal landscape with blue water and cliffs"]), locale: locale, requireDescription: requireDescription)
        }
        var `ridge`: Image { store.image(for: AssetCatalog.`Travel`.`ridge`, fallback: Image(decorative: "ridge", bundle: bundle)) }
        func `ridgeArtwork`(locale: Locale = .current, requireDescription: Bool = false) -> AssetArtwork {
            store.artwork(for: AssetCatalog.`Travel`.`ridge`, fallback: Image(decorative: "ridge", bundle: bundle), bundledAccessibility: try! AssetAccessibility(defaultLocale: "en", descriptions: ["en": "A mountain landscape with layered ridges"]), locale: locale, requireDescription: requireDescription)
        }
    }
    var `tasks`: `Tasks` { `Tasks`(store: store, bundle: bundle) }
    @MainActor struct `Tasks` {
        let store: AssetImageStore
        let bundle: Bundle
        var `garden`: Image { store.image(for: AssetCatalog.`Tasks`.`garden`, fallback: Image(decorative: "garden", bundle: bundle)) }
        func `gardenArtwork`(locale: Locale = .current, requireDescription: Bool = false) -> AssetArtwork {
            store.artwork(for: AssetCatalog.`Tasks`.`garden`, fallback: Image(decorative: "garden", bundle: bundle), bundledAccessibility: try! AssetAccessibility(defaultLocale: "en", descriptions: ["en": "A small garden of green plants"]), locale: locale, requireDescription: requireDescription)
        }
    }
}
