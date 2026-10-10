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

let legacyTicket = #"{"id":1,"number":"INC0000001","type":"incident","title":"Example","description":"Example record","state":"New","priority":"P2","category":"Hardware","opened_at":"2026-10-10T00:00:00Z","updated_at":"2026-10-10T00:00:00Z"}"#
let oldTicket = try decoder.decode(ServiceTicket.self, from: Data(legacyTicket.utf8))
require(oldTicket.details == nil && oldTicket.configurationItems == nil, "Older ticket responses must remain compatible")
let ciJSON = #"{"id":7,"name":"example-server","ci_class":"Server","environment":"Production","status":"Operational","relationship_role":"Primary CI","ip_address":"192.0.2.7","rack":{"id":3,"name":"Example rack","site":"Example site","capacity":42,"position":8.5,"u_height":2,"face":"rear"}}"#
let detailJSON = "{\"schema_version\":1,\"can_manage\":true,\"allowed_states\":[\"New\",\"In Progress\"],\"configuration_items\":[" + ciJSON + "],\"sections\":[{\"id\":\"history\",\"title\":\"Event history\",\"entries\":[{\"id\":\"1\",\"title\":\"Record created\",\"fields\":[{\"label\":\"Details\",\"value\":null}]}]}]}"
let richTicketJSON = String(legacyTicket.dropLast()) + ",\"configuration_items\":[" + ciJSON + "],\"details\":" + detailJSON + "}"
let richTicket = try decoder.decode(ServiceTicket.self, from: Data(richTicketJSON.utf8))
require(richTicket.details?.configurationItems.first?.rack?.position == 8.5, "Ticket CI decoding must preserve exact rack positions")
require(richTicket.details?.allowedStates == ["New", "In Progress"], "Server transitions must survive decoding")
require(richTicket.details?.sections.first?.entries.first?.fields.first?.value == nil, "Missing recorded fields must remain null")
require(richTicket.configurationItems?.first?.relationshipRole == "Primary CI", "Ticket CI roles must be retained")
print("Legacy and rich ticket-detail decoding regressions passed")

let oldProfile = try decoder.decode(MobileProfile.self, from: Data(#"{"id":4,"username":"agent","name":"Example Agent","role":"agent"}"#.utf8))
require(oldProfile.hasAvatar == nil, "Profiles from servers without avatars must remain compatible")
let avatarProfile = try decoder.decode(MobileProfile.self, from: Data(#"{"id":4,"username":"agent","name":"Example Agent","role":"agent","has_avatar":true}"#.utf8))
require(avatarProfile.hasAvatar == true, "The avatar flag must decode")
func scopedTicket(id: Int, state: String, priority: String, type: String, assignee: Int?, group: Int?) throws -> ServiceTicket {
    let assignedTo = assignee.map { #"{"id":\#($0),"name":"Person"}"# } ?? "null"
    let assignmentGroup = group.map { #"{"id":\#($0),"name":"Group"}"# } ?? "null"
    let json = #"{"id":\#(id),"number":"INC\#(id)","type":"\#(type)","title":"Example","description":"Example","state":"\#(state)","priority":"\#(priority)","category":"General","opened_at":"2026-10-10T00:00:00Z","updated_at":"2026-10-10T00:00:00Z","internal":{"assignment_group":\#(assignmentGroup),"assigned_to":\#(assignedTo)}}"#
    return try decoder.decode(ServiceTicket.self, from: Data(json.utf8))
}
let mineP1 = try scopedTicket(id: 1, state: "In Progress", priority: "P1", type: "incident", assignee: 4, group: 9)
let closedMine = try scopedTicket(id: 2, state: "Closed", priority: "P1", type: "incident", assignee: 4, group: 9)
let otherP2Change = try scopedTicket(id: 3, state: "New", priority: "P2", type: "change", assignee: 5, group: 8)
let unassignedP3 = try scopedTicket(id: 4, state: "New", priority: "P3", type: "incident", assignee: nil, group: nil)
let scoped = [mineP1, closedMine, otherP2Change, unassignedP3]
func ids(_ scope: TicketScope) -> [Int] { scoped.filter { scope.matches($0, userID: 4, groupIDs: [9]) }.map(\.id) }
require(ids(.open) == [1, 3, 4], "Open must exclude closed records")
require(ids(.assignedToMe) == [1], "Assigned to me must match the signed-in user's open records")
require(ids(.myGroups) == [1], "My group's work must match the user's assignment groups")
require(ids(.majorIncidents) == [1], "Major incidents must be open P1 incidents only")
require(ids(.highRisk) == [1, 3], "High risk must be open P1 and P2 records")
require(!TicketScope.assignedToMe.matches(mineP1, userID: nil, groupIDs: []), "Without a profile nothing is assigned to me")
print("Profile avatar flag and widget filter regressions passed")
