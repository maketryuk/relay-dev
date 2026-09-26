import Foundation

/// YouTrack's answers, as it writes them.
///
/// Everything is optional that a request might not have asked for or an
/// instance might not have: a field YouTrack does not return is simply absent,
/// and a card that fails to decode over a colour nobody set is a board with a
/// hole in it.
enum YouTrackWire {
    struct User: Decodable {
        var id: String?
        var login: String?
        var fullName: String?
        var avatarUrl: String?
    }

    struct Project: Decodable {
        var id: String
        var shortName: String?
        var name: String?
    }

    struct Color: Decodable {
        var background: String?
        var foreground: String?
    }

    struct Tag: Decodable {
        var name: String?
        var color: Color?
    }

    /// Any value a custom field can hold that is an object: a state, a
    /// person, a period, a block of text.
    struct Entity: Decodable {
        var id: String?
        var name: String?
        var localizedName: String?
        var login: String?
        var fullName: String?
        var avatarUrl: String?
        var presentation: String?
        var text: String?
        var minutes: Int?
        var isResolved: Bool?
        var color: Color?
    }

    /// A custom field's value, which is whatever the field's kind makes it.
    enum Value: Decodable {
        case none
        case one(Entity)
        case many([Entity])
        case number(Double)
        case string(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .none
            } else if let many = try? container.decode([Entity].self) {
                self = .many(many)
            } else if let one = try? container.decode(Entity.self) {
                self = .one(one)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else {
                self = .none
            }
        }
    }

    struct FieldBundle: Decodable {
        var values: [Entity]?
        var aggregatedUsers: [User]?
    }

    struct ProjectCustomField: Decodable {
        var canBeEmpty: Bool?
        var emptyFieldText: String?
        var bundle: FieldBundle?
    }

    struct CustomField: Decodable {
        var name: String
        var type: String
        var value: Value?
        var projectCustomField: ProjectCustomField?

        enum CodingKeys: String, CodingKey {
            case name
            case type = "$type"
            case value
            case projectCustomField
        }
    }

    struct Issue: Decodable {
        var id: String
        var idReadable: String?
        var summary: String?
        var description: String?
        var created: Int64?
        var updated: Int64?
        var resolved: Int64?
        var project: Project?
        var reporter: User?
        var updater: User?
        var tags: [Tag]?
        var customFields: [CustomField]?
        var attachments: [Attachment]?
    }

    struct Attachment: Decodable {
        var id: String
        var name: String?
        var url: String?
        var thumbnailURL: String?
        var mimeType: String?
        var size: Int64?
        var removed: Bool?
    }

    struct ColorCoding: Decodable {
        var prototype: FieldReference?
    }

    struct Comment: Decodable {
        var id: String
        var text: String?
        var created: Int64?
        var deleted: Bool?
        var author: User?
    }

    struct Duration: Decodable {
        var minutes: Int?
    }

    struct WorkType: Decodable {
        var id: String
        var name: String?
    }

    struct WorkItem: Decodable {
        var id: String
        var date: Int64?
        var text: String?
        var duration: Duration?
        var author: User?
        var type: WorkType?
    }

    struct TimeTrackingSettings: Decodable {
        var enabled: Bool?
        var workItemTypes: [WorkType]?
    }

    struct SprintReference: Decodable {
        var id: String
        var name: String?
        var archived: Bool?
        var start: Int64?
        var finish: Int64?
    }

    struct Sprint: Decodable {
        var id: String
        var name: String?
        var archived: Bool?
        var start: Int64?
        var finish: Int64?
        var issues: [Issue]?
    }

    struct SprintsSettings: Decodable {
        var disableSprints: Bool?
        var isExplicit: Bool?
    }

    struct FieldReference: Decodable {
        var name: String?
    }

    struct WIPLimit: Decodable {
        var max: Int?
    }

    struct ColumnValue: Decodable {
        var name: String?
        var isResolved: Bool?
    }

    struct Column: Decodable {
        var id: String
        var presentation: String?
        var isResolved: Bool?
        var ordinal: Int?
        var wipLimit: WIPLimit?
        var fieldValues: [ColumnValue]?
    }

    struct ColumnSettings: Decodable {
        var field: FieldReference?
        var columns: [Column]?
    }

    struct Board: Decodable {
        var id: String
        var name: String?
        var projects: [Project]?
        var sprintsSettings: SprintsSettings?
        var currentSprint: SprintReference?
        var sprints: [SprintReference]?
        var columnSettings: ColumnSettings?
        var colorCoding: ColorCoding?
    }

    /// What YouTrack says when it says no.
    struct Failure: Decodable {
        var error: String?
        var errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}
