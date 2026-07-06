import Foundation
import Observation
import CastorEngine

@MainActor
@Observable
final class AppState {
    let engineVersion = Castor.version
}
