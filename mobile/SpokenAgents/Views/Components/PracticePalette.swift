import SwiftUI

enum PracticePalette {
  static let action = Color(red: 0.12, green: 0.40, blue: 0.36)
  static let accent = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.52, green: 0.82, blue: 0.74, alpha: 1)
        : UIColor(red: 0.12, green: 0.40, blue: 0.36, alpha: 1)
    })
}
