import SwiftUI

struct PracticeCard<Content: View>: View {
  let title: String
  let symbol: String
  let content: Content
  init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.symbol = symbol
    self.content = content()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(title, systemImage: symbol).font(.headline).foregroundStyle(PracticePalette.accent)
      content
    }
    .textFieldStyle(.roundedBorder).buttonStyle(.bordered).controlSize(.large)
    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
  }
}
