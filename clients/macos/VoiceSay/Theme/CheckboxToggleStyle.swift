// VSCheckboxStyle — the app's checkbox. A rounded square that fills with the
// accent and shows a checkmark when on, mirroring the tag-picker's circular
// check. Replaces the native `.checkbox` style so toggles read consistently
// on the dark surface (the native one renders a pale system square).

import SwiftUI

struct VSCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(configuration.isOn ? Tokens.accent : Color.clear)
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .stroke(configuration.isOn ? Color.clear : Tokens.borderStrong, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Tokens.bg)
                    }
                }
                .frame(width: 16, height: 16)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == VSCheckboxStyle {
    /// `.toggleStyle(.vsCheckbox)` — the app checkbox.
    static var vsCheckbox: VSCheckboxStyle { VSCheckboxStyle() }
}
