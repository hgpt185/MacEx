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
                // Back panel: saturated tone so the tab reads clearly in both appearances.
                LibraryFolderBack()
                    .fill(LinearGradient(colors: [tone.opacity(colorScheme == .dark ? 0.75 : 0.55), tone.opacity(colorScheme == .dark ? 0.55 : 0.40)],
                                         startPoint: .top, endPoint: .bottom))
                HStack(spacing: 7) { previews }
                    .padding(.horizontal, 18).padding(.top, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                // Front panel: frosted glass tinted by the tone, with a bright top edge.
                LibraryFolderFront()
                    .fill(.ultraThinMaterial)
                    .overlay { LibraryFolderFront().fill(LinearGradient(colors: [tone.opacity(colorScheme == .dark ? 0.42 : 0.30), tone.opacity(colorScheme == .dark ? 0.26 : 0.16)], startPoint: .top, endPoint: .bottom)) }
                    .overlay { LibraryFolderFront().stroke(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.35 : 0.7), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1) }
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(tone.opacity(colorScheme == .dark ? 0.85 : 0.75)))
                            .shadow(color: tone.opacity(0.35), radius: 6, y: 2)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.14)))
                    }.padding(14)
                }.accessibilityHidden(true)
            }
            .aspectRatio(1.55, contentMode: .fit)
            .clipShape(LibraryFolderBack())
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.10), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
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
