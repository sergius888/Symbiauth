// STATUS: ACTIVE
// PURPOSE: iOS lock-screen widget UI — single button that triggers AuthorizeIntent

import WidgetKit
import SwiftUI
import AppIntents

struct ArmadilloWidgetEntryView: View {
    var body: some View {
        Button(intent: AuthorizeIntent()) {
            Label("Authorize Mac", systemImage: "key.fill")
                .font(.caption)
                .fontWeight(.semibold)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
    }
}

struct ArmadilloWidget: Widget {
    let kind: String = "ArmadilloAuth"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EmptyProvider()) { _ in
            ArmadilloWidgetEntryView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Armadillo")
        .description("Tap to unlock your Mac vault.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .systemSmall
        ])
    }
}

// Minimal timeline provider — widget is stateless, no live data needed
struct EmptyProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry() }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) { completion(SimpleEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry()], policy: .never))
    }
}

struct SimpleEntry: TimelineEntry {
    let date = Date()
}
