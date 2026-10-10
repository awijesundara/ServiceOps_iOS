import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

require(RackLayout.offset(capacity: 12, position: 12, height: 1) == 0, "Top unit must draw at the top")
require(RackLayout.offset(capacity: 12, position: 1, height: 3) == 9, "Bottom device must fit exactly")
require(RackLayout.offset(capacity: 24, position: 8.5, height: 2) == 14.5, "Fractional positions must remain exact")
require(RackLayout.offset(capacity: 12, position: 12, height: 2) == nil, "Overflow must be rejected")
require(RackLayout.offset(capacity: 12, position: nil, height: 1) == nil, "Missing position must stay unplaced")
require(RackLayout.offset(capacity: 12, position: 1, height: nil) == nil, "Missing height must stay unplaced")
require(RackLayout.offset(capacity: 12, position: .nan, height: 1) == nil, "Non-finite positions must be rejected")
require(!RackLayout.hasOverlap(capacity: 12, placements: [(1, 2), (3, 1)]), "Adjacent devices must remain valid")
require(RackLayout.hasOverlap(capacity: 12, placements: [(1, 3), (2, 1)]), "Overlapping devices must be flagged")
let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
let legacy = try decoder.decode(ConfigurationItemSummary.self, from: Data(#"{"id":1,"name":"example-server","ci_class":"Server","environment":"Production","status":"Operational","rack":{"name":"Example rack","site":"Example site","position":8,"u_height":2,"face":"front"}}"#.utf8))
require(legacy.rack?.id == nil && legacy.rack?.capacity == nil, "Old asset responses must remain compatible")
let rack = try decoder.decode(RackViewEnvelope.self, from: Data(#"{"data":{"id":3,"name":"Example rack","site":"Example site","capacity":12,"active":true,"assets":[{"id":1,"name":"Example device","ci_class":"Server","status":"Operational","position":8.5,"u_height":2,"face":"front"}]},"meta":{"truncated":false,"limit":1000}}"#.utf8))
require(rack.data.stats == nil, "Optional rack totals must support older servers")
require(rack.data.assets.first?.position == 8.5, "Rack decoding must preserve fractional units")
require(rack.data.assets.first?.placementNote == nil, "Older device metadata must remain compatible")
print("Rack layout and backward-compatible asset/rack decoding regressions passed")
