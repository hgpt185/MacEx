import SwiftUI

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    var body: some View { FileTable(model: model) }
}
