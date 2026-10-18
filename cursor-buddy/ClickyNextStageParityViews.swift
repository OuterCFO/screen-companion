import AppKit
import SwiftUI
import OCCore

struct ClickyPermissionGuideSection: View {
    var viewState: PermissionGuideAssistant.ViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewState.headline)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(viewState.summary)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 4) {
                ForEach(viewState.steps) { step in
                    HStack(spacing: 8) {
                        Image(systemName: step.systemImageName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(step.status == .granted ? DS.Colors.success : DS.Colors.warning)
                            .frame(width: 15)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                            if viewState.primaryStep?.kind == step.kind {
                                Text(step.detail)
                                    .font(.system(size: 9))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(step.status == .granted ? "Granted" : "Needed")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(step.status == .granted ? DS.Colors.success : DS.Colors.warning)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let primaryStep = viewState.primaryStep {
                Button(action: { NSWorkspace.shared.open(primaryStep.settingsURL) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                        Text("Open \(primaryStep.title)")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }
}
