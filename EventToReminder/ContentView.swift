import SwiftUI
import EventKit
import EventKitUI

struct ContentView: View {
    @State private var loading = true
    @State private var isPre: Bool = false
    @State private var events: [EKEvent] = []
    @State private var calendars: Set<EKCalendar> = []
    @State private var selectedCalendars: Set<EKCalendar> = []
    
    // State for showing the loading indicator and completion dialog
    @State private var isProcessing = false
    @State private var showCompletionAlert = false

    func getPredicate(_ eventStore: EKEventStore) -> NSPredicate {
        return eventStore.predicateForEvents(withStart: Date(), end: Date(timeIntervalSinceNow: TimeInterval(60 * 60 * 24 * 7)), calendars: nil)
    }

    func convertToColor(_ color: CGColor?) -> Color? {
        if let color {
            return Color(red: Double(color.components![0]), green: Double(color.components![1]), blue: Double(color.components![2]))
        } else {
            return nil
        }
    }

    var filteredEvents: [EKEvent] {
        if selectedCalendars.isEmpty {
            return events // No calendar is selected, show all events
        } else {
            return events.filter { event in
                if let calendar = event.calendar {
                    return selectedCalendars.contains(calendar)
                }
                return false
            }
        }
    }

    var body: some View {
        VStack {
            Text("Event to Reminder")
            
            if loading {
                ProgressView()
            } else {
                // Horizontal Scroll View for Calendar Buttons
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(calendars), id: \.hashValue) { calendar in
                            Button(action: {
                                // Toggle calendar selection
                                if selectedCalendars.contains(calendar) {
                                    selectedCalendars.remove(calendar)
                                } else {
                                    selectedCalendars.insert(calendar)
                                }
                            }) {
                                Text(calendar.title)
                                    .padding(.all, 10.0)
                                    .foregroundColor(.white)
                                    .background(convertToColor(calendar.cgColor) ?? .yellow)
                                    .cornerRadius(5)
                                    .opacity(selectedCalendars.contains(calendar) ? 1.0 : 0.5) // Highlight selected calendars
                            }
                        }
                        .padding(.vertical, 5.0)
                    }.padding(.horizontal, 10.0)
                }
                .padding(.vertical)

                // List of filtered events
                List(filteredEvents, id: \.hashValue) { event in
                        
                    
                        Text(event.title ?? "Untitled")
                        .foregroundStyle( convertToColor(event.calendar?.cgColor) ?? .gray)
                        .listRowBackground(convertToColor(event.calendar?.cgColor)?.opacity(0.25) ?? .gray)
                        
                    
                }
                Spacer()
                
                Button("Add \(filteredEvents.count) event(s) to reminders") {
                    // Start loading process
                    isProcessing = true
                    Task {
                        await addEventsToReminders()
                    }
                }
                .disabled(isProcessing)
            }
        }
        .task {
            await OnLoad()
        }
        .padding()
        .alert("Need permission to access calendar for the app to work", isPresented: $isPre) {
            Button("OK", role: .cancel) { }
        }
        .alert("Added to Reminders", isPresented: $showCompletionAlert) {
            Button("OK", role: .cancel) { }
        }
        .overlay {
            if isProcessing {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .overlay(
                        VStack {
                            ProgressView("Processing...")
                            Text("Adding events to reminders...")
                        }
                        .padding()
                        .cornerRadius(10)
                    )
            }
        }
    }

    func clearReminders(for calendar: EKCalendar, in eventStore: EKEventStore) {
        let predicate = eventStore.predicateForReminders(in: [calendar])
        eventStore.fetchReminders(matching: predicate) { reminders in
            for reminder in reminders ?? [] {
                do {
                    try eventStore.remove(reminder, commit: false)
                } catch {
                    print("Error removing reminder: \(error.localizedDescription)")
                }
            }
            do {
                try eventStore.commit()
            } catch {
                print("Error committing reminder deletions: \(error.localizedDescription)")
            }
        }
    }

    @State private var _eventStore: EKEventStore?

    func OnLoad() async {
        let eventStore = EKEventStore()
        do {
            try await eventStore.requestFullAccessToEvents()
            try await eventStore.requestFullAccessToReminders()
            let predicate = getPredicate(eventStore)
            events = eventStore.events(matching: predicate)
            while(events.filter { $0.calendar.cgColor == nil }.count != 0) {
                print("Was nil, trying again")
                try await Task.sleep(nanoseconds: 1000000000)
                events = eventStore.events(matching: predicate)
            }
            events.forEach { cal in
                if let unwrapped = cal.calendar {
                    calendars.insert(unwrapped)
                }
            }
        } catch {
            isPre = true
        }
        loading = false
        _eventStore = eventStore
    }

    func addEventsToReminders() async {
        if let eventStore = _eventStore {
            for calendar in selectedCalendars {
                // Check if a reminder list with this calendar's name already exists
                if let reminderList = eventStore.calendars(for: .reminder).first(where: { $0.title == calendar.title }) {
                    // Clear existing reminders in the list
                    clearReminders(for: reminderList, in: eventStore)
                } else {
                    // Create a new reminder list if it doesn't exist
                    let newReminderList = EKCalendar(for: .reminder, eventStore: eventStore)
                    newReminderList.title = calendar.title
                    newReminderList.source = eventStore.defaultCalendarForNewReminders()?.source
                    newReminderList.cgColor = calendar.cgColor
                
                    
                    do {
                        try eventStore.saveCalendar(newReminderList, commit: true)
                    } catch {
                        print("Error creating new reminder list: \(error.localizedDescription)")
                        return
                    }
                }
                
                // Add filtered events to the reminder list
                for event in filteredEvents.filter({ $0.calendar == calendar }).sorted(by: { event1, event2 in
                    return event1.startDate < event2.startDate
                }) {
                    let reminder = EKReminder(eventStore: eventStore)
                    reminder.title = event.title
                    reminder.calendar = eventStore.calendars(for: .reminder).first(where: { $0.title == calendar.title })
                    
                    let dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: event.startDate)
                    reminder.dueDateComponents = dueDateComponents
                    
                    do {
                        try eventStore.save(reminder, commit: false)
                    } catch {
                        print("Error saving reminder: \(error.localizedDescription)")
                    }
                }
            }
            
            do {
                try eventStore.commit()
                // Show completion dialog after committing changes
                showCompletionAlert = true
            } catch {
                print("Error committing reminder changes: \(error.localizedDescription)")
            }
        }
        // End the processing state
        isProcessing = false
    }
}

#Preview {
    ContentView()
}
