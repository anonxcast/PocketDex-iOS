import Foundation

/// Shared sampler interface for Gen 1 / Gen 2 / Gen 3 companion reads.
protocol CompanionSampling: AnyObject {
  func sample() -> CompanionSnapshot?
}
