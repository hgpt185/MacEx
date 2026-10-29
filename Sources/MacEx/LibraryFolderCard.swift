import SwiftUI

/// A connected folder silhouette with real previews supplied by the caller.
struct LibraryFolderCard<Previews: View>: View {
    let title: String
    let symbol: String
    let detail: String
    let tone: Color
    @ViewBuilder var previews: Previews
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                LibraryFolderBack()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        LibraryFolderBack().fill(tone.opacity(colorScheme == .dark ? 0.46 : 0.30))
                    }
                    .overlay {
                        LibraryFolderBack().stroke(tone.opacity(0.18), lineWidth: 0.75)
                    }
                HStack(spacing: 7) { previews }
                    .padding(.horizontal, 18).padding(.top, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                LibraryFolderFront()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        LibraryFolderFront().fill(LinearGradient(
                            colors: [tone.opacity(colorScheme == .dark ? 0.30 : 0.18), tone.opacity(colorScheme == .dark ? 0.18 : 0.10)],
                            startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        LibraryFolderFront().stroke(tone.opacity(colorScheme == .dark ? 0.32 : 0.22), lineWidth: 0.75)
                    }
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: symbol).font(.system(size: 26, weight: .medium))
                            .foregroundStyle(tone.opacity(colorScheme == .dark ? 0.90 : 0.72))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tone.opacity(0.65))
                    }.padding(18)
                }.accessibilityHidden(true)
            }
            .aspectRatio(1.55, contentMode: .fit)
            .clipShape(LibraryFolderBack())
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.07), radius: 4, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }.padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .contentShape(Rectangle())
    }
}

private struct LibraryFolderBack: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(14.0, rect.height * 0.10)
        let shoulder = rect.height * 0.12
        let tab = rect.width * 0.38
        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: tab - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: tab, y: shoulder * 0.45), control: CGPoint(x: tab - 3, y: 0))
        path.addLine(to: CGPoint(x: tab + shoulder * 0.65, y: shoulder))
        path.addLine(to: CGPoint(x: rect.width - radius, y: shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: shoulder + radius), control: CGPoint(x: rect.width, y: shoulder))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - radius))
        path.addQuadCurve(to: CGPoint(x: rect.width - radius, y: rect.height), control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: radius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.height - radius), control: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.closeSubpath()
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

private struct LibraryFolderFront: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: CGRect(x: rect.minX, y: rect.minY + rect.height * 0.37,
                                 width: rect.width, height: rect.height * 0.63),
             cornerRadius: min(14, rect.height * 0.10))
    }
}
