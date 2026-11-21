import SwiftUI
import AppKit
import UserNotifications
import RetrotecaCore

/// While a Switch game's app opens: its art across the window, title, the choices it starts with, last session.
/// It goes away when the game's window takes over (Retroteca stops being the active app); Esc stops the launch.
struct LaunchOverlay: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.platea) private var colors
    let game: Game

    var body: some View {
        ZStack {
            GameArt(game: game, backdrop: true).ignoresSafeArea()
            RadialGradient(colors: [.clear, colors.bg.opacity(0.9)], center: .center, startRadius: 80, endRadius: 700).ignoresSafeArea()
            VStack(spacing: 10) {
                Kicker(text: String(localized: "AVVIO"))
                Text(game.title).font(.system(size: 48, weight: .heavy)).tracking(-0.8).foregroundStyle(.white)
                    .multilineTextAlignment(.center).shadow(color: .black.opacity(0.5), radius: 18, y: 4)
                ProgressView().progressViewStyle(.linear).tint(.white).frame(width: 260).padding(.top, 14)
                Text("Apertura dell'app Mac…").font(.system(size: 12)).foregroundStyle(colors.fg.opacity(0.85))
                if let last = game.lastPlayedAt {
                    Text(String(localized: "Ultima partita \(last.formatted(.relative(presentation: .named)))"))
                        .font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.top, 12)
                }
            }
            .padding(40)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { model.cancelLaunch() } label: {
                        HStack(spacing: 6) {
                            Text("esc").font(.system(size: 10, weight: .semibold)).foregroundStyle(colors.bg)
                                .padding(.horizontal, 6).padding(.vertical, 3).background(colors.fg, in: RoundedRectangle(cornerRadius: 5))
                            Text("Annulla").font(.system(size: 13)).foregroundStyle(colors.fg)
                        }
                    }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 40).padding(.bottom, 24)
            }
        }
        .transition(.opacity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.gameWindowAppeared()
        }
    }
}

/// A notification when a long build ends, also when Retroteca is in the background.
enum BuildNotifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
