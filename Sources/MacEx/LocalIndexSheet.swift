import SwiftUI
import MacExCore

@MainActor
private final class LocalIndexFields: ObservableObject {
    @Published var content = ""
    @Published var clearConfirmation = false
}

struct LocalIndexSheet: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var model: LocalIndexModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fields = LocalIndexFields()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local OCR & Search").font(.title2).bold()
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Text stays in MacEx’s private index on this Mac. No cloud service or model download. Indexing starts only when you press Start; opening MacEx never starts a scan.")
                .font(.callout).foregroundStyle(.secondary)
            TabView {
                folders.tabItem { Text("Folders & OCR") }
                search.tabItem { Text("Search Index") }
                semantic.tabItem { Text("Related Text Experiment") }
                images.tabItem { Text("Similar Images Experiment") }
            }.disabled(!model.ready)
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
        }.padding(20).frame(width: 760, height: 670).onAppear { model.load() }
            .confirmationDialog("Clear all indexed text? Source files remain unchanged. Saved folders and settings remain.", isPresented: $fields.clearConfirmation) {
                Button("Clear Index", role: .destructive) { model.clear() }
            }
    }
    private var folders: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(model.roots, id: \.self) { root in
                    HStack {
                        Text(root).textSelection(.enabled); Spacer()
                        Button("Remove") { model.remove(root) }.disabled(model.running || model.monitoring)
                    }
                }
            }.frame(height: 110)
            HStack {
                Button("Choose Folder…") { model.addFolder() }.disabled(model.running || model.monitoring || model.roots.count >= 8)
                Text("Up to 8 non-overlapping folders").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Excluded exact names, separated by commas", text: Binding(get: { model.options.excludedNames.joined(separator: ", ") }, set: {
                model.options.excludedNames = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            })).textFieldStyle(.roundedBorder).disabled(model.running || model.monitoring)
            Text("Hidden files, packages, links and paths through links are always excluded. Exclusions match exact file or folder names.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("OCR languages (e.g. en-US)", text: Binding(get: { model.options.languages.joined(separator: ", ") }, set: {
                    model.options.languages = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                })).textFieldStyle(.roundedBorder)
                Menu("Supported Languages") { ForEach(model.languages, id: \.self) { language in Button(language) { if !model.options.languages.contains(language) { model.options.languages.append(language) } } } }
            }.disabled(model.running || model.monitoring)
            Text("Caps: 20,000 files across all folders; 100,000 entries per pass; 32 levels; 64 MiB per source; 10 PDF pages; 65,536 characters per file; ~512 MiB database. Images up to 50 megapixels use their first frame at up to 2,048 px.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Allow indexing on battery power", isOn: $model.options.allowBattery).disabled(model.running || model.monitoring)
            Toggle("Keep folders updated while this app session is active", isOn: $model.keepUpdated).disabled(model.running || model.monitoring)
            Text("Low Power Mode or serious thermal pressure pauses work. Resume repeats enumeration and reuses committed files. Folder events and a 30-minute reconciliation refresh active sessions.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Button("Start / Resume / Reconcile") { model.start() }.disabled(model.running || model.roots.isEmpty)
                Button("Pause / Stop") { model.stop() }.disabled(!model.running && !model.monitoring)
                Spacer(); Button("Clear Index…", role: .destructive) { fields.clearConfirmation = true }.disabled(model.running)
            }
        }.padding(14)
    }
    private var search: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search scope: \(browser.location.path)").font(.caption).textSelection(.enabled)
            TextField("Words in text, screenshots or PDFs", text: $fields.content).textFieldStyle(.roundedBorder)
            HStack {
                Button("Search Indexed Text") { model.search(SearchRequest(scope: browser.location.path, content: fields.content)) }.disabled(model.running || fields.content.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Use Editable Search Filters") { browser.showIndex = false; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { browser.showSearch = true } }
            }
            results
        }.padding(14)
    }
    private var semantic: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional research preview: rank related text with an installed macOS sentence embedding. This searches text and OCR transcripts, not visual meaning. No model is bundled or downloaded. Availability and quality vary by language and OS.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Enable related-text ranking for this app session", isOn: $model.semanticConsent).disabled(model.running)
            HStack {
                TextField("Describe related text", text: $model.semanticQuery).textFieldStyle(.roundedBorder)
                TextField("Language (en)", text: $model.semanticLanguage).textFieldStyle(.roundedBorder).frame(width: 100)
            }
            Text("Bounded to 1,000 scoped index records / 8 MiB of text, 4,096 characters per document, 30 seconds and 50 results. Vectors exist only during a search. Pause stops after the current embedding. No relevance threshold is assumed. CPU and process peak RAM are reported; hardware energy is not measured.").font(.caption).foregroundStyle(.secondary)
            Button("Find Related Text") { model.relatedText(scope: browser.location.path) }.disabled(model.running || !model.semanticConsent || model.semanticQuery.isEmpty)
            results
        }.padding(14)
    }
    private var images: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional research preview: compare an explicitly chosen reference image with indexed images using Vision feature prints. This is image-to-image similarity, not text-to-image search or proof of duplicate files.").font(.callout).foregroundStyle(.secondary)
            Toggle("Enable image similarity for this app session", isOn: $model.imageConsent).disabled(model.running)
            HStack {
                Button("Choose Reference Image…") { model.chooseImage() }.disabled(model.running)
                Text(model.imageReference?.lastPathComponent ?? "No reference selected").font(.caption)
            }
            Text("Caps: first 1,000 scoped index records / 8 MiB of text, 100 image comparisons, 30 seconds, 50 results; 64 MiB and 50 megapixels per source, scaled to 512 px. No model download or saved feature prints. CPU and process peak RAM are reported; hardware energy is not measured.").font(.caption).foregroundStyle(.secondary)
            Button("Find Similar Images") { model.similarImages(scope: browser.location.path) }.disabled(model.running || !model.imageConsent || model.imageReference == nil)
            results
        }.padding(14)
    }
    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.resultSummary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            List(model.documents, id: \.path) { document in
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.path).font(.callout).textSelection(.enabled)
                    Text(document.coverage).font(.caption).foregroundStyle(.secondary)
                    Text(String((document.candidate.content ?? "").prefix(180))).font(.caption).lineLimit(2)
                }
            }
            Button("Show Results in Browser") {
                browser.showIndexedResults(model.documents, summary: model.resultSummary)
                dismiss()
            }.disabled(model.running || model.documents.isEmpty)
        }
    }
}
