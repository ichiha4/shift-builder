import SwiftUI

struct PaydayPrompt: Identifiable {
    let profile: EmployerProfile
    let payDate: String
    var id: String { profile.id + payDate }
}

/// The "it's payday" banner on the Overview tab — appears the day an employer's (already
/// weekend/holiday-adjusted) payment date is today, and stays until the user records what they
/// actually received. Animates in with a spring pop plus a gently pulsing yen icon so it reads
/// as a small celebration, not just another list row.
struct PaydayBanner: View {
    let prompt: PaydayPrompt
    let onEnterPay: () -> Void
    @EnvironmentObject var notifications: NotificationLogStore
    @State private var hasAppeared = false
    @State private var iconSpin = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.green.opacity(0.18)).frame(width: 46, height: 46)
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.green)
                    .rotation3DEffect(.degrees(iconSpin ? 360 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .animation(.linear(duration: 2.5).repeatForever(autoreverses: false), value: iconSpin)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(prompt.profile.name)：給料日になりました")
                    .font(.subheadline).fontWeight(.bold)
                Text("給与を入力して、年収の残りを確認")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("入力する", action: onEnterPay)
                .font(.caption).fontWeight(.semibold)
                .buttonStyle(.borderedProminent)
                .tint(.green)
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Color.green.opacity(0.16), Color.green.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.green.opacity(0.35), lineWidth: 1)
        )
        .scaleEffect(hasAppeared ? 1 : 0.85)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { hasAppeared = true }
            iconSpin = true
            notifications.logPaydayIfNeeded(employer: prompt.profile.name, payDate: prompt.payDate)
        }
    }
}
