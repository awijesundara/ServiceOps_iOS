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

// Dashboards and projects: responses captured from the server's mobile API.
let dashboardListing = try decoder.decode(DataEnvelope<DashboardListing>.self, from: Data(#"{"data":{"dashboards":[{"description":"","group":null,"home":true,"id":1,"name":"My dashboard","scope":"personal"}],"home_id":1}}"#.utf8))
require(dashboardListing.data.dashboards.contains { $0.id == dashboardListing.data.homeId && $0.home }, "The home dashboard must be listed and marked")
let dashboard = try decoder.decode(DataEnvelope<DashboardDocument>.self, from: Data(#"{"data":{"description":"","editable":true,"group":null,"home":true,"id":1,"name":"My dashboard","scope":"personal","widgets":[{"id":1,"key":"ticket_counts","span":3,"team":null,"tiles":[{"count":6,"label":"Open","list":{"filter":[{"field":"assignee","op":"eq","value":"1"},{"field":"open","op":"eq","value":"1"}],"kind":"all"},"tone":""},{"count":3,"label":"Priority 1 and 2","list":{"filter":[{"field":"assignee","op":"eq","value":"1"},{"field":"open","op":"eq","value":"1"},{"field":"urgent","op":"eq","value":"1"}],"kind":"all"},"tone":"warn"},{"count":0,"label":"Unassigned","list":{"filter":[{"field":"assignee","op":"eq","value":"1"},{"field":"open","op":"eq","value":"1"},{"field":"unassigned","op":"eq","value":"1"}],"kind":"all"},"tone":""},{"count":0,"label":"SLA breached","list":{"filter":[{"field":"assignee","op":"eq","value":"1"},{"field":"sla","op":"eq","value":"breached"}],"kind":"all"},"tone":""}],"title":"Ticket counts","view":"tiles"},{"id":2,"key":"ticket_list","list":{"filter":[{"field":"assignee","op":"eq","value":"1"},{"field":"open","op":"eq","value":"1"}],"kind":"all"},"span":2,"team":null,"tickets":[{"category":"Infrastructure","closure_category":null,"closure_subcategory":null,"id":10,"internal":{"assigned_to":{"id":1,"name":"System Administrator"},"assignment_group":{"id":6,"name":"Network"}},"number":"CHG0000010","opened_at":"2026-10-18T15:36:28.782902","priority":"P2","resolution_notes":null,"resolved_at":null,"state":"Implemented","subcategory":"","title":"Emergency firewall rule rollback on EDGE-FW01","type":"change","updated_at":"2026-10-18T15:36:28.838886","description":"Example"}],"title":"Ticket list","view":"tickets"},{"bars":[{"count":2,"label":"P2","list":{"filter":[{"field":"assignee","op":"eq","value":"1"},{"field":"open","op":"eq","value":"1"},{"field":"priority","op":"eq","value":"P2"}],"kind":"incident"}},{"count":2,"label":"P3","list":{"filter":[{"field":"assignee","op":"eq","value":"1"},{"field":"open","op":"eq","value":"1"},{"field":"priority","op":"eq","value":"P3"}],"kind":"incident"}}],"id":6,"key":"ticket_chart","list":{"filter":[{"field":"assignee","op":"eq","value":"1"},{"field":"open","op":"eq","value":"1"}],"kind":"incident"},"span":1,"team":null,"title":"Ticket chart","total":4,"view":"bars"},{"days":[{"date":"2026-10-05","opened":0,"resolved":0},{"date":"2026-10-06","opened":0,"resolved":0}],"id":7,"key":"ticket_trend","opened_total":4,"resolved_total":0,"span":2,"team":null,"title":"Opened and resolved","view":"trend"},{"id":8,"key":"team_workload","members":[],"missing_team":true,"span":1,"team":null,"title":"Team workload","view":"workload"},{"articles":[{"category":"Configuration Management","created_at":"2026-10-18T15:36:28.807486","id":5,"title":"CMDB data quality guidelines"}],"id":10,"key":"knowledge","span":1,"team":null,"title":"New knowledge","view":"articles"},{"disabled":false,"id":11,"key":"work_items","span":1,"team":null,"title":"My work items","view":"work_items","work_items":[{"due_date":"2026-12-01","key":"WEB-2","priority":"medium","project":"WEB","status":{"category":"todo","name":"To do"},"title":"Passkeys"}]},{"id":15,"key":"note","paragraphs":["On call: Database team"],"span":1,"team":null,"title":"Note","view":"note"}]}}"#.utf8)).data
require(dashboard.widgets.map(\.view) == ["tiles", "tickets", "bars", "trend", "workload", "articles", "work_items", "note"], "Every widget view must decode")
require(dashboard.widgets[0].tiles?.count == 4 && dashboard.widgets[0].tiles?.first?.list?.kind == "all", "Count tiles must carry their list reference")
require(dashboard.widgets[1].tickets?.first?.number.isEmpty == false, "Ticket widgets must decode full tickets")
require(dashboard.widgets[3].days?.count == 2, "Trend days must decode")
require(dashboard.widgets[4].missingTeam == true, "A workload widget without a team must say so")
require(dashboard.widgets[7].paragraphs == ["On call: Database team"], "Notes must decode")
let reference = TicketListReference(kind: "all", filter: [.init(field: "open", op: "eq", value: "1")])
require(reference.filterParameter == #"[{"field":"open","op":"eq","value":"1"}]"#, "The filter parameter must match the web list link")
let ticketList = try decoder.decode(DashboardTicketPage.self, from: Data(#"{"data":[{"attachments":[],"category":"Infrastructure","closure_category":null,"closure_subcategory":null,"description":"Example","id":10,"internal":{"assigned_to":{"id":1,"name":"System Administrator"},"assignment_group":{"id":6,"name":"Network"}},"number":"CHG0000010","opened_at":"2026-10-18T15:36:28.782902","priority":"P2","resolution_notes":null,"resolved_at":null,"state":"Implemented","subcategory":"","title":"Emergency firewall rule rollback on EDGE-FW01","type":"change","updated_at":"2026-10-18T15:36:28.838886"}],"meta":{"has_more":true,"limit":2,"next_cursor":"eyJzY29wZSI6WzEsMSwiL2FwaS92MS9tb2JpbGUvdGlja2V0LWxpc3QiLCIiXSwidmFsdWVzIjpbIjIwMjYtMTAtMThUMTU6MzY6MjguODM4MDAzIiw5XX0.c8Jg-K1mE66Jxl9KxXRzhh85jg8","returned":2,"total":6}}"#.utf8))
require(ticketList.meta.total >= ticketList.data.count && ticketList.meta.hasMore != nil, "Ticket list pages must report the full count")
let project = try decoder.decode(DataEnvelope<ProjectSummary>.self, from: Data(#"{"data":{"archived":false,"description":"","key":"WEB","lead":"admin","name":"Customer portal","statuses":[{"category":"todo","id":1,"name":"To do","wip_limit":null},{"category":"in_progress","id":2,"name":"In progress","wip_limit":null},{"category":"in_progress","id":3,"name":"In review","wip_limit":null},{"category":"done","id":4,"name":"Done","wip_limit":null}],"visibility":"open"}}"#.utf8)).data
require(project.key == "WEB" && !project.statuses.isEmpty, "Projects must decode with their statuses")
let workItem = try decoder.decode(DataEnvelope<WorkItem>.self, from: Data(#"{"data":{"affects_versions":[],"assignees":["admin"],"comments":[{"author":"admin","body":"Looks good","created_at":"2026-10-18T15:36:28.900100","id":1}],"components":[],"created_at":"2026-10-18T15:36:28.895375","description":"","due_date":"2026-12-01","environment":"","estimate_minutes":null,"fix_versions":[],"flagged":false,"form_responses":[],"key":"WEB-2","labels":["ios"],"parent":"WEB-1","priority":"medium","project":"WEB","remaining_minutes":null,"reporter":"admin","resolution":null,"resolved_at":null,"spent_minutes":0,"start_date":null,"status":{"category":"todo","id":1,"name":"To do"},"story_points":3.0,"title":"Passkeys","type":"story","updated_at":"2026-10-18T15:36:28.908042"}}"#.utf8)).data
require(workItem.key == "WEB-2" && workItem.storyPoints == 3 && workItem.comments?.count == 1 && !workItem.isDone, "Work items must decode with comments")
let resolvedMine = try scopedTicket(id: 5, state: "Resolved", priority: "P1", type: "incident", assignee: 4, group: 9)
require(!TicketScope.open.matches(resolvedMine, userID: 4, groupIDs: [9]), "Resolved records are not open, as on the web")
print("Dashboard, ticket list and project decoding regressions passed")
