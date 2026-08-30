import SwiftUI

// MARK: - Tags

struct TagsView: View {
    @Environment(AppState.self) private var app
    @State private var selectedTag: String?

    var body: some View {
        Group {
            if app.meta.allTags.isEmpty {
                ContentUnavailableView(
                    "No tags yet",
                    systemImage: "tag",
                    description: Text("Add tags to packages from their detail pane to organize your setup - e.g. “work”, “media”, “dev-tools”.")
                )
            } else {
                HStack(spacing: 0) {
                    List(selection: $selectedTag) {
                        Section("Tags") {
                            ForEach(app.meta.allTags, id: \.self) { tag in
                                HStack {
                                    Label(tag, systemImage: "tag")
                                    Spacer()
                                    Text("\(app.meta.packageIDs(withTag: tag).count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(tag)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(width: 200)
                    Divider()
                    if let tag = selectedTag, app.meta.allTags.contains(tag) {
                        PackageBrowserView(title: "Tag: \(tag)", scope: .tag(tag))
                    } else {
                        ContentUnavailableView("Select a tag", systemImage: "tag",
                            description: Text("Choose a tag to see its packages."))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Tags")
        .onAppear {
            if selectedTag == nil { selectedTag = app.meta.allTags.first }
        }
    }
}

// MARK: - Collections

struct CollectionsView: View {
    @Environment(AppState.self) private var app
    @State private var selectedCollectionID: UUID?
    @State private var creating = false
    @State private var newName = ""
    @State private var renaming = false
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedCollectionID) {
                    Section("Collections") {
                        ForEach(app.meta.collections) { collection in
                            HStack {
                                Label(collection.name, systemImage: "rectangle.stack")
                                Spacer()
                                Text("\(collection.packageIDs.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(collection.id)
                            .contextMenu {
                                Button("Rename…") {
                                    renameText = collection.name
                                    selectedCollectionID = collection.id
                                    renaming = true
                                }
                                Button("Delete", role: .destructive) {
                                    app.meta.deleteCollection(collection.id)
                                    if selectedCollectionID == collection.id { selectedCollectionID = nil }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Button {
                        creating = true
                    } label: {
                        Label("New Collection", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .padding(8)
                    Spacer()
                }
            }
            .frame(width: 220)
            Divider()

            if let id = selectedCollectionID, app.meta.collection(id: id) != nil {
                PackageBrowserView(
                    title: app.meta.collection(id: id)?.name ?? "Collection",
                    scope: .collection(id)
                )
                .id(id)
            } else if app.meta.collections.isEmpty {
                ContentUnavailableView(
                    "No collections yet",
                    systemImage: "rectangle.stack",
                    description: Text("Group related packages - a “Web dev” kit, a “Design” setup - and act on them together. Add packages from their detail pane.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView("Select a collection", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Collections")
        .alert("New Collection", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                newName = ""
                guard !name.isEmpty else { return }
                let collection = app.meta.addCollection(named: name)
                selectedCollectionID = collection.id
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename Collection", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = selectedCollectionID {
                    app.meta.renameCollection(id, to: renameText)
                }
                renameText = ""
            }
            Button("Cancel", role: .cancel) { renameText = "" }
        }
        .onAppear {
            if selectedCollectionID == nil { selectedCollectionID = app.meta.collections.first?.id }
        }
    }
}
