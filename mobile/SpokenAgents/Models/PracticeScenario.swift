import SwiftUI

struct PracticeScenario: Identifiable, Equatable {
  let id: String
  let title: String
  let subtitle: String
  let symbol: String
  let goal: String
  let topic: String
  let color: Color
  static let everyday = PracticeScenario(
    id: "everyday", title: "Everyday", subtitle: "Small talk, big confidence",
    symbol: "cup.and.saucer.fill", goal: "Everyday conversation", topic: "", color: .orange)
  static let all: [PracticeScenario] = [
    everyday,
    .init(
      id: "travel", title: "Travel", subtitle: "Feel at home anywhere", symbol: "airplane",
      goal: "Travel conversation", topic: "Airports, hotels, and getting around", color: .blue),
    .init(
      id: "work", title: "Work", subtitle: "Make your point clearly", symbol: "briefcase.fill",
      goal: "Workplace communication", topic: "Meetings and sharing ideas", color: .purple),
    .init(
      id: "interview", title: "Interviews", subtitle: "Tell your story well",
      symbol: "person.text.rectangle.fill", goal: "Job interview practice",
      topic: "Experience, strengths, and career goals", color: .pink),
  ]
}
