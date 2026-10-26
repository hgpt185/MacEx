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
    var phrase = ""
    var scope: String?
    var mediaType = ""
    var screenshotsOnly = false
    var limitAdded = false
    var addedFrom = Date()
    var addedTo = Date()
    var title = ""
    var pinned = true
    var message: String?
}

struct SearchSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
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
            TextField("Try: large videos in Downloads", text: $model.searchFields.phrase).textFieldStyle(.roundedBorder)
            Button("Translate to Editable Filters") { translate() }
            Text("English grammar: [large] files/videos/images/photos/audio/PDFs/documents/screenshots [in Downloads] [last week] [containing literal words]. Large means ≥100 MB. Last week uses your calendar. Downloaded files last week uses date added where available. Screenshots use system screenshot metadata.").font(.caption).foregroundStyle(.secondary)
            TextField("Search folder", text: Binding(get: { model.searchFields.scope ?? model.location.path }, set: { model.searchFields.scope = $0 })).textFieldStyle(.roundedBorder)
            Button("Use Current Folder") { model.searchFields.scope = nil }
            field("Name contains", text: $model.searchFields.name)
            field("Extension", text: $model.searchFields.fileExtension)
            Picker("Media type", selection: $model.searchFields.mediaType) {
                Text("Any").tag(""); Text("Image").tag("image"); Text("Video").tag("video"); Text("Audio").tag("audio"); Text("PDF").tag("pdf"); Text("Text").tag("text")
            }
            Toggle("Screenshots only (system metadata)", isOn: $model.searchFields.screenshotsOnly)
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
            Toggle("Date added (missing metadata excluded)", isOn: $model.searchFields.limitAdded)
            if model.searchFields.limitAdded {
                DatePicker("From", selection: $model.searchFields.addedFrom)
                DatePicker("To", selection: $model.searchFields.addedTo)
            }
            if let message = model.searchFields.message { Text(message).foregroundStyle(.orange).font(.system(size: 12)) }
            HStack {
                Button("Search Spotlight") { submit(scan: false) }.keyboardShortcut(.defaultAction)
                Button("Scan This Folder") { submit(scan: true) }
                Button("Search Local Index") { submitIndex() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Local Index uses whole-word/phrase matching and only committed checkpoints from explicitly indexed folders.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Save this search").font(.system(size: 13, weight: .semibold))
            field("Name", text: $model.searchFields.title)
            Toggle("Pin in sidebar", isOn: $model.searchFields.pinned)
            Button("Save Search") { save() }
        }.padding(22) }.frame(width: 560, height: 700)
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
        return try SearchRequest(scope: fields.scope ?? model.location.path, name: fields.name, fileExtension: fields.fileExtension, kind: fields.kind, content: fields.content,
                                 minimumBytes: try bytes(fields.minimum), maximumBytes: try bytes(fields.maximum),
                                 createdFrom: fields.limitCreated ? fields.createdFrom : nil, createdTo: fields.limitCreated ? fields.createdTo : nil,
                                 modifiedFrom: fields.limitModified ? fields.modifiedFrom : nil, modifiedTo: fields.limitModified ? fields.modifiedTo : nil,
                                 addedFrom: fields.limitAdded ? fields.addedFrom : nil, addedTo: fields.limitAdded ? fields.addedTo : nil,
                                 mediaType: fields.mediaType.isEmpty ? nil : fields.mediaType, screenshotsOnly: fields.screenshotsOnly ? true : nil).validated()
    }

    private func translate() {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let folders = Dictionary(uniqueKeysWithValues: ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"].map { ($0, home.appendingPathComponent($0).path) })
            let r = try NaturalSearch.parse(model.searchFields.phrase, scope: model.location.path, folders: folders)
            var f = model.searchFields
            f.scope = r.scope; f.name = r.name; f.fileExtension = r.fileExtension; f.kind = r.kind; f.content = r.content
            f.minimum = r.minimumBytes.map(String.init) ?? ""; f.maximum = r.maximumBytes.map(String.init) ?? ""
            f.mediaType = r.mediaType ?? ""; f.screenshotsOnly = r.screenshotsOnly == true
            f.limitModified = r.modifiedFrom != nil; f.modifiedFrom = r.modifiedFrom ?? Date(); f.modifiedTo = r.modifiedTo ?? Date()
            f.limitCreated = false; f.limitAdded = r.addedFrom != nil; f.addedFrom = r.addedFrom ?? Date(); f.addedTo = r.addedTo ?? Date()
            f.message = "Filters are ready to review and edit. No search or scan has started."
            model.searchFields = f
        } catch { model.searchFields.message = error.localizedDescription }
    }
    private func submitIndex() {
        do { let r = try request(); dismiss(); model.searchLocalIndex(r) }
        catch { model.searchFields.message = error.localizedDescription }
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
