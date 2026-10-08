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
        var `coast`: Image { store.image(for: AssetCatalog.`Travel`.`coast`, fallback: Image("coast", bundle: bundle)) }
        var `ridge`: Image { store.image(for: AssetCatalog.`Travel`.`ridge`, fallback: Image("ridge", bundle: bundle)) }
    }
    var `tasks`: `Tasks` { `Tasks`(store: store, bundle: bundle) }
    @MainActor struct `Tasks` {
        let store: AssetImageStore
        let bundle: Bundle
        var `garden`: Image { store.image(for: AssetCatalog.`Tasks`.`garden`, fallback: Image("garden", bundle: bundle)) }
    }
}
