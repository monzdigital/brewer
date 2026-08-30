import SwiftUI

/// Curated package catalog with live descriptions and install counts from formulae.brew.sh.
struct DiscoverView: View {
    @Environment(AppState.self) private var app
    @State private var selectedCategoryID: String?

    private var selectedCategory: DiscoverCategory {
        if let id = selectedCategoryID,
           let category = app.discover.categories.first(where: { $0.id == id }) {
            return category
        }
        return app.discover.allCategory
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryList
                .frame(width: 210)
            Divider()
            categoryContent
        }
        .navigationTitle("Discover")
    }

    private var categoryList: some View {
        List(selection: $selectedCategoryID) {
            Section("Categories") {
                Label("All Categories", systemImage: "square.grid.2x2")
                    .tag(Optional<String>.none as String?)
                ForEach(app.discover.categories) { category in
                    HStack {
                        Label(category.name, systemImage: category.symbol)
                        Spacer()
                        Text("\(category.items.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(category.id))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var categoryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.gradient.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: selectedCategory.symbol)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedCategory.name)
                            .font(.title.bold())
                        Text("\(selectedCategory.items.count) popular packages")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 330), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(selectedCategory.items) { item in
                        DiscoverCard(item: item)
                    }
                }
            }
            .padding(18)
        }
    }
}

private struct DiscoverCard: View {
    @Environment(AppState.self) private var app
    let item: DiscoverItem

    private var detail: DiscoverStore.ApiDetail? {
        app.discover.details[item.id]
    }

    private var installedPackage: BrewPackage? {
        app.packages.package(id: BrewPackage.makeID(kind: item.kind, name: item.token))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(item.kind == .formula
                      ? AnyShapeStyle(Color.green.gradient.opacity(0.8))
                      : AnyShapeStyle(Color.blue.gradient.opacity(0.8)))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: item.kind == .formula ? "shippingbox.fill" : "macwindow")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.token)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    TinyBadge(text: item.kind == .formula ? "CLI" : "App",
                              color: item.kind == .formula ? .green : .blue)
                }
                Text(detail?.desc ?? item.fallbackDesc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let installs = detail?.installs365d {
                    Label(Format.installsPerYear(installs), systemImage: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            if installedPackage != nil {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.top, 8)
            } else if app.console.isPending(subject: BrewPackage.makeID(kind: item.kind, name: item.token)) {
                Label("Queued", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                Button("Install") {
                    Task { await app.packages.install(name: item.token, kind: item.kind) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 6)
            }
        }
        .cardStyle()
        .onAppear {
            app.discover.loadDetailsIfNeeded(for: item)
        }
        .contextMenu {
            if let homepage = detail?.homepage, let url = URL(string: homepage) {
                Link("Open Homepage", destination: url)
            }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.token, forType: .string)
            }
        }
    }
}
