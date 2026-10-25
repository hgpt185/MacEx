import SwiftUI
import MacExCore

struct SearchFields {
    var name = ""
    var fileExtension = ""
    var kind = ""
    var content = ""
    var minimum = ""
    var maximum = ""
    var limitModified = false
    var limitCreated = false
    var modifiedFrom = Date()
    var modifiedTo = Date()
    var createdFrom = Date()
    var createdTo = Date()
    var title = ""
    var pinned = true
    var message: String?
}

struct SearchSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search this folder").font(.system(size: 18, weight: .semibold))
            if !model.workspace.savedSearches.isEmpty {
                Menu("Saved Searches") {
                    ForEach(model.workspace.savedSearches) { search in
                        Button(search.title) { dismiss(); model.runSavedSearch(search) }
                        Button(search.pinned ? "Unpin \(search.title)" : "Pin \(search.title)") {
                            model.workspace.setSearchPinned(search.id, pinned: !search.pinned)
                        }
                    }
                }
            }
            Text(model.location.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            field("Name contains", text: $model.searchFields.name)
            field("Extension", text: $model.searchFields.fileExtension)
            field("Kind contains", text: $model.searchFields.kind)
            field("Content contains", text: $model.searchFields.content)
            HStack {
                field("Minimum bytes", text: $model.searchFields.minimum)
                field("Maximum bytes", text: $model.searchFields.maximum)
            }
            Toggle("Modified date", isOn: $model.searchFields.limitModified)
            if model.searchFields.limitModified {
                DatePicker("From", selection: $model.searchFields.modifiedFrom)
                DatePicker("To", selection: $model.searchFields.modifiedTo)
            }
            Toggle("Created date", isOn: $model.searchFields.limitCreated)
            if model.searchFields.limitCreated {
                DatePicker("From", selection: $model.searchFields.createdFrom)
                DatePicker("To", selection: $model.searchFields.createdTo)
            }
            if let message = model.searchFields.message { Text(message).foregroundStyle(.orange).font(.system(size: 12)) }
            HStack {
                Button("Search Spotlight") { submit(scan: false) }.keyboardShortcut(.defaultAction)
                Button("Scan This Folder") { submit(scan: true) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            Text("Save this search").font(.system(size: 13, weight: .semibold))
            field("Name", text: $model.searchFields.title)
            Toggle("Pin in sidebar", isOn: $model.searchFields.pinned)
            Button("Save Search") { save() }
        }.padding(22).frame(width: 460)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func request() throws -> SearchRequest {
        let fields = model.searchFields
        func bytes(_ text: String) throws -> Int64? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard let value = Int64(trimmed) else { throw FileFailure.message("Enter size limits as whole bytes.") }
            return value
        }
        return try SearchRequest(scope: model.location.path, name: fields.name, fileExtension: fields.fileExtension, kind: fields.kind, content: fields.content,
                                 minimumBytes: try bytes(fields.minimum), maximumBytes: try bytes(fields.maximum),
                                 createdFrom: fields.limitCreated ? fields.createdFrom : nil, createdTo: fields.limitCreated ? fields.createdTo : nil,
                                 modifiedFrom: fields.limitModified ? fields.modifiedFrom : nil, modifiedTo: fields.limitModified ? fields.modifiedTo : nil).validated()
    }

    private func submit(scan: Bool) {
        do {
            let request = try request()
            model.searchFields.message = nil
            dismiss()
            if scan { model.scan(request) } else { model.searchSpotlight(request) }
        } catch { model.searchFields.message = error.localizedDescription }
    }

    private func save() {
        do {
            let request = try request()
            let label = model.searchFields.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { model.searchFields.message = "Enter a name for the saved search."; return }
            model.workspace.saveSearch(SavedSearch(title: label, request: request, pinned: model.searchFields.pinned))
            model.searchFields.message = model.searchFields.pinned ? "Pinned in the sidebar." : "Saved."
        } catch { model.searchFields.message = error.localizedDescription }
    }
}
